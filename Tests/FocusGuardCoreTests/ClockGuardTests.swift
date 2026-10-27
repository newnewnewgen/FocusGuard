import XCTest
@testable import FocusGuardCore

final class ClockGuardTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let guardian = ClockGuard(tolerance: 120)

    func testFirstSampleIsTrusted() {
        let s = ClockSample(wall: t0, monotonic: 500)
        XCTAssertEqual(guardian.trustedNow(previous: nil, current: s), t0)
    }

    func testNormalProgressIsTrusted() {
        let prev = ClockSample(wall: t0, monotonic: 500)
        let now = ClockSample(wall: t0.addingTimeInterval(10), monotonic: 510)
        XCTAssertEqual(guardian.trustedNow(previous: prev, current: now), t0.addingTimeInterval(10))
    }

    func testSmallDriftWithinToleranceIsTrusted() {
        let prev = ClockSample(wall: t0, monotonic: 500)
        let now = ClockSample(wall: t0.addingTimeInterval(-30), monotonic: 510)  // NTP nudged back 40s
        XCTAssertEqual(guardian.trustedNow(previous: prev, current: now), t0.addingTimeInterval(-30))
    }

    func testBackwardsJumpUsesProjectedTime() {
        let prev = ClockSample(wall: t0, monotonic: 500)
        let now = ClockSample(wall: t0.addingTimeInterval(-3600), monotonic: 510)  // user set clock back 1h
        XCTAssertEqual(guardian.trustedNow(previous: prev, current: now), t0.addingTimeInterval(10))
    }

    func testForwardJumpIsTrusted() {
        // Sleep: monotonic (continuous) and wall both advance; a forward-only wall jump is also fine.
        let prev = ClockSample(wall: t0, monotonic: 500)
        let now = ClockSample(wall: t0.addingTimeInterval(7200), monotonic: 510)
        XCTAssertEqual(guardian.trustedNow(previous: prev, current: now), t0.addingTimeInterval(7200))
    }

    func testProjectionPersistsAcrossTicksUntilClockIsRestored() {
        // The caller stores the *trusted* time as `previous`, so the projection keeps advancing.
        var prev = ClockSample(wall: t0, monotonic: 500)
        let tick1 = ClockSample(wall: t0.addingTimeInterval(-3600 + 2), monotonic: 502)
        let trusted1 = guardian.trustedNow(previous: prev, current: tick1)
        XCTAssertEqual(trusted1, t0.addingTimeInterval(2))
        prev = ClockSample(wall: trusted1, monotonic: tick1.monotonic)

        let tick2 = ClockSample(wall: t0.addingTimeInterval(-3600 + 4), monotonic: 504)
        XCTAssertEqual(guardian.trustedNow(previous: prev, current: tick2), t0.addingTimeInterval(4))

        // Clock restored: wall agrees with projection again.
        prev = ClockSample(wall: t0.addingTimeInterval(4), monotonic: 504)
        let tick3 = ClockSample(wall: t0.addingTimeInterval(6), monotonic: 506)
        XCTAssertEqual(guardian.trustedNow(previous: prev, current: tick3), t0.addingTimeInterval(6))
    }
}
