import XCTest
@testable import FocusGuardCore

/// Regression tests for the ways an independent review got around a daemon-enforced Impossible
/// window without a password (docs/qa/2026-11-06-independent-qa.md, second pass).
final class LockBypassTests: XCTestCase {
    let list = BlockList(name: "l", domains: ["x.com"], appBundleIDs: ["com.example.app"])
    func window(_ name: String, _ days: Set<Weekday>, _ start: String, _ end: String,
                mode: UnlockMode = .impossible, lists: [UUID]? = nil, enabled: Bool = true, id: UUID = UUID()) -> ScheduleWindow {
        ScheduleWindow(id: id, name: name, days: days, start: TimeOfDay(start)!, end: TimeOfDay(end)!,
                       blockListIDs: lists ?? [list.id], enabled: enabled, unlockMode: mode)
    }
    func at(_ day: Weekday, _ hhmm: String) -> LocalMoment {
        LocalMoment(weekday: day, minutesSinceMidnight: TimeOfDay(hhmm)!.minutesSinceMidnight)
    }
    lazy var locked = Config(blockLists: [list], schedules: [window("a", [.mon], "09:00", "12:00")])

    // MARK: B1 — duplicate IDs

    func testTwinWindowsWithOneIDCannotHideAWeakening() {
        // First copy protects nothing; the disabled second copy carries the lists. Keyed by ID,
        // the old check saw "window still active, items still there".
        let id = locked.schedules[0].id
        let twins = Config(blockLists: [list], schedules: [
            window("a", [.mon], "09:00", "12:00", lists: [], id: id),
            window("a", [.mon], "09:00", "12:00", enabled: false, id: id),
        ])
        XCTAssertTrue(twins.activeSet(at: at(.mon, "10:00")).isEmpty, "the proposal really does unblock everything")
        XCTAssertEqual(twins.weakens(from: locked, at: at(.mon, "10:00")), .impossible)
    }

    func testDuplicateWindowIDsDoNotDecode() throws {
        var twice = locked
        twice.schedules.append(locked.schedules[0])
        XCTAssertThrowsError(try Config.decodeJSON(try twice.encodeJSON()))
    }

    func testDuplicateListIDsDoNotDecode() throws {
        var twice = locked
        twice.blockLists.append(list)
        XCTAssertThrowsError(try Config.decodeJSON(try twice.encodeJSON()))
    }

    // MARK: B2 — a missing file is a proposal to block nothing

    func testDeletingTheFileDoesNotDropAFollowingImpossibleWindow() {
        let both = Config(blockLists: [list], schedules: [window("a", [.mon], "09:00", "12:00"), window("b", [.mon], "12:00", "17:00")])
        var r = ConfigResolver()
        _ = r.resolve(live: both, at: at(.mon, "10:00"), monotonic: 0)
        XCTAssertEqual(r.resolve(live: nil, at: at(.mon, "11:00"), monotonic: 3600).source, .lastGood)
        let duringB = r.resolve(live: nil, at: at(.mon, "12:30"), monotonic: 9000)
        XCTAssertEqual(duringB.source, .lastGood, "window b was not active when the file vanished, but it is Impossible")
        XCTAssertEqual(duringB.config, both)
        XCTAssertEqual(r.resolve(live: nil, at: at(.mon, "17:30"), monotonic: 27000).source, .none)
    }

    func testAMissingFileStillHonoursALaterImpossibleWindow() {
        var r = ConfigResolver()
        _ = r.resolve(live: locked, at: at(.mon, "10:00"), monotonic: 0)
        XCTAssertEqual(r.resolve(live: nil, at: at(.mon, "16:00"), monotonic: 21600).source, .none, "nothing to protect right now")
        XCTAssertEqual(r.resolve(live: nil, at: at(.mon, "10:00"), monotonic: 7 * 86400).source, .lastGood,
                       "next week's Impossible window is enforced from the accepted copy")
    }

    func testAValidEmptyConfigOutsideTheWindowRemovesTheSchedule() {
        // The legitimate way to drop an Impossible schedule: save a readable config while unlocked.
        var r = ConfigResolver()
        _ = r.resolve(live: locked, at: at(.mon, "10:00"), monotonic: 0)
        XCTAssertEqual(r.resolve(live: .empty, at: at(.mon, "16:00"), monotonic: 21600).source, .live)
        XCTAssertEqual(r.resolve(live: nil, at: at(.mon, "10:00"), monotonic: 7 * 86400).source, .none)
    }

