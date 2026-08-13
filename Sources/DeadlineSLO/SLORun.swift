//
//  SLORun.swift
//  DeadlineSLO
//
//  The execution engine: one SLORun represents one user-facing operation with one
//  absolute deadline, executing named stages under per-stage policies, recording an
//  auditable ledger of where the budget actually went.
//
//  Degradation ladder for each stage, in order:
//    1. Admission — if the stage's policy refuses the remaining budget, the primary
//       never starts. With a fallback: run the fallback. Without: throw
//       `BudgetExhaustedError`.
//    2. Primary under a stage deadline — allowance carved from the remaining budget,
//       tightened by the operation-wide deadline (a stage can never outlive the
//       operation).
//    3. Fallback on primary failure — a primary that exceeds its stage deadline or
//       throws falls back (if a fallback exists and any budget remains), running
//       under the operation-wide deadline.
//    4. Cancellation is never absorbed — if the surrounding task is cancelled, the
//       error propagates immediately; the fallback is NOT attempted. Degrading on
//       user-abandonment would burn budget on work nobody is waiting for.
//

/// Receives a `StageReport` the moment each stage settles. Implementations must be
/// fast and non-blocking — the callback is invoked synchronously on the actor.
/// Forward to your metrics pipeline (os_signpost, MetricKit, an analytics queue)
/// rather than doing I/O inline.
public protocol SLOObserver: Sendable {
    func stageCompleted(_ report: StageReport, operation: String)
}

/// How a single stage settled, with the timing evidence.
public struct StageReport: Sendable, Hashable {
    /// Why a fallback ran instead of (or after) the primary.
    public enum FallbackReason: Sendable, Hashable {
        /// The policy refused to start the primary: remaining budget was below
        /// `minimumViable` by `shortfall`.
        case insufficientBudget(shortfall: Duration)
        /// The primary started but exceeded its stage deadline.
        case primaryDeadlineExceeded
        /// The primary threw a non-deadline, non-cancellation error.
        case primaryFailed(description: String)
    }

    public enum Outcome: Sendable, Hashable {
        /// The primary completed within its allowance.
        case completedPrimary
        /// The fallback completed; the reason records why the primary didn't.
        case completedFallback(FallbackReason)
        /// Admission refused the primary and no fallback was available.
        /// `BudgetExhaustedError` was thrown.
        case rejected(shortfall: Duration)
        /// The stage (primary, and fallback if any) exceeded the deadline.
        /// `DeadlineExceededError` was thrown.
        case deadlineExceeded
        /// The stage failed with an ordinary error (including cancellation of the
        /// surrounding task, recorded as "cancelled").
        case failed(description: String)
    }

    public let stage: String
    public let outcome: Outcome
    /// The allowance the policy granted the primary; `nil` when the primary was
    /// never admitted.
    public let allowance: Duration?
    /// Wall time this stage consumed, measured on the run's clock.
    public let elapsed: Duration
    /// Operation budget left after this stage settled.
    public let remainingAfter: Duration

    public init(
        stage: String,
        outcome: Outcome,
        allowance: Duration?,
        elapsed: Duration,
        remainingAfter: Duration
    ) {
        self.stage = stage
        self.outcome = outcome
        self.allowance = allowance
        self.elapsed = elapsed
        self.remainingAfter = remainingAfter
    }

    /// Whether the stage produced a value (primary or fallback).
    public var isSuccess: Bool {
        switch outcome {
        case .completedPrimary, .completedFallback:
            return true
        case .rejected, .deadlineExceeded, .failed:
            return false
        }
    }
}

/// The auditable record of one operation: which stages ran, in what order they
/// settled, what each consumed, and what was left afterwards.
public struct BudgetLedger: Sendable, Hashable {
    public let operation: String
    public let budget: Duration
    public let reports: [StageReport]

    public init(operation: String, budget: Duration, reports: [StageReport]) {
        self.operation = operation
        self.budget = max(.zero, budget)
        self.reports = reports
    }

    /// Sum of per-stage elapsed times. Can legitimately exceed `budget` when the
    /// final stage overran while acknowledging cancellation.
    public var totalElapsed: Duration {
        reports.reduce(.zero) { $0 + $1.elapsed }
    }

