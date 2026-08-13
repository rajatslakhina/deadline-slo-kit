import Foundation
import XCTest
import DeadlineSLO

private struct Boom: Error, Equatable {}

private actor Flag {
    private(set) var isSet = false
    func set() { isSet = true }
}

/// Thread-safe spy for observer-delivery assertions. `@unchecked Sendable` is safe
/// here because every access to `storage` is serialized through `lock`.
private final class SpyObserver: SLOObserver, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [StageReport] = []

    func stageCompleted(_ report: StageReport, operation: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(report)
    }

    var reports: [StageReport] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

final class SLORunTests: XCTestCase {

    // MARK: Happy path

    func testSequentialStagesCompleteAndLedgerRecordsThemInOrder() async throws {
        let spy = SpyObserver()
        let run = SLORun(operation: "load", budget: .seconds(30), observer: spy)

        let a = try await run.run(StageSpec(name: "cache")) { 1 }
        let b = try await run.run(StageSpec(name: "network")) { 2 }
        let c = try await run.run(StageSpec(name: "inference")) { 3 }
        XCTAssertEqual([a, b, c], [1, 2, 3])

        let ledger = await run.ledger()
        XCTAssertEqual(ledger.reports.map(\.stage), ["cache", "network", "inference"])
        XCTAssertTrue(ledger.allStagesSucceeded)
        XCTAssertFalse(ledger.degraded)
        for report in ledger.reports {
            XCTAssertEqual(report.outcome, .completedPrimary)
            XCTAssertNotNil(report.allowance)
        }
        // Remaining budget must be non-increasing across settlement order.
        let remainings = ledger.reports.map(\.remainingAfter)
        for (earlier, later) in zip(remainings, remainings.dropFirst()) {
            XCTAssertGreaterThanOrEqual(earlier, later)
        }
        // Observer saw exactly the ledger, in the same order.
        XCTAssertEqual(spy.reports, ledger.reports)
    }

    // MARK: Stage cap → fallback

    func testPrimaryExceedingItsCapFallsBackWithinBounds() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        let run = SLORun(operation: "load", budget: .seconds(30))
        let spec = StageSpec(name: "network", policy: StagePolicy(cap: .milliseconds(100)))

        let value = try await run.run(spec) { () -> Int in
            try await Task.sleep(for: .seconds(30))
            return -1
        } fallback: {
            7
        }

        XCTAssertEqual(value, 7)
        // Proves the 100 ms CAP cut the primary, not the 30 s operation budget:
        // an implementation that ignores the cap runs the primary for the full
        // 30 s budget and fails this bound.
        XCTAssertLessThan(start.duration(to: clock.now), .seconds(10))

