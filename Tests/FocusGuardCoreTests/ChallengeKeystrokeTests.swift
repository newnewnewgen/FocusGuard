import XCTest
@testable import FocusGuardCore

final class ChallengeKeystrokeTests: XCTestCase {
    func testTypingOneCharacterIsAKeystroke() {
        XCTAssertTrue(Challenge.isSingleKeystroke(from: "", to: "a"))
        XCTAssertTrue(Challenge.isSingleKeystroke(from: "abou", to: "about"))
        XCTAssertTrue(Challenge.isSingleKeystroke(from: "abut", to: "about"), "insert in the middle")
    }

    func testDeletingIsAKeystroke() {
        XCTAssertTrue(Challenge.isSingleKeystroke(from: "about", to: "abou"))
        XCTAssertTrue(Challenge.isSingleKeystroke(from: "about above", to: ""), "select all, delete")
        XCTAssertTrue(Challenge.isSingleKeystroke(from: "about", to: "about"), "no change")
    }

    func testTypingOverASelectionIsAKeystroke() {
        XCTAssertTrue(Challenge.isSingleKeystroke(from: "about above", to: "about x"))
        XCTAssertTrue(Challenge.isSingleKeystroke(from: "junk", to: "a"))
    }

    func testPasteIsNotAKeystroke() {
        XCTAssertFalse(Challenge.isSingleKeystroke(from: "", to: "about above"))
        XCTAssertFalse(Challenge.isSingleKeystroke(from: "abo", to: "about"))
    }

    func testPasteOverASelectionOfTheSameLengthIsNotAKeystroke() {
        // The bypass the old "grew by more than one" check allowed: type junk, select all, paste.
        let sentence = "about above across after again"
        let junk = String(repeating: "j", count: sentence.count)
        XCTAssertFalse(Challenge.isSingleKeystroke(from: junk, to: sentence))
        XCTAssertFalse(Challenge.isSingleKeystroke(from: junk + "jjjj", to: sentence), "even when it gets shorter")
        XCTAssertFalse(Challenge.isSingleKeystroke(from: "about XXXXX across", to: "about above across"))
    }
}

final class ProtectedAppsTests: XCTestCase {
    func testProtectedAppsNeverEnterTheActiveSet() {
        let list = BlockList(name: "l", domains: [], appBundleIDs: ["com.apple.finder", "com.apple.Finder", "com.focusguard.app", "com.apple.Chess"])
        let window = ScheduleWindow(name: "w", days: [.mon], start: TimeOfDay("09:00")!, end: TimeOfDay("12:00")!, blockListIDs: [list.id])
        let config = Config(blockLists: [list], schedules: [window])
        XCTAssertEqual(config.activeSet(at: LocalMoment(weekday: .mon, minutesSinceMidnight: 600)).bundleIDs, ["com.apple.Chess"])
    }
}

final class DaemonStatusTests: XCTestCase {
    let wall = Date(timeIntervalSince1970: 1_000_000)

    func testNoOffsetIsPublishedWhileTheClocksAgree() {
        // Inside the guard's tolerance trusted and wall differ slightly; publishing that would
        // rewrite status.json for no reason.
        XCTAssertEqual(DaemonStatus.publishedOffset(trusted: wall.addingTimeInterval(37), wall: wall, tampered: false), 0)
    }

    func testOffsetIsRoundedWhenTheClockWasChanged() {
        XCTAssertEqual(DaemonStatus.publishedOffset(trusted: wall.addingTimeInterval(-7198.6), wall: wall, tampered: true), -7200)
        XCTAssertEqual(DaemonStatus.publishedOffset(trusted: wall.addingTimeInterval(3602), wall: wall, tampered: true), 3600)
    }

    func testRoundTripsThroughJSON() throws {
        let status = DaemonStatus(pid: 42, source: .held, clockOffsetSeconds: -7200, clockTampered: true)
        let data = try JSONEncoder().encode(status)
        XCTAssertEqual(try JSONDecoder().decode(DaemonStatus.self, from: data), status)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"held\""))
    }
}
