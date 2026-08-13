import XCTest
import DeadlineSLO

/// Pure `Deadline` semantics — no timing races, no concurrency. These tests pin the
/// composition rules the rest of the library is built on.
final class DeadlineTests: XCTestCase {

    // MARK: earliest(_:_:)

    func testEarliestOfTwoNilsIsNil() {
        XCTAssertNil(Deadline.earliest(nil, nil))
    }

    func testEarliestWithOneSidePresentReturnsThatSide() {
        let d = Deadline(after: .seconds(1))
        XCTAssertEqual(Deadline.earliest(d, nil), d)
        XCTAssertEqual(Deadline.earliest(nil, d), d)
    }

    func testEarliestPicksTheEarlierInstant() {
        let clock = ContinuousClock()
        let now = clock.now
        let sooner = Deadline(at: now.advanced(by: .milliseconds(100)))
        let later = Deadline(at: now.advanced(by: .seconds(10)))
        XCTAssertEqual(Deadline.earliest(sooner, later), sooner)
        XCTAssertEqual(Deadline.earliest(later, sooner), sooner)
    }

    // MARK: tightened(by:)

    func testTightenedByNilReturnsSelf() {
        let d = Deadline(after: .seconds(1))
        XCTAssertEqual(d.tightened(by: nil), d)
    }

    func testTightenedCanOnlyShortenNeverExtend() {
        let clock = ContinuousClock()
        let now = clock.now
        let tight = Deadline(at: now.advanced(by: .milliseconds(100)))
        let loose = Deadline(at: now.advanced(by: .seconds(10)))

        // A loose enclosing deadline does not extend a tight one…
        XCTAssertEqual(tight.tightened(by: loose), tight)
        // …and a tight enclosing deadline shortens a loose one. A broken
        // implementation that always preferred `self` (or always preferred
        // `other`) fails one of these two assertions.
        XCTAssertEqual(loose.tightened(by: tight), tight)
    }

    // MARK: construction and clamping

    func testNegativeDurationClampsToAnAlreadyExpiredDeadline() {
        let d = Deadline(after: .milliseconds(-500))
        XCTAssertTrue(d.hasPassed())
        XCTAssertEqual(d.remaining(), .zero)
    }

    func testRemainingNeverGoesNegative() {
        let clock = ContinuousClock()
        let past = Deadline(at: clock.now.advanced(by: .milliseconds(-250)))
        XCTAssertEqual(past.remaining(clock: clock), .zero)
    }

    func testRemainingOfFutureDeadlineIsPositiveAndBounded() {
        let d = Deadline(after: .seconds(10))
        let remaining = d.remaining()
        XCTAssertGreaterThan(remaining, .zero)
        XCTAssertLessThanOrEqual(remaining, .seconds(10))
    }

    // MARK: Comparable

    func testComparableOrdersByInstant() {
        let clock = ContinuousClock()
        let now = clock.now
        let a = Deadline(at: now.advanced(by: .seconds(1)))
        let b = Deadline(at: now.advanced(by: .seconds(2)))
        XCTAssertLessThan(a, b)
        XCTAssertFalse(b < a)
    }
}