        let ledger = await run.ledger()
        XCTAssertEqual(ledger.reports.count, 1)
        XCTAssertEqual(ledger.reports.first?.outcome, .completedFallback(.primaryDeadlineExceeded))
        XCTAssertTrue(ledger.degraded)
    }

    // MARK: Admission control

    func testInsufficientBudgetWithoutFallbackThrowsAndNeverStartsPrimary() async {
        let started = Flag()
        let run = SLORun(operation: "load", budget: .seconds(5))
        let spec = StageSpec(
            name: "inference",
            policy: StagePolicy(minimumViable: .seconds(30))
        )
        do {
            _ = try await run.run(spec) { () -> Int in
                await started.set()
                return 0
            }
            XCTFail("expected BudgetExhaustedError")
        } catch let error as BudgetExhaustedError {
            XCTAssertEqual(error.stage, "inference")
            XCTAssertEqual(error.required, .seconds(30))
            XCTAssertLessThanOrEqual(error.remaining, .seconds(5))
        } catch {
            XCTFail("wrong error: \(error)")
        }
        let didStart = await started.isSet
        XCTAssertFalse(didStart, "doomed primary must never start")

        let ledger = await run.ledger()
        XCTAssertEqual(ledger.reports.count, 1)
        if case .rejected = ledger.reports[0].outcome {
            XCTAssertNil(ledger.reports[0].allowance)
        } else {
            XCTFail("expected .rejected, got \(ledger.reports[0].outcome)")
        }
    }

    func testInsufficientBudgetWithFallbackSkipsStraightToFallback() async throws {
        let primaryStarted = Flag()
        let run = SLORun(operation: "load", budget: .seconds(5))
        let spec = StageSpec(
            name: "inference",
            policy: StagePolicy(minimumViable: .seconds(30))
        )
        let value = try await run.run(spec) { () -> Int in
            await primaryStarted.set()
            return -1
        } fallback: {
            11
        }
        XCTAssertEqual(value, 11)
        let didStart = await primaryStarted.isSet
        XCTAssertFalse(didStart)

        let ledger = await run.ledger()
        XCTAssertEqual(ledger.reports.count, 1)
        if case .completedFallback(.insufficientBudget) = ledger.reports[0].outcome {
            // Expected.
        } else {
            XCTFail("expected .completedFallback(.insufficientBudget), got \(ledger.reports[0].outcome)")
        }
    }

    // MARK: Error → fallback ladder

    func testPrimaryErrorRecoversThroughFallback() async throws {
        let run = SLORun(operation: "load", budget: .seconds(30))
        let value = try await run.run(StageSpec(name: "network")) { () -> Int in
            throw Boom()
        } fallback: {
            21
        }
        XCTAssertEqual(value, 21)

        let ledger = await run.ledger()
        if case .completedFallback(.primaryFailed) = ledger.reports[0].outcome {
            // Expected.
        } else {
            XCTFail("expected .completedFallback(.primaryFailed), got \(ledger.reports[0].outcome)")
        }
    }

    func testPrimaryErrorWithoutFallbackPropagatesAndIsRecorded() async {
        let run = SLORun(operation: "load", budget: .seconds(30))
        do {
            _ = try await run.run(StageSpec(name: "network")) { () -> Int in
                throw Boom()
            }
            XCTFail("expected Boom")
        } catch is Boom {
            // Expected.
        } catch {
            XCTFail("wrong error: \(error)")
        }
        let ledger = await run.ledger()
        if case .failed = ledger.reports[0].outcome {
            // Expected.
        } else {
            XCTFail("expected .failed, got \(ledger.reports[0].outcome)")
        }
    }

    // MARK: Cancellation is never degraded

    func testExternalCancellationDoesNotTriggerFallback() async {
        let fallbackRan = Flag()
        let run = SLORun(operation: "load", budget: .seconds(30))

        let task = Task<Int, any Error> {
            try await run.run(StageSpec(name: "network")) { () -> Int in
                try await Task.sleep(for: .seconds(30))
                return 0
            } fallback: {
                await fallbackRan.set()
                return 1
            }
        }
        try? await Task.sleep(for: .milliseconds(200))
        task.cancel()

        let result = await task.result
        switch result {
        case .success:
            XCTFail("expected cancellation")
        case .failure(let error):
            XCTAssertTrue(error is CancellationError, "expected CancellationError, got \(error)")
        }
        let degraded = await fallbackRan.isSet
        // A ladder that falls back on ANY failure would burn budget on work
        // nobody is waiting for — and fail this assertion.
        XCTAssertFalse(degraded)
    }

    // MARK: Exhausted runs

    func testZeroBudgetRunRefusesEveryStageImmediately() async {
        let started = Flag()
        let run = SLORun(operation: "load", budget: .zero)
        do {
            _ = try await run.run(StageSpec(name: "cache")) { () -> Int in
                await started.set()
                return 0
            }
            XCTFail("expected DeadlineExceededError")
        } catch let error as DeadlineExceededError {
            XCTAssertEqual(error.stage, "cache")
        } catch {
            XCTFail("wrong error: \(error)")
        }
        let didStart = await started.isSet
        XCTAssertFalse(didStart)
    }

    func testNegativeBudgetIsClampedToZeroNotTrapped() async {
        let run = SLORun(operation: "load", budget: .seconds(-5))
        let budget = run.budget
        XCTAssertEqual(budget, .zero)
        do {
            _ = try await run.run(StageSpec(name: "cache")) { 0 }
            XCTFail("expected DeadlineExceededError")
        } catch is DeadlineExceededError {
            // Expected.
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    // MARK: Stage deadline never outlives the operation deadline

    func testStageAllowanceIsTightenedByTheOperationDeadline() async throws {
        // Budget 300 ms, stage requests an uncapped allowance. If the stage
        // deadline were NOT tightened by the operation deadline, a 30 s primary
        // would run for 30 s. With tightening it is cut within the budget.
        let clock = ContinuousClock()
        let start = clock.now
        let run = SLORun(operation: "load", budget: .milliseconds(300))
        do {
            _ = try await run.run(StageSpec(name: "network")) { () -> Int in
                try await Task.sleep(for: .seconds(30))
                return 0
            }
            XCTFail("expected DeadlineExceededError")
        } catch is DeadlineExceededError {
            // Expected.
        } catch {
            XCTFail("wrong error: \(error)")
        }
        XCTAssertLessThan(start.duration(to: clock.now), .seconds(10))
    }
}
