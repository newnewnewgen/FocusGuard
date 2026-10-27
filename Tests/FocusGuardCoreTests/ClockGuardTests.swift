import XCTest
@testable import FocusGuardCore

final class ClockGuardTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let guardian = ClockGuard(tolerance: 120, reconvergeAfter: 24 * 3600)

    /// Wall clock = t0 + wallOffset; monotonic = mono.
    func sample(_ wallOffset: TimeInterval, _ mono: TimeInterval) -> ClockSample {
        ClockSample(wall: t0.addingTimeInterval(wallOffset), monotonic: mono)
    }
    var anchored: ClockGuard.State { guardian.step(state: nil, now: sample(0, 500)).state }

    func testFirstSampleIsTrustedAndBecomesAnchor() {
        let s = guardian.step(state: nil, now: sample(0, 500))
        XCTAssertEqual(s.trusted, t0)
        XCTAssertEqual(s.state.anchor, sample(0, 500))
        XCTAssertNil(s.state.disagreeingSince)
        XCTAssertFalse(s.tampered)
    }

    func testNormalProgressFollowsProjectionAndKeepsAnchor() {
        let s = guardian.step(state: anchored, now: sample(10, 510))
        XCTAssertEqual(s.trusted, t0.addingTimeInterval(10))
        XCTAssertFalse(s.tampered)
        XCTAssertEqual(s.state, anchored, "anchor is sticky")
    }

    func testSleepAdvancesBothClocksAndIsNotTamper() {
        let s = guardian.step(state: anchored, now: sample(7200, 7700))  // 2 h nap
        XCTAssertEqual(s.trusted, t0.addingTimeInterval(7200))
        XCTAssertFalse(s.tampered)
    }

    func testSmallDriftIsToleratedButProjectionStillWins() {
        let s = guardian.step(state: anchored, now: sample(-30, 510))
        XCTAssertEqual(s.trusted, t0.addingTimeInterval(10))
        XCTAssertFalse(s.tampered)
        XCTAssertEqual(s.state.anchor, anchored.anchor)
    }

    func testBackwardsJumpIsTamperAndKeepsProjection() {
        let s = guardian.step(state: anchored, now: sample(-3600 + 10, 510))
        XCTAssertEqual(s.trusted, t0.addingTimeInterval(10))
        XCTAssertTrue(s.tampered)
        XCTAssertEqual(s.state.disagreeingSince, 510)
    }

    func testForwardJumpIsTamperToo() {
        let s = guardian.step(state: anchored, now: sample(3600 + 10, 510))
        XCTAssertEqual(s.trusted, t0.addingTimeInterval(10), "a forward jump must not end a window early")
        XCTAssertTrue(s.tampered)
    }

    func testCreepWithinToleranceCannotAccumulate() {
        // Every 2 s tick the user sets the clock back another 119 s (just under tolerance).
        var st = anchored
        for k in 1...100 {
            let mono = 500 + Double(k) * 2
            let truth = Double(k) * 2
            let s = guardian.step(state: st, now: sample(truth - 119 * Double(k), mono))
            XCTAssertEqual(s.trusted, t0.addingTimeInterval(truth), "tick \(k)")
            st = s.state
        }
    }

    func testLegitimateCorrectionReconvergesAfterGracePeriod() {
        // Clock was 1 h fast at boot; user fixes it at mono 510.
        var st = guardian.step(state: nil, now: sample(3600, 500)).state
        var s = guardian.step(state: st, now: sample(10, 510))
        XCTAssertEqual(s.trusted, t0.addingTimeInterval(3610))
        XCTAssertTrue(s.tampered)
        st = s.state

        s = guardian.step(state: st, now: sample(10 + 23 * 3600, 510 + 23 * 3600))
        XCTAssertTrue(s.tampered, "still projecting after 23 h")
        st = s.state

        s = guardian.step(state: st, now: sample(10 + 24 * 3600, 510 + 24 * 3600))
        XCTAssertFalse(s.tampered)
        XCTAssertEqual(s.trusted, t0.addingTimeInterval(10 + 24 * 3600), "wall clock wins after 24 h")
        XCTAssertEqual(s.state.anchor, sample(10 + 24 * 3600, 510 + 24 * 3600))
        XCTAssertNil(s.state.disagreeingSince)
    }

    func testAlternatingTamperNeverReachesGracePeriod() {
        var st = anchored
        for i in 1...100 {  // every hour: flip between correct and 2 h behind
            let truth = Double(i) * 3600
            let wall = (i % 2 == 0) ? truth : truth - 7200
            let s = guardian.step(state: st, now: sample(wall, 500 + truth))
            XCTAssertEqual(s.trusted, t0.addingTimeInterval(truth), "hour \(i)")
            st = s.state
        }
    }

    func testRebootResetsAnchorToWall() {
        let s = guardian.step(state: anchored, now: sample(600, 50))  // monotonic restarted
        XCTAssertEqual(s.trusted, t0.addingTimeInterval(600))
        XCTAssertEqual(s.state.anchor, sample(600, 50))
        XCTAssertFalse(s.tampered)
    }

    func testStateRoundTripsThroughJSON() throws {
        let st = ClockGuard.State(anchor: sample(0, 500), disagreeingSince: 510)
        let data = try JSONEncoder().encode(st)
        XCTAssertEqual(try JSONDecoder().decode(ClockGuard.State.self, from: data), st)
    }
}
