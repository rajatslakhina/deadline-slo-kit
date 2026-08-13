//
//  Deadline.swift
//  DeadlineSLO
//
//  An absolute point on the continuous (monotonic) clock by which work must finish.
//
//  Why absolute instants and not durations: durations do not compose across call
//  boundaries. If a caller has 800 ms left and passes "500 ms" to a child, the child
//  cannot know whether that allowance is still honest after its own queueing delays.
//  An absolute deadline survives any number of hops unchanged — every layer can ask
//  "how much time is actually left?" against the same fixed point. This is the same
//  reasoning behind gRPC deadline propagation and Swift Evolution's accepted
//  SE-0526 `withDeadline` proposal.
//

/// An absolute point in time, on the continuous clock, by which an operation must complete.
///
/// `Deadline` is deliberately tied to `ContinuousClock`: a monotonic clock that never
/// jumps backwards and keeps advancing while the process is running. Wall-clock time
/// (`Date`) is unsuitable for deadlines because NTP adjustments and user changes can
/// move it arbitrarily.
///
/// Trade-off (documented, not hidden): `ContinuousClock` also keeps advancing while a
/// device is asleep. A deadline that spans a suspension will typically have expired on
/// wake. For user-facing SLO budgets — the intended use of this library — that is the
/// desired behavior: a "render this screen in 800 ms" promise made before suspension is
/// meaningless after it. A `SuspendingClock`-based variant was considered and rejected
/// for v1 to keep the task-local propagation model to a single concrete clock type.
public struct Deadline: Sendable, Hashable, Comparable, CustomStringConvertible {
    /// The instant at which this deadline expires.
    public let instant: ContinuousClock.Instant

    /// Creates a deadline that expires at the given instant.
    public init(at instant: ContinuousClock.Instant) {
        self.instant = instant
    }

    /// Creates a deadline `duration` from now.
    ///
    /// Negative durations are clamped to zero, producing an already-expired deadline
    /// rather than trapping or wrapping.
    public init(after duration: Duration, clock: ContinuousClock = ContinuousClock()) {
        self.instant = clock.now.advanced(by: max(.zero, duration))
    }

    /// The time remaining until this deadline, clamped to zero once it has passed.
    ///
    /// Never returns a negative duration, so callers can use the result directly as a
    /// budget without re-clamping.
    public func remaining(clock: ContinuousClock = ContinuousClock()) -> Duration {
        max(.zero, clock.now.duration(to: instant))
    }

    /// Whether this deadline has already expired.
    public func hasPassed(clock: ContinuousClock = ContinuousClock()) -> Bool {
        clock.now >= instant
    }

    /// Returns the tighter of `self` and `other`.
    ///
    /// Composition rule: a nested scope may only *shorten* the time available, never
    /// extend it. `nil` means "no enclosing deadline", so `self` is returned unchanged.
    public func tightened(by other: Deadline?) -> Deadline {
        guard let other else { return self }
        return other.instant < instant ? other : self
    }

    /// The earlier of two optional deadlines; `nil` only when both are `nil`.
    public static func earliest(_ lhs: Deadline?, _ rhs: Deadline?) -> Deadline? {
        switch (lhs, rhs) {
        case (nil, nil):
            return nil
        case (let l?, nil):
            return l
        case (nil, let r?):
            return r
        case (let l?, let r?):
            return l.instant <= r.instant ? l : r
        }
    }

    public static func < (lhs: Deadline, rhs: Deadline) -> Bool {
        lhs.instant < rhs.instant
    }

    public var description: String {
        "Deadline(at: \(instant))"
    }
}

extension Deadline {
    /// The deadline governing the current structured-concurrency scope, if any.
    ///
    /// Bound by ``withDeadline(_:stage:clock:operation:)`` and inherited by child tasks,
    /// so any layer — a cache, a network client, an inference wrapper — can check the
    /// remaining budget without threading a parameter through every signature.
    @TaskLocal public static var current: Deadline?
}