    // MARK: B3 — size limits

    func testOversizedFileDoesNotDecode() {
        let padded = Data(#"{"version":1,"blockLists":[],"schedules":[]}"#.utf8) + Data(repeating: 0x20, count: Config.Limits.maxBytes)
        XCTAssertThrowsError(try Config.decodeJSON(padded))
    }

    func testTooManyWindowsOrItemsDoNotDecode() throws {
        var manyWindows = Config(blockLists: [list], schedules: [])
        for i in 0...Config.Limits.maxWindows { manyWindows.schedules.append(window("w\(i)", [.mon], "09:00", "10:00", mode: .basic)) }
        XCTAssertThrowsError(try Config.decodeJSON(try manyWindows.encodeJSON()))

        var manyDomains = locked
        manyDomains.blockLists[0].domains = (0...Config.Limits.maxDomains).map { "d\($0).com" }
        XCTAssertThrowsError(try Config.decodeJSON(try manyDomains.encodeJSON()))
    }

    func testTheLargestAllowedConfigIsJudgedQuickly() throws {
        // Staggered windows over a full list: the shape that took minutes before the limits.
        var big = Config(blockLists: [], schedules: [])
        let perList = Config.Limits.maxDomains / Config.Limits.maxLists
        for l in 0..<Config.Limits.maxLists {
            big.blockLists.append(BlockList(name: "l\(l)", domains: (0..<perList).map { "l\(l)d\($0).com" }, appBundleIDs: []))
        }
        let all = big.blockLists.map(\.id)
        for w in 0..<Config.Limits.maxWindows {
            let start = String(format: "%02d:%02d", w / 2, w % 2 * 30)
            big.schedules.append(window("w\(w)", Set(Weekday.allCases), start, "23:59", mode: w == 0 ? .impossible : .basic, lists: all))
        }
        XCTAssertNoThrow(try Config.decodeJSON(try big.encodeJSON()), "this is within the limits")
        var shorter = big
        shorter.schedules[0].end = TimeOfDay("23:58")!
        let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        XCTAssertEqual(shorter.weakens(from: big, at: at(.mon, "10:00")), .impossible)
        let seconds = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start) / 1e9
        XCTAssertLessThan(seconds, 3, "worst case within limits took \(seconds) s of CPU (debug build)")
    }

    func testAHeldProposalIsNotReJudgedEveryTick() {
        var r = ConfigResolver()
        _ = r.resolve(live: locked, at: at(.mon, "10:00"), monotonic: 0)
        var off = locked
        off.schedules[0].enabled = false
        for tick in 1...5 { XCTAssertEqual(r.resolve(live: off, at: at(.mon, "10:00"), monotonic: Double(tick) * 2).source, .held) }
        XCTAssertEqual(r.verdictsComputed, 1, "same proposal, same minute: one judgement")
        _ = r.resolve(live: off, at: at(.mon, "10:01"), monotonic: 60)
        XCTAssertEqual(r.verdictsComputed, 2)
    }

    // MARK: B4 — locks longer than a day

    func testALockLongerThanADayCannotBeCutShort() {
        // Gapless from Saturday 00:00 to Sunday 23:59 (the bridge covers the 23:59 minute).
        let weekend = Config(blockLists: [list], schedules: [
            window("sat", [.sat], "00:00", "23:59"), window("bridge", [.sat], "23:00", "01:00"), window("sun", [.sun], "00:00", "23:59"),
        ])
        var cut = weekend
        cut.schedules[2].end = TimeOfDay("10:00")!   // 24 h from "now"
        XCTAssertEqual(cut.weakens(from: weekend, at: at(.sat, "10:00")), .impossible)
        var r = ConfigResolver()
        _ = r.resolve(live: weekend, at: at(.sat, "10:00"), monotonic: 0)
        XCTAssertEqual(r.resolve(live: cut, at: at(.sat, "10:00"), monotonic: 2).source, .held)
    }

    func testAnAlwaysOnImpossibleScheduleCanNeverBeWeakened() {
        let always = Config(blockLists: [list], schedules: [
            window("day", Set(Weekday.allCases), "00:00", "23:59"), window("bridge", Set(Weekday.allCases), "23:00", "01:00"),
        ])
        var fewer = always
        fewer.schedules[0].days.remove(.fri)
        XCTAssertEqual(fewer.weakens(from: always, at: at(.mon, "10:00")), .impossible, "Friday is four days away and still protected")
    }
}
