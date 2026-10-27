# FocusGuard Core + Daemon Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A SwiftPM package containing `FocusGuardCore` (pure, fully unit-tested enforcement logic) and `focusguardd` (a root launchd daemon that blocks domains via `/etc/hosts` and kills apps by bundle ID on a weekly schedule), installable by hand and verified end-to-end on this Mac.

**Architecture:** All decisions live in `FocusGuardCore` behind injected protocols (clock, hosts file, DNS flusher, process list), so every scenario — window enter/exit, clock rewind, config vanishing, kill escalation — is a plain XCTest with fakes. The daemon is a thin shell: real implementations of those protocols plus a 2-second timer and SIGTERM handling. Spec: `docs/superpowers/specs/2026-08-18-focusguard-design.md`. The user-session app (menu bar, `SMAppService` install, tab watcher) is **Plan 2** and is out of scope here.

**Tech Stack:** Swift 5 language mode on the Swift 6.2 toolchain (`swift-tools-version: 5.10` to avoid strict-concurrency friction), SwiftPM, XCTest, Foundation, Darwin libproc, `os.Logger`, launchd. No third-party dependencies.

**Decisions this plan locks in (resolving spec §9):**
- Reconcile tick is **2 s while an app block is active, 30 s otherwise** (battery). `/etc/hosts` is only *written* on diff, and the process list is only enumerated while some bundle ID is actually blocked, so outside windows the daemon does one 1 KB file read every 30 s and nothing else. Timers use generous leeway so the kernel can coalesce wake-ups. This also makes "reconcile on wake" automatic (next tick after wake). Event-driven `NSWorkspace` kill is deferred to the Plan 2 app, which lives in the user session where those notifications are reliable.
- Hosts region emits both `0.0.0.0` and `::` lines so AAAA lookups are blocked too.
- Config dir `/Library/Application Support/FocusGuard/` is `root:admin 0775`; `config.json` is `0664` (admin user can write, root reads); `last-good.json` is root-only `0600`.
- Processes are enumerated with libproc (works as root without a window server), bundle ID resolved from the **last** `.app/` in the executable path so helper bundles are never matched by their parent's ID.

---

## File structure

```
FocusGuard/
├── Package.swift
├── Sources/
│   ├── FocusGuardCore/
│   │   ├── Models.swift          Weekday, TimeOfDay, BlockList, ScheduleWindow, Config (+ JSON)
│   │   ├── Domains.swift         DomainNormalizer
│   │   ├── Schedule.swift        LocalMoment, ScheduleWindow.isActive
│   │   ├── ActiveSet.swift       ActiveSet, Config.activeSet(at:)
│   │   ├── HostsRegion.swift     render / apply / strip of the marked region
│   │   ├── ClockGuard.swift      ClockSample, ClockGuard.step (sticky anchor, persisted State)
│   │   ├── ConfigResolver.swift  bounded fail-closed policy
│   │   ├── Ports.swift           protocols: HostsFileStore, DNSCacheFlusher, ProcessController, ReconcilerLog
│   │   └── Reconciler.swift      one tick = converge the system to the active set
│   └── focusguardd/
│       ├── main.swift            `run` / `once` / `check` subcommands
│       ├── Daemon.swift          timer loop, signals, wiring
│       ├── Paths.swift           config / last-good / log paths
│       ├── ConfigFile.swift      load config, save/load last-good, ensure dir perms
│       ├── SystemClock.swift     ClockSample from Date + mach_continuous_time
│       ├── EtcHostsStore.swift   atomic read/write of /etc/hosts
│       ├── DSCacheFlusher.swift  dscacheutil + mDNSResponder HUP
│       ├── LibprocProcessController.swift
│       └── OSLogAdapter.swift    ReconcilerLog → os.Logger
├── Tests/FocusGuardCoreTests/
│   ├── ModelsTests.swift
│   ├── DomainsTests.swift
│   ├── ScheduleTests.swift
│   ├── ActiveSetTests.swift
│   ├── HostsRegionTests.swift
│   ├── ClockGuardTests.swift
│   ├── ConfigResolverTests.swift
│   ├── Fakes.swift
│   └── ReconcilerTests.swift
├── launchd/com.focusguard.daemon.plist
├── scripts/install-daemon.sh
├── scripts/uninstall-daemon.sh
├── examples/config.json
└── README.md
```

---

### Task 1: Package skeleton

**Files:**
- Create: `Package.swift`
- Create: `Sources/FocusGuardCore/Models.swift` (placeholder, filled in Task 2)
- Create: `Sources/focusguardd/main.swift` (placeholder, filled in Task 11)
- Create: `Tests/FocusGuardCoreTests/ModelsTests.swift` (placeholder, filled in Task 2)
- Modify: `.gitignore`

- [ ] **Step 1: Write Package.swift**

```swift
// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "FocusGuard",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FocusGuardCore", targets: ["FocusGuardCore"]),
        .executable(name: "focusguardd", targets: ["focusguardd"]),
    ],
    targets: [
        .target(name: "FocusGuardCore"),
        .executableTarget(name: "focusguardd", dependencies: ["FocusGuardCore"]),
        .testTarget(name: "FocusGuardCoreTests", dependencies: ["FocusGuardCore"]),
    ]
)
```

- [ ] **Step 2: Create placeholder sources so the package builds**

`Sources/FocusGuardCore/Models.swift`:
```swift
import Foundation
```

`Sources/focusguardd/main.swift`:
```swift
import Foundation
print("focusguardd: not implemented yet")
```

`Tests/FocusGuardCoreTests/ModelsTests.swift`:
```swift
import XCTest
@testable import FocusGuardCore

final class ModelsTests: XCTestCase {
    func testPackageBuilds() { XCTAssertTrue(true) }
}
```

- [ ] **Step 3: Update .gitignore**

Append to `.gitignore`:
```
.build/
*.xcodeproj
.swiftpm/
DerivedData/
```

- [ ] **Step 4: Build and test**

Run: `swift test 2>&1 | tail -5`
Expected: `Test Suite 'All tests' passed` with 1 test.

- [ ] **Step 5: Commit**

```bash
git add Package.swift Sources Tests .gitignore
git commit -m "Scaffold SwiftPM package: FocusGuardCore, focusguardd, tests

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: Config models + JSON round-trip

**Files:**
- Modify: `Sources/FocusGuardCore/Models.swift`
- Modify: `Tests/FocusGuardCoreTests/ModelsTests.swift`

- [ ] **Step 1: Write the failing tests**

Replace `Tests/FocusGuardCoreTests/ModelsTests.swift`:
```swift
import XCTest
@testable import FocusGuardCore

final class ModelsTests: XCTestCase {
    func testTimeOfDayParsesHHmm() {
        XCTAssertEqual(TimeOfDay("09:30"), TimeOfDay(hour: 9, minute: 30))
        XCTAssertEqual(TimeOfDay("09:30")?.minutesSinceMidnight, 570)
        XCTAssertEqual(TimeOfDay(hour: 9, minute: 5)?.string, "09:05")
    }

    func testTimeOfDayRejectsGarbage() {
        XCTAssertNil(TimeOfDay("25:00"))
        XCTAssertNil(TimeOfDay("09:60"))
        XCTAssertNil(TimeOfDay("9"))
        XCTAssertNil(TimeOfDay("nine"))
        XCTAssertNil(TimeOfDay(hour: -1, minute: 0))
    }

    func testTimeOfDayIsComparable() {
        XCTAssertLessThan(TimeOfDay("08:00")!, TimeOfDay("08:01")!)
    }

    func testWeekdayFromCalendarAndPrevious() {
        XCTAssertEqual(Weekday(calendarWeekday: 1), .sun)
        XCTAssertEqual(Weekday(calendarWeekday: 2), .mon)
        XCTAssertEqual(Weekday(calendarWeekday: 7), .sat)
        XCTAssertEqual(Weekday.mon.previous, .sun)
        XCTAssertEqual(Weekday.sun.previous, .sat)
    }

    func testConfigRoundTripsThroughJSON() throws {
        let list = BlockList(name: "Social", domains: ["reddit.com"], appBundleIDs: ["com.tinyspeck.slackmacgap"])
        let window = ScheduleWindow(
            name: "Deep work", days: [.mon, .tue], start: TimeOfDay("09:00")!, end: TimeOfDay("12:00")!,
            blockListIDs: [list.id], enabled: true)
        let config = Config(blockLists: [list], schedules: [window])

        let data = try config.encodeJSON()
        let decoded = try Config.decodeJSON(data)

        XCTAssertEqual(decoded, config)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"start\" : \"09:00\""), "time encodes as HH:mm string, got:\n\(text)")
    }

    func testDecodeRejectsBadTime() {
        let json = """
        {"version":1,"blockLists":[],"schedules":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"x","days":["mon"],"start":"99:00","end":"10:00","blockListIDs":[],"enabled":true}]}
        """
        XCTAssertThrowsError(try Config.decodeJSON(Data(json.utf8)))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test 2>&1 | grep -E "error|Executed" | head`
Expected: compile errors — `TimeOfDay`, `Weekday`, `BlockList` etc. not found.

- [ ] **Step 3: Implement the models**

Replace `Sources/FocusGuardCore/Models.swift`:
```swift
import Foundation

public enum Weekday: String, Codable, CaseIterable, Hashable {
    case mon, tue, wed, thu, fri, sat, sun

    /// `Calendar.component(.weekday)` is 1 = Sunday … 7 = Saturday.
    public init(calendarWeekday: Int) {
        switch calendarWeekday {
        case 1: self = .sun
        case 2: self = .mon
        case 3: self = .tue
        case 4: self = .wed
        case 5: self = .thu
        case 6: self = .fri
        default: self = .sat
        }
    }

    public var previous: Weekday {
        let all = Weekday.allCases
        let i = all.firstIndex(of: self)!
        return all[(i + all.count - 1) % all.count]
    }
}

/// A local wall-clock time of day, encoded in JSON as "HH:mm".
public struct TimeOfDay: Hashable, Comparable, Codable {
    public let hour: Int
    public let minute: Int

    public init?(hour: Int, minute: Int) {
        guard (0..<24).contains(hour), (0..<60).contains(minute) else { return nil }
        self.hour = hour
        self.minute = minute
    }

    public init?(_ string: String) {
        let parts = string.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        self.init(hour: h, minute: m)
    }

    public var minutesSinceMidnight: Int { hour * 60 + minute }
    public var string: String { String(format: "%02d:%02d", hour, minute) }

    public static func < (a: TimeOfDay, b: TimeOfDay) -> Bool {
        a.minutesSinceMidnight < b.minutesSinceMidnight
    }

    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let t = TimeOfDay(s) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Bad time \"\(s)\", expected HH:mm"))
        }
        self = t
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(string)
    }
}

public struct BlockList: Codable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var domains: [String]
    public var appBundleIDs: [String]

    public init(id: UUID = UUID(), name: String, domains: [String] = [], appBundleIDs: [String] = []) {
        self.id = id
        self.name = name
        self.domains = domains
        self.appBundleIDs = appBundleIDs
    }
}

public struct ScheduleWindow: Codable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var days: Set<Weekday>
    public var start: TimeOfDay
    public var end: TimeOfDay
    public var blockListIDs: [UUID]
    public var enabled: Bool

    public init(id: UUID = UUID(), name: String, days: Set<Weekday>, start: TimeOfDay, end: TimeOfDay,
                blockListIDs: [UUID], enabled: Bool = true) {
        self.id = id
        self.name = name
        self.days = days
        self.start = start
        self.end = end
        self.blockListIDs = blockListIDs
        self.enabled = enabled
    }
}

public struct Config: Codable, Equatable {
    public static let currentVersion = 1

    public var version: Int
    public var blockLists: [BlockList]
    public var schedules: [ScheduleWindow]

    public init(version: Int = Config.currentVersion, blockLists: [BlockList] = [], schedules: [ScheduleWindow] = []) {
        self.version = version
        self.blockLists = blockLists
        self.schedules = schedules
    }

    public static let empty = Config()

