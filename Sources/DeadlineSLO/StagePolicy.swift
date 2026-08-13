//
//  StagePolicy.swift
//  DeadlineSLO
//
//  Per-stage budget policy — the layer SE-0526 deliberately does not provide.
//  `withDeadline` answers "cancel this work at instant X". A multi-stage user
//  operation (cache → network → inference → render prep) additionally needs to
//  answer: how much of the remaining budget may THIS stage consume, what must be
//  left for the stages after it, and below what allowance is starting the stage
//  pointless? That is what `StagePolicy` encodes, as pure data with a pure
//  allocation function — fully unit-testable with no clocks and no concurrency.
//

/// Declares how a single stage may draw from an operation's remaining time budget.
public struct StagePolicy: Sendable, Hashable {
    /// Below this allowance the stage is not worth starting at all (its result would
    /// arrive too late to matter, or its cost is front-loaded). Admission control
    /// refuses the stage instead of starting doomed work. Zero means "any strictly
    /// positive allowance is acceptable".
    public var minimumViable: Duration

    /// Time that must be *left over* for later stages after this stage's allowance
    /// is carved out. This is how an early, greedy stage (network) is prevented from
    /// starving a mandatory late stage (on-device inference fallback, render prep).
    public var reserveForRemainder: Duration

    /// An absolute ceiling on this stage's allowance, independent of how much budget
    /// remains. `nil` means uncapped.
    public var cap: Duration?

    /// All negative inputs are clamped to zero at construction — a policy can never
    /// be constructed into a trapping or nonsensical state.
    public init(
        minimumViable: Duration = .zero,
        reserveForRemainder: Duration = .zero,
        cap: Duration? = nil
    ) {
        self.minimumViable = max(.zero, minimumViable)
        self.reserveForRemainder = max(.zero, reserveForRemainder)
        self.cap = cap.map { max(.zero, $0) }
    }

    /// The admission decision for a stage, given the operation's remaining budget.
    public enum Allocation: Sendable, Hashable {
        /// Start the stage with at most `allowance` of the budget.
        case run(allowance: Duration)
        /// Do not start the stage; `shortfall` is how much additional budget would
        /// have been needed to reach `minimumViable` (zero when the failure is
        /// "no strictly positive allowance left" with a zero minimum).
        case insufficient(shortfall: Duration)
    }

    /// Pure allocation math: what may this stage spend, given `remaining` budget?
    ///
    /// Order of application: clamp `remaining` to zero → subtract the reserve →
    /// apply the cap → refuse unless the result is strictly positive and at least
    /// `minimumViable`. A stage always needs a strictly positive allowance; running
    /// a stage with a zero allowance is an instant deadline and therefore refused.
    public func allocation(remaining: Duration) -> Allocation {
        let remaining = max(.zero, remaining)
        var allowance = max(.zero, remaining - reserveForRemainder)
        if let cap {
            allowance = min(allowance, cap)
        }
        guard allowance > .zero, allowance >= minimumViable else {
            return .insufficient(shortfall: max(.zero, minimumViable - allowance))
        }
        return .run(allowance: allowance)
    }
}

/// A named stage plus its budget policy. Purely descriptive; the execution engine
/// is ``SLORun``.
public struct StageSpec: Sendable, Hashable {
    public var name: String
    public var policy: StagePolicy

    public init(name: String, policy: StagePolicy = StagePolicy()) {
        self.name = name
        self.policy = policy
    }
}
