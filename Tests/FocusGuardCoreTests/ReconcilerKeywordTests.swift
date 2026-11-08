import XCTest
@testable import FocusGuardCore

final class ReconcilerKeywordTests: XCTestCase {
    let base = "127.0.0.1 localhost\n"
    let manga = KeywordRule(text: "manga", match: .contains)
    lazy var list = BlockList(name: "l", domains: [], appBundleIDs: [], keywords: [manga])
    lazy var cfg = Config(blockLists: [list], schedules: [
        ScheduleWindow(name: "w", days: [.mon], start: TimeOfDay("09:00")!, end: TimeOfDay("12:00")!, blockListIDs: [list.id])])

    var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Vancouver")!
        return c
    }()
    func monday(_ h: Int, _ m: Int) -> Date {   // 2026-10-26 is a Monday
        cal.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: h, minute: m))!
    }

    var hosts: FakeHosts!
    var dns: FakeDNS!
    var log: FakeLog!
    var sut: Reconciler!

    override func setUp() {
        hosts = FakeHosts(base)
        dns = FakeDNS()
        log = FakeLog()
        sut = Reconciler(hosts: hosts, dns: dns, processes: FakeProcesses(), log: log, calendar: cal)
    }

    func testActiveSetIncludesLearnedNamesThatMatch() {
        let learned: Set<String> = ["mangadex.org", "comics.org"]
        XCTAssertEqual(cfg.activeSet(at: LocalMoment(weekday: .mon, minutesSinceMidnight: 600), learned: learned).domains, ["mangadex.org"])
        XCTAssertEqual(cfg.activeSet(at: LocalMoment(weekday: .mon, minutesSinceMidnight: 800), learned: learned).domains, [])
    }

    func testObserveRecordsMatchesAndTheNextTickBlocksThem() {
        _ = sut.tick(live: cfg, clock: ClockSample(wall: monday(10, 0), monotonic: 100))
        XCTAssertTrue(sut.observe(name: "mangadex.org", wall: monday(10, 0, 1)))
        XCTAssertFalse(sut.observe(name: "mangadex.org", wall: monday(10, 0, 2)), "already known")
        XCTAssertFalse(sut.observe(name: "comics.org", wall: monday(10, 0, 3)), "no rule matches")
        XCTAssertFalse(sut.observe(name: "3.1.168.192.in-addr.arpa", wall: monday(10, 0, 4)), "reverse lookups are ignored")
        XCTAssertEqual(sut.learned.names, ["mangadex.org"])
        let r = sut.tick(live: cfg, clock: ClockSample(wall: monday(10, 0, 5), monotonic: 105))
        XCTAssertEqual(r.activeSet.domains, ["mangadex.org"])
        XCTAssertTrue(hosts.contents.contains("0.0.0.0 mangadex.org"))
    }

    func testObserveLearnsOutsideTheWindowButDoesNotBlockUntilItOpens() {
        _ = sut.tick(live: cfg, clock: ClockSample(wall: monday(8, 0), monotonic: 100))
        XCTAssertTrue(sut.observe(name: "mangadex.org", wall: monday(8, 0, 1)))
        XCTAssertFalse(hosts.contents.contains("mangadex"))
        let r = sut.tick(live: cfg, clock: ClockSample(wall: monday(9, 0), monotonic: 3700))
        XCTAssertEqual(r.activeSet.domains, ["mangadex.org"])
    }

    func testObserveHonoursTheAllowListAndNeedsAConfig() {
        var allowed = cfg
        allowed.alwaysAllow = ["mangalore.in"]
        _ = sut.tick(live: allowed, clock: ClockSample(wall: monday(10, 0), monotonic: 100))
        XCTAssertFalse(sut.observe(name: "mangalore.in", wall: monday(10, 0, 1)))
        XCTAssertFalse(Reconciler(hosts: hosts, dns: dns, processes: FakeProcesses(), log: log, calendar: cal)
            .observe(name: "mangadex.org", wall: monday(10, 0, 1)), "nothing known before the first tick")
    }

    func testWatchWantedFollowsTheEffectiveConfig() {
        XCTAssertTrue(sut.tick(live: cfg, clock: ClockSample(wall: monday(14, 0), monotonic: 100)).keywordWatchWanted, "rules exist, window or not")
        var none = cfg
        none.blockLists[0].keywords = []
        XCTAssertFalse(sut.tick(live: none, clock: ClockSample(wall: monday(14, 0), monotonic: 102)).keywordWatchWanted)
    }

    func testObserveUnderAHeldProposalLearnsAgainstTheEnforcedConfig() {
        let strict = ScheduleWindow(name: "w", days: [.mon], start: TimeOfDay("09:00")!, end: TimeOfDay("12:00")!,
                                    blockListIDs: [list.id], unlockMode: .impossible)
        let accepted = Config(blockLists: [list], schedules: [strict])
        _ = sut.tick(live: accepted, clock: ClockSample(wall: monday(10, 0), monotonic: 100))
        var proposal = accepted
        proposal.blockLists[0].keywords.append(KeywordRule(text: "comic", match: .contains))
        proposal.blockLists[0].keywords.removeAll { $0.text == "manga" }
        let r = sut.tick(live: proposal, clock: ClockSample(wall: monday(10, 0, 2), monotonic: 102))
        XCTAssertEqual(r.source, .held)
        XCTAssertFalse(sut.observe(name: "comics.org", wall: monday(10, 0, 3)))
        XCTAssertTrue(sut.observe(name: "mangadex.org", wall: monday(10, 0, 4)))
    }

    func testEvictionOnlyOutsideKeywordWindows() {
        let full = LearnedNames(lastSeen: Dictionary(uniqueKeysWithValues:
            (0..<(LearnedNames.cap + 5)).map { ("site\($0).com", monday(1, 0).addingTimeInterval(Double($0))) }))
        let r = Reconciler(hosts: hosts, dns: dns, processes: FakeProcesses(), log: log, calendar: cal, learned: full)
        _ = r.tick(live: cfg, clock: ClockSample(wall: monday(10, 0), monotonic: 100))
        XCTAssertEqual(r.learned.count, LearnedNames.cap + 5, "window active: nothing evicted")
        _ = r.tick(live: cfg, clock: ClockSample(wall: monday(14, 0), monotonic: 14500))
        XCTAssertEqual(r.learned.count, LearnedNames.cap)
    }

    func testNamesRenderedLastTickSurviveTheCapEviction() {
        // mangadex.org is the oldest-seen name because /etc/hosts answers it: no lookup ever
        // refreshes it. A flood of new matches must evict the unblocked names, not the enforced one.
        var seen = Dictionary(uniqueKeysWithValues:
            (1..<LearnedNames.cap).map { ("site\($0).com", monday(1, 0).addingTimeInterval(Double($0))) })
        seen["mangadex.org"] = monday(0, 0)
        let r = Reconciler(hosts: hosts, dns: dns, processes: FakeProcesses(), log: log, calendar: cal, learned: LearnedNames(lastSeen: seen))
        _ = r.tick(live: cfg, clock: ClockSample(wall: monday(10, 0), monotonic: 100))
        XCTAssertTrue(hosts.contents.contains("0.0.0.0 mangadex.org"))
        XCTAssertTrue(r.observe(name: "mangaplus.shueisha.co.jp", wall: monday(10, 0, 1)))
        XCTAssertTrue(r.learned.names.contains("mangadex.org"), "enforced name survives")
        XCTAssertFalse(r.learned.names.contains("site1.com"), "the oldest unblocked name went instead")
        XCTAssertTrue(r.learned.names.contains("mangaplus.shueisha.co.jp"))
    }
}

private extension ReconcilerKeywordTests {
    func monday(_ h: Int, _ m: Int, _ s: Int) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: h, minute: m, second: s))!
    }
}