    public func encodeJSON() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(self)
    }

    public static func decodeJSON(_ data: Data) throws -> Config {
        try JSONDecoder().decode(Config.self, from: data)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test 2>&1 | grep -E "error|failed|Executed"`
Expected: `Executed 6 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Sources/FocusGuardCore/Models.swift Tests/FocusGuardCoreTests/ModelsTests.swift
git commit -m "Core: config models with HH:mm time encoding and JSON round-trip

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: Domain normalization

Users will type `https://www.Reddit.com/r/foo` into a block list. The hosts file needs `reddit.com`.

**Files:**
- Create: `Sources/FocusGuardCore/Domains.swift`
- Create: `Tests/FocusGuardCoreTests/DomainsTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import FocusGuardCore

final class DomainsTests: XCTestCase {
    func testLowercasesAndTrims() {
        XCTAssertEqual(DomainNormalizer.normalize("  Reddit.COM "), "reddit.com")
    }

    func testStripsSchemePathAndPort() {
        XCTAssertEqual(DomainNormalizer.normalize("https://reddit.com/r/foo?x=1"), "reddit.com")
        XCTAssertEqual(DomainNormalizer.normalize("http://reddit.com:8080"), "reddit.com")
    }

    func testStripsLeadingWwwAndTrailingDot() {
        XCTAssertEqual(DomainNormalizer.normalize("www.reddit.com"), "reddit.com")
        XCTAssertEqual(DomainNormalizer.normalize("reddit.com."), "reddit.com")
    }

    func testKeepsOtherSubdomains() {
        XCTAssertEqual(DomainNormalizer.normalize("old.reddit.com"), "old.reddit.com")
    }

    func testEmptyStaysEmpty() {
        XCTAssertEqual(DomainNormalizer.normalize("   "), "")
        XCTAssertEqual(DomainNormalizer.normalize("https://"), "")
    }

    func testHostMatchesDomainOrSubdomain() {
        XCTAssertTrue(DomainNormalizer.host("old.reddit.com", isUnder: "reddit.com"))
        XCTAssertTrue(DomainNormalizer.host("reddit.com", isUnder: "reddit.com"))
        XCTAssertFalse(DomainNormalizer.host("notreddit.com", isUnder: "reddit.com"))
        XCTAssertFalse(DomainNormalizer.host("reddit.com.evil.io", isUnder: "reddit.com"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter DomainsTests 2>&1 | grep -E "error|Executed" | head -3`
Expected: compile error, `DomainNormalizer` not found.

- [ ] **Step 3: Implement**

`Sources/FocusGuardCore/Domains.swift`:
```swift
import Foundation

public enum DomainNormalizer {
    /// "https://www.Reddit.com/r/x" → "reddit.com". Returns "" for input with no host.
    public static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let r = s.range(of: "://") { s = String(s[r.upperBound...]) }
        if let i = s.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) { s = String(s[..<i]) }
        if let i = s.firstIndex(of: ":") { s = String(s[..<i]) }
        while s.hasSuffix(".") { s.removeLast() }
        if s.hasPrefix("www.") { s.removeFirst(4) }
        return s
    }

    /// True when `host` equals `domain` or is a subdomain of it. Both must already be normalized.
    public static func host(_ host: String, isUnder domain: String) -> Bool {
        host == domain || host.hasSuffix("." + domain)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter DomainsTests 2>&1 | grep -E "failed|Executed"`
Expected: `Executed 6 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Sources/FocusGuardCore/Domains.swift Tests/FocusGuardCoreTests/DomainsTests.swift
git commit -m "Core: domain normalization and subdomain matching

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: Schedule matching (incl. windows that cross midnight)

**Files:**
- Create: `Sources/FocusGuardCore/Schedule.swift`
- Create: `Tests/FocusGuardCoreTests/ScheduleTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import FocusGuardCore

final class ScheduleTests: XCTestCase {
    private func window(days: Set<Weekday>, _ start: String, _ end: String, enabled: Bool = true) -> ScheduleWindow {
        ScheduleWindow(name: "w", days: days, start: TimeOfDay(start)!, end: TimeOfDay(end)!, blockListIDs: [], enabled: enabled)
    }
    private func at(_ day: Weekday, _ hhmm: String) -> LocalMoment {
        LocalMoment(weekday: day, minutesSinceMidnight: TimeOfDay(hhmm)!.minutesSinceMidnight)
    }

    func testInsideWindowOnListedDay() {
        let w = window(days: [.mon], "09:00", "12:00")
        XCTAssertTrue(w.isActive(at: at(.mon, "09:00")))
        XCTAssertTrue(w.isActive(at: at(.mon, "11:59")))
    }

    func testEndIsExclusive() {
        let w = window(days: [.mon], "09:00", "12:00")
        XCTAssertFalse(w.isActive(at: at(.mon, "12:00")))
    }

    func testOutsideHoursOrWrongDay() {
        let w = window(days: [.mon], "09:00", "12:00")
        XCTAssertFalse(w.isActive(at: at(.mon, "08:59")))
        XCTAssertFalse(w.isActive(at: at(.tue, "10:00")))
    }

    func testDisabledNeverActive() {
        let w = window(days: [.mon], "09:00", "12:00", enabled: false)
        XCTAssertFalse(w.isActive(at: at(.mon, "10:00")))
    }

    func testCrossesMidnightBelongsToStartDay() {
        // Friday 22:00 → 02:00 means Fri night into Sat morning.
        let w = window(days: [.fri], "22:00", "02:00")
        XCTAssertTrue(w.isActive(at: at(.fri, "23:30")))
        XCTAssertTrue(w.isActive(at: at(.sat, "01:59")))
        XCTAssertFalse(w.isActive(at: at(.sat, "02:00")))
        XCTAssertFalse(w.isActive(at: at(.sat, "23:30")), "Saturday night is not listed")
        XCTAssertFalse(w.isActive(at: at(.fri, "01:00")), "Friday early morning is Thursday's night")
    }

    func testZeroLengthWindowNeverActive() {
        let w = window(days: [.mon], "09:00", "09:00")
        XCTAssertFalse(w.isActive(at: at(.mon, "09:00")))
    }

    func testLocalMomentFromDate() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Vancouver")!
        // 2026-10-27 is a Tuesday.
        let date = cal.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: 14, minute: 7))!
        let m = LocalMoment(date: date, calendar: cal)
        XCTAssertEqual(m, LocalMoment(weekday: .tue, minutesSinceMidnight: 14 * 60 + 7))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ScheduleTests 2>&1 | grep -E "error|Executed" | head -3`
Expected: compile error, `LocalMoment` not found.

- [ ] **Step 3: Implement**

`Sources/FocusGuardCore/Schedule.swift`:
```swift
import Foundation

/// A point in local calendar time: which weekday, and minutes since that day's midnight.
public struct LocalMoment: Equatable {
    public let weekday: Weekday
    public let minutesSinceMidnight: Int

    public init(weekday: Weekday, minutesSinceMidnight: Int) {
        self.weekday = weekday
        self.minutesSinceMidnight = minutesSinceMidnight
    }

    public init(date: Date, calendar: Calendar = .current) {
        let c = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        self.weekday = Weekday(calendarWeekday: c.weekday!)
        self.minutesSinceMidnight = c.hour! * 60 + c.minute!
    }
}

