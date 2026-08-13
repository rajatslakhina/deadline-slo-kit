import XCTest
import DeadlineSLO

private actor Flag {
    private(set) var isSet = false
    func set() { isSet = true }
}

/// Pins the sharpest edge of the budget model, found in adversarial review:
/// a stage with no `cap` and no `reserveForRemainder` is granted the ENTIRE
/// remaining operation budget as its allowance. If its primary then exceeds the
/// deadline, the operation budget is exhausted at that same instant — so the
/// stage's own fallback must NOT run (running it would overrun the operation's
/// promise), and `DeadlineExceededError` must surface.
///
/// This is deliberate, documented behavior, not a bug: pipeline authors who want
/// a reachable fallback for a stage must leave that stage headroom, via
/// `reserveForRemainder` (the fallback runs inside the reserve) or `cap`.
final class UncappedStageInvariantTests: XCTestCase {

    func testUncappedStageThatExhaustsTheOperationBudgetSkipsItsFallback() async {
        let fallbackRan = Flag()
        let run = SLORun(operation: "load", budget: .milliseconds(250))
        do {
            _ = try await run.run(StageSpec(name: "inference")) { () -> Int in
                try await Task.sleep(for: .seconds(30))
                return 0
            } fallback: {
                await fallbackRan.set()
                return 1
            }
            XCTFail("expected DeadlineExceededError")
        } catch is DeadlineExceededError {
            // Expected: allowance == whole budget, so expiry leaves zero remaining.
        } catch {
            XCTFail("wrong error: \(error)")
        }
        let ran = await fallbackRan.isSet
        XCTAssertFalse(ran, "fallback must not start with zero remaining budget")

        let ledger = await run.ledger()
        XCTAssertEqual(ledger.reports.count, 1)
        XCTAssertEqual(ledger.reports.first?.outcome, .deadlineExceeded)
    }

    func testReservedStageKeepsItsFallbackReachableAfterPrimaryExpiry() async throws {
        // The constructive counterpart: reserving headroom makes the fallback
        // reachable. Primary blows its (budget − reserve) allowance; the fallback
        // then completes inside the reserve. An implementation that granted the
        // whole budget despite the reserve would fail this (fallback skipped),
        // and one that never ran primaries would record the wrong reason.
        let run = SLORun(operation: "load", budget: .seconds(30))
        let spec = StageSpec(
            name: "rerank",
            policy: StagePolicy(reserveForRemainder: .seconds(29))  // allowance ≈ 1 s
        )
        let clock = ContinuousClock()
        let start = clock.now
        let value = try await run.run(spec) { () -> Int in
            try await Task.sleep(for: .seconds(30))
            return -1
        } fallback: {
            7
        }
        XCTAssertEqual(value, 7)
        // Primary was cut at ~1 s (not the 30 s budget) and the fallback ran.
        XCTAssertLessThan(start.duration(to: clock.now), .seconds(10))

        let ledger = await run.ledger()
        XCTAssertEqual(ledger.reports.first?.outcome, .completedFallback(.primaryDeadlineExceeded))
    }
}
