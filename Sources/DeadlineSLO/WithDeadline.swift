//
//  WithDeadline.swift
//  DeadlineSLO
//
//  A today-usable backport of the deadline-scoping primitive Swift Evolution accepted
//  as SE-0526 (`withDeadline`), for Swift 6.0 toolchains that predate it.
//
//  Semantics preserved from SE-0526, in order of load-bearing-ness:
//
//  1. STRUCTURED. The operation runs as a child task. When the deadline fires, the
//     operation is *cancelled and awaited* — `withDeadline` never abandons running
//     work, never leaks a task, and may return later than the deadline if the
//     operation is slow to acknowledge cancellation. Expiry is cooperative
//     cancellation, not preemption.
//
//  2. THE OPERATION'S RESPONSE DECIDES THE OUTCOME. Exactly as SE-0526 specifies:
//     if the deadline fires but the operation still completes with a value while
//     unwinding, that value is returned; if it throws its own error, that error
//     propagates. Only when the operation answers cancellation with a bare
//     `CancellationError` do we report deadline expiry.
//
//  3. COMPOSABLE — MIN OF NESTED DEADLINES. A nested `withDeadline` cannot extend
//     an enclosing one. Composition emerges the same way as in SE-0526 — each scope
//     races independently, so the earliest deadline cancels first — and is
//     additionally short-circuited here via the `Deadline.current` task-local
//     (see divergence D3).
//
//  4. CANCELLATION IS NOT A DEADLINE. If the surrounding task is cancelled, callers
//     see `CancellationError`, not `DeadlineExceededError`. The two conditions demand
//     different handling upstream (a user-abandoned UI flow is not an SLO violation)
//     and conflating them poisons error-rate metrics.
//
//  Documented divergences — each forced by a language/runtime feature Swift 6.0
//  does not have, not chosen casually:
//
//  D1. DISTINCT ERROR TYPE. SE-0526 reports expiry as `CancellationError` with a new
//      `reason: .deadlineExpired` field, added to the standard library's resilient
//      Concurrency module. A package cannot retrofit stored properties onto
//      `CancellationError`, so this backport throws `DeadlineExceededError` instead —
//      the design SE-0526 rejected for the standard library is the only design
//      available to a library.
//
//  D2. `@escaping @Sendable` OPERATION. SE-0526's closure is non-escaping and
//      `nonisolated(nonsending)`, so it can touch actor-isolated state. That relies
//      on SE-0461 caller's-executor semantics (Swift 6.2+). Running the operation as
//      a task-group child on Swift 6.0 requires escaping + Sendable. This is the
//      backport tax; call sites inside actors must hop through Sendable state.
//
//  D3. TASK-LOCAL CURRENT DEADLINE. SE-0526 exposes the active deadline via runtime
//      accessors (`Task.activeDeadline(for:)`) that only the standard library can
//      implement. The `Deadline.current` task-local is this library's stand-in, and
//      is also what the SLO budget layer reads to answer "how much time is left?".
//
//  D4. ADMISSION CONTROL. If the effective deadline has already passed, the
//      operation closure is never invoked; SE-0526 would start it cancelled. For the
//      SLO-budget use case, refusing provably-doomed work is the point, so the
//      stricter behavior is deliberate here.
//

private enum DeadlineRace<T: Sendable>: Sendable {
    case finished(T)
    case deadlineElapsed
}