extension ScheduleWindow {
    /// Start is inclusive, end is exclusive. A window whose end is at or before its start
    /// crosses midnight and belongs to its start day.
    public func isActive(at m: LocalMoment) -> Bool {
        guard enabled else { return false }
        let s = start.minutesSinceMidnight
        let e = end.minutesSinceMidnight
        let t = m.minutesSinceMidnight
        if s == e { return false }
        if s < e {
            return days.contains(m.weekday) && t >= s && t < e
        }
        return (days.contains(m.weekday) && t >= s)
            || (days.contains(m.weekday.previous) && t < e)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ScheduleTests 2>&1 | grep -E "failed|Executed"`
Expected: `Executed 7 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Sources/FocusGuardCore/Schedule.swift Tests/FocusGuardCoreTests/ScheduleTests.swift
git commit -m "Core: schedule window matching with midnight crossing

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: Active set computation

**Files:**
- Create: `Sources/FocusGuardCore/ActiveSet.swift`
- Create: `Tests/FocusGuardCoreTests/ActiveSetTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import FocusGuardCore

final class ActiveSetTests: XCTestCase {
    let social = BlockList(name: "Social", domains: ["Reddit.com", "https://www.youtube.com/"], appBundleIDs: ["com.tinyspeck.slackmacgap"])
    let games = BlockList(name: "Games", domains: ["steampowered.com"], appBundleIDs: ["com.valvesoftware.steam"])
    let mon10 = LocalMoment(weekday: .mon, minutesSinceMidnight: 10 * 60)

    func testUnionOfActiveWindowsLists() {
        let a = ScheduleWindow(name: "a", days: [.mon], start: TimeOfDay("09:00")!, end: TimeOfDay("12:00")!, blockListIDs: [social.id])
        let b = ScheduleWindow(name: "b", days: [.mon], start: TimeOfDay("09:30")!, end: TimeOfDay("10:30")!, blockListIDs: [games.id])
        let cfg = Config(blockLists: [social, games], schedules: [a, b])

        let set = cfg.activeSet(at: mon10)

        XCTAssertEqual(set.domains, ["reddit.com", "youtube.com", "steampowered.com"])
        XCTAssertEqual(set.bundleIDs, ["com.tinyspeck.slackmacgap", "com.valvesoftware.steam"])
    }

    func testInactiveWindowContributesNothing() {
        let a = ScheduleWindow(name: "a", days: [.tue], start: TimeOfDay("09:00")!, end: TimeOfDay("12:00")!, blockListIDs: [social.id])
        let cfg = Config(blockLists: [social], schedules: [a])
        XCTAssertEqual(cfg.activeSet(at: mon10), .empty)
        XCTAssertTrue(cfg.activeSet(at: mon10).isEmpty)
    }

    func testDanglingBlockListIDIsIgnored() {
        let a = ScheduleWindow(name: "a", days: [.mon], start: TimeOfDay("09:00")!, end: TimeOfDay("12:00")!, blockListIDs: [UUID()])
        let cfg = Config(blockLists: [social], schedules: [a])
        XCTAssertEqual(cfg.activeSet(at: mon10), .empty)
    }

    func testEmptyDomainStringsAreDropped() {
        let junk = BlockList(name: "j", domains: ["  ", "https://"], appBundleIDs: [])
        let a = ScheduleWindow(name: "a", days: [.mon], start: TimeOfDay("09:00")!, end: TimeOfDay("12:00")!, blockListIDs: [junk.id])
        let cfg = Config(blockLists: [junk], schedules: [a])
        XCTAssertEqual(cfg.activeSet(at: mon10).domains, [])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ActiveSetTests 2>&1 | grep -E "error|Executed" | head -3`
Expected: compile error, `ActiveSet` / `activeSet(at:)` not found.

- [ ] **Step 3: Implement**

`Sources/FocusGuardCore/ActiveSet.swift`:
```swift
import Foundation

/// Everything that should be blocked right now.
public struct ActiveSet: Equatable {
    public var domains: Set<String>
    public var bundleIDs: Set<String>

    public init(domains: Set<String>, bundleIDs: Set<String>) {
        self.domains = domains
        self.bundleIDs = bundleIDs
    }

    public static let empty = ActiveSet(domains: [], bundleIDs: [])
    public var isEmpty: Bool { domains.isEmpty && bundleIDs.isEmpty }
}

extension Config {
    public func activeSet(at moment: LocalMoment) -> ActiveSet {
        let activeListIDs = Set(schedules.filter { $0.isActive(at: moment) }.flatMap(\.blockListIDs))
        var out = ActiveSet.empty
        for list in blockLists where activeListIDs.contains(list.id) {
            out.domains.formUnion(list.domains.map(DomainNormalizer.normalize).filter { !$0.isEmpty })
            out.bundleIDs.formUnion(list.appBundleIDs)
        }
        return out
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ActiveSetTests 2>&1 | grep -E "failed|Executed"`
Expected: `Executed 4 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Sources/FocusGuardCore/ActiveSet.swift Tests/FocusGuardCoreTests/ActiveSetTests.swift
git commit -m "Core: active-set computation from config and moment

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: Hosts-file marked region

**Files:**
- Create: `Sources/FocusGuardCore/HostsRegion.swift`
- Create: `Tests/FocusGuardCoreTests/HostsRegionTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import FocusGuardCore

final class HostsRegionTests: XCTestCase {
    let base = """
    ##
    # Host Database
    127.0.0.1\tlocalhost
    255.255.255.255\tbroadcasthost
    ::1             localhost

    """

    func testRenderIsSortedAndCoversWwwAndIPv6() {
        let out = HostsRegion.render(domains: ["youtube.com", "reddit.com"])
        XCTAssertTrue(out.hasPrefix("""
        0.0.0.0 reddit.com
        0.0.0.0 www.reddit.com
        :: reddit.com
        :: www.reddit.com
        0.0.0.0 youtube.com
        0.0.0.0 www.youtube.com
        :: youtube.com
        :: www.youtube.com

        """), "got:\n\(out)")
    }

    func testRenderSinkholesDoHEndpointsAfterDomains() {
        let out = HostsRegion.render(domains: ["reddit.com"])
        XCTAssertTrue(out.contains("0.0.0.0 dns.google"))
        XCTAssertTrue(out.contains(":: mozilla.cloudflare-dns.com"))
        XCTAssertLessThan(out.range(of: "reddit.com")!.lowerBound, out.range(of: "dns.google")!.lowerBound)
    }

    func testRenderEmptyHasNoDoHLines() {
        XCTAssertEqual(HostsRegion.render(domains: []), "")
    }

    func testApplyAppendsRegionAndPreservesRest() {
        let out = HostsRegion.apply(domains: ["reddit.com"], to: base)
        XCTAssertTrue(out.hasPrefix(base + "# FOCUSGUARD START\n0.0.0.0 reddit.com\n"))
        XCTAssertTrue(out.hasSuffix("# FOCUSGUARD END\n"))
    }

    func testApplyReplacesExistingRegionInPlace() {
        let withOld = HostsRegion.apply(domains: ["old.com"], to: base)
        let out = HostsRegion.apply(domains: ["new.com"], to: withOld)
        XCTAssertFalse(out.contains("old.com"))
        XCTAssertTrue(out.contains("0.0.0.0 new.com"))
        XCTAssertEqual(out.components(separatedBy: HostsRegion.startMarker).count, 2, "exactly one region")
    }

    func testApplyIsIdempotent() {
        let once = HostsRegion.apply(domains: ["reddit.com"], to: base)
        XCTAssertEqual(HostsRegion.apply(domains: ["reddit.com"], to: once), once)
    }

    func testApplyEmptyRemovesRegionEntirely() {
        let withRegion = HostsRegion.apply(domains: ["reddit.com"], to: base)
        XCTAssertEqual(HostsRegion.apply(domains: [], to: withRegion), base)
        XCTAssertEqual(HostsRegion.apply(domains: [], to: base), base)
    }

    func testStripHandlesRegionInTheMiddle() {
        let contents = "a\n" + HostsRegion.startMarker + "\n0.0.0.0 x.com\n" + HostsRegion.endMarker + "\nb\n"
        XCTAssertEqual(HostsRegion.strip(contents), "a\nb\n")
    }

    func testStripToleratesMissingEndMarker() {
        let contents = "a\n" + HostsRegion.startMarker + "\n0.0.0.0 x.com\n"
        XCTAssertEqual(HostsRegion.strip(contents), "a\n")
    }

    func testApplyToFileWithoutTrailingNewline() {
        let out = HostsRegion.apply(domains: ["x.com"], to: "127.0.0.1 localhost")
        XCTAssertTrue(out.hasPrefix("127.0.0.1 localhost\n# FOCUSGUARD START\n"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter HostsRegionTests 2>&1 | grep -E "error|Executed" | head -3`
Expected: compile error, `HostsRegion` not found.

- [ ] **Step 3: Implement**

`Sources/FocusGuardCore/HostsRegion.swift`:
```swift
import Foundation

/// The daemon owns exactly one marked region in /etc/hosts and never touches anything else.
public enum HostsRegion {
    public static let startMarker = "# FOCUSGUARD START"
    public static let endMarker = "# FOCUSGUARD END"

    /// Public DNS-over-HTTPS resolvers. Sinkholed whenever any block is active so Chrome
    /// (automatic secure DNS) and Firefox (default TRR mode) fall back to the system resolver,
    /// which honours this file. Zero runtime cost; replaces the need for a browser tab watcher.
    public static let dohEndpoints: [String] = [
        "dns.google", "cloudflare-dns.com", "mozilla.cloudflare-dns.com",
        "dns.quad9.net", "doh.opendns.com", "dns.nextdns.io",
    ]

    /// Body of the region: both A (0.0.0.0) and AAAA (::) sinks for each domain and its www. form,
    /// followed by the DoH endpoints.
    public static func render(domains: Set<String>) -> String {
        var lines: [String] = []
        for d in domains.sorted() + (domains.isEmpty ? [] : dohEndpoints) {
            lines.append("0.0.0.0 \(d)")
            lines.append("0.0.0.0 www.\(d)")
            lines.append(":: \(d)")
            lines.append(":: www.\(d)")
        }
        return lines.joined(separator: "\n")
    }

    /// Returns `contents` with the region replaced (or removed when `domains` is empty).
    public static func apply(domains: Set<String>, to contents: String) -> String {
        let stripped = strip(contents)
        if domains.isEmpty { return stripped }
        let region = [startMarker, render(domains: domains), endMarker].joined(separator: "\n")
        let base = (stripped.isEmpty || stripped.hasSuffix("\n")) ? stripped : stripped + "\n"
        return base + region + "\n"
    }


    /// Removes the marked region. A missing end marker strips to end of file.
    public static func strip(_ contents: String) -> String {
        var kept: [Substring] = []
        var inRegion = false
        for line in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            if line == startMarker { inRegion = true; continue }
            if line == endMarker { inRegion = false; continue }
            if !inRegion { kept.append(line) }
        }
        var result = kept.joined(separator: "\n")
        while result.hasSuffix("\n\n") { result.removeLast() }
        return result
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter HostsRegionTests 2>&1 | grep -E "failed|Executed"`
Expected: `Executed 10 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Sources/FocusGuardCore/HostsRegion.swift Tests/FocusGuardCoreTests/HostsRegionTests.swift
git commit -m "Core: hosts-file marked region render/apply/strip

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 7: Clock-tamper guard

Wall clock can be set back by the user; `mach_continuous_time` cannot. If the wall clock lags the monotonic-projected time by more than the tolerance, trust the projection.

**Files:**
- Create: `Sources/FocusGuardCore/ClockGuard.swift`
- Create: `Tests/FocusGuardCoreTests/ClockGuardTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ClockGuardTests 2>&1 | grep -E "error|Executed" | head -3`
Expected: compile error, `ClockGuard` not found.

- [ ] **Step 3: Implement**

`Sources/FocusGuardCore/ClockGuard.swift`:
```swift
import Foundation

/// A paired reading of the wall clock and a monotonic clock that keeps counting through sleep.
public struct ClockSample: Codable, Equatable {
    public var wall: Date
    public var monotonic: TimeInterval

    public init(wall: Date, monotonic: TimeInterval) {
        self.wall = wall
        self.monotonic = monotonic
    }
}

public struct ClockGuard {
    public var tolerance: TimeInterval

    public init(tolerance: TimeInterval = 120) {
        self.tolerance = tolerance
    }

    /// The wall-clock time to use for schedule matching. If the wall clock has gone backwards
    /// relative to monotonic progress by more than `tolerance`, the monotonic projection wins.
    /// Callers should feed back `ClockSample(wall: <returned value>, monotonic: current.monotonic)`
    /// as the next `previous`, so a tampered clock stays overridden until it agrees again.
    public func trustedNow(previous: ClockSample?, current: ClockSample) -> Date {
        guard let previous else { return current.wall }
        let projected = previous.wall.addingTimeInterval(current.monotonic - previous.monotonic)
        if current.wall < projected.addingTimeInterval(-tolerance) {
            return projected
        }
        return current.wall
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ClockGuardTests 2>&1 | grep -E "failed|Executed"`
Expected: `Executed 6 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Sources/FocusGuardCore/ClockGuard.swift Tests/FocusGuardCoreTests/ClockGuardTests.swift
git commit -m "Core: clock-tamper guard using monotonic projection

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 8: Bounded fail-closed config resolver

**Files:**
- Create: `Sources/FocusGuardCore/ConfigResolver.swift`
- Create: `Tests/FocusGuardCoreTests/ConfigResolverTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import FocusGuardCore

final class ConfigResolverTests: XCTestCase {
    let list = BlockList(name: "l", domains: ["x.com"], appBundleIDs: [])
    lazy var cfg = Config(
        blockLists: [list],
        schedules: [ScheduleWindow(name: "w", days: [.mon], start: TimeOfDay("09:00")!, end: TimeOfDay("12:00")!, blockListIDs: [list.id])])
    let inside = LocalMoment(weekday: .mon, minutesSinceMidnight: 10 * 60)
    let outside = LocalMoment(weekday: .mon, minutesSinceMidnight: 13 * 60)

    func testLiveConfigWinsAndBecomesLastGood() {
        var r = ConfigResolver()
        let out = r.resolve(live: cfg, at: inside)
        XCTAssertEqual(out.config, cfg)
        XCTAssertEqual(out.source, .live)
        XCTAssertEqual(r.lastGood, cfg)
    }

    func testNothingAtAllYieldsEmpty() {
        var r = ConfigResolver()
        let out = r.resolve(live: nil, at: inside)
        XCTAssertEqual(out.config, .empty)
        XCTAssertEqual(out.source, .none)
    }

    func testVanishMidWindowKeepsEnforcingLastGood() {
        var r = ConfigResolver()
        _ = r.resolve(live: cfg, at: inside)
        let out = r.resolve(live: nil, at: inside)
        XCTAssertEqual(out.config, cfg)
        XCTAssertEqual(out.source, .lastGood)
    }

    func testFallbackIsReleasedOnceNoWindowIsActiveAndStaysReleased() {
        var r = ConfigResolver()
        _ = r.resolve(live: cfg, at: inside)
        _ = r.resolve(live: nil, at: inside)
        XCTAssertEqual(r.resolve(live: nil, at: outside).source, .none)
        // A later window must NOT re-arm the fallback: that would be an unbounded lockout.
        XCTAssertEqual(r.resolve(live: nil, at: inside).source, .none)
    }

    func testLiveConfigReturningReArmsFallback() {
        var r = ConfigResolver()
        _ = r.resolve(live: cfg, at: inside)
        _ = r.resolve(live: nil, at: outside)   // released
        _ = r.resolve(live: cfg, at: inside)    // live is back
        XCTAssertEqual(r.resolve(live: nil, at: inside).source, .lastGood)
    }

    func testSeededLastGoodIsUsedOnColdStart() {
        var r = ConfigResolver(lastGood: cfg)
        XCTAssertEqual(r.resolve(live: nil, at: inside).source, .lastGood)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ConfigResolverTests 2>&1 | grep -E "error|Executed" | head -3`
Expected: compile error, `ConfigResolver` not found.

- [ ] **Step 3: Implement**

`Sources/FocusGuardCore/ConfigResolver.swift`:
```swift
import Foundation

/// Decides which config to enforce when the live one is unreadable.
///
/// Bounded fail-closed: keep enforcing the last-known-good config, but only until the
/// moment it says nothing is active. After that it is released and stays released until a
/// live config is read again. A bug can therefore never lock the user out indefinitely.
public struct ConfigResolver {
    public enum Source: Equatable { case live, lastGood, none }

    public private(set) var lastGood: Config?
    public private(set) var fallbackReleased = false

    public init(lastGood: Config? = nil) {
        self.lastGood = lastGood
    }

    public mutating func resolve(live: Config?, at moment: LocalMoment) -> (config: Config, source: Source) {
        if let live {
            lastGood = live
            fallbackReleased = false
            return (live, .live)
        }
        guard let lastGood, !fallbackReleased else { return (.empty, .none) }
        if lastGood.activeSet(at: moment).isEmpty {
            fallbackReleased = true
            return (.empty, .none)
        }
        return (lastGood, .lastGood)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ConfigResolverTests 2>&1 | grep -E "failed|Executed"`
Expected: `Executed 6 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Sources/FocusGuardCore/ConfigResolver.swift Tests/FocusGuardCoreTests/ConfigResolverTests.swift
git commit -m "Core: bounded fail-closed config resolver

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 8b: Redesign ClockGuard and ConfigResolver bound (review fixes)

Review of Tasks 6–8 found three design flaws in the plan's own code (not the implementation):
1. `ClockGuard.trustedNow` trusted *forward* jumps, so setting the clock to 13:00 during a 09–12 window ended it; and because the trusted time was fed back as `previous`, backwards steps smaller than the tolerance could creep without bound (119 s per tick → 3 h/100 ticks).
2. A legitimate correction of a fast clock locked in a permanent offset.
3. `ConfigResolver` released the fallback only when *no* window was active, so back-to-back (09–12, 12–15) or 24/7 schedules made the "bounded" fail-closed unbounded.

New design, replacing Task 7 and Task 8 code entirely:

- **ClockGuard** keeps a sticky **anchor** sample and always projects trusted time from it along the monotonic clock. The anchor moves only on the first sample, after a reboot (monotonic went backwards), or after the wall clock has disagreed with the projection *continuously* for `reconvergeAfter` (24 h). Any disagreement beyond `tolerance` in **either** direction is tamper. Because the anchor is sticky, drift is compared cumulatively, so creep cannot accumulate. Its `State` is `Codable` so the daemon can persist it across restarts (within one boot).
- **ConfigResolver** records the IDs of the windows active at the moment the live config vanished and keeps enforcing only while one of *those* is still active, with an absolute ceiling of `maxFallback` (24 h).
- Two minor HostsRegion fixes: trim lines before marker comparison (a marker with trailing whitespace orphaned the region body), and only collapse trailing blank lines when a region was actually removed.

**Files:**
- Replace: `Sources/FocusGuardCore/ClockGuard.swift`, `Tests/FocusGuardCoreTests/ClockGuardTests.swift`
- Replace: `Sources/FocusGuardCore/ConfigResolver.swift`, `Tests/FocusGuardCoreTests/ConfigResolverTests.swift`
- Modify: `Sources/FocusGuardCore/HostsRegion.swift` (`strip` only), `Tests/FocusGuardCoreTests/HostsRegionTests.swift` (add two tests)

- [ ] **Step 1: Replace the ClockGuard tests**

`Tests/FocusGuardCoreTests/ClockGuardTests.swift`:
```swift
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
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter ClockGuardTests 2>&1 | grep -E "error|Executed" | head -3`
Expected: compile errors (`step`, `State` not found).

- [ ] **Step 3: Replace ClockGuard**

`Sources/FocusGuardCore/ClockGuard.swift`:
```swift
import Foundation

/// A paired reading of the wall clock and a monotonic clock that keeps counting through sleep.
public struct ClockSample: Codable, Equatable {
    public var wall: Date
    public var monotonic: TimeInterval

    public init(wall: Date, monotonic: TimeInterval) {
        self.wall = wall
        self.monotonic = monotonic
    }
}

/// Defends schedule matching against the wall clock being changed.
///
/// Trusted time is always projected from an *anchor* sample along the monotonic clock
/// (`mach_continuous_time`: counts through sleep, cannot be set). The anchor moves only on the
/// first sample, after a reboot (monotonic went backwards), or after the wall clock has disagreed
/// with the projection continuously for `reconvergeAfter` — long enough that a genuine correction
/// eventually wins, far too long for a clock change to shorten or delay a window. Because the
/// anchor is sticky, drift is measured cumulatively and small steps cannot creep past `tolerance`.
public struct ClockGuard {
    public struct State: Codable, Equatable {
        public var anchor: ClockSample
        /// Monotonic time at which the wall clock started disagreeing; nil while it agrees.
        public var disagreeingSince: TimeInterval?

        public init(anchor: ClockSample, disagreeingSince: TimeInterval? = nil) {
            self.anchor = anchor
            self.disagreeingSince = disagreeingSince
        }
    }

    public struct Step: Equatable {
        public var trusted: Date
        public var state: State
        public var tampered: Bool
    }

    public var tolerance: TimeInterval
    public var reconvergeAfter: TimeInterval

    public init(tolerance: TimeInterval = 120, reconvergeAfter: TimeInterval = 24 * 3600) {
        self.tolerance = tolerance
        self.reconvergeAfter = reconvergeAfter
    }

    public func step(state: State?, now: ClockSample) -> Step {
        guard let state, now.monotonic >= state.anchor.monotonic else {
            // First sample, or the machine rebooted: nothing to project from.
            return Step(trusted: now.wall, state: State(anchor: now), tampered: false)
        }
        let projected = state.anchor.wall.addingTimeInterval(now.monotonic - state.anchor.monotonic)
        let diff = now.wall.timeIntervalSince(projected)
        if abs(diff) <= tolerance {
            return Step(trusted: projected, state: State(anchor: state.anchor), tampered: false)
        }
        let since = state.disagreeingSince ?? now.monotonic
        if now.monotonic - since >= reconvergeAfter {
            return Step(trusted: now.wall, state: State(anchor: now), tampered: false)
        }
        return Step(trusted: projected, state: State(anchor: state.anchor, disagreeingSince: since), tampered: true)
    }
}
```

- [ ] **Step 4: Run ClockGuard tests**

Run: `swift test --filter ClockGuardTests 2>&1 | grep -E "failed|Executed"`
Expected: `Executed 11 tests, with 0 failures`.

- [ ] **Step 5: Replace the ConfigResolver tests**

`Tests/FocusGuardCoreTests/ConfigResolverTests.swift`:
```swift
import XCTest
@testable import FocusGuardCore

final class ConfigResolverTests: XCTestCase {
    let list = BlockList(name: "l", domains: ["x.com"], appBundleIDs: [])
    lazy var morning = ScheduleWindow(name: "am", days: [.mon], start: TimeOfDay("09:00")!, end: TimeOfDay("12:00")!, blockListIDs: [list.id])
    lazy var afternoon = ScheduleWindow(name: "pm", days: [.mon], start: TimeOfDay("12:00")!, end: TimeOfDay("15:00")!, blockListIDs: [list.id])
    lazy var cfg = Config(blockLists: [list], schedules: [morning])
    lazy var backToBack = Config(blockLists: [list], schedules: [morning, afternoon])
    lazy var always = Config(blockLists: [list], schedules: [
        ScheduleWindow(name: "24/7", days: Set(Weekday.allCases), start: TimeOfDay("00:00")!, end: TimeOfDay("23:59")!, blockListIDs: [list.id])])

    let at10 = LocalMoment(weekday: .mon, minutesSinceMidnight: 10 * 60)
    let at1230 = LocalMoment(weekday: .mon, minutesSinceMidnight: 12 * 60 + 30)
    let at16 = LocalMoment(weekday: .mon, minutesSinceMidnight: 16 * 60)

    func testLiveConfigWinsAndBecomesLastGood() {
        var r = ConfigResolver()
        let out = r.resolve(live: cfg, at: at10, monotonic: 0)
        XCTAssertEqual(out.config, cfg)
        XCTAssertEqual(out.source, .live)
        XCTAssertEqual(r.lastGood, cfg)
    }

    func testNothingAtAllYieldsEmpty() {
        var r = ConfigResolver()
        let out = r.resolve(live: nil, at: at10, monotonic: 0)
        XCTAssertEqual(out.config, .empty)
        XCTAssertEqual(out.source, .none)
    }

    func testVanishMidWindowKeepsEnforcingLastGood() {
        var r = ConfigResolver()
        _ = r.resolve(live: cfg, at: at10, monotonic: 0)
        let out = r.resolve(live: nil, at: at10, monotonic: 2)
        XCTAssertEqual(out.config, cfg)
        XCTAssertEqual(out.source, .lastGood)
    }

    func testReleasedWhenTheVanishTimeWindowEndsAndStaysReleased() {
        var r = ConfigResolver()
        _ = r.resolve(live: cfg, at: at10, monotonic: 0)
        _ = r.resolve(live: nil, at: at10, monotonic: 2)
        XCTAssertEqual(r.resolve(live: nil, at: at16, monotonic: 6 * 3600).source, .none)
        // Next Monday's window must NOT re-arm the fallback.
        XCTAssertEqual(r.resolve(live: nil, at: at10, monotonic: 7 * 24 * 3600).source, .none)
    }

    func testBackToBackWindowsDoNotExtendTheFallback() {
        var r = ConfigResolver()
        _ = r.resolve(live: backToBack, at: at10, monotonic: 0)
        XCTAssertEqual(r.resolve(live: nil, at: at10, monotonic: 2).source, .lastGood)
        // 12:30: the afternoon window is active, but it was not the one active when config vanished.
        XCTAssertEqual(r.resolve(live: nil, at: at1230, monotonic: 2.5 * 3600).source, .none)
    }

    func testVanishDuringAfternoonIsBoundedByAfternoon() {
        var r = ConfigResolver()
        _ = r.resolve(live: backToBack, at: at1230, monotonic: 0)
        XCTAssertEqual(r.resolve(live: nil, at: at1230, monotonic: 2).source, .lastGood)
        XCTAssertEqual(r.resolve(live: nil, at: at16, monotonic: 4 * 3600).source, .none)
    }

    func testAlwaysOnScheduleHitsTheAbsoluteCeiling() {
        var r = ConfigResolver(maxFallback: 24 * 3600)
        _ = r.resolve(live: always, at: at10, monotonic: 0)
        XCTAssertEqual(r.resolve(live: nil, at: at10, monotonic: 2).source, .lastGood)
        XCTAssertEqual(r.resolve(live: nil, at: at16, monotonic: 23 * 3600).source, .lastGood)
        XCTAssertEqual(r.resolve(live: nil, at: at16, monotonic: 2 + 24 * 3600).source, .none)
    }

    func testLiveConfigReturningReArmsFallback() {
        var r = ConfigResolver()
        _ = r.resolve(live: cfg, at: at10, monotonic: 0)
        _ = r.resolve(live: nil, at: at16, monotonic: 1)   // released immediately: nothing active
        _ = r.resolve(live: cfg, at: at10, monotonic: 2)   // live is back
        XCTAssertEqual(r.resolve(live: nil, at: at10, monotonic: 3).source, .lastGood)
    }

    func testSeededLastGoodIsUsedOnColdStart() {
        var r = ConfigResolver(lastGood: cfg)
        XCTAssertEqual(r.resolve(live: nil, at: at10, monotonic: 0).source, .lastGood)
    }
}
```

- [ ] **Step 6: Run to verify failure**

Run: `swift test --filter ConfigResolverTests 2>&1 | grep -E "error|Executed" | head -3`
Expected: compile errors (`monotonic:` label, `maxFallback:`).

- [ ] **Step 7: Replace ConfigResolver**

`Sources/FocusGuardCore/ConfigResolver.swift`:
```swift
import Foundation

/// Decides which config to enforce when the live one is unreadable.
///
/// Bounded fail-closed: keep enforcing the last-known-good config, but only while one of the
/// windows that was active *when the live config vanished* is still active, and never longer
/// than `maxFallback`. After that the fallback is released and stays released until a live
/// config is read again. A bug can therefore never lock the user out indefinitely, even with
/// back-to-back or 24/7 schedules.
public struct ConfigResolver {
    public enum Source: Equatable { case live, lastGood, none }

    public private(set) var lastGood: Config?
    public private(set) var fallbackReleased = false
    public var maxFallback: TimeInterval

    private var fallbackWindowIDs: Set<UUID>?
    private var fallbackSince: TimeInterval?

    public init(lastGood: Config? = nil, maxFallback: TimeInterval = 24 * 3600) {
        self.lastGood = lastGood
        self.maxFallback = maxFallback
    }

    public mutating func resolve(live: Config?, at moment: LocalMoment, monotonic: TimeInterval) -> (config: Config, source: Source) {
        if let live {
            lastGood = live
            fallbackReleased = false
            fallbackWindowIDs = nil
            fallbackSince = nil
            return (live, .live)
        }
        guard let lastGood, !fallbackReleased else { return (.empty, .none) }

        if fallbackWindowIDs == nil {
            fallbackWindowIDs = Set(lastGood.schedules.filter { $0.isActive(at: moment) }.map(\.id))
            fallbackSince = monotonic
        }
        let ids = fallbackWindowIDs ?? []
        let since = fallbackSince ?? monotonic
        let stillActive = lastGood.schedules.contains { ids.contains($0.id) && $0.isActive(at: moment) }
        let expired = monotonic - since >= maxFallback

        if !stillActive || expired {
            fallbackReleased = true
            fallbackWindowIDs = nil
            fallbackSince = nil
            return (.empty, .none)
        }
        return (lastGood, .lastGood)
    }
}
```

- [ ] **Step 8: Run ConfigResolver tests**

Run: `swift test --filter ConfigResolverTests 2>&1 | grep -E "failed|Executed"`
Expected: `Executed 9 tests, with 0 failures`.

- [ ] **Step 9: HostsRegion strip fixes — tests first**

Add to `Tests/FocusGuardCoreTests/HostsRegionTests.swift`:
```swift
    func testMarkersWithTrailingWhitespaceStillDelimitTheRegion() {
        let contents = "a\n" + HostsRegion.startMarker + " \n0.0.0.0 x.com\n" + HostsRegion.endMarker + "\t\nb\n"
        XCTAssertEqual(HostsRegion.strip(contents), "a\nb\n")
    }

    func testStripLeavesFilesWithoutARegionByteIdentical() {
        XCTAssertEqual(HostsRegion.strip("a\n\n\n"), "a\n\n\n")
        XCTAssertEqual(HostsRegion.apply(domains: [], to: "a\n\n\n"), "a\n\n\n")
    }
```
Run: `swift test --filter HostsRegionTests 2>&1 | grep -E "failed|Executed"` → expect 2 failures.

- [ ] **Step 10: Fix `strip`**

Replace `strip` in `Sources/FocusGuardCore/HostsRegion.swift`:
```swift
    /// Removes the marked region. A missing end marker strips to end of file. A file with no
    /// region is returned unchanged.
    public static func strip(_ contents: String) -> String {
        var kept: [Substring] = []
        var inRegion = false
        var sawRegion = false
        for line in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == startMarker { inRegion = true; sawRegion = true; continue }
            if trimmed == endMarker { inRegion = false; continue }
            if !inRegion { kept.append(line) }
        }
        guard sawRegion else { return contents }
        if inRegion, !kept.isEmpty { kept.append("") }  // unterminated region: keep the preceding line's newline
        var result = kept.joined(separator: "\n")
        while result.hasSuffix("\n\n") { result.removeLast() }
        return result
    }
```
Run: `swift test --filter HostsRegionTests 2>&1 | grep -E "failed|Executed"` → `Executed 12 tests, with 0 failures`.

- [ ] **Step 11: Full suite and commit**

Run: `swift test 2>&1 | grep -E "failed|error:|Executed"`
Expected: `Executed 58 tests, with 0 failures`.

```bash
git add Sources/FocusGuardCore Tests/FocusGuardCoreTests
git commit -m "Core: sticky-anchor clock guard, window-bounded fallback, hosts strip fixes

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 8c: Boot-session tag on ClockSample; strip idempotency (review fixes)

Review of Task 8b found: (1) the persisted clock anchor only checks `now.monotonic >= anchor.monotonic`, but monotonic time restarts at every boot and the anchor is taken seconds after boot, so a stale anchor from the previous boot is accepted roughly half the time and every window runs shifted by the previous uptime for 24 h — a retryable bypass. Fix: tag samples with a boot-session identifier. (2) `strip`'s trailing-blank-line collapse fires whenever a region is present, so `apply` is not idempotent on files with trailing blank lines, and a stray end marker outside a region is dropped. Fix: remove the collapse; only honour an end marker while inside a region. (3) Doc comment on `ConfigResolver` overstated the bound: it is per daemon lifetime (a restart with a still-broken config re-arms the fallback, which is deliberate fail-closed-after-reboot).

**Files:**
- Modify: `Sources/FocusGuardCore/ClockGuard.swift`, `Tests/FocusGuardCoreTests/ClockGuardTests.swift`
- Modify: `Sources/FocusGuardCore/HostsRegion.swift`, `Tests/FocusGuardCoreTests/HostsRegionTests.swift`
- Modify: `Sources/FocusGuardCore/ConfigResolver.swift` (comment only)

- [ ] **Step 1: Tests first**

Add to `ClockGuardTests`:
```swift
    func testDifferentBootSessionResetsAnchorEvenIfMonotonicIsLarger() {
        let st = guardian.step(state: nil, now: ClockSample(wall: t0, monotonic: 25, boot: "boot-A")).state
        let s = guardian.step(state: st, now: ClockSample(wall: t0.addingTimeInterval(5500), monotonic: 40, boot: "boot-B"))
        XCTAssertEqual(s.trusted, t0.addingTimeInterval(5500), "a new boot has nothing to project from")
        XCTAssertFalse(s.tampered)
        XCTAssertEqual(s.state.anchor.boot, "boot-B")
    }
```
Add to `HostsRegionTests`:
```swift
    func testApplyIsIdempotentWithTrailingBlankLines() {
        let once = HostsRegion.apply(domains: ["x.com"], to: "a\n\n\n")
        XCTAssertEqual(HostsRegion.apply(domains: ["x.com"], to: once), once)
        XCTAssertEqual(HostsRegion.apply(domains: [], to: once), "a\n\n\n")
    }

    func testStrayEndMarkerOutsideRegionIsPreserved() {
        let contents = "a\n# FOCUSGUARD END\nb\n" + HostsRegion.startMarker + "\n0.0.0.0 x.com\n" + HostsRegion.endMarker + "\n"
        XCTAssertEqual(HostsRegion.strip(contents), "a\n# FOCUSGUARD END\nb\n")
    }
```
Run: `swift test 2>&1 | grep -E "error|failed|Executed"` → compile error (`boot:` label) is the expected failure.

- [ ] **Step 2: ClockSample gets a boot tag**

In `ClockGuard.swift` replace `ClockSample` with:
```swift
/// A paired reading of the wall clock and a monotonic clock that keeps counting through sleep.
/// `boot` identifies the boot session: monotonic values from different boots are incomparable.
public struct ClockSample: Codable, Equatable {
    public var wall: Date
    public var monotonic: TimeInterval
    public var boot: String

    public init(wall: Date, monotonic: TimeInterval, boot: String = "") {
        self.wall = wall
        self.monotonic = monotonic
        self.boot = boot
    }
}
```
and change the guard at the top of `step` to:
```swift
        guard let state, now.boot == state.anchor.boot, now.monotonic >= state.anchor.monotonic else {
            // First sample, or a different boot session: nothing to project from.
            return Step(trusted: now.wall, state: State(anchor: now), tampered: false)
        }
```

- [ ] **Step 3: strip fixes**

In `HostsRegion.swift`, inside `strip`:
- change `if trimmed == endMarker { inRegion = false; continue }` to `if trimmed == endMarker, inRegion { inRegion = false; continue }`
- replace the last three lines (`var result = …`, the `while` loop, `return result`) with `return kept.joined(separator: "\n")`.

- [ ] **Step 4: ConfigResolver comment**

Replace the doc comment block above `public struct ConfigResolver` with:
```swift
/// Decides which config to enforce when the live one is unreadable.
///
/// Bounded fail-closed: keep enforcing the last-known-good config, but only while one of the
/// windows that was active *when the live config vanished* is still active, and never longer
/// than `maxFallback`. After that the fallback is released for the rest of this daemon's
/// lifetime, until a live config is read again. A daemon restart re-arms it from the persisted
/// last-good config — deliberately fail-closed after a reboot — so the bound is per lifetime,
/// not cumulative. A bug can never lock the user out for more than `maxFallback` without a
/// restart, and the README documents `launchctl bootout` as the escape hatch.
```

- [ ] **Step 5: Run and commit**

Run: `swift test 2>&1 | grep -E "failed|error:|Executed"` → `Executed 61 tests, with 0 failures`.
```bash
git add Sources/FocusGuardCore Tests/FocusGuardCoreTests
git commit -m "Core: tag clock samples with boot session; make hosts strip idempotent

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 9: Ports (protocols) and test fakes

**Files:**
- Create: `Sources/FocusGuardCore/Ports.swift`
- Create: `Tests/FocusGuardCoreTests/Fakes.swift`

- [ ] **Step 1: Define the ports**

`Sources/FocusGuardCore/Ports.swift`:
```swift
import Foundation

public protocol HostsFileStore {
    func read() throws -> String
    func write(_ contents: String) throws
}

public protocol DNSCacheFlusher {
    func flush()
}

public struct RunningApp: Equatable {
    public let pid: Int32
    public let bundleID: String?

    public init(pid: Int32, bundleID: String?) {
        self.pid = pid
        self.bundleID = bundleID
    }
}

public protocol ProcessController {
    func runningApps() -> [RunningApp]
    /// Polite request (SIGTERM).
    func terminate(pid: Int32)
    /// Forceful (SIGKILL).
    func kill(pid: Int32)
}

public protocol ReconcilerLog {
    func info(_ message: String)
    func error(_ message: String)
}
```

- [ ] **Step 2: Write the fakes**

`Tests/FocusGuardCoreTests/Fakes.swift`:
```swift
import Foundation
@testable import FocusGuardCore

final class FakeHosts: HostsFileStore {
    var contents: String
    var writes = 0
    var failReads = false
    init(_ contents: String) { self.contents = contents }
    struct Failure: Error {}
    func read() throws -> String {
        if failReads { throw Failure() }
        return contents
    }
    func write(_ new: String) throws { contents = new; writes += 1 }
}

final class FakeDNS: DNSCacheFlusher {
    var flushes = 0
    func flush() { flushes += 1 }
}

final class FakeProcesses: ProcessController {
    var apps: [RunningApp] = []
    var terminated: [Int32] = []
    var killed: [Int32] = []
    var enumerations = 0
    func runningApps() -> [RunningApp] { enumerations += 1; return apps }
    func terminate(pid: Int32) { terminated.append(pid) }
    func kill(pid: Int32) { killed.append(pid); apps.removeAll { $0.pid == pid } }
}

final class FakeLog: ReconcilerLog {
    var infos: [String] = []
    var errors: [String] = []
    func info(_ m: String) { infos.append(m) }
    func error(_ m: String) { errors.append(m) }
}
```

- [ ] **Step 3: Build**

Run: `swift build --build-tests 2>&1 | tail -2`
Expected: `Build complete!`

- [ ] **Step 4: Commit**

```bash
git add Sources/FocusGuardCore/Ports.swift Tests/FocusGuardCoreTests/Fakes.swift
git commit -m "Core: enforcement ports and test fakes

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 10: Reconciler — one tick converges the system

**Files:**
- Create: `Sources/FocusGuardCore/Reconciler.swift`
- Create: `Tests/FocusGuardCoreTests/ReconcilerTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import FocusGuardCore

final class ReconcilerTests: XCTestCase {
    let base = "127.0.0.1 localhost\n"
    let list = BlockList(name: "l", domains: ["reddit.com"], appBundleIDs: ["com.example.slack"])
    lazy var cfg = Config(
        blockLists: [list],
        schedules: [ScheduleWindow(name: "w", days: [.mon], start: TimeOfDay("09:00")!, end: TimeOfDay("12:00")!, blockListIDs: [list.id])])

    var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Vancouver")!
        return c
    }()
    // 2026-10-26 is a Monday.
    func monday(_ h: Int, _ m: Int) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: h, minute: m))!
    }

    var hosts: FakeHosts!
    var dns: FakeDNS!
    var procs: FakeProcesses!
    var log: FakeLog!
    var sut: Reconciler!

    override func setUp() {
        hosts = FakeHosts(base)
        dns = FakeDNS()
        procs = FakeProcesses()
        log = FakeLog()
        sut = Reconciler(hosts: hosts, dns: dns, processes: procs, log: log, killGrace: 3, calendar: cal)
    }

    func testEnteringWindowWritesHostsAndFlushesOnce() {
        let r = sut.tick(live: cfg, clock: ClockSample(wall: monday(10, 0), monotonic: 100))
        XCTAssertTrue(r.hostsChanged)
        XCTAssertTrue(hosts.contents.contains("0.0.0.0 reddit.com"))
        XCTAssertEqual(dns.flushes, 1)
        XCTAssertEqual(r.source, .live)

        let r2 = sut.tick(live: cfg, clock: ClockSample(wall: monday(10, 0, 2), monotonic: 102))
        XCTAssertFalse(r2.hostsChanged)
        XCTAssertEqual(hosts.writes, 1)
        XCTAssertEqual(dns.flushes, 1)
    }

    func testLeavingWindowStripsRegion() {
        _ = sut.tick(live: cfg, clock: ClockSample(wall: monday(11, 59), monotonic: 100))
        let r = sut.tick(live: cfg, clock: ClockSample(wall: monday(12, 0), monotonic: 160))
        XCTAssertTrue(r.hostsChanged)
        XCTAssertEqual(hosts.contents, base)
        XCTAssertTrue(r.activeSet.isEmpty)
    }

    func testBlockedAppIsTerminatedThenKilledAfterGrace() {
        procs.apps = [RunningApp(pid: 42, bundleID: "com.example.slack"), RunningApp(pid: 7, bundleID: "com.apple.Safari")]

        let r1 = sut.tick(live: cfg, clock: ClockSample(wall: monday(10, 0), monotonic: 100))
        XCTAssertEqual(r1.terminated, [42])
        XCTAssertEqual(r1.killed, [])

        let r2 = sut.tick(live: cfg, clock: ClockSample(wall: monday(10, 0, 2), monotonic: 102))
        XCTAssertEqual(r2.terminated, [], "no second SIGTERM inside the grace period")
        XCTAssertEqual(r2.killed, [])

        let r3 = sut.tick(live: cfg, clock: ClockSample(wall: monday(10, 0, 4), monotonic: 104))
        XCTAssertEqual(r3.killed, [42])
        XCTAssertEqual(procs.terminated, [42])
        XCTAssertFalse(procs.killed.contains(7))
    }

    func testAppThatExitsAfterTermIsNotKilled() {
        procs.apps = [RunningApp(pid: 42, bundleID: "com.example.slack")]
        _ = sut.tick(live: cfg, clock: ClockSample(wall: monday(10, 0), monotonic: 100))
        procs.apps = []  // it quit politely
        let r = sut.tick(live: cfg, clock: ClockSample(wall: monday(10, 0, 4), monotonic: 104))
        XCTAssertEqual(r.killed, [])
        // Relaunch later gets a fresh SIGTERM, not an immediate SIGKILL.
        procs.apps = [RunningApp(pid: 43, bundleID: "com.example.slack")]
        let r2 = sut.tick(live: cfg, clock: ClockSample(wall: monday(10, 0, 6), monotonic: 106))
        XCTAssertEqual(r2.terminated, [43])
    }

    func testNoKillsOutsideWindow() {
        procs.apps = [RunningApp(pid: 42, bundleID: "com.example.slack")]
        let r = sut.tick(live: cfg, clock: ClockSample(wall: monday(13, 0), monotonic: 100))
        XCTAssertEqual(r.terminated, [])
        XCTAssertEqual(hosts.writes, 0)
        XCTAssertEqual(procs.enumerations, 0, "no process scan when no apps are blocked (battery)")
    }

    func testClockRewindDoesNotReleaseWindow() {
        _ = sut.tick(live: cfg, clock: ClockSample(wall: monday(11, 0), monotonic: 100))
        // User sets the clock back to 08:00 two seconds later.
        let r = sut.tick(live: cfg, clock: ClockSample(wall: monday(8, 0), monotonic: 102))
        XCTAssertFalse(r.activeSet.isEmpty, "projected time is still 11:00:02")
        XCTAssertTrue(hosts.contents.contains("0.0.0.0 reddit.com"))
        XCTAssertEqual(log.errors.count, 1, "tamper logged once, not every tick")
        _ = sut.tick(live: cfg, clock: ClockSample(wall: monday(8, 0, 2), monotonic: 104))
        XCTAssertEqual(log.errors.count, 1)
    }

    func testClockJumpForwardDoesNotReleaseWindow() {
        _ = sut.tick(live: cfg, clock: ClockSample(wall: monday(11, 0), monotonic: 100))
        let r = sut.tick(live: cfg, clock: ClockSample(wall: monday(14, 0), monotonic: 102))
        XCTAssertFalse(r.activeSet.isEmpty)
        XCTAssertTrue(hosts.contents.contains("0.0.0.0 reddit.com"))
    }

    func testClockStateIsExposedAndSeedable() {
        _ = sut.tick(live: cfg, clock: ClockSample(wall: monday(11, 0), monotonic: 100))
        let saved = sut.clockState
        XCTAssertNotNil(saved)
        // A restarted reconciler seeded with the saved state still resists a rewind.
        let restarted = Reconciler(hosts: hosts, dns: dns, processes: procs, log: log,
                                   clockState: saved, killGrace: 3, calendar: cal)
        let r = restarted.tick(live: cfg, clock: ClockSample(wall: monday(8, 0), monotonic: 102))
        XCTAssertFalse(r.activeSet.isEmpty)
    }

    func testConfigVanishingMidWindowKeepsBlockingUntilWindowEnds() {
        _ = sut.tick(live: cfg, clock: ClockSample(wall: monday(11, 0), monotonic: 100))
        let r = sut.tick(live: nil, clock: ClockSample(wall: monday(11, 30), monotonic: 1900))
        XCTAssertEqual(r.source, .lastGood)
        XCTAssertTrue(hosts.contents.contains("0.0.0.0 reddit.com"))

        let r2 = sut.tick(live: nil, clock: ClockSample(wall: monday(12, 1), monotonic: 3760))
        XCTAssertEqual(r2.source, .none)
        XCTAssertEqual(hosts.contents, base)
    }

    func testHostsReadFailureIsLoggedNotFatal() {
        hosts.failReads = true
        let r = sut.tick(live: cfg, clock: ClockSample(wall: monday(10, 0), monotonic: 100))
        XCTAssertFalse(r.hostsChanged)
        XCTAssertEqual(log.errors.count, 1)
    }

    func testTeardownStripsRegion() {
        _ = sut.tick(live: cfg, clock: ClockSample(wall: monday(10, 0), monotonic: 100))
        sut.teardown()
        XCTAssertEqual(hosts.contents, base)
        XCTAssertEqual(dns.flushes, 2)
    }
}

private extension ReconcilerTests {
    func monday(_ h: Int, _ m: Int, _ s: Int) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: h, minute: m, second: s))!
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ReconcilerTests 2>&1 | grep -E "error|Executed" | head -3`
Expected: compile error, `Reconciler` not found.

- [ ] **Step 3: Implement**

`Sources/FocusGuardCore/Reconciler.swift`:
```swift
import Foundation

/// Converges the system to the active set. Every tick rebuilds desired state from scratch,
/// so running it from any starting state (fresh boot, crash mid-window) is safe.
public final class Reconciler {
    public struct Result: Equatable {
        public var activeSet: ActiveSet
        public var source: ConfigResolver.Source
        public var hostsChanged: Bool
        public var terminated: [Int32]
        public var killed: [Int32]
    }

    private let hosts: HostsFileStore
    private let dns: DNSCacheFlusher
    private let processes: ProcessController
    private let log: ReconcilerLog
    private let clockGuard: ClockGuard
    private let killGrace: TimeInterval
    private let calendar: Calendar

    private var resolver: ConfigResolver
    /// Persisted by the daemon so a restart within the same boot cannot reset the clock anchor.
    public private(set) var clockState: ClockGuard.State?
    private var wasTampered = false
    /// pid → monotonic deadline after which SIGKILL is sent.
    private var pendingKill: [Int32: TimeInterval] = [:]

    public init(hosts: HostsFileStore, dns: DNSCacheFlusher, processes: ProcessController, log: ReconcilerLog,
                clockGuard: ClockGuard = ClockGuard(), clockState: ClockGuard.State? = nil,
                killGrace: TimeInterval = 3,
                resolver: ConfigResolver = ConfigResolver(), calendar: Calendar = .current) {
        self.hosts = hosts
        self.dns = dns
        self.processes = processes
        self.log = log
        self.clockGuard = clockGuard
        self.clockState = clockState
        self.killGrace = killGrace
        self.resolver = resolver
        self.calendar = calendar
    }

    public var lastGoodConfig: Config? { resolver.lastGood }

    @discardableResult
    public func tick(live: Config?, clock: ClockSample) -> Result {
        let step = clockGuard.step(state: clockState, now: clock)
        clockState = step.state
        if step.tampered != wasTampered {
            wasTampered = step.tampered
            if step.tampered {
                log.error("wall clock \(clock.wall) disagrees with monotonic projection; using \(step.trusted) until they agree")
            } else {
                log.info("wall clock agrees with projection again")
            }
        }

        let moment = LocalMoment(date: step.trusted, calendar: calendar)
        let (config, source) = resolver.resolve(live: live, at: moment, monotonic: clock.monotonic)
        let active = config.activeSet(at: moment)

        let hostsChanged = reconcileHosts(domains: active.domains)
        let (terminated, killed) = reconcileApps(bundleIDs: active.bundleIDs, monotonic: clock.monotonic)

        return Result(activeSet: active, source: source, hostsChanged: hostsChanged,
                      terminated: terminated, killed: killed)
    }

    /// Remove our hosts region. Called on daemon shutdown.
    public func teardown() {
        _ = reconcileHosts(domains: [])
        pendingKill.removeAll()
    }

    private func reconcileHosts(domains: Set<String>) -> Bool {
        let current: String
        do {
            current = try hosts.read()
        } catch {
            log.error("hosts read failed: \(error)")
            return false
        }
        let desired = HostsRegion.apply(domains: domains, to: current)
        guard desired != current else { return false }
        do {
            try hosts.write(desired)
        } catch {
            log.error("hosts write failed: \(error)")
            return false
        }
        dns.flush()
        log.info("hosts region updated: \(domains.count) domain(s)")
        return true
    }

    private func reconcileApps(bundleIDs: Set<String>, monotonic: TimeInterval) -> ([Int32], [Int32]) {
        // Battery: outside any window we never enumerate processes at all.
        guard !bundleIDs.isEmpty else {
            pendingKill.removeAll()
            return ([], [])
        }

        var terminated: [Int32] = []
        var killed: [Int32] = []
        let running = processes.runningApps()
        let runningPIDs = Set(running.map(\.pid))
        pendingKill = pendingKill.filter { runningPIDs.contains($0.key) }

        for app in running {
            guard let id = app.bundleID, bundleIDs.contains(id) else { continue }
            if let deadline = pendingKill[app.pid] {
                if monotonic >= deadline {
                    processes.kill(pid: app.pid)
                    pendingKill[app.pid] = nil
                    killed.append(app.pid)
                    log.info("killed \(id) pid \(app.pid)")
                }
            } else {
                processes.terminate(pid: app.pid)
                pendingKill[app.pid] = monotonic + killGrace
                terminated.append(app.pid)
                log.info("terminated \(id) pid \(app.pid)")
            }
        }
        return (terminated, killed)
    }
}
```

- [ ] **Step 4: Run the whole suite**

Run: `swift test 2>&1 | grep -E "failed|error:|Executed"`
Expected: `Executed 70 tests, with 0 failures` (count may differ by one or two; zero failures is the requirement).

- [ ] **Step 5: Commit**

```bash
git add Sources/FocusGuardCore/Reconciler.swift Tests/FocusGuardCoreTests/ReconcilerTests.swift
git commit -m "Core: reconciler converging hosts and apps to the active set

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 10b: Latch failure logging; don't re-SIGTERM an already-SIGKILLed pid (review fixes)

Review of Task 10 found two log-volume problems on persistent failure paths at a 2 s tick: a hosts read/write failure logged every tick, and a process that survives SIGKILL got a fresh SIGTERM + log line every tick. Normal operation was already quiet.

**Files:**
- Modify: `Sources/FocusGuardCore/Reconciler.swift`
- Modify: `Tests/FocusGuardCoreTests/ReconcilerTests.swift`, `Tests/FocusGuardCoreTests/Fakes.swift`

- [ ] **Step 1: Tests first**

Add to `Fakes.swift`:
```swift
/// A process that ignores SIGKILL (protected or zombie): stays in the list after kill.
final class StubbornProcesses: ProcessController {
    var apps: [RunningApp] = []
    var terminated: [Int32] = []
    var killed: [Int32] = []
    func runningApps() -> [RunningApp] { apps }
    func terminate(pid: Int32) { terminated.append(pid) }
    func kill(pid: Int32) { killed.append(pid) }
}
```
Add to `ReconcilerTests`:
```swift
    func testPersistentHostsFailureLogsOnceAndRecoveryOnce() {
        hosts.failReads = true
        for i in 0..<3 {
            _ = sut.tick(live: cfg, clock: ClockSample(wall: monday(10, 0, i * 2), monotonic: 100 + Double(i * 2)))
        }
        XCTAssertEqual(log.errors.count, 1, "latched: one error for a persistent failure")
        hosts.failReads = false
        _ = sut.tick(live: cfg, clock: ClockSample(wall: monday(10, 0, 8), monotonic: 108))
        XCTAssertEqual(log.errors.count, 1)
        XCTAssertTrue(log.infos.contains { $0.contains("recovered") })
        XCTAssertTrue(hosts.contents.contains("0.0.0.0 reddit.com"))
    }

    func testUnkillableAppIsNotReSignalledEveryTick() {
        let stubborn = StubbornProcesses()
        stubborn.apps = [RunningApp(pid: 42, bundleID: "com.example.slack")]
        let r = Reconciler(hosts: hosts, dns: dns, processes: stubborn, log: log, killGrace: 3, calendar: cal)
        for i in 0..<10 {
            _ = r.tick(live: cfg, clock: ClockSample(wall: monday(10, 0, i * 2), monotonic: 100 + Double(i * 2)))
        }
        XCTAssertEqual(stubborn.terminated, [42])
        XCTAssertEqual(stubborn.killed, [42])
        XCTAssertEqual(log.infos.filter { $0.contains("pid 42") }.count, 2, "one terminate line, one kill line")
    }
```
Run: `swift test --filter ReconcilerTests 2>&1 | grep -E "failed|Executed"` → 2 failures.

- [ ] **Step 2: Implement**

In `Reconciler.swift` add a stored property next to `wasTampered`:
```swift
    private var hostsFailing = false
```
Replace `reconcileHosts` with:
```swift
    private func reconcileHosts(domains: Set<String>) -> Bool {
        do {
            let current = try hosts.read()
            let desired = HostsRegion.apply(domains: domains, to: current)
            var changed = false
            if desired != current {
                try hosts.write(desired)
                dns.flush()
                log.info("hosts region updated: \(domains.count) domain(s)")
                changed = true
            }
            if hostsFailing {
                hostsFailing = false
                log.info("hosts access recovered")
            }
            return changed
        } catch {
            // Latched: a persistent failure at a 2 s tick must not log every tick.
            if !hostsFailing {
                hostsFailing = true
                log.error("hosts access failed: \(error)")
            }
            return false
        }
    }
```
In `reconcileApps`, change the comment on `pendingKill` to `/// pid → monotonic deadline for SIGKILL; `.infinity` once SIGKILL has been sent (waiting for it to disappear).` and replace the `if let deadline = pendingKill[app.pid]` block with:
```swift
            if let deadline = pendingKill[app.pid] {
                if deadline.isFinite, monotonic >= deadline {
                    processes.kill(pid: app.pid)
                    pendingKill[app.pid] = .infinity
                    killed.append(app.pid)
                    log.info("killed \(id) pid \(app.pid)")
                }
            } else {
```
(The `else` branch that sends SIGTERM is unchanged. `pendingKill` is still pruned to running pids at the top of the function, so a pid that finally exits is forgotten and a relaunch gets a fresh SIGTERM.)

- [ ] **Step 3: Run and commit**

Run: `swift test 2>&1 | grep -E "failed|error:|Executed"` → `Executed 74 tests, with 0 failures`.
```bash
git add Sources/FocusGuardCore/Reconciler.swift Tests/FocusGuardCoreTests
git commit -m "Core: latch hosts-failure logging; no re-signal after SIGKILL

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 11: Daemon — real adapters

No unit tests here: these are thin wrappers over the OS. They are verified by `focusguardd once` in Task 13.

**Files:**
- Create: `Sources/focusguardd/Paths.swift`
- Create: `Sources/focusguardd/SystemClock.swift`
- Create: `Sources/focusguardd/EtcHostsStore.swift`
- Create: `Sources/focusguardd/DSCacheFlusher.swift`
- Create: `Sources/focusguardd/LibprocProcessController.swift`
- Create: `Sources/focusguardd/OSLogAdapter.swift`
- Create: `Sources/focusguardd/ConfigFile.swift`

- [ ] **Step 1: Paths**

`Sources/focusguardd/Paths.swift`:
```swift
import Foundation

enum Paths {
    static let supportDir = "/Library/Application Support/FocusGuard"
    static let config = supportDir + "/config.json"
    static let lastGood = supportDir + "/last-good.json"
    static let clockState = supportDir + "/clock-state.json"
    static let hosts = "/etc/hosts"
    static let launchdLabel = "com.focusguard.daemon"
}
```

- [ ] **Step 2: System clock**

`Sources/focusguardd/SystemClock.swift`:
```swift
import Foundation
import FocusGuardCore

enum SystemClock {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    /// `mach_continuous_time` keeps counting while the machine sleeps, unlike `mach_absolute_time`.
    static func monotonicSeconds() -> TimeInterval {
        let ticks = mach_continuous_time()
        let nanos = Double(ticks) * Double(timebase.numer) / Double(timebase.denom)
        return nanos / 1_000_000_000
    }

    /// Monotonic values are only comparable within one boot; samples carry the boot session so a
    /// persisted anchor from a previous boot is never projected from.
    private static let bootSessionID: String = {
        if let uuid = sysctlString("kern.bootsessionuuid"), !uuid.isEmpty { return uuid }
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        if sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0 { return "boottime-\(tv.tv_sec)" }
        return "unknown-\(UUID().uuidString)"  // never matches a persisted anchor: fail safe
    }()

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }

    static func sample() -> ClockSample {
        ClockSample(wall: Date(), monotonic: monotonicSeconds(), boot: bootSessionID)
    }
}
```

- [ ] **Step 3: /etc/hosts store with atomic write**

`Sources/focusguardd/EtcHostsStore.swift`:
```swift
import Foundation
import FocusGuardCore

struct EtcHostsStore: HostsFileStore {
    let path: String

    func read() throws -> String {
        try String(contentsOfFile: path, encoding: .utf8)
    }

    /// Write to a sibling temp file, then rename over the original so readers never see a partial file.
    func write(_ contents: String) throws {
        let tmp = path + ".focusguard.tmp"
        try contents.write(toFile: tmp, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: tmp)
        if rename(tmp, path) != 0 {
            let err = errno
            try? FileManager.default.removeItem(atPath: tmp)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(err),
                          userInfo: [NSLocalizedDescriptionKey: "rename \(tmp) → \(path): \(String(cString: strerror(err)))"])
        }
    }
}
```

- [ ] **Step 4: DNS cache flusher**

`Sources/focusguardd/DSCacheFlusher.swift`:
```swift
import Foundation
import FocusGuardCore

struct DSCacheFlusher: DNSCacheFlusher {
    func flush() {
        run("/usr/bin/dscacheutil", ["-flushcache"])
        run("/usr/bin/killall", ["-HUP", "mDNSResponder"])
    }

    private func run(_ tool: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            fputs("focusguardd: \(tool) failed: \(error)\n", stderr)
        }
    }
}
```

- [ ] **Step 5: libproc process controller**

`Sources/focusguardd/LibprocProcessController.swift`:
```swift
import Darwin
import Foundation
import FocusGuardCore

/// Enumerates processes with libproc (works as root with no window server) and maps each
/// executable path to the bundle ID of the innermost `.app` containing it, so a helper like
/// `Slack.app/Contents/Frameworks/Slack Helper.app/...` reports the helper's own ID.
final class LibprocProcessController: ProcessController {
    private var bundleIDCache: [String: String?] = [:]

    func runningApps() -> [RunningApp] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard got > 0 else { return [] }
        return pids.prefix(Int(got)).compactMap { pid in
            guard pid > 0, let path = executablePath(pid) else { return nil }
            return RunningApp(pid: pid, bundleID: bundleID(forExecutablePath: path))
        }
    }

    func terminate(pid: Int32) { _ = Darwin.kill(pid, SIGTERM) }
    func kill(pid: Int32) { _ = Darwin.kill(pid, SIGKILL) }

    private func executablePath(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: Int(PROC_PIDPATHINFO_MAXSIZE))
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard n > 0 else { return nil }
        return String(cString: buf)
    }

    private func bundleID(forExecutablePath path: String) -> String? {
        guard let r = path.range(of: ".app/", options: .backwards) else { return nil }
        let bundlePath = String(path[..<r.lowerBound]) + ".app"
        if let cached = bundleIDCache[bundlePath] { return cached }
        let id = Bundle(path: bundlePath)?.bundleIdentifier
        bundleIDCache[bundlePath] = id
        return id
    }
}
```

If the compiler cannot find `proc_listallpids`/`proc_pidpath`, add `import Darwin.libproc` — but `import Darwin` is expected to be sufficient on this toolchain.

- [ ] **Step 6: os.Logger adapter**

`Sources/focusguardd/OSLogAdapter.swift`:
```swift
import Foundation
import os
import FocusGuardCore

struct OSLogAdapter: ReconcilerLog {
    private let logger = Logger(subsystem: "com.focusguard", category: "daemon")
    func info(_ message: String) { logger.info("\(message, privacy: .public)") }
    func error(_ message: String) { logger.error("\(message, privacy: .public)") }
}
```

View logs with: `log stream --predicate 'subsystem == "com.focusguard"' --level info`

- [ ] **Step 7: Config file access**

`Sources/focusguardd/ConfigFile.swift`:
```swift
import Foundation
import FocusGuardCore

enum ConfigFile {
    /// Create the support dir as root:admin 0775 so an admin user can write config.json.
    static func ensureSupportDir() throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: Paths.supportDir) {
            try fm.createDirectory(atPath: Paths.supportDir, withIntermediateDirectories: true)
        }
        try fm.setAttributes([.posixPermissions: 0o775, .groupOwnerAccountName: "admin"], ofItemAtPath: Paths.supportDir)
    }

    /// nil on any failure; the caller falls back to last-good.
    static func load(log: ReconcilerLog) -> Config? {
        guard let data = FileManager.default.contents(atPath: Paths.config) else { return nil }
        do {
            return try Config.decodeJSON(data)
        } catch {
            log.error("config.json unreadable: \(error)")
            return nil
        }
    }

    static func loadLastGood() -> Config? {
        guard let data = FileManager.default.contents(atPath: Paths.lastGood) else { return nil }
        return try? Config.decodeJSON(data)
    }

    static func saveLastGood(_ config: Config) {
        guard let data = try? config.encodeJSON() else { return }
        FileManager.default.createFile(atPath: Paths.lastGood, contents: data, attributes: [.posixPermissions: 0o600])
    }

    /// Clock-guard anchor, root-only. Only meaningful within one boot; ClockGuard discards it
    /// itself when the monotonic clock has gone backwards.
    static func loadClockState() -> ClockGuard.State? {
        guard let data = FileManager.default.contents(atPath: Paths.clockState) else { return nil }
        return try? JSONDecoder().decode(ClockGuard.State.self, from: data)
    }

    static func saveClockState(_ state: ClockGuard.State) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        FileManager.default.createFile(atPath: Paths.clockState, contents: data, attributes: [.posixPermissions: 0o600])
    }
}
```

- [ ] **Step 8: Build**

Run: `swift build 2>&1 | grep -E "error|Compiling|Build complete" | tail -3`
Expected: `Build complete!`

- [ ] **Step 9: Commit**

```bash
git add Sources/focusguardd
git commit -m "Daemon: real adapters for clock, hosts, DNS flush, libproc, logging, config file

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 12: Daemon — loop, signals, CLI

