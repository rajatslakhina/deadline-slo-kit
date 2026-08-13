//
//  DeadlineErrors.swift
//  DeadlineSLO
//
//  Typed failures for deadline and budget violations. Both errors are Hashable value
//  types carrying enough diagnostic context to answer the on-call question that
//  actually matters: *which stage* blew the budget, and by how much.
//

/// Thrown when an operation's deadline expires before the operation completes,
/// or when an operation is asked to start after its deadline has already passed.
public struct DeadlineExceededError: Error, Sendable, Hashable, CustomStringConvertible {
    /// The named stage that was executing when the deadline expired, if known.
    public let stage: String?

    /// How far past the deadline the violation was observed. Clamped to zero at
    /// every construction site in this library; never negative by convention.
    public let exceededBy: Duration

    public init(stage: String? = nil, exceededBy: Duration = .zero) {
        self.stage = stage
        self.exceededBy = exceededBy
    }

    public var description: String {
        let location = stage.map { " in stage '\($0)'" } ?? ""
        return "Deadline exceeded\(location) (observed \(exceededBy.milliphrase) past the deadline)"
    }
}

/// Thrown when a stage cannot even *start*: the remaining budget is below the stage's
/// declared minimum-viable allowance and no fallback path is available.
///
/// This is admission control, the client-side analogue of a server rejecting a request
/// whose propagated deadline has no chance of being met — failing fast is cheaper than
/// starting work that is guaranteed to be thrown away.
public struct BudgetExhaustedError: Error, Sendable, Hashable, CustomStringConvertible {
    /// The stage that was refused admission.
    public let stage: String

    /// The stage's declared minimum-viable allowance.
    public let required: Duration

    /// The budget that was actually left when admission was evaluated.
    public let remaining: Duration

    public init(stage: String, required: Duration, remaining: Duration) {
        self.stage = stage
        self.required = required
        self.remaining = remaining
    }

    public var description: String {
        "Budget exhausted before stage '\(stage)': requires \(required.milliphrase), only \(remaining.milliphrase) remaining"
    }
}

extension Duration {
    /// Seconds as a `Double`. Safe: pure floating-point arithmetic; both components
    /// are `Int64`-family integers whose `Double` conversions are always finite, so
    /// the result is always finite. No trapping integer conversions on this path.
    var secondsDouble: Double {
        Double(components.seconds) + Double(components.attoseconds) * 1e-18
    }

    /// A short human-readable milliseconds phrase for diagnostics, e.g. "150.0 ms".
    ///
    /// Deliberately avoids `Int(Double)` — which traps on NaN/infinity/out-of-range —
    /// and avoids Foundation's `String(format:)` to keep the library dependency-free.
    /// Formatting only; never used for arithmetic or control flow.
    var milliphrase: String {
        let milliseconds = secondsDouble * 1000
        let clamped = min(max(milliseconds, -1e15), 1e15)
        let rounded = (clamped * 10).rounded() / 10
        return "\(rounded) ms"
    }
}
