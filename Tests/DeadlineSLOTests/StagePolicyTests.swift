import XCTest
import DeadlineSLO

/// The allocation function is pure math, so every case is asserted with EXACT
/// durations — a broken implementation that ignores the reserve, the cap, or the
/// minimum produces a different exact value and fails the corresponding test.
final class StagePolicyTests: XCTestCase {

    func testDefaultPolicyGrantsEverythingRemaining() {
        let policy = StagePolicy()
        XCTAssertEqual(
            policy.allocation(remaining: .milliseconds(100)),
            .run(allowance: .milliseconds(100))
        )
    }

    func testReserveIsCarvedOutOfTheAllowance() {
        let policy = StagePolicy(reserveForRemainder: .milliseconds(300))
        // 1000 − 300 = 700, exactly. An implementation that ignores the reserve
        // returns 1000 and fails here.
        XCTAssertEqual(
            policy.allocation(remaining: .milliseconds(1000)),
            .run(allowance: .milliseconds(700))
        )
    }

    func testCapBoundsTheAllowance() {
        let policy = StagePolicy(cap: .milliseconds(200))
        XCTAssertEqual(
            policy.allocation(remaining: .milliseconds(1000)),
            .run(allowance: .milliseconds(200))
        )
    }

    func testCapAndReserveComposeAsMinAfterSubtraction() {
        let policy = StagePolicy(
            reserveForRemainder: .milliseconds(300),
            cap: .milliseconds(500)
        )
        // min(1000 − 300, 500) = 500.
        XCTAssertEqual(
            policy.allocation(remaining: .milliseconds(1000)),
            .run(allowance: .milliseconds(500))
        )
    }

    func testBelowMinimumViableIsRefusedWithExactShortfall() {
        let policy = StagePolicy(minimumViable: .milliseconds(400))
        XCTAssertEqual(
            policy.allocation(remaining: .milliseconds(350)),
            .insufficient(shortfall: .milliseconds(50))
        )
    }

    func testReserveCanPushAllowanceBelowMinimumViable() {
        let policy = StagePolicy(
            minimumViable: .milliseconds(400),
            reserveForRemainder: .milliseconds(700)
        )
        // 1000 − 700 = 300 < 400 → refused, short by exactly 100.
        XCTAssertEqual(
            policy.allocation(remaining: .milliseconds(1000)),
            .insufficient(shortfall: .milliseconds(100))
        )
    }

    func testZeroRemainingIsRefused() {
        let policy = StagePolicy(minimumViable: .milliseconds(250))
        XCTAssertEqual(
            policy.allocation(remaining: .zero),
            .insufficient(shortfall: .milliseconds(250))
        )
    }

    func testNegativeRemainingIsTreatedAsZero() {
        let policy = StagePolicy()
        XCTAssertEqual(
            policy.allocation(remaining: .milliseconds(-100)),
            .insufficient(shortfall: .zero)
        )
    }

    func testZeroAllowanceIsRefusedEvenWithZeroMinimum() {
        // Reserve swallows the whole budget: allowance would be zero, and a stage
        // with zero allowance is an instant deadline — refused, not started.
        let policy = StagePolicy(reserveForRemainder: .milliseconds(100))
        XCTAssertEqual(
            policy.allocation(remaining: .milliseconds(100)),
            .insufficient(shortfall: .zero)
        )
    }

    func testNegativeInputsAreClampedAtConstruction() {
        let policy = StagePolicy(
            minimumViable: .milliseconds(-1),
            reserveForRemainder: .milliseconds(-2),
            cap: .milliseconds(-3)
        )
        XCTAssertEqual(policy.minimumViable, .zero)
        XCTAssertEqual(policy.reserveForRemainder, .zero)
        XCTAssertEqual(policy.cap, .zero)
        // A zero cap means no strictly positive allowance can ever be granted.
        XCTAssertEqual(
            policy.allocation(remaining: .seconds(1)),
            .insufficient(shortfall: .zero)
        )
    }

    // MARK: BudgetLedger arithmetic (pure, hand-built reports)

    private func report(elapsed: Duration) -> StageReport {
        StageReport(
            stage: "s",
            outcome: .completedPrimary,
            allowance: elapsed,
            elapsed: elapsed,
            remainingAfter: .zero
        )
    }

    func testSpentFractionIsExactForNormalBudgets() {
        let ledger = BudgetLedger(
            operation: "op",
            budget: .seconds(1),
            reports: [report(elapsed: .milliseconds(250))]
        )
        XCTAssertEqual(ledger.spentFraction, 0.25, accuracy: 0.001)
    }

    func testSpentFractionExceedsOneOnOverrunInsteadOfClamping() {
        let ledger = BudgetLedger(
            operation: "op",
            budget: .seconds(1),
            reports: [report(elapsed: .milliseconds(1500))]
        )
        XCTAssertEqual(ledger.spentFraction, 1.5, accuracy: 0.001)
    }

    func testSpentFractionWithZeroBudgetDoesNotDivideByZero() {
        let spentNothing = BudgetLedger(operation: "op", budget: .zero, reports: [])
        XCTAssertEqual(spentNothing.spentFraction, 0)

        let spentSomething = BudgetLedger(
            operation: "op",
            budget: .zero,
            reports: [report(elapsed: .milliseconds(5))]
        )
        XCTAssertEqual(spentSomething.spentFraction, 1)
    }

    func testDegradedFlagsOnlyFallbackOutcomes() {
        let primary = report(elapsed: .milliseconds(1))
        let fallback = StageReport(
            stage: "f",
            outcome: .completedFallback(.primaryDeadlineExceeded),
            allowance: nil,
            elapsed: .milliseconds(1),
            remainingAfter: .zero
        )
        XCTAssertFalse(
            BudgetLedger(operation: "op", budget: .seconds(1), reports: [primary]).degraded
        )
        XCTAssertTrue(
            BudgetLedger(operation: "op", budget: .seconds(1), reports: [primary, fallback]).degraded
        )
    }
}