**Files:**
- Create: `Sources/focusguardd/Daemon.swift`
- Modify: `Sources/focusguardd/main.swift`

- [ ] **Step 1: Daemon loop**

`Sources/focusguardd/Daemon.swift`:
```swift
import Foundation
import FocusGuardCore

final class Daemon {
    /// While a window is active: fast sweep so a blocked app dies within ~2 s.
    static let activeTick: TimeInterval = 2
    /// Outside all windows: nothing to enforce, so wake rarely. A window boundary is
    /// therefore honoured within 30 s; the Plan 2 app tightens this with an exact timer.
    static let idleTick: TimeInterval = 30

    private let log = OSLogAdapter()
    private let reconciler: Reconciler
    private var timer: DispatchSourceTimer?
    private var currentInterval: TimeInterval = 0
    private var signalSources: [DispatchSourceSignal] = []
    private var lastSavedLastGood: Config?
    private var lastSavedClockState: ClockGuard.State?

    init() {
        lastSavedClockState = ConfigFile.loadClockState()
        reconciler = Reconciler(
            hosts: EtcHostsStore(path: Paths.hosts),
            dns: DSCacheFlusher(),
            processes: LibprocProcessController(),
            log: log,
            clockState: lastSavedClockState,
            resolver: ConfigResolver(lastGood: ConfigFile.loadLastGood()))
    }

    /// One reconcile pass. Safe to call from `once` or from the timer.
    func tick() {
        let live = ConfigFile.load(log: log)
        let result = reconciler.tick(live: live, clock: SystemClock.sample())
        if let good = reconciler.lastGoodConfig, good != lastSavedLastGood {
            ConfigFile.saveLastGood(good)
            lastSavedLastGood = good
        }
        // The anchor changes rarely (first run, reboot, 24 h reconverge), so this almost never writes.
        if let state = reconciler.clockState, state != lastSavedClockState {
            ConfigFile.saveClockState(state)
            lastSavedClockState = state
        }
        if result.hostsChanged || !result.terminated.isEmpty || !result.killed.isEmpty {
            log.info("tick: source=\(result.source) domains=\(result.activeSet.domains.count) apps=\(result.activeSet.bundleIDs.count)")
        }
        reschedule(interval: result.activeSet.bundleIDs.isEmpty ? Self.idleTick : Self.activeTick)
    }

    /// Generous leeway lets the kernel coalesce our wake-ups with everyone else's (timer coalescing),
    /// which is what keeps a periodic daemon off the battery radar.
    private func reschedule(interval: TimeInterval) {
        guard let timer, interval != currentInterval else { return }
        currentInterval = interval
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(Int(interval * 250)))
    }

    func run() -> Never {
        do {
            try ConfigFile.ensureSupportDir()
        } catch {
            log.error("cannot create \(Paths.supportDir): \(error)")
        }
        log.info("focusguardd starting, tick \(Self.activeTick)s active / \(Self.idleTick)s idle")

        // launchd sends SIGTERM on bootout; strip our hosts region before exiting.
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [self] in shutdown() }
            src.resume()
            signalSources.append(src)
        }

        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: Self.activeTick, leeway: .milliseconds(500))
        t.setEventHandler { [self] in tick() }
        timer = t
        currentInterval = Self.activeTick
        t.resume()

        dispatchMain()
    }

    private func shutdown() -> Never {
        log.info("focusguardd shutting down; clearing hosts region")
        reconciler.teardown()
        exit(0)
    }
}
```

