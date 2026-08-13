import XCTest
import DeadlineSLO

private struct Boom: Error, Equatable {}

private actor Flag {
    private(set) var isSet = false
    func set() { isSet = true }
}

/// Behavior of the `withDeadline` backport. Timing tests use deliberately wide
/// margins (a correct implementation settles in ~0.1–0.3 s; the assertions allow up
/// to 10 s) so slow CI runners cannot produce flakes, while a broken implementation
/// — one that fails to cancel, or lets an inner deadline loosen an outer one —
/// overshoots the margin by 20 s or more and fails deterministically.
final class WithDeadlineTests: XCTestCase {

    // MARK: Completion before the deadline

    func testFastOperationReturnsItsValue() async throws {
        let value = try await withDeadline(in: .seconds(10)) { 42 }
        XCTAssertEqual(value, 42)
    }

    func testOperationErrorBeforeDeadlinePropagatesUnchanged() async {
        do {
            _ = try await withDeadline(in: .seconds(10)) { () -> Int in
                throw Boom()
            }
            XCTFail("expected Boom")
        } catch is Boom {
            // Expected: SE-0526 example 1 — the operation's own error wins.
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    // MARK: Deadline expiry

    func testSlowOperationThrowsDeadlineExceededQuickly() async {
        let clock = ContinuousClock()
        let start = clock.now
        do {
            _ = try await withDeadline(in: .milliseconds(150), stage: "net") { () -> Int in
                try await Task.sleep(for: .seconds(30))
                return 0
            }
            XCTFail("expected DeadlineExceededError")
        } catch let error as DeadlineExceededError {
            XCTAssertEqual(error.stage, "net")
        } catch {
            XCTFail("wrong error: \(error)")
        }
        // Proves the race actually cancelled the 30 s sleep: a non-cancelling
        // implementation would take ≥ 30 s and fail this bound.
        XCTAssertLessThan(start.duration(to: clock.now), .seconds(10))
    }

    func testAlreadyExpiredDeadlineNeverStartsTheOperation() async {
        let started = Flag()
        do {
            _ = try await withDeadline(Deadline(after: .milliseconds(-1))) { () -> Int in
                await started.set()
                return 0
            }
            XCTFail("expected DeadlineExceededError")
        } catch is DeadlineExceededError {
            // Expected: admission control (divergence D4).
        } catch {
            XCTFail("wrong error: \(error)")
        }
        let didStart = await started.isSet
        // An implementation that starts the operation and cancels it afterwards
        // (SE-0526's behavior, but not this library's contract) fails here.
        XCTAssertFalse(didStart)
    }

    // MARK: SE-0526 fidelity — the operation's response decides the outcome

    func testValueProducedWhileUnwindingAfterExpiryIsReturned() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        // The operation swallows cancellation and completes with a value. Per
        // SE-0526, `withDeadline` must RETURN that value, not throw. A naive
        // race that throws whenever the timer wins fails this test.
        let value = try await withDeadline(in: .milliseconds(100)) { () -> Int in
            do {
                try await Task.sleep(for: .seconds(30))
                return 1
            } catch {
                return 99
            }
        }
        XCTAssertEqual(value, 99)
        XCTAssertLessThan(start.duration(to: clock.now), .seconds(10))
    }

    func testErrorThrownWhileUnwindingAfterExpiryPropagates() async {
        do {
            _ = try await withDeadline(in: .milliseconds(100)) { () -> Int in
                do {
                    try await Task.sleep(for: .seconds(30))
                    return 1
                } catch {
                    throw Boom()
                }
            }
            XCTFail("expected Boom")
        } catch is Boom {
            // Expected: the operation's own error wins over deadline reporting.
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    // MARK: Composition — nested deadlines can only tighten

    func testInnerScopeObservesTheTighterOuterDeadline() async throws {
        let outer = Deadline(after: .seconds(5))
        let observedInstant = try await withDeadline(outer) {
            try await withDeadline(in: .seconds(3600)) {
                Deadline.current?.instant
            }
        }
        // A broken composition that lets the inner (looser) deadline replace the
        // outer one observes an instant ~1 h out and fails this equality.
        XCTAssertEqual(observedInstant, outer.instant)
    }

    func testOuterDeadlineFiresEvenInsideALooserInnerScope() async {
        let clock = ContinuousClock()
        let start = clock.now
        do {
            _ = try await withDeadline(in: .milliseconds(150), stage: "outer") { () -> Int in
                try await withDeadline(in: .seconds(3600), stage: "inner") { () -> Int in
                    try await Task.sleep(for: .seconds(30))
                    return 0
                }
            }
            XCTFail("expected DeadlineExceededError")
        } catch is DeadlineExceededError {
            // Expected.
        } catch {
            XCTFail("wrong error: \(error)")
        }
        XCTAssertLessThan(start.duration(to: clock.now), .seconds(10))
    }

    // MARK: Cancellation is not a deadline

    func testExternalCancellationSurfacesAsCancellationErrorNotDeadline() async {
        let task = Task<Int, any Error> {
            try await withDeadline(in: .seconds(30)) { () -> Int in
                try await Task.sleep(for: .seconds(30))
                return 0
            }
        }
        try? await Task.sleep(for: .milliseconds(200))
        task.cancel()

        let result = await task.result
        switch result {
        case .success:
            XCTFail("expected cancellation")
        case .failure(let error):
            // A conflating implementation reports DeadlineExceededError here and
            // fails; user abandonment must stay distinguishable from SLO violation.
            XCTAssertTrue(error is CancellationError, "expected CancellationError, got \(error)")
        }
    }

    // MARK: Task-local propagation

    func testDeadlineCurrentIsVisibleInsideTheScopeAndAbsentOutside() async throws {
        XCTAssertNil(Deadline.current)
        let observed = try await withDeadline(in: .seconds(10)) {
            Deadline.current
        }
        XCTAssertNotNil(observed)
        if let observed {
            XCTAssertLessThanOrEqual(observed.remaining(), .seconds(10))
        }
        XCTAssertNil(Deadline.current)
    }

    // MARK: checkDeadline

    func testCheckDeadlineIsANoOpWithoutAScope() {
        XCTAssertNoThrow(try checkDeadline(stage: "decode"))
    }

    func testCheckDeadlineThrowsInsideAnExpiredScope() {
        Deadline.$current.withValue(Deadline(after: .milliseconds(-1))) {
            do {
                try checkDeadline(stage: "decode")
                XCTFail("expected DeadlineExceededError")
            } catch let error as DeadlineExceededError {
                XCTAssertEqual(error.stage, "decode")
            } catch {
                XCTFail("wrong error: \(error)")
            }
        }
    }

    func testCheckDeadlinePassesInsideALiveScope() async throws {
        try await withDeadline(in: .seconds(10)) {
            try checkDeadline(stage: "decode")
        }
    }
}