/// Runs `operation` under an absolute deadline, cancelling it if the deadline expires
/// first.
///
/// The effective deadline is `deadline` tightened by any enclosing scope's deadline
/// (`Deadline.current`), and is published to `Deadline.current` for the duration of
/// the operation so nested code can observe its remaining budget.
///
/// - Parameters:
///   - deadline: The latest instant by which `operation` should complete.
///   - stage: Optional label included in thrown `DeadlineExceededError`s.
///   - tolerance: Scheduling tolerance for the expiry timer, as in SE-0526.
///   - clock: The clock to sleep on. Injectable for tests; the same continuous clock
///     family `Deadline` is defined against.
///   - operation: The work to perform; runs as a child task.
/// - Returns: The operation's result — including a result produced while unwinding
///   after expiry, matching SE-0526.
/// - Throws: `DeadlineExceededError` when the deadline expired and the operation
///   acknowledged cancellation; `CancellationError` when the surrounding task was
///   cancelled; otherwise whatever `operation` throws.
public func withDeadline<T: Sendable>(
    _ deadline: Deadline,
    stage: String? = nil,
    tolerance: Duration? = nil,
    clock: ContinuousClock = ContinuousClock(),
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let effective = deadline.tightened(by: Deadline.current)

    // D4: never start work whose deadline has already passed.
    let now = clock.now
    guard effective.instant > now else {
        throw DeadlineExceededError(
            stage: stage,
            exceededBy: max(.zero, effective.instant.duration(to: now))
        )
    }

    return try await Deadline.$current.withValue(effective) {
        try await withThrowingTaskGroup(of: DeadlineRace<T>.self) { group in
            group.addTask {
                .finished(try await operation())
            }
            group.addTask {
                // Throws CancellationError when the group cancels it (operation won
                // the race, or the surrounding task was cancelled).
                try await clock.sleep(until: effective.instant, tolerance: tolerance)
                return .deadlineElapsed
            }

            defer { group.cancelAll() }

            // Phase 1: first child to finish. If it throws, that is either the
            // operation's own pre-deadline error (propagate, per SE-0526) or a
            // CancellationError from external cancellation (propagate — semantic 4).
            guard let first = try await group.next() else {
                // Unreachable: the group was just populated with two children.
                // Non-trapping safety net per this library's no-crash policy.
                throw CancellationError()
            }

            switch first {
            case .finished(let value):
                return value

            case .deadlineElapsed:
                // Phase 2: the timer won. Cancel the operation and await its
                // response — the response decides the outcome (semantic 2).
                group.cancelAll()
                do {
                    if let second = try await group.next(),
                       case .finished(let value) = second {
                        return value
                    }
                    // No second result (unreachable) — report plain expiry.
                    throw DeadlineExceededError(
                        stage: stage,
                        exceededBy: max(.zero, effective.instant.duration(to: clock.now))
                    )
                } catch let error as DeadlineExceededError {
                    // A nested scope already diagnosed expiry; its (inner, more
                    // precise) stage label wins. Rethrow unchanged.
                    throw error
                } catch is CancellationError {
                    // The operation acknowledged cancellation. If the *surrounding*
                    // task was itself cancelled, report that truthfully; otherwise
                    // this is the backport's stand-in for SE-0526's
                    // CancellationError(reason: .deadlineExpired).
                    if Task.isCancelled {
                        throw CancellationError()
                    }
                    throw DeadlineExceededError(
                        stage: stage,
                        exceededBy: max(.zero, effective.instant.duration(to: clock.now))
                    )
                }
                // Any other error thrown by the operation while unwinding
                // propagates via the do-catch fallthrough (rethrows from `next()`).
            }
        }
    }
}

/// Runs `operation` with a deadline `duration` from now — SE-0526's `in:` shorthand.
/// Identical semantics to the absolute form.
public func withDeadline<T: Sendable>(
    in duration: Duration,
    stage: String? = nil,
    tolerance: Duration? = nil,
    clock: ContinuousClock = ContinuousClock(),
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withDeadline(
        Deadline(after: duration, clock: clock),
        stage: stage,
        tolerance: tolerance,
        clock: clock,
        operation: operation
    )
}

/// Admission-control checkpoint: throws `DeadlineExceededError` if the current
/// scope's deadline has already passed.
///
/// Sprinkle at the top of expensive synchronous sections (decode loops, image
/// resizing, serialization) the same way a server handler checks a propagated
/// request deadline before each costly step. No-op when no deadline is in scope.
public func checkDeadline(
    stage: String? = nil,
    clock: ContinuousClock = ContinuousClock()
) throws {
    guard let current = Deadline.current else { return }
    let now = clock.now
    if now >= current.instant {
        throw DeadlineExceededError(
            stage: stage,
            exceededBy: max(.zero, current.instant.duration(to: now))
        )
    }
}