- [ ] **Step 2: CLI entry point**

Replace `Sources/focusguardd/main.swift`:
```swift
import Foundation
import FocusGuardCore

let usage = """
usage: focusguardd <command>
  run     enforce forever (launchd entry point; needs root)
  once    single reconcile pass and exit (needs root)
  check   print what would be blocked right now (any user)
"""

func check() {
    let data = FileManager.default.contents(atPath: Paths.config)
    guard let data else {
        print("no config at \(Paths.config)")
        exit(1)
    }
    let config: Config
    do {
        config = try Config.decodeJSON(data)
    } catch {
        print("config.json invalid: \(error)")
        exit(1)
    }
    let moment = LocalMoment(date: Date())
    let active = config.activeSet(at: moment)
    print("now: \(moment.weekday) \(moment.minutesSinceMidnight / 60):\(String(format: "%02d", moment.minutesSinceMidnight % 60))")
    for w in config.schedules {
        print("  [\(w.isActive(at: moment) ? "ACTIVE" : "      ")] \(w.name) \(w.days.map(\.rawValue).sorted().joined(separator: ",")) \(w.start.string)-\(w.end.string)\(w.enabled ? "" : " (disabled)")")
    }
    print("domains: \(active.domains.sorted().joined(separator: " "))")
    print("apps:    \(active.bundleIDs.sorted().joined(separator: " "))")
}

func requireRoot() {
    if getuid() != 0 {
        fputs("focusguardd: this command needs root (run with sudo)\n", stderr)
        exit(2)
    }
}

switch CommandLine.arguments.dropFirst().first {
case "run":
    requireRoot()
    Daemon().run()
case "once":
    requireRoot()
    Daemon().tick()
case "check":
    check()
default:
    print(usage)
    exit(64)
}
```