    /// Fraction of the budget consumed, as a `Double` in `[0, ∞)`. Safe against a
    /// zero budget (returns 1 when anything was spent against a zero budget, else 0).
    /// May exceed 1.0 on overrun — clamp at the display layer if needed.
    public var spentFraction: Double {
        let budgetSeconds = budget.secondsDouble
        let spentSeconds = max(0, totalElapsed.secondsDouble)
        guard budgetSeconds > 0 else {
            return spentSeconds > 0 ? 1 : 0
        }
        return spentSeconds / budgetSeconds
    }

    /// True when every recorded stage produced a value.
    public var allStagesSucceeded: Bool {
        reports.allSatisfy(\.isSuccess)
    }

    /// True when at least one stage settled via its fallback path.
    public var degraded: Bool {
        reports.contains { report in
            if case .completedFallback = report.outcome { return true }
            return false
        }
    }
}

/// One user-facing operation executing under one absolute deadline.
///
/// Create an `SLORun` per operation (per navigation, per refresh, per query), then
/// execute stages through ``run(_:primary:fallback:)``. The run's deadline is fixed
/// at initialization: `budget` from `clock.now`. Stages are intended to be executed
/// sequentially from a single task. Concurrent `run` calls on the same instance are
/// memory-safe (actor isolation) and their budget math stays correct — allowances
/// always derive from the immutable deadline and the clock — but ledger entries are
/// appended in settlement order, which is the honest order for an audit trail.
public actor SLORun {
    // Immutable, Sendable state is nonisolated so callers (and other modules) can
    // read it synchronously without an actor hop.
    public nonisolated let operation: String
    public nonisolated let budget: Duration
    public nonisolated let deadline: Deadline

    private nonisolated let clock: ContinuousClock
    private let observer: (any SLOObserver)?
    private var reports: [StageReport] = []

    /// - Parameters:
    ///   - operation: Diagnostic name, e.g. `"product-page-load"`.
    ///   - budget: Total time allowed for all stages together. Negative values are
    ///     clamped to zero (an already-exhausted run that refuses all stages).
    ///   - observer: Optional per-stage telemetry hook.
    ///   - clock: Injectable for tests.
    public init(
        operation: String,
        budget: Duration,
        observer: (any SLOObserver)? = nil,
        clock: ContinuousClock = ContinuousClock()
    ) {
        let clamped = max(.zero, budget)
        self.operation = operation
        self.budget = clamped
        self.clock = clock
        self.observer = observer
        self.deadline = Deadline(after: clamped, clock: clock)
    }

    /// Budget remaining right now, clamped to zero.
    public nonisolated var remaining: Duration {
        deadline.remaining(clock: clock)
    }

    /// Snapshot of the ledger so far.
    public func ledger() -> BudgetLedger {
        BudgetLedger(operation: operation, budget: budget, reports: reports)
    }

    /// Executes one stage under this run's budget.
    ///
    /// - Parameters:
    ///   - spec: The stage's name and budget policy.
    ///   - primary: The preferred implementation. Runs under a stage deadline equal
    ///     to the policy's allowance, tightened by the operation deadline.
    ///   - fallback: Optional degraded implementation (smaller model, cached value,
    ///     placeholder). Runs under the operation-wide deadline when the primary is
    ///     refused admission, exceeds its stage deadline, or throws.
    ///
    ///     Reachability caveat (deliberate, and pinned by a test): a stage with no
    ///     `cap` and no `reserveForRemainder` is granted the entire remaining
    ///     budget, so when its primary expires there is nothing left and the
    ///     fallback is skipped. A stage that wants a reachable fallback after
    ///     primary expiry must leave itself headroom via `reserveForRemainder`
    ///     (the fallback then runs inside the reserve) or `cap`.
    /// - Returns: The primary's or fallback's value.
    /// - Throws: `BudgetExhaustedError` when admission is refused and no fallback
    ///   exists; `DeadlineExceededError` when the deadline expires without recovery;
    ///   `CancellationError` immediately if the surrounding task is cancelled;
    ///   otherwise the underlying stage error.
    public func run<T: Sendable>(
        _ spec: StageSpec,
        primary: @escaping @Sendable () async throws -> T,
        fallback: (@Sendable () async throws -> T)? = nil
    ) async throws -> T {
        let started = clock.now
        let remainingAtStart = deadline.remaining(clock: clock)

        // Operation-wide deadline already blown: refuse regardless of policy.
        guard remainingAtStart > .zero else {
            record(stage: spec.name, outcome: .deadlineExceeded, allowance: nil, started: started)
            throw DeadlineExceededError(
                stage: spec.name,
                exceededBy: max(.zero, deadline.instant.duration(to: clock.now))
            )
        }

        switch spec.policy.allocation(remaining: remainingAtStart) {
        case .run(let allowance):
            let stageDeadline = Deadline(after: allowance, clock: clock).tightened(by: deadline)
            do {
                let value = try await withDeadline(
                    stageDeadline,
                    stage: spec.name,
                    clock: clock,
                    operation: primary
                )
                record(stage: spec.name, outcome: .completedPrimary, allowance: allowance, started: started)
                return value
            } catch is CancellationError {
                // Ladder rule 4: never degrade on cancellation.
                record(
                    stage: spec.name,
                    outcome: .failed(description: "cancelled"),
                    allowance: allowance,
                    started: started
                )
                throw CancellationError()
            } catch let error as DeadlineExceededError {
                return try await recover(
                    spec: spec,
                    allowance: allowance,
                    started: started,
                    reason: .primaryDeadlineExceeded,
                    fallback: fallback,
                    upstream: error
                )
            } catch {
                return try await recover(
                    spec: spec,
                    allowance: allowance,
                    started: started,
                    reason: .primaryFailed(description: String(describing: error)),
                    fallback: fallback,
                    upstream: error
                )
            }

        case .insufficient(let shortfall):
            guard let fallback else {
                record(stage: spec.name, outcome: .rejected(shortfall: shortfall), allowance: nil, started: started)
                throw BudgetExhaustedError(
                    stage: spec.name,
                    required: spec.policy.minimumViable,
                    remaining: remainingAtStart
                )
            }
            return try await runFallback(
                spec: spec,
                allowance: nil,
                started: started,
                reason: .insufficientBudget(shortfall: shortfall),
                fallback: fallback
            )
        }
    }

    // MARK: - Private

    /// Primary failed (deadline or error): attempt the fallback if one exists and
    /// any budget remains; otherwise record and rethrow the primary's error.
    private func recover<T: Sendable>(
        spec: StageSpec,
        allowance: Duration,
        started: ContinuousClock.Instant,
        reason: StageReport.FallbackReason,
        fallback: (@Sendable () async throws -> T)?,
        upstream: any Error
    ) async throws -> T {
        guard let fallback, deadline.remaining(clock: clock) > .zero else {
            let outcome: StageReport.Outcome
            if upstream is DeadlineExceededError {
                outcome = .deadlineExceeded
            } else {
                outcome = .failed(description: String(describing: upstream))
            }
            record(stage: spec.name, outcome: outcome, allowance: allowance, started: started)
            throw upstream
        }
        return try await runFallback(
            spec: spec,
            allowance: allowance,
            started: started,
            reason: reason,
            fallback: fallback
        )
    }

    private func runFallback<T: Sendable>(
        spec: StageSpec,
        allowance: Duration?,
        started: ContinuousClock.Instant,
        reason: StageReport.FallbackReason,
        fallback: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        do {
            let value = try await withDeadline(
                deadline,
                stage: "\(spec.name) (fallback)",
                clock: clock,
                operation: fallback
            )
            record(
                stage: spec.name,
                outcome: .completedFallback(reason),
                allowance: allowance,
                started: started
            )
            return value
        } catch is CancellationError {
            record(
                stage: spec.name,
                outcome: .failed(description: "cancelled"),
                allowance: allowance,
                started: started
            )
            throw CancellationError()
        } catch let error as DeadlineExceededError {
            record(stage: spec.name, outcome: .deadlineExceeded, allowance: allowance, started: started)
            throw error
        } catch {
            record(
                stage: spec.name,
                outcome: .failed(description: String(describing: error)),
                allowance: allowance,
                started: started
            )
            throw error
        }
    }

    private func record(
        stage: String,
        outcome: StageReport.Outcome,
        allowance: Duration?,
        started: ContinuousClock.Instant
    ) {
        let report = StageReport(
            stage: stage,
            outcome: outcome,
            allowance: allowance,
            elapsed: max(.zero, started.duration(to: clock.now)),
            remainingAfter: deadline.remaining(clock: clock)
        )
        reports.append(report)
        observer?.stageCompleted(report, operation: operation)
    }
}