- [ ] **Step 3: Build and smoke-test the unprivileged path**

Run: `swift build 2>&1 | tail -1 && .build/debug/focusguardd && .build/debug/focusguardd check`
Expected: `Build complete!`, then the usage text (exit 64), then `no config at /Library/Application Support/FocusGuard/config.json` (exit 1).

- [ ] **Step 4: Commit**

```bash
git add Sources/focusguardd/Daemon.swift Sources/focusguardd/main.swift
git commit -m "Daemon: 2s reconcile loop, SIGTERM teardown, run/once/check CLI

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 12b: Daemon hardening before launchd install (review fixes)

Review of Tasks 11–12 cleared `once` as safe to run but asked for these before the daemon runs permanently: (1) `fsync` the temp file before `rename` so a power loss cannot leave an empty `/etc/hosts`; (2) tolerate a Latin-1 hosts file on read; (3) latch the `config.json` decode-error log (a half-saved editor write spams the log at 2 s); (4) use wall-clock deadlines and cap the idle leeway at 2 s so a window boundary is honoured within 32 s even after sleep; (5) keep `last-good.json` and `clock-state.json` in a `0700 root:wheel` subdirectory so an admin user cannot delete them without `sudo`, matching spec §6; (6) ensure directories exist in `once` too.

**Files:**
- Modify: `Sources/focusguardd/EtcHostsStore.swift`, `ConfigFile.swift`, `Paths.swift`, `Daemon.swift`

- [ ] **Step 1: EtcHostsStore — durable atomic write, tolerant read**

Replace the whole file:
```swift
import Darwin
import Foundation
import FocusGuardCore

struct EtcHostsStore: HostsFileStore {
    let path: String

    struct EncodingError: Error {}

    func read() throws -> String {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        if let s = String(data: data, encoding: .utf8) { return s }
        // A hosts file with stray Latin-1 bytes must not make the site layer permanently inert.
        guard let s = String(data: data, encoding: .isoLatin1) else { throw EncodingError() }
        return s
    }

    /// Write to a sibling temp file, flush it to stable storage, then rename over the original,
    /// so readers never see a partial file and a power loss cannot leave an empty /etc/hosts.
    func write(_ contents: String) throws {
        let tmp = path + ".focusguard.tmp"
        let fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { throw posixError("open \(tmp)") }
        defer { close(fd) }
        guard fchmod(fd, 0o644) == 0 else { throw posixError("chmod \(tmp)") }

        let data = Data(contents.utf8)
        try data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            guard let base = buf.baseAddress else { return }
            var off = 0
            while off < buf.count {
                let n = Darwin.write(fd, base + off, buf.count - off)
                guard n > 0 else { throw posixError("write \(tmp)") }
                off += n
            }
        }
        guard fcntl(fd, F_FULLFSYNC) == 0 || fsync(fd) == 0 else { throw posixError("fsync \(tmp)") }
        guard rename(tmp, path) == 0 else {
            let err = posixError("rename \(tmp) → \(path)")
            try? FileManager.default.removeItem(atPath: tmp)
            throw err
        }
    }

    private func posixError(_ what: String) -> Error {
        let err = errno
        return NSError(domain: NSPOSIXErrorDomain, code: Int(err),
                       userInfo: [NSLocalizedDescriptionKey: "\(what): \(String(cString: strerror(err)))"])
    }
}
```

- [ ] **Step 2: Paths — root-only state subdirectory**

Replace the whole file:
```swift
import Foundation

enum Paths {
    static let supportDir = "/Library/Application Support/FocusGuard"   // root:admin 0775
    static let config = supportDir + "/config.json"                      // admin-writable
    static let stateDir = supportDir + "/state"                          // root:wheel 0700
    static let lastGood = stateDir + "/last-good.json"
    static let clockState = stateDir + "/clock-state.json"
    static let hosts = "/etc/hosts"
    static let launchdLabel = "com.focusguard.daemon"
}
```

- [ ] **Step 3: ConfigFile — create both dirs, latch decode errors**

Replace `ensureSupportDir` and `load` (leave the last-good / clock-state functions as they are):
```swift
    /// Support dir is root:admin 0775 so an admin user can write config.json; the state dir is
    /// root-only so the fail-closed snapshot and clock anchor cannot be removed without sudo.
    static func ensureSupportDir() throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: Paths.supportDir) {
            try fm.createDirectory(atPath: Paths.supportDir, withIntermediateDirectories: true)
        }
        try fm.setAttributes([.posixPermissions: 0o775, .groupOwnerAccountName: "admin"], ofItemAtPath: Paths.supportDir)
        if !fm.fileExists(atPath: Paths.stateDir) {
            try fm.createDirectory(atPath: Paths.stateDir, withIntermediateDirectories: false)
        }
        try fm.setAttributes([.posixPermissions: 0o700, .groupOwnerAccountName: "wheel"], ofItemAtPath: Paths.stateDir)
    }

    private static var lastDecodeError: String?

    /// nil on any failure; the caller falls back to last-good. Decode errors are logged once per
    /// distinct message, not every tick.
    static func load(log: ReconcilerLog) -> Config? {
        guard let data = FileManager.default.contents(atPath: Paths.config) else { return nil }
        do {
            let config = try Config.decodeJSON(data)
            if lastDecodeError != nil {
                lastDecodeError = nil
                log.info("config.json readable again")
            }
            return config
        } catch {
            let message = "\(error)"
            if message != lastDecodeError {
                lastDecodeError = message
                log.error("config.json unreadable: \(message)")
            }
            return nil
        }
    }
```

- [ ] **Step 4: Daemon — wall deadlines, capped leeway, dirs in `once`**

In `Daemon.swift`:
- Change the doc comment on `idleTick` to: `/// Outside all windows: nothing to enforce, so wake rarely. A window boundary is therefore honoured within idleTick + leeway (32 s); the Plan 2 app tightens this with an exact timer.`
- Move the `ensureSupportDir` call from `run()` into `init()` as its first statement, so `once` creates the directories too:
```swift
    init() {
        do {
            try ConfigFile.ensureSupportDir()
        } catch {
            log.error("cannot create \(Paths.supportDir): \(error)")
        }
        lastSavedClockState = ConfigFile.loadClockState()
        …
```
  and delete the `do { try ConfigFile.ensureSupportDir() } catch { … }` block from `run()`.
- Replace `reschedule` with:
```swift
    /// Wall-clock deadlines keep firing on schedule after sleep; a 2 s leeway still lets the kernel
    /// coalesce our wake-ups with everyone else's.
    private func reschedule(interval: TimeInterval) {
        guard let timer, interval != currentInterval else { return }
        currentInterval = interval
        timer.schedule(wallDeadline: .now() + interval, repeating: interval, leeway: .seconds(2))
    }
```
- Change the initial schedule line in `run()` to `t.schedule(wallDeadline: .now(), repeating: Self.activeTick, leeway: .milliseconds(500))`.

- [ ] **Step 5: Build, smoke, commit**

Run: `swift build 2>&1 | grep -E "error|warning|Build complete"` → `Build complete!`, no errors.
Run: `.build/debug/focusguardd check; echo exit=$?` → `no config at …`, `exit=1` (unchanged).
```bash
git add Sources/focusguardd
git commit -m "Daemon: fsync hosts writes, root-only state dir, latched config log, wall-clock timer

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 13: Example config + manual `once` verification

**Files:**
- Create: `examples/config.json`

- [ ] **Step 1: Write an example config with a window that is active right now**

Pick today's weekday and a window spanning the current time. The file below assumes Tuesday; edit `days`/`start`/`end` to match when you run it. (Spec note: the block list ID must match between `blockLists` and `blockListIDs`.)

`examples/config.json`:
```json
{
  "version": 1,
  "blockLists": [
    {
      "id": "0B1C2D3E-0000-4000-8000-000000000001",
      "name": "Distractions",
      "domains": ["example.com", "reddit.com"],
      "appBundleIDs": ["com.apple.Chess"]
    }
  ],
  "schedules": [
    {
      "id": "0B1C2D3E-0000-4000-8000-000000000002",
      "name": "Test window",
      "days": ["mon", "tue", "wed", "thu", "fri", "sat", "sun"],
      "start": "00:00",
      "end": "23:59",
      "blockListIDs": ["0B1C2D3E-0000-4000-8000-000000000001"],
      "enabled": true
    }
  ]
}
```

- [ ] **Step 2: Install the config and confirm `check` sees it**

```bash
sudo mkdir -p "/Library/Application Support/FocusGuard"
sudo cp examples/config.json "/Library/Application Support/FocusGuard/config.json"
.build/debug/focusguardd check
```
Expected: `[ACTIVE] Test window ...`, `domains: example.com reddit.com`, `apps: com.apple.Chess`.

- [ ] **Step 3: Back up /etc/hosts, open Chess, run one pass as root**

```bash
sudo cp /etc/hosts /tmp/hosts.before
open -a Chess
sleep 2
sudo .build/debug/focusguardd once
```
Expected: Chess quits within ~1 s. Then:

```bash
grep -A4 "FOCUSGUARD START" /etc/hosts
curl -sS -m 5 -o /dev/null -w "%{http_code}\n" https://example.com || echo "blocked (curl could not connect)"
```
Expected: four lines for `example.com` / `www.example.com` under the marker; curl fails to connect.

- [ ] **Step 4: Confirm release when no window is active**

Edit the installed config so `"enabled": false`, then:
```bash
sudo .build/debug/focusguardd once
grep -c FOCUSGUARD /etc/hosts; diff /tmp/hosts.before /etc/hosts && echo "hosts restored"
curl -sS -m 5 -o /dev/null -w "%{http_code}\n" https://example.com
```
Expected: `0`, `hosts restored`, `200`.

- [ ] **Step 5: Commit**

```bash
git add examples/config.json
git commit -m "Add example config for manual verification

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 14: launchd plist + install/uninstall scripts

**Files:**
- Create: `launchd/com.focusguard.daemon.plist`
- Create: `scripts/install-daemon.sh`
- Create: `scripts/uninstall-daemon.sh`

- [ ] **Step 1: launchd plist**

`launchd/com.focusguard.daemon.plist`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.focusguard.daemon</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/libexec/focusguardd</string>
        <string>run</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/Library/Logs/FocusGuard/daemon.log</string>
    <key>StandardErrorPath</key>
    <string>/Library/Logs/FocusGuard/daemon.log</string>
</dict>
</plist>
```

- [ ] **Step 2: Install script**

`scripts/install-daemon.sh`:
```bash
#!/bin/bash
# Build focusguardd in release mode and install it as a root launchd daemon.
# Plan 2 replaces this with SMAppService registration from the app bundle.
set -euo pipefail
cd "$(dirname "$0")/.."

LABEL=com.focusguard.daemon
BIN=/usr/local/libexec/focusguardd
PLIST=/Library/LaunchDaemons/$LABEL.plist

swift build -c release
sudo mkdir -p /usr/local/libexec /Library/Logs/FocusGuard "/Library/Application Support/FocusGuard"
sudo chown root:admin "/Library/Application Support/FocusGuard"
sudo chmod 775 "/Library/Application Support/FocusGuard"

if sudo launchctl print system/$LABEL >/dev/null 2>&1; then
    sudo launchctl bootout system/$LABEL
fi
sudo install -m 755 .build/release/focusguardd "$BIN"
sudo install -m 644 launchd/$LABEL.plist "$PLIST"
sudo chown root:wheel "$PLIST"
sudo launchctl bootstrap system "$PLIST"
sudo launchctl print system/$LABEL | grep -E "state|pid" | head -2
echo "installed. logs: log stream --predicate 'subsystem == \"com.focusguard\"' --level info"
```

- [ ] **Step 3: Uninstall script**

`scripts/uninstall-daemon.sh`:
```bash
#!/bin/bash
# Stop the daemon (its SIGTERM handler clears the hosts region) and remove installed files.
set -euo pipefail
LABEL=com.focusguard.daemon

if sudo launchctl print system/$LABEL >/dev/null 2>&1; then
    sudo launchctl bootout system/$LABEL
fi
sudo rm -f /Library/LaunchDaemons/$LABEL.plist /usr/local/libexec/focusguardd
if grep -q "FOCUSGUARD START" /etc/hosts; then
    echo "WARNING: hosts region still present; remove the block between the FOCUSGUARD markers in /etc/hosts by hand" >&2
    exit 1
fi
echo "uninstalled. config left in '/Library/Application Support/FocusGuard'"
```

- [ ] **Step 4: Make executable, install, verify on a live 2-minute window**

```bash
chmod +x scripts/*.sh
scripts/install-daemon.sh
```
Expected: `state = running`, a pid, and the "installed." line.

Now edit `/Library/Application Support/FocusGuard/config.json` so the schedule is `enabled: true` with `start` = one minute from now and `end` = three minutes from now (today's weekday in `days`). Then:

```bash
log stream --predicate 'subsystem == "com.focusguard"' --level info
```
Expected within ~2 s of `start`: `hosts region updated: 2 domain(s)`; `open -a Chess` is terminated within ~2 s; `https://example.com` fails in a browser (Safari, with no DoH, is the right test — Chrome with DoH is Plan 2's job). Within ~2 s of `end`: `hosts region updated: 0 domain(s)` and the site loads again.

- [ ] **Step 5: Verify KeepAlive and SIGTERM teardown**

```bash
sudo kill -9 $(sudo launchctl print system/com.focusguard.daemon | awk '/pid =/{print $3}')
sleep 3; sudo launchctl print system/com.focusguard.daemon | grep -E "state|pid" | head -2
```
Expected: a new pid, `state = running`. Then, with a window active and the region present:

```bash
sudo launchctl bootout system/com.focusguard.daemon; sleep 1; grep -c FOCUSGUARD /etc/hosts
scripts/install-daemon.sh
```
Expected: `0` (teardown stripped the region on SIGTERM), then reinstalled and running.

- [ ] **Step 6: Commit**

```bash
git add launchd scripts
git commit -m "Daemon: launchd plist and manual install/uninstall scripts

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 15: README + spec amendments

**Files:**
- Create: `README.md`
- Modify: `docs/superpowers/specs/2026-08-18-focusguard-design.md`

- [ ] **Step 1: README**

`README.md`:
```markdown
# FocusGuard

Lightweight macOS website + app blocker on a recurring weekly schedule. Single user, no
Apple Developer account. Design: `docs/superpowers/specs/2026-08-18-focusguard-design.md`.
Survey of prior art: `docs/research/2026-10-27-open-source-blockers.md`.

## Status

- [x] `FocusGuardCore` — schedule matching, active set, hosts region, clock-tamper guard,
      bounded fail-closed, reconciler. `swift test`.
- [x] `focusguardd` — root launchd daemon: `/etc/hosts` + app kill every 2 s.
- [ ] `FocusGuard.app` — menu-bar editor, `SMAppService` install, browser tab watcher (Plan 2).

## Install the daemon (manual, until the app exists)

    scripts/install-daemon.sh

Config lives at `/Library/Application Support/FocusGuard/config.json`
(see `examples/config.json`). The daemon re-reads it every 2 s; no restart needed.

    focusguardd check        # what would be blocked right now (any user)
    log stream --predicate 'subsystem == "com.focusguard"' --level info

## Recovery

If something goes wrong and you are locked out:

    sudo launchctl bootout system/com.focusguard.daemon

The daemon clears its `/etc/hosts` region on the way down. If it didn't, delete the lines
between `# FOCUSGUARD START` and `# FOCUSGUARD END` in `/etc/hosts`. The daemon only ever
touches that region.

Unreadable config is **fail-closed but bounded**: the last good config keeps being enforced
until its current window ends, then everything is released.

## Uninstall

    scripts/uninstall-daemon.sh
```

- [ ] **Step 2: Amend the spec with the locked-in decisions**

In `docs/superpowers/specs/2026-08-18-focusguard-design.md`, section 5a, change the first sentence from:

```
The daemon runs an idempotent reconciliation loop every ~20 seconds, on
config-file change, and on **system wake**
```
to:
```
The daemon runs an idempotent reconciliation loop every **2 seconds** (reading
`/etc/hosts` is free; it is only *written* on diff, so the short tick costs
nothing and makes "reconcile on wake" automatic)
```

In section 5a step 2, change the hosts example to include IPv6 sinks:
```
   # FOCUSGUARD START
   0.0.0.0 reddit.com
   0.0.0.0 www.reddit.com
   :: reddit.com
   :: www.reddit.com
   # FOCUSGUARD END
```
and change `Desired content = one `0.0.0.0` line (plus a `www.` line) per active domain.` to `Desired content = `0.0.0.0` and `::` lines, each also for `www.`, per active domain.`

In section 5a, replace the **Apps (event-driven…)** paragraph with:
```
**Apps (event-driven, Plan 2):** the user-session app subscribes to
`NSWorkspace.didLaunchApplicationNotification` and terminates a blocked bundle
ID the instant it launches. The daemon's 2 s sweep is the backstop and the
only layer that survives the app being quit.
```

In section 9, delete the bullet beginning "Whether the daemon (a non-GUI process running as root) receives `NSWorkspace` launch notifications" and the bullet beginning "Exact directory/file permission scheme", and add:
```
- *(resolved)* Config dir is `root:admin 0775`, `config.json` `0664`,
  `last-good.json` root-only `0600`. Event-driven app kill lives in the app.
```

- [ ] **Step 3: Commit**

```bash
git add README.md docs/superpowers/specs/2026-08-18-focusguard-design.md
git commit -m "README and spec amendments for the daemon decisions

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

## Self-review

**Spec coverage (sections → tasks):** §3 daemon target, Core module → T1, T11–12. §3 app target, SMAppService, Automation → Plan 2. §4 data model → T2 (days as `Set<Weekday>`, encoded as array). §5a compute active set → T4–5; hosts region → T6, T10; app sweep with SIGTERM→SIGKILL, helper exclusion → T10, T11 (last `.app/`); outside windows → T6/T10 tests. §5a event-driven kill → moved to Plan 2, spec amended T15. §5b tab watcher → Plan 2. §6 bounded fail-closed + last-good.json → T8, T11 (`saveLastGood`), T12. §6 clock tamper → T7, T10 test. §6 manual hosts edits preserved → T6 tests. §6 DST/timezone → `LocalMoment(date:calendar:)` T4. §6 recovery path → README T15. §7 unit + integration (fake hosts, fake clock, fake processes; enter/exit/clock-rewind/config-vanishes) → T10. §7 manual acceptance → T13, T14. §8 injectable ports → T9.

**Placeholder scan:** none. Every code step has full code; every run step has a command and expected output.

**Type consistency:** `ClockSample(wall:monotonic:)` used identically in T7, T10, T11, T12. `Reconciler.init(hosts:dns:processes:log:clockGuard:killGrace:resolver:calendar:)` matches T10 tests and T12 usage. `Reconciler.Result` fields (`activeSet`, `source`, `hostsChanged`, `terminated`, `killed`) match test assertions. `ConfigResolver.Source` cases `.live/.lastGood/.none` consistent. `Config.decodeJSON`/`encodeJSON` used in T2, T11, T12. `HostsRegion.apply(domains:to:)` argument order consistent in T6 and T10. `TimeOfDay.string` used in T12 `check`.
