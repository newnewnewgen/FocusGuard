# FocusGuard.app (Plan 2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A SwiftUI menu-bar app that edits `config.json`, shows status, installs `focusguardd` with `SMAppService` from inside its own bundle, kills blocked apps the instant they launch, and gates every weakening edit behind a per-window unlock mode (Basic / Friction / Impossible).

**Architecture:** All new decisions are pure functions in `FocusGuardCore` (next boundary, lock state, weakening check, challenge sentence), written test-first. The app target `FocusGuard` is a thin SwiftUI shell: one `@Observable` `AppModel` composes a file-backed `ConfigStore`, a single wall-clock `ScheduleClock`, an `NSWorkspace`-driven `AppKiller`, an `SMAppService` `Installer`, and an on-demand `DaemonProbe`. Nothing in the app is periodic. Spec: `docs/superpowers/specs/2026-08-18-focusguard-design.md` §10.

**Tech Stack:** Swift 5 language mode on the Swift 6.2.4 toolchain (`swift-tools-version: 5.10`), SwiftPM only (no Xcode project — `*.xcodeproj` is gitignored), SwiftUI `MenuBarExtra` + `Settings` scenes (macOS 14 minimum), Observation, ServiceManagement, AppKit (`NSWorkspace`, `NSRunningApplication`), libproc, `os.Logger`, XCTest. Ad-hoc code signing (`codesign -s -`); no developer account.

**Verified before planning (spike 2026-10-30):** an ad-hoc-signed bundle in `/Applications` with `Contents/Library/LaunchDaemons/<label>.plist` using `BundleProgram` + `ProgramArguments` registers via `SMAppService.daemon`; `register()` throws `SMAppServiceErrorDomain Code=1 "Operation not permitted"` while status becomes `.requiresApproval`; after the user enables it in System Settings → General → Login Items & Extensions → Allow in the Background, the daemon runs as uid 0 with argv from `ProgramArguments`. Treat that throw-plus-`requiresApproval` as success.

**Live-test caveat:** this Mac currently has the **manual** daemon installed (`/Library/LaunchDaemons/com.focusguard.daemon.plist`, binary at `/usr/local/libexec/focusguardd`) under the **same label** the app will register. Task 15 needs the user to run `scripts/uninstall-daemon.sh` (sudo password) before "Install protection" can work. `sudo` is not passwordless here; ask the user to run it in their terminal.

---

## File structure

```
FocusGuard/
├── Package.swift                              + executable target FocusGuard (SwiftUI app)
├── Sources/FocusGuardCore/
│   ├── Models.swift                           + UnlockMode; ScheduleWindow.unlockMode (default .friction)
│   ├── Schedule.swift                         + Weekday.next, LocalMoment.advanced(byMinutes:)
│   ├── ActiveSet.swift                        refactor: Config.items(ofLists:) used by activeSet
│   ├── Boundary.swift                         NEW Config.nextBoundary(after:calendar:), Config.windows(startingAt:)
│   ├── Lock.swift                             NEW LockState, Config.lockState(at:), Config.weakens(from:at:)
│   ├── Challenge.swift                        NEW Challenge.sentence / matches / words
│   └── Paths.swift                            MOVED from focusguardd (public)
├── Sources/focusguardd/Paths.swift            DELETED (uses Core's)
├── Sources/FocusGuard/                        NEW app target
│   ├── FocusGuardApp.swift                    @main: MenuBarExtra + Settings scenes
│   ├── Info.plist                             copied into the bundle by the build script
│   ├── Model/AppModel.swift                   @Observable hub: config, activeSet, lockState, edits, unlock gate
│   ├── Model/ConfigStore.swift                load/save config.json atomically, vnode watch
│   ├── Model/ScheduleClock.swift              one wall-clock timer + wake/clock-change observers
│   ├── Model/AppKiller.swift                  didLaunchApplicationNotification → terminate/forceTerminate
│   ├── Model/Installer.swift                  SMAppService daemon+agent, move to /Applications, legacy detect
│   ├── Model/DaemonProbe.swift                libproc scan for focusguardd (on demand)
│   ├── Model/InstalledApps.swift              running + /Applications scan for the Add-app sheet
│   ├── Views/MenuView.swift                   menu-bar dropdown content
│   ├── Views/SettingsView.swift               TabView: Status / Block Lists / Schedule
│   ├── Views/StatusTab.swift                  setup checklist ↔ health view
│   ├── Views/BlockListsTab.swift              sidebar + Sites/Apps detail
│   ├── Views/AddAppSheet.swift                searchable app picker
│   ├── Views/ScheduleTab.swift                window rows with day toggles, times, lists, mode, enabled
│   └── Views/ChallengeSheet.swift             captcha-style sentence + paste-proof field
├── Tests/FocusGuardCoreTests/
│   ├── ModelsTests.swift                      + unlockMode default decoding
│   ├── BoundaryTests.swift                    NEW
│   ├── LockTests.swift                        NEW
│   └── ChallengeTests.swift                   NEW
├── launchd/com.focusguard.daemon.plist        BundleProgram form (for the bundle)
├── launchd/com.focusguard.app.plist           NEW LaunchAgent for the app
├── scripts/build-app.sh                       NEW: swift build → build/FocusGuard.app, ad-hoc sign
├── scripts/install-daemon.sh                  writes its own absolute-path plist (fallback)
└── README.md                                  app install flow, fallback, unlock modes
```

Conventions: tests use `XCTest` + `@testable import FocusGuardCore`, one `final class XTests: XCTestCase` per file, fixtures as instance `let`s (see `Tests/FocusGuardCoreTests/ActiveSetTests.swift`). Run the full suite with `swift test 2>&1 | tail -5`. Commit after every task with the trailer `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.

---

### Task 1: `UnlockMode` on `ScheduleWindow`

**Files:**
- Modify: `Sources/FocusGuardCore/Models.swift` (ScheduleWindow struct, lines ~86–106)
- Test: `Tests/FocusGuardCoreTests/ModelsTests.swift`

- [ ] **Step 1: Write the failing tests** — append inside `ModelsTests`:

```swift
    func testUnlockModeDefaultsToFrictionWhenAbsent() throws {
        let json = """
        {"version":1,"blockLists":[],"schedules":[{"id":"0B1C2D3E-0000-4000-8000-000000000002",
         "name":"w","days":["mon"],"start":"09:00","end":"10:00","blockListIDs":[],"enabled":true}]}
        """
        let cfg = try Config.decodeJSON(Data(json.utf8))
        XCTAssertEqual(cfg.schedules[0].unlockMode, .friction)
    }

    func testUnlockModeRoundTripsAndOrders() throws {
        var w = ScheduleWindow(name: "w", days: [.mon], start: TimeOfDay("09:00")!, end: TimeOfDay("10:00")!, blockListIDs: [])
        w.unlockMode = .impossible
        let cfg = Config(schedules: [w])
        let decoded = try Config.decodeJSON(try cfg.encodeJSON())
        XCTAssertEqual(decoded.schedules[0].unlockMode, .impossible)
        XCTAssertTrue(String(data: try cfg.encodeJSON(), encoding: .utf8)!.contains("\"unlockMode\" : \"impossible\""))
        XCTAssertLessThan(UnlockMode.basic, UnlockMode.friction)
        XCTAssertLessThan(UnlockMode.friction, UnlockMode.impossible)
        XCTAssertEqual(max(UnlockMode.basic, .impossible), .impossible)
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter ModelsTests 2>&1 | grep -E "error|passed|failed" | head`
Expected: compile error `has no member 'unlockMode'`.

- [ ] **Step 3: Implement** — in `Models.swift`, add before `ScheduleWindow`:

```swift
/// How much friction the app puts in front of an edit that would unblock something while this
/// window is active. The daemon ignores it; it is the app's own gate (spec §10.4).
public enum UnlockMode: String, Codable, Comparable, CaseIterable, Hashable {
    case basic, friction, impossible

    private var rank: Int {
        switch self {
        case .basic: return 0
        case .friction: return 1
        case .impossible: return 2
        }
    }

    public static func < (a: UnlockMode, b: UnlockMode) -> Bool { a.rank < b.rank }

    public var title: String {
        switch self {
        case .basic: return "Basic"
        case .friction: return "Friction"
        case .impossible: return "Impossible"
        }
    }
}
```

Replace the `ScheduleWindow` struct with:

```swift
public struct ScheduleWindow: Codable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var days: Set<Weekday>
    public var start: TimeOfDay
    public var end: TimeOfDay
    public var blockListIDs: [UUID]
    public var enabled: Bool
    public var unlockMode: UnlockMode

    public init(id: UUID = UUID(), name: String, days: Set<Weekday>, start: TimeOfDay, end: TimeOfDay,
                blockListIDs: [UUID], enabled: Bool = true, unlockMode: UnlockMode = .friction) {
        self.id = id
        self.name = name
        self.days = days
        self.start = start
        self.end = end
        self.blockListIDs = blockListIDs
        self.enabled = enabled
        self.unlockMode = unlockMode
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, days, start, end, blockListIDs, enabled, unlockMode
    }

    /// Configs written before unlock modes existed decode as `.friction`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        days = try c.decode(Set<Weekday>.self, forKey: .days)
        start = try c.decode(TimeOfDay.self, forKey: .start)
        end = try c.decode(TimeOfDay.self, forKey: .end)
        blockListIDs = try c.decode([UUID].self, forKey: .blockListIDs)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        unlockMode = try c.decodeIfPresent(UnlockMode.self, forKey: .unlockMode) ?? .friction
    }
}
```

(The synthesized `encode(to:)` still applies because only `init(from:)` is hand-written.)

- [ ] **Step 4: Run the whole suite**

Run: `swift test 2>&1 | tail -3`
Expected: `Executed 77 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Sources/FocusGuardCore/Models.swift Tests/FocusGuardCoreTests/ModelsTests.swift
git commit -m "Core: UnlockMode per schedule window, defaults to friction

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: Minute arithmetic on `LocalMoment`

**Files:**
- Modify: `Sources/FocusGuardCore/Models.swift` (Weekday, add `next`)
- Modify: `Sources/FocusGuardCore/Schedule.swift` (LocalMoment)
- Test: `Tests/FocusGuardCoreTests/ScheduleTests.swift`

- [ ] **Step 1: Failing tests** — append to `ScheduleTests`:

```swift
    func testWeekdayNext() {
        XCTAssertEqual(Weekday.mon.next, .tue)
        XCTAssertEqual(Weekday.sun.next, .mon)
    }

    func testLocalMomentAdvancesAcrossMidnight() {
        let m = LocalMoment(weekday: .mon, minutesSinceMidnight: 23 * 60 + 50)
        XCTAssertEqual(m.advanced(byMinutes: 5), LocalMoment(weekday: .mon, minutesSinceMidnight: 23 * 60 + 55))
        XCTAssertEqual(m.advanced(byMinutes: 10), LocalMoment(weekday: .tue, minutesSinceMidnight: 0))
        XCTAssertEqual(m.advanced(byMinutes: 10 + 1440), LocalMoment(weekday: .wed, minutesSinceMidnight: 0))
        XCTAssertEqual(m.timeOfDay, TimeOfDay("23:50")!)
    }
```

- [ ] **Step 2: Run** `swift test --filter ScheduleTests 2>&1 | grep -E "error|Executed" | head -3` — expect compile errors for `next`, `advanced`, `timeOfDay`.

- [ ] **Step 3: Implement.** In `Models.swift` add to `Weekday` after `previous`:

```swift
    public var next: Weekday {
        let all = Weekday.allCases
        let i = all.firstIndex(of: self)!
        return all[(i + 1) % all.count]
    }
```

In `Schedule.swift` add to `LocalMoment`:

```swift
    /// Same clock, `n` minutes later (n ≥ 0), rolling over weekdays.
    public func advanced(byMinutes n: Int) -> LocalMoment {
        var total = minutesSinceMidnight + n
        var day = weekday
        while total >= 1440 {
            total -= 1440
            day = day.next
        }
        return LocalMoment(weekday: day, minutesSinceMidnight: total)
    }

    public var timeOfDay: TimeOfDay {
        TimeOfDay(hour: minutesSinceMidnight / 60, minute: minutesSinceMidnight % 60)!
    }
```

- [ ] **Step 4: Run** `swift test 2>&1 | tail -3` → 79 tests, 0 failures.

- [ ] **Step 5: Commit** `git commit -am "Core: Weekday.next, LocalMoment.advanced(byMinutes:)" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"`

---

### Task 3: `Config.nextBoundary(after:)` and `windows(startingAt:)`

**Files:**
- Create: `Sources/FocusGuardCore/Boundary.swift`
- Test: `Tests/FocusGuardCoreTests/BoundaryTests.swift`

- [ ] **Step 1: Failing tests**

```swift
import XCTest
@testable import FocusGuardCore

final class BoundaryTests: XCTestCase {
    // A fixed calendar so tests do not depend on the machine's zone.
    var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Vancouver")!
        return c
    }()

    /// 2026-10-26 is a Monday.
    func date(_ day: Int, _ h: Int, _ m: Int, month: Int = 10) -> Date {
        cal.date(from: DateComponents(year: 2026, month: month, day: day, hour: h, minute: m))!
    }

    let list = BlockList(name: "L", domains: ["a.com"])

    func window(_ days: Set<Weekday>, _ s: String, _ e: String, enabled: Bool = true) -> ScheduleWindow {
        ScheduleWindow(name: "w", days: days, start: TimeOfDay(s)!, end: TimeOfDay(e)!, blockListIDs: [list.id], enabled: enabled)
    }

    func testNextBoundaryIsStartThenEndSameDay() {
        let cfg = Config(blockLists: [list], schedules: [window([.mon], "09:00", "12:00")])
        XCTAssertEqual(cfg.nextBoundary(after: date(26, 8, 0), calendar: cal), date(26, 9, 0))
        XCTAssertEqual(cfg.nextBoundary(after: date(26, 9, 0), calendar: cal), date(26, 12, 0))
        XCTAssertEqual(cfg.nextBoundary(after: date(26, 10, 30), calendar: cal), date(26, 12, 0))
    }

    func testNextBoundaryWrapsToNextWeek() {
        let cfg = Config(blockLists: [list], schedules: [window([.mon], "09:00", "12:00")])
        // Monday 13:00 → next Monday 09:00 (Nov 2).
        XCTAssertEqual(cfg.nextBoundary(after: date(26, 13, 0), calendar: cal), date(2, 9, 0, month: 11))
    }

    func testMidnightCrossingWindowEndsOnFollowingDay() {
        let cfg = Config(blockLists: [list], schedules: [window([.mon], "22:00", "02:00")])
        XCTAssertEqual(cfg.nextBoundary(after: date(26, 23, 0), calendar: cal), date(27, 2, 0))
        XCTAssertEqual(cfg.nextBoundary(after: date(26, 21, 0), calendar: cal), date(26, 22, 0))
    }

    func testDisabledEmptyAndDegenerateWindowsAreIgnored() {
        let cfg = Config(blockLists: [list], schedules: [
            window([.mon], "09:00", "12:00", enabled: false),
            window([.mon], "10:00", "10:00"),
        ])
        XCTAssertNil(cfg.nextBoundary(after: date(26, 8, 0), calendar: cal))
        XCTAssertNil(Config.empty.nextBoundary(after: date(26, 8, 0), calendar: cal))
    }

    func testEarliestAcrossWindowsWins() {
        let cfg = Config(blockLists: [list], schedules: [window([.mon], "09:00", "12:00"), window([.mon], "08:30", "08:45")])
        XCTAssertEqual(cfg.nextBoundary(after: date(26, 8, 0), calendar: cal), date(26, 8, 30))
    }

    func testDSTFallBackDayStillFindsBoundary() {
        // Nov 1 2026 is the fall-back Sunday in Vancouver.
        let cfg = Config(blockLists: [list], schedules: [window([.sun], "09:00", "12:00")])
        XCTAssertEqual(cfg.nextBoundary(after: date(1, 0, 30, month: 11), calendar: cal), date(1, 9, 0, month: 11))
    }

    func testWindowsStartingAtMoment() {
        let a = window([.mon], "09:00", "12:00")
        let b = window([.mon], "09:00", "10:00")
        let c = window([.tue], "09:00", "10:00")
        let cfg = Config(blockLists: [list], schedules: [a, b, c])
        XCTAssertEqual(cfg.windows(startingAt: LocalMoment(weekday: .mon, minutesSinceMidnight: 540)).map(\.id), [a.id, b.id])
        XCTAssertTrue(cfg.windows(startingAt: LocalMoment(weekday: .mon, minutesSinceMidnight: 541)).isEmpty)
    }
}
```

- [ ] **Step 2: Run** `swift test --filter BoundaryTests 2>&1 | grep -E "error" | head -3` — expect `no member 'nextBoundary'`.

- [ ] **Step 3: Implement** `Sources/FocusGuardCore/Boundary.swift`:

```swift
import Foundation

extension Config {
    /// The next instant strictly after `date` at which any enabled window starts or ends, or nil
    /// when no window can ever fire. Searches nine calendar days so a once-a-week window wraps.
    /// The app arms its single timer on this.
    public func nextBoundary(after date: Date, calendar: Calendar = .current) -> Date? {
        let startOfToday = calendar.startOfDay(for: date)
        for dayOffset in 0...8 {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: startOfToday) else { continue }
            let weekday = Weekday(calendarWeekday: calendar.component(.weekday, from: day))
            var best: Date?
            for w in schedules where w.enabled && w.start != w.end {
                var times: [TimeOfDay] = []
                if w.days.contains(weekday) {
                    times.append(w.start)
                    if w.start < w.end { times.append(w.end) }
                }
                // A midnight-crossing window started yesterday ends today.
                if w.start > w.end && w.days.contains(weekday.previous) { times.append(w.end) }
                for t in times {
                    guard let d = calendar.date(bySettingHour: t.hour, minute: t.minute, second: 0, of: day), d > date else { continue }
                    if best == nil || d < best! { best = d }
                }
            }
            if let best { return best }
        }
        return nil
    }

    /// Enabled windows whose start is exactly `moment`, in config order (for "Next: Evening at 19:00").
    public func windows(startingAt moment: LocalMoment) -> [ScheduleWindow] {
        schedules.filter { $0.enabled && $0.start != $0.end && $0.days.contains(moment.weekday) && $0.start.minutesSinceMidnight == moment.minutesSinceMidnight }
    }
}
```

- [ ] **Step 4: Run** `swift test 2>&1 | tail -3` → 86 tests, 0 failures. If the DST test fails because `date(bySettingHour:)` picks the wrong instant, replace that call with `calendar.date(byAdding: DateComponents(hour: t.hour, minute: t.minute), to: day)` and re-run; keep whichever passes all six boundary tests.

- [ ] **Step 5: Commit** `git add -A && git commit -m "Core: nextBoundary(after:) and windows(startingAt:)" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"`

---

### Task 4: `LockState` and `weakens`

**Files:**
- Modify: `Sources/FocusGuardCore/ActiveSet.swift` (extract `items(ofLists:)`)
- Create: `Sources/FocusGuardCore/Lock.swift`
- Test: `Tests/FocusGuardCoreTests/LockTests.swift`

- [ ] **Step 1: Failing tests**

```swift
import XCTest
@testable import FocusGuardCore

final class LockTests: XCTestCase {
    let social = BlockList(name: "Social", domains: ["reddit.com"], appBundleIDs: ["com.slack"])
    let games = BlockList(name: "Games", domains: ["steampowered.com"])
    let mon10 = LocalMoment(weekday: .mon, minutesSinceMidnight: 10 * 60)

    func w(_ name: String, _ s: String, _ e: String, lists: [BlockList], mode: UnlockMode, days: Set<Weekday> = [.mon]) -> ScheduleWindow {
        ScheduleWindow(name: name, days: days, start: TimeOfDay(s)!, end: TimeOfDay(e)!, blockListIDs: lists.map(\.id), unlockMode: mode)
    }

    // MARK: lockState

    func testIdleConfigHasNoLocks() {
        let cfg = Config(blockLists: [social], schedules: [w("a", "11:00", "12:00", lists: [social], mode: .impossible)])
        let s = cfg.lockState(at: mon10)
        XCTAssertEqual(s, LockState())
        XCTAssertNil(s.lockedUntil)
    }

    func testActiveWindowLocksItsListsWithStrictestMode() {
        let a = w("a", "09:00", "12:00", lists: [social], mode: .friction)
        let b = w("b", "09:30", "10:30", lists: [social, games], mode: .impossible)
        let cfg = Config(blockLists: [social, games], schedules: [a, b])
        let s = cfg.lockState(at: mon10)
        XCTAssertEqual(s.windowModes, [a.id: .friction, b.id: .impossible])
        XCTAssertEqual(s.listModes, [social.id: .impossible, games.id: .impossible])
        XCTAssertEqual(s.overall, .impossible)
        XCTAssertEqual(s.lockedUntil, TimeOfDay("12:00")!)
    }

    func testLockedUntilSpansBackToBackWindowsAndMidnight() {
        let a = w("a", "09:00", "12:00", lists: [social], mode: .basic)
        let b = w("b", "12:00", "01:00", lists: [games], mode: .basic)
        let cfg = Config(blockLists: [social, games], schedules: [a, b])
        XCTAssertEqual(cfg.lockState(at: mon10).lockedUntil, TimeOfDay("01:00")!)
    }

    func testTwentyFourSevenWindowLocksForAtMostADay() {
        let a = w("a", "00:00", "23:59", lists: [social], mode: .basic, days: Set(Weekday.allCases))
        let cfg = Config(blockLists: [social], schedules: [a])
        // Only the one-minute gap at 23:59 ends it.
        XCTAssertEqual(cfg.lockState(at: mon10).lockedUntil, TimeOfDay("23:59")!)
    }

    // MARK: weakens

    func testNoChangeOrAdditionNeverWeakens() {
        let a = w("a", "09:00", "12:00", lists: [social], mode: .impossible)
        let old = Config(blockLists: [social], schedules: [a])
        var new = old
        new.blockLists[0].domains.append("youtube.com")
        new.schedules.append(w("b", "13:00", "14:00", lists: [social], mode: .basic))
        XCTAssertNil(old.weakens(from: old, at: mon10))
        XCTAssertNil(new.weakens(from: old, at: mon10))
    }

    func testRemovingActiveItemWeakensWithWindowMode() {
        let a = w("a", "09:00", "12:00", lists: [social], mode: .friction)
        let old = Config(blockLists: [social], schedules: [a])
        var new = old
        new.blockLists[0].domains = []
        XCTAssertEqual(new.weakens(from: old, at: mon10), .friction)
        var new2 = old
        new2.blockLists[0].appBundleIDs = []
        XCTAssertEqual(new2.weakens(from: old, at: mon10), .friction)
    }

    func testRemovalCoveredByAnotherActiveListDoesNotWeaken() {
        let dup = BlockList(name: "Dup", domains: ["reddit.com"], appBundleIDs: ["com.slack"])
        let a = w("a", "09:00", "12:00", lists: [social, dup], mode: .impossible)
        let old = Config(blockLists: [social, dup], schedules: [a])
        var new = old
        new.blockLists.removeAll { $0.id == dup.id }
        new.schedules[0].blockListIDs = [social.id]
        XCTAssertNil(new.weakens(from: old, at: mon10))
    }

    func testShorteningEndWeakensExtendingDoesNot() {
        let a = w("a", "09:00", "12:00", lists: [social], mode: .impossible)
        let old = Config(blockLists: [social], schedules: [a])
        var shorter = old
        shorter.schedules[0].end = TimeOfDay("11:00")!
        XCTAssertEqual(shorter.weakens(from: old, at: mon10), .impossible)
        var longer = old
        longer.schedules[0].end = TimeOfDay("13:00")!
        XCTAssertNil(longer.weakens(from: old, at: mon10))
    }

    func testDisablingDeletingOrRemovingTodayWeakens() {
        let a = w("a", "09:00", "12:00", lists: [social], mode: .basic)
        let old = Config(blockLists: [social], schedules: [a])
        var disabled = old; disabled.schedules[0].enabled = false
        XCTAssertEqual(disabled.weakens(from: old, at: mon10), .basic)
        var deleted = old; deleted.schedules = []
        XCTAssertEqual(deleted.weakens(from: old, at: mon10), .basic)
        var noMonday = old; noMonday.schedules[0].days = [.tue]
        XCTAssertEqual(noMonday.weakens(from: old, at: mon10), .basic)
    }

    func testLoweringModeOfActiveWindowWeakensAtOldMode() {
        let a = w("a", "09:00", "12:00", lists: [social], mode: .impossible)
        let old = Config(blockLists: [social], schedules: [a])
        var new = old
        new.schedules[0].unlockMode = .basic
        XCTAssertEqual(new.weakens(from: old, at: mon10), .impossible)
        var raised = old
        raised.schedules[0].unlockMode = .impossible
        XCTAssertNil(raised.weakens(from: old, at: mon10))
    }

    func testFutureCutWithinActiveStretchIsCaught() {
        // Edit does not change the active set *now* but removes coverage at 11:00, still inside the window.
        let a = w("a", "09:00", "11:00", lists: [social], mode: .friction)
        let b = w("b", "11:00", "12:00", lists: [social], mode: .impossible)
        let old = Config(blockLists: [social], schedules: [a, b])
        var new = old
        new.schedules.removeAll { $0.id == b.id }
        XCTAssertEqual(new.weakens(from: old, at: mon10), .impossible)
    }

    func testEditsOutsideAnyActiveWindowAreFree() {
        let a = w("a", "11:00", "12:00", lists: [social], mode: .impossible)
        let old = Config(blockLists: [social], schedules: [a])
        var new = old
        new.schedules = []
        XCTAssertNil(new.weakens(from: old, at: mon10))
    }
}
```

- [ ] **Step 2: Run** `swift test --filter LockTests 2>&1 | grep error | head -3` — expect `cannot find 'LockState'`.

- [ ] **Step 3: Implement.** Replace the `extension Config` in `ActiveSet.swift` with:

```swift
extension Config {
    /// Normalized domains and trimmed bundle IDs of the given lists; dangling IDs are ignored.
    public func items(ofLists ids: [UUID]) -> ActiveSet {
        let wanted = Set(ids)
        var out = ActiveSet.empty
        for list in blockLists where wanted.contains(list.id) {
            out.domains.formUnion(list.domains.map(DomainNormalizer.normalize).filter { !$0.isEmpty })
            out.bundleIDs.formUnion(list.appBundleIDs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        }
        return out
    }

    public func activeSet(at moment: LocalMoment) -> ActiveSet {
        items(ofLists: schedules.filter { $0.isActive(at: moment) }.flatMap(\.blockListIDs))
    }
}
```

Add to `ActiveSet` the subset helper:

```swift
    public func isSubset(of other: ActiveSet) -> Bool {
        domains.isSubset(of: other.domains) && bundleIDs.isSubset(of: other.bundleIDs)
    }
```

Create `Sources/FocusGuardCore/Lock.swift`:

```swift
import Foundation

/// What the app must not let the user weaken right now, and how hard it should resist.
/// Only `.friction` and `.impossible` change the UI; `.basic` is recorded so callers can tell
/// "protected by a basic window" from "not protected at all".
public struct LockState: Equatable {
    /// Lists attached to at least one active window → strictest mode among those windows.
    public var listModes: [UUID: UnlockMode] = [:]
    /// Active windows → their own mode.
    public var windowModes: [UUID: UnlockMode] = [:]
    /// Strictest mode of any active window; gates quitting the app and uninstalling.
    public var overall: UnlockMode? = nil
    /// When the current active stretch ends (max 24 h out); nil when nothing is active.
    public var lockedUntil: TimeOfDay? = nil

    public init(listModes: [UUID: UnlockMode] = [:], windowModes: [UUID: UnlockMode] = [:],
                overall: UnlockMode? = nil, lockedUntil: TimeOfDay? = nil) {
        self.listModes = listModes
        self.windowModes = windowModes
        self.overall = overall
        self.lockedUntil = lockedUntil
    }
}

extension Config {
    /// Longest stretch `weakens` and `lockedUntil` look ahead: a 24/7 schedule must still release.
    static let lockHorizonMinutes = 1440

    public func lockState(at moment: LocalMoment) -> LockState {
        var state = LockState()
        for w in schedules where w.isActive(at: moment) {
            state.windowModes[w.id] = w.unlockMode
            state.overall = max(state.overall ?? w.unlockMode, w.unlockMode)
            for id in w.blockListIDs {
                state.listModes[id] = max(state.listModes[id] ?? w.unlockMode, w.unlockMode)
            }
        }
        guard state.overall != nil else { return state }
        for step in 1...Self.lockHorizonMinutes {
            let m = moment.advanced(byMinutes: step)
            if !schedules.contains(where: { $0.isActive(at: m) }) {
                state.lockedUntil = m.timeOfDay
                break
            }
        }
        return state
    }

    /// nil when replacing `old` with `self` unblocks nothing before `old` would have; otherwise the
    /// strictest unlock mode among the `old` windows whose protection is cut. Walks minute by minute
    /// from `moment` until `old` has no active window (at most 24 h), so shortening an end time or
    /// deleting a window that starts later in the same stretch is caught even though the active set
    /// at `moment` is unchanged. Lowering a window's mode is itself a cut (it weakens what guards it).
    public func weakens(from old: Config, at moment: LocalMoment) -> UnlockMode? {
        var worst: UnlockMode?
        for step in 0..<Self.lockHorizonMinutes {
            let m = moment.advanced(byMinutes: step)
            let oldActive = old.schedules.filter { $0.isActive(at: m) }
            if oldActive.isEmpty { break }
            let newSet = activeSet(at: m)
            for w in oldActive {
                let protected = old.items(ofLists: w.blockListIDs)
                let newMode = schedules.first { $0.id == w.id }?.unlockMode
                let cut = !protected.isSubset(of: newSet) || (newMode ?? .basic) < w.unlockMode
                if cut { worst = max(worst ?? w.unlockMode, w.unlockMode) }
            }
            if worst == .impossible { break }
        }
        return worst
    }
}
```

Note on the mode check: a window deleted in `self` has `newMode == nil`; if its items are still covered by another window the items test passes, and `(nil ?? .basic) < w.unlockMode` is only true when the deleted window was stricter than basic — which is the intended "you removed an impossible guard" case. For a basic window that is fully covered elsewhere, deletion is free. The test `testRemovalCoveredByAnotherActiveListDoesNotWeaken` keeps the window, so it passes.

- [ ] **Step 4: Run** `swift test 2>&1 | tail -3` → 98 tests, 0 failures.

- [ ] **Step 5: Commit** `git add -A && git commit -m "Core: LockState and weakens(from:at:) for unlock modes" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"`

---

### Task 5: `Challenge` sentences

**Files:**
- Create: `Sources/FocusGuardCore/Challenge.swift`
- Test: `Tests/FocusGuardCoreTests/ChallengeTests.swift`

- [ ] **Step 1: Failing tests**

```swift
import XCTest
@testable import FocusGuardCore

/// Deterministic generator so sentences are reproducible in tests (SplitMix64).
struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

final class ChallengeTests: XCTestCase {
    func testSentenceHasRequestedWordCountFromWordList() {
        var rng = SeededRNG(state: 1)
        let s = Challenge.sentence(wordCount: 10, using: &rng)
        let words = s.split(separator: " ").map(String.init)
        XCTAssertEqual(words.count, 10)
        XCTAssertTrue(words.allSatisfy { Challenge.words.contains($0) }, s)
    }

    func testSentenceIsDeterministicForSeedAndVariesAcrossSeeds() {
        var a = SeededRNG(state: 7), b = SeededRNG(state: 7), c = SeededRNG(state: 8)
        XCTAssertEqual(Challenge.sentence(wordCount: 8, using: &a), Challenge.sentence(wordCount: 8, using: &b))
        var a2 = SeededRNG(state: 7)
        XCTAssertNotEqual(Challenge.sentence(wordCount: 8, using: &a2), Challenge.sentence(wordCount: 8, using: &c))
    }

    func testWordListIsLargeLowercaseAndUnique() {
        XCTAssertGreaterThanOrEqual(Challenge.words.count, 200)
        XCTAssertEqual(Set(Challenge.words).count, Challenge.words.count)
        XCTAssertTrue(Challenge.words.allSatisfy { $0 == $0.lowercased() && $0.count >= 3 && $0.count <= 8 })
    }

    func testMatchesIsExactExceptSurroundingWhitespace() {
        XCTAssertTrue(Challenge.matches(typed: "river stone clock", sentence: "river stone clock"))
        XCTAssertTrue(Challenge.matches(typed: " river stone clock \n", sentence: "river stone clock"))
        XCTAssertFalse(Challenge.matches(typed: "River stone clock", sentence: "river stone clock"))
        XCTAssertFalse(Challenge.matches(typed: "river  stone clock", sentence: "river stone clock"))
        XCTAssertFalse(Challenge.matches(typed: "river stone", sentence: "river stone clock"))
    }
}
```

- [ ] **Step 2: Run** `swift test --filter ChallengeTests 2>&1 | grep error | head -2` — expect `cannot find 'Challenge'`.

- [ ] **Step 3: Implement** `Sources/FocusGuardCore/Challenge.swift`:

```swift
import Foundation

/// The Friction unlock: a random sentence the user must type word for word (spec §10.4).
public enum Challenge {
    public static let defaultWordCount = 10

    /// Common, unambiguous, easy-to-type words (3–8 letters, lowercase, no homophones that
    /// an OCR'd screenshot would make trivially guessable).
    public static let words: [String] = """
    about above across after again against along among animal answer around arrive basket beach \
    before begin behind below beside better between beyond bottle branch bread bridge bright broken \
    brother butter button camera candle carpet castle cattle center chance change cheese circle \
    class clock cloud coffee color corner cotton count country cousin cover crowd dance danger \
    daughter decide desert dinner doctor dollar double dragon dream dress drink early earth eight \
    either empty enemy engine enough evening every expect family famous farmer father field fight \
    figure finger finish flower follow forest forget forward friend front fruit future garden gather \
    gentle giant glass golden grass green ground guard guess hammer happen harbor heavy hidden \
    history honey horse hotel hundred hunger hurry island jacket journey jungle kitchen ladder \
    language large laugh leader learn leather letter level light listen little lonely machine magic \
    manner marble market master matter meadow member memory metal middle minute mirror modern \
    moment money monkey morning mother mountain music narrow nation nature needle never night \
    noise north notice number object ocean office orange order other paint palace paper parent \
    pattern pencil people pepper person picture pillow planet plant pocket point police potato \
    powder power pretty prince prison pupil puzzle quarter question quick quiet rabbit rather reach \
    reason record remain repeat rescue return ribbon river rocket round saddle salad school second \
    secret seven shadow shelter shout signal silent silver simple single sister sleep smile smoke \
    soldier south speak spider spring square stone story stream street strong sudden sugar summer \
    supper table teacher temple thick thirty thread throat thunder ticket timber tomato tongue \
    tower travel treasure trouble turtle twelve twenty uncle under until valley velvet village \
    voice wagon watch water weather wheel whisper window winter wonder wooden yellow young
    """.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)

    /// `wordCount` words drawn with replacement from `words`, joined by single spaces.
    public static func sentence(wordCount: Int = defaultWordCount, using rng: inout some RandomNumberGenerator) -> String {
        (0..<max(wordCount, 1)).map { _ in words.randomElement(using: &rng)! }.joined(separator: " ")
    }

    /// Convenience with the system generator.
    public static func sentence(wordCount: Int = defaultWordCount) -> String {
        var rng = SystemRandomNumberGenerator()
        return sentence(wordCount: wordCount, using: &rng)
    }

    /// Exact match after trimming leading/trailing whitespace and newlines. Case and internal
    /// spacing must match.
    public static func matches(typed: String, sentence: String) -> Bool {
        typed.trimmingCharacters(in: .whitespacesAndNewlines) == sentence
    }
}
```

- [ ] **Step 4: Run** `swift test 2>&1 | tail -3` → 102 tests, 0 failures. If `testWordListIsLargeLowercaseAndUnique` reports a duplicate or an over-long word, fix the list (keep ≥ 200 words).

- [ ] **Step 5: Commit** `git add -A && git commit -m "Core: Challenge sentence generator for the Friction unlock" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"`

---

### Task 6: Move `Paths` into Core; launchd plists for the bundle; fallback script

**Files:**
- Create: `Sources/FocusGuardCore/Paths.swift`
- Delete: `Sources/focusguardd/Paths.swift`
- Modify: `launchd/com.focusguard.daemon.plist`
- Create: `launchd/com.focusguard.app.plist`
- Modify: `scripts/install-daemon.sh`

- [ ] **Step 1: Move Paths.**

```bash
git mv Sources/focusguardd/Paths.swift Sources/FocusGuardCore/Paths.swift
```

Replace its contents with:

```swift
import Foundation

/// Filesystem locations shared by the daemon (writer of state, reader of config) and the app
/// (writer of config). Permissions are set by the daemon at start (spec §9).
public enum Paths {
    public static let supportDir = "/Library/Application Support/FocusGuard"   // root:admin 0775
    public static let config = supportDir + "/config.json"                      // admin-writable 0664
    public static let stateDir = supportDir + "/state"                          // root:wheel 0700
    public static let lastGood = stateDir + "/last-good.json"
    public static let clockState = stateDir + "/clock-state.json"
    public static let hosts = "/etc/hosts"

    public static let daemonLabel = "com.focusguard.daemon"
    public static let agentLabel = "com.focusguard.app"
    /// Where the manual installer (scripts/install-daemon.sh) puts things; the app refuses to
    /// register while these exist because the label would collide.
    public static let legacyDaemonPlist = "/Library/LaunchDaemons/" + daemonLabel + ".plist"
    public static let legacyDaemonBinary = "/usr/local/libexec/focusguardd"
}
```

Run: `swift build 2>&1 | grep -E "error|Compiling|Build" | tail -3` — expect `Build complete`. (`focusguardd` already imports `FocusGuardCore`, so `Paths.x` resolves unchanged.)

- [ ] **Step 2: Rewrite `launchd/com.focusguard.daemon.plist`** for the bundle:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.focusguard.daemon</string>
    <key>BundleProgram</key>
    <string>Contents/MacOS/focusguardd</string>
    <key>ProgramArguments</key>
    <array>
        <string>focusguardd</string>
        <string>run</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>AssociatedBundleIdentifiers</key>
    <array>
        <string>com.focusguard.app</string>
    </array>
</dict>
</plist>
```

- [ ] **Step 3: Create `launchd/com.focusguard.app.plist`** (LaunchAgent; relaunches the app if it exits):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.focusguard.app</string>
    <key>BundleProgram</key>
    <string>Contents/MacOS/FocusGuard</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>AssociatedBundleIdentifiers</key>
    <array>
        <string>com.focusguard.app</string>
    </array>
</dict>
</plist>
```

- [ ] **Step 4: Make the fallback script self-contained.** In `scripts/install-daemon.sh` replace the line `sudo install -m 644 launchd/$LABEL.plist "$PLIST"` with:

```bash
# The plist in launchd/ is the in-bundle (BundleProgram) form used by the app; the manual
# install needs an absolute program path, so write it here.
sudo tee "$PLIST" >/dev/null <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key><array><string>$BIN</string><string>run</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardOutPath</key><string>/Library/Logs/FocusGuard/daemon.log</string>
    <key>StandardErrorPath</key><string>/Library/Logs/FocusGuard/daemon.log</string>
</dict>
</plist>
EOF
sudo chmod 644 "$PLIST"
```

Also change the header comment to: `# Fallback: build focusguardd and install it by hand as a root launchd daemon. Prefer FocusGuard.app → Settings → Status → Install protection, which registers the daemon from inside the app bundle. Do not use both: same label.`

Check: `bash -n scripts/install-daemon.sh && plutil -lint launchd/*.plist` → both `OK`.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "Paths into Core; in-bundle launchd plists; manual installer writes its own plist

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 7: App target skeleton, `Info.plist`, build script

A menu-bar app that shows "FocusGuard" with a Quit item, bundled and ad-hoc signed. Everything later hangs off this.

**Files:**
- Modify: `Package.swift`
- Create: `Sources/FocusGuard/FocusGuardApp.swift`
- Create: `Sources/FocusGuard/Info.plist`
- Create: `scripts/build-app.sh`

- [ ] **Step 1: Package.swift** — replace the file with:

```swift
// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "FocusGuard",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FocusGuardCore", targets: ["FocusGuardCore"]),
        .executable(name: "focusguardd", targets: ["focusguardd"]),
        .executable(name: "FocusGuard", targets: ["FocusGuard"]),
    ],
    targets: [
        .target(name: "FocusGuardCore"),
        .executableTarget(name: "focusguardd", dependencies: ["FocusGuardCore"]),
        .executableTarget(name: "FocusGuard", dependencies: ["FocusGuardCore"], exclude: ["Info.plist"]),
        .testTarget(name: "FocusGuardCoreTests", dependencies: ["FocusGuardCore"]),
    ]
)
```

- [ ] **Step 2: `Sources/FocusGuard/FocusGuardApp.swift`** (temporary body; Task 11 replaces the scene content):

```swift
import SwiftUI

@main
struct FocusGuardApp: App {
    var body: some Scene {
        MenuBarExtra("FocusGuard", systemImage: "shield") {
            Button("Quit FocusGuard") { NSApp.terminate(nil) }.keyboardShortcut("q")
        }
    }
}
```

- [ ] **Step 3: `Sources/FocusGuard/Info.plist`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.focusguard.app</string>
    <key>CFBundleName</key><string>FocusGuard</string>
    <key>CFBundleDisplayName</key><string>FocusGuard</string>
    <key>CFBundleExecutable</key><string>FocusGuard</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.2.0</string>
    <key>CFBundleVersion</key><string>2</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>FocusGuard</string>
</dict>
</plist>
```

- [ ] **Step 4: `scripts/build-app.sh`**

```bash
#!/bin/bash
# Build FocusGuard.app (menu-bar app + embedded focusguardd + launchd plists), ad-hoc signed.
# Output: build/FocusGuard.app. Run it from /Applications: the app's Status tab offers to move itself.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=${1:-release}
swift build -c "$CONFIG" --product FocusGuard --product focusguardd
BIN=".build/$CONFIG"
APP=build/FocusGuard.app

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" \
         "$APP/Contents/Library/LaunchDaemons" "$APP/Contents/Library/LaunchAgents"
cp "$BIN/FocusGuard"  "$APP/Contents/MacOS/FocusGuard"
cp "$BIN/focusguardd" "$APP/Contents/MacOS/focusguardd"
cp Sources/FocusGuard/Info.plist "$APP/Contents/Info.plist"
cp launchd/com.focusguard.daemon.plist "$APP/Contents/Library/LaunchDaemons/"
cp launchd/com.focusguard.app.plist    "$APP/Contents/Library/LaunchAgents/"
echo -n "APPL????" > "$APP/Contents/PkgInfo"

# Ad-hoc: no developer account. SMAppService accepts this from /Applications (spike 2026-10-30).
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
echo "built $APP"
```

Run: `chmod +x scripts/build-app.sh && scripts/build-app.sh 2>&1 | tail -3` → `built build/FocusGuard.app`.
Run: `open build/FocusGuard.app` → a shield appears in the menu bar with a Quit item. Quit it.
If `swift build` complains that product `FocusGuard` collides with the package name, rename the product to `FocusGuardApp` in `Package.swift` and update `BIN/FocusGuard` → `BIN/FocusGuardApp` in the script (the bundle executable stays `FocusGuard`).

- [ ] **Step 5: Commit**

```bash
git add Package.swift Sources/FocusGuard scripts/build-app.sh
git commit -m "App: SwiftUI menu-bar target, Info.plist, build-app.sh bundle + ad-hoc sign

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 8: `ConfigStore`, `ScheduleClock`, `AppModel`

The model layer, with the unlock gate. No UI yet beyond compiling.

**Files:**
- Create: `Sources/FocusGuard/Model/ConfigStore.swift`
- Create: `Sources/FocusGuard/Model/ScheduleClock.swift`
- Create: `Sources/FocusGuard/Model/AppModel.swift`
- Create: `Sources/FocusGuard/Model/ConfigEdits.swift`

- [ ] **Step 1: `ConfigStore.swift`**

```swift
import Foundation
import FocusGuardCore

/// Reads and writes `config.json` as the logged-in admin user. Saves are temp-file + rename in the
/// same directory (atomic for the daemon, which re-reads every tick). A vnode source reports
/// external edits; nothing polls.
final class ConfigStore {
    var onExternalChange: (() -> Void)?

    private var source: DispatchSourceFileSystemObject?
    private var watchedPath: String?

    var supportDirExists: Bool { FileManager.default.fileExists(atPath: Paths.supportDir) }
    var configExists: Bool { FileManager.default.fileExists(atPath: Paths.config) }

    /// Missing file → empty config (fresh install). Malformed file → throws (caller shows it).
    func load() throws -> Config {
        defer { watch() }
        guard let data = FileManager.default.contents(atPath: Paths.config) else { return .empty }
        return try Config.decodeJSON(data)
    }

    func save(_ config: Config) throws {
        let data = try config.encodeJSON()
        let tmp = Paths.supportDir + "/.config.json.tmp"
        guard FileManager.default.createFile(atPath: tmp, contents: data, attributes: [.posixPermissions: 0o664]) else {
            throw StoreError.cannotWrite(Paths.supportDir)
        }
        guard rename(tmp, Paths.config) == 0 else {
            let code = errno
            unlink(tmp)
            throw StoreError.rename(String(cString: strerror(code)))
        }
    }

    enum StoreError: LocalizedError {
        case cannotWrite(String), rename(String)
        var errorDescription: String? {
            switch self {
            case .cannotWrite(let dir): return "Cannot write to \(dir). Install protection first (the daemon creates the folder), and make sure this user is an administrator."
            case .rename(let why): return "Could not replace config.json: \(why)"
            }
        }
    }

    /// Watch the file if it exists, else the directory (to see the file appear), else nothing.
    private func watch() {
        let path: String? = configExists ? Paths.config : (supportDirExists ? Paths.supportDir : nil)
        guard path != watchedPath else { return }
        source?.cancel()
        source = nil
        watchedPath = path
        guard let path else { return }
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { watchedPath = nil; return }
        let s = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .attrib, .delete, .rename], queue: .main)
        s.setEventHandler { [weak self] in
            guard let self else { return }
            // After a rename/delete our fd points at the old inode; forget it so load() re-watches.
            if s.data.contains(.delete) || s.data.contains(.rename) { self.watchedPath = nil }
            self.onExternalChange?()
        }
        s.setCancelHandler { close(fd) }
        s.resume()
        source = s
    }
}
```

- [ ] **Step 2: `ScheduleClock.swift`**

```swift
import AppKit
import Foundation

/// The app's only timer: one wall-clock deadline at the next window boundary. Re-armed by the
/// model after every fire or config change, and poked on wake and clock/zone changes so a
/// boundary crossed during sleep is honoured immediately.
final class ScheduleClock {
    var onFire: (() -> Void)?

    private var timer: DispatchSourceTimer?
    private var observers: [NSObjectProtocol] = []

    init() {
        let fire: (Notification) -> Void = { [weak self] _ in self?.onFire?() }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: fire))
        observers.append(NotificationCenter.default.addObserver(
            forName: .NSSystemClockDidChange, object: nil, queue: .main, using: fire))
        observers.append(NotificationCenter.default.addObserver(
            forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main, using: fire))
    }

    /// nil disarms. Fires 50 ms after `date` so `Date()` inside the handler is past the boundary.
    func arm(at date: Date?) {
        timer?.cancel()
        timer = nil
        guard let date else { return }
        let target = date.timeIntervalSince1970 + 0.05
        let deadline = DispatchWallTime(timespec: timespec(
            tv_sec: Int(target.rounded(.down)),
            tv_nsec: Int((target - target.rounded(.down)) * 1_000_000_000)))
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(wallDeadline: deadline, leeway: .milliseconds(100))
        t.setEventHandler { [weak self] in self?.onFire?() }
        t.resume()
        timer = t
    }
}
```

- [ ] **Step 3: `ConfigEdits.swift`** — small mutators the views use inside `model.apply`:

```swift
import Foundation
import FocusGuardCore

extension Config {
    mutating func update(list id: UUID, _ change: (inout BlockList) -> Void) {
        guard let i = blockLists.firstIndex(where: { $0.id == id }) else { return }
        change(&blockLists[i])
    }

    mutating func update(window id: UUID, _ change: (inout ScheduleWindow) -> Void) {
        guard let i = schedules.firstIndex(where: { $0.id == id }) else { return }
        change(&schedules[i])
    }

    mutating func removeList(id: UUID) {
        blockLists.removeAll { $0.id == id }
        for i in schedules.indices { schedules[i].blockListIDs.removeAll { $0 == id } }
    }

    func list(_ id: UUID) -> BlockList? { blockLists.first { $0.id == id } }
    func window(_ id: UUID) -> ScheduleWindow? { schedules.first { $0.id == id } }
}
```

- [ ] **Step 4: `AppModel.swift`**

```swift
import AppKit
import FocusGuardCore
import Observation
import os

/// One pending Friction challenge. `onSuccess` is the gated action.
struct PendingChallenge: Identifiable {
    let id = UUID()
    let sentence: String
    let onSuccess: () -> Void
}

/// Hub for the UI: the config, what is active/locked right now, and the gate every weakening
/// action goes through. Recomputes only on events (boundary, config change, wake, clock change).
@MainActor @Observable
final class AppModel {
    static let log = Logger(subsystem: "com.focusguard", category: "app")

    private(set) var config: Config?
    private(set) var loadError: String?
    private(set) var saveError: String?
    private(set) var activeSet = ActiveSet.empty
    private(set) var lockState = LockState()
    private(set) var nextBoundary: Date?
    private(set) var nextWindowNames: [String] = []

    var pendingChallenge: PendingChallenge?
    var lockedMessage: String?

    let store = ConfigStore()
    let installer = Installer()
    private let clock = ScheduleClock()
    private var killer: AppKiller?

    init() {
        killer = AppKiller { [weak self] in self?.activeSet.bundleIDs ?? [] }
        store.onExternalChange = { [weak self] in self?.reload() }
        clock.onFire = { [weak self] in self?.refresh() }
        reload()
    }

    // MARK: Derived state

    var isBlocking: Bool { lockState.overall != nil }
    var activeWindowNames: [String] {
        guard let config else { return [] }
        return config.schedules.filter { lockState.windowModes[$0.id] != nil }.map(\.name)
    }
    var lockedUntilText: String {
        lockState.lockedUntil.map { "Locked until \($0.string)" } ?? "Locked while a window is active"
    }
    func mode(forList id: UUID) -> UnlockMode? { lockState.listModes[id] }
    func mode(forWindow id: UUID) -> UnlockMode? { lockState.windowModes[id] }

    // MARK: Loading

    func reload() {
        do {
            config = try store.load()
            loadError = nil
        } catch {
            config = nil
            loadError = "config.json is not valid: \(error.localizedDescription)"
        }
        refresh()
    }

    /// Recompute everything time-dependent and re-arm the single timer.
    func refresh() {
        let now = Date()
        let moment = LocalMoment(date: now)
        let cfg = config ?? .empty
        let wasBlocking = isBlocking
        activeSet = cfg.activeSet(at: moment)
        lockState = cfg.lockState(at: moment)
        nextBoundary = cfg.nextBoundary(after: now)
        nextWindowNames = nextBoundary.map { cfg.windows(startingAt: LocalMoment(date: $0)).map(\.name) } ?? []
        clock.arm(at: nextBoundary)
        if !activeSet.bundleIDs.isEmpty { killer?.sweep() }
        Self.log.info("refresh: blocking=\(self.isBlocking) was=\(wasBlocking) domains=\(self.activeSet.domains.count) apps=\(self.activeSet.bundleIDs.count) next=\(self.nextBoundary?.description ?? "none", privacy: .public)")
    }

    // MARK: Editing through the gate

    enum Outcome { case applied, challenge, locked, noChange, failed }

    /// Apply `edit` to a copy of the config; save it now, after a challenge, or refuse, depending on
    /// the strictest unlock mode the edit cuts through. Views never mutate config directly.
    @discardableResult
    func apply(_ edit: (inout Config) -> Void) -> Outcome {
        guard let old = config else { return .failed }
        var new = old
        edit(&new)
        guard new != old else { return .noChange }
        return gate(new.weakens(from: old, at: LocalMoment(date: Date()))) { [weak self] in self?.commit(new) }
    }

    /// Run `action` now (nil / basic), after a typed challenge (friction), or never (impossible).
    @discardableResult
    func gate(_ mode: UnlockMode?, action: @escaping () -> Void) -> Outcome {
        switch mode {
        case nil, .basic?:
            action()
            return .applied
        case .friction?:
            pendingChallenge = PendingChallenge(sentence: Challenge.sentence(), onSuccess: action)
            return .challenge
        case .impossible?:
            lockedMessage = lockedUntilText
            return .locked
        }
    }

    private func commit(_ new: Config) {
        do {
            try store.save(new)
            config = new
            saveError = nil
            refresh()
        } catch {
            saveError = error.localizedDescription
        }
    }

    // MARK: Whole-app actions (gated by the strictest active mode)

    /// Quit needs a window to show the challenge in when the mode is friction/impossible.
    var quitNeedsSettingsWindow: Bool { (lockState.overall ?? .basic) > .basic }

    func requestQuit() {
        gate(lockState.overall) { [installer] in
            try? installer.unregisterAgent()   // otherwise KeepAlive relaunches us
            NSApp.terminate(nil)
        }
    }

    func requestUninstall() {
        gate(lockState.overall) { [installer] in installer.uninstall() }
    }
}
```

- [ ] **Step 5: Stubs so it compiles** — create `Sources/FocusGuard/Model/AppKiller.swift` and `Sources/FocusGuard/Model/Installer.swift` with the minimum (Tasks 9 and 10 replace them):

```swift
// AppKiller.swift
import Foundation
final class AppKiller {
    init(blocked: @escaping () -> Set<String>) {}
    func sweep() {}
}
```

```swift
// Installer.swift
import Observation
@MainActor @Observable final class Installer {
    func unregisterAgent() throws {}
    func uninstall() {}
}
```

Run: `swift build --product FocusGuard 2>&1 | grep -E "error|warning: var|Build" | head` → `Build complete`. Fix any Swift 6 toolchain complaints by adding `@MainActor` to the type the diagnostic names (Swift 5 mode should produce none).

- [ ] **Step 6: Commit**

```bash
git add Sources/FocusGuard
git commit -m "App: ConfigStore (atomic save, vnode watch), ScheduleClock, AppModel with unlock gate

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 9: `AppKiller`

**Files:**
- Replace: `Sources/FocusGuard/Model/AppKiller.swift`

- [ ] **Step 1: Implement**

```swift
import AppKit
import os

/// Event-driven app kill in the user session. `didLaunchApplicationNotification` arrives within
/// tens of milliseconds of launch; `terminate()` is a polite quit, escalated to `forceTerminate()`
/// from a one-shot 3 s timer. The daemon's 2 s libproc sweep remains the backstop.
final class AppKiller {
    private let blocked: () -> Set<String>
    private var observer: NSObjectProtocol?
    private let log = Logger(subsystem: "com.focusguard", category: "kill")

    init(blocked: @escaping () -> Set<String>) {
        self.blocked = blocked
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.enforce(app, reason: "launch")
        }
    }

    /// Called when a window becomes active so already-running blocked apps die at once.
    func sweep() {
        for app in NSWorkspace.shared.runningApplications { enforce(app, reason: "sweep") }
    }

    private func enforce(_ app: NSRunningApplication, reason: String) {
        guard let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier,
              blocked().contains(id) else { return }
        let ms = app.launchDate.map { Int(Date().timeIntervalSince($0) * 1000) } ?? -1
        log.info("terminate \(id, privacy: .public) pid=\(app.processIdentifier) reason=\(reason, privacy: .public) sinceLaunch=\(ms)ms")
        if !app.terminate() { _ = app.forceTerminate() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [log] in
            if !app.isTerminated {
                log.info("forceTerminate \(id, privacy: .public) pid=\(app.processIdentifier)")
                _ = app.forceTerminate()
            }
        }
    }
}
```

- [ ] **Step 2: Build** `swift build --product FocusGuard 2>&1 | grep -E "error|Build" | head -3` → `Build complete`.

- [ ] **Step 3: Commit** `git add -A && git commit -m "App: AppKiller — terminate blocked bundle IDs on didLaunchApplicationNotification" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"`

---

### Task 10: `Installer` and `DaemonProbe`

**Files:**
- Replace: `Sources/FocusGuard/Model/Installer.swift`
- Create: `Sources/FocusGuard/Model/DaemonProbe.swift`

- [ ] **Step 1: `DaemonProbe.swift`**

```swift
import Darwin
import Foundation

/// Is a `focusguardd` running, and from where? One libproc pass, only when asked (Status tab
/// shown, after an install action, on a boundary). Never on a timer.
enum DaemonProbe {
    struct Result: Equatable {
        let pid: pid_t
        let path: String
        var isFromBundle: Bool { path.contains("/FocusGuard.app/Contents/MacOS/focusguardd") }
    }

    static func find() -> Result? {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard got > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        for pid in pids.prefix(Int(got)) where pid > 0 {
            guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { continue }
            let path = String(cString: buf)
            if path.hasSuffix("/focusguardd") { return Result(pid: pid, path: path) }
        }
        return nil
    }
}
```

- [ ] **Step 2: `Installer.swift`**

```swift
import AppKit
import FocusGuardCore
import Observation
import ServiceManagement

/// Registers the embedded daemon and the app's own KeepAlive agent with SMAppService, and
/// handles the two things that stop that working: not being in /Applications, and the legacy
/// manual install holding the same launchd label.
@MainActor @Observable
final class Installer {
    private(set) var daemonStatus: SMAppService.Status = .notFound
    private(set) var agentStatus: SMAppService.Status = .notFound
    private(set) var daemonProcess: DaemonProbe.Result?
    private(set) var lastError: String?

    private let daemon = SMAppService.daemon(plistName: Paths.daemonLabel + ".plist")
    private let agent = SMAppService.agent(plistName: Paths.agentLabel + ".plist")

    static let applicationsURL = URL(fileURLWithPath: "/Applications/FocusGuard.app")

    var inApplications: Bool { Bundle.main.bundleURL.path.hasPrefix("/Applications/") }
    var legacyInstallPresent: Bool { FileManager.default.fileExists(atPath: Paths.legacyDaemonPlist) }
    var canInstall: Bool { inApplications && !legacyInstallPresent }

    var daemonRunningFromBundle: Bool { daemonProcess?.isFromBundle == true }

    func refresh() {
        daemonStatus = daemon.status
        agentStatus = agent.status
        daemonProcess = DaemonProbe.find()
    }

    /// Register both. The first daemon registration throws "Operation not permitted" while the
    /// status moves to requiresApproval — that is the normal path, not an error.
    func install() {
        lastError = nil
        register(daemon, what: "daemon")
        register(agent, what: "login item")
        refresh()
        // launchd needs a moment to start the daemon; one delayed re-probe, not a loop.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.refresh() }
    }

    private func register(_ service: SMAppService, what: String) {
        do {
            try service.register()
        } catch {
            if service.status != .requiresApproval && service.status != .enabled {
                lastError = "Could not register \(what): \(error.localizedDescription)"
            }
        }
    }

    func uninstall() {
        lastError = nil
        do { try daemon.unregister() } catch { lastError = "Could not remove daemon: \(error.localizedDescription)" }
        try? agent.unregister()
        refresh()
    }

    func unregisterAgent() throws { try agent.unregister() }

    func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }

    /// Copy this bundle to /Applications, launch the copy, quit. /Applications is admin-writable.
    func moveToApplications() {
        lastError = nil
        let fm = FileManager.default
        let dest = Self.applicationsURL
        do {
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: Bundle.main.bundleURL, to: dest)
        } catch {
            lastError = "Could not copy to /Applications: \(error.localizedDescription)"
            return
        }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: dest, configuration: cfg) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

extension SMAppService.Status {
    var label: String {
        switch self {
        case .notRegistered: return "not installed"
        case .enabled: return "enabled"
        case .requiresApproval: return "waiting for approval"
        case .notFound: return "not found in bundle"
        @unknown default: return "unknown"
        }
    }
}
```

- [ ] **Step 3: Build** `swift build --product FocusGuard 2>&1 | grep -E "error|Build" | head -3` → `Build complete`.

- [ ] **Step 4: Commit** `git add -A && git commit -m "App: Installer (SMAppService daemon+agent, move to /Applications, legacy detect) and DaemonProbe" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"`

---

### Task 11: App scenes, `MenuView`, `SettingsView`, `StatusTab`

**Files:**
- Replace: `Sources/FocusGuard/FocusGuardApp.swift`
- Create: `Sources/FocusGuard/Views/MenuView.swift`
- Create: `Sources/FocusGuard/Views/SettingsView.swift`
- Create: `Sources/FocusGuard/Views/StatusTab.swift`
- Create stubs: `Sources/FocusGuard/Views/BlockListsTab.swift`, `Sources/FocusGuard/Views/ScheduleTab.swift`, `Sources/FocusGuard/Views/ChallengeSheet.swift` (filled in Tasks 12–14)

- [ ] **Step 1: `FocusGuardApp.swift`**

```swift
import SwiftUI

@main
struct FocusGuardApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra("FocusGuard", systemImage: model.isBlocking ? "shield.fill" : "shield") {
            MenuView().environment(model)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView().environment(model)
        }
    }
}
```

- [ ] **Step 2: `MenuView.swift`**

```swift
import SwiftUI

struct MenuView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if model.isBlocking {
            Text(activeLine)
            Text("\(model.activeSet.domains.count) sites, \(model.activeSet.bundleIDs.count) apps blocked")
        } else {
            Text("Not blocking")
        }
        if let next = model.nextBoundary {
            Text("Next: \(nextLabel) at \(next, format: .dateTime.weekday(.abbreviated).hour().minute())")
        }
        if model.loadError != nil {
            Text("⚠︎ config.json is unreadable")
        }
        Divider()
        SettingsLink { Text("Open Settings…") }.keyboardShortcut(",")
        Button("Quit FocusGuard") {
            if model.quitNeedsSettingsWindow { openSettings() }
            model.requestQuit()
        }.keyboardShortcut("q")
    }

    private var activeLine: String {
        let names = model.activeWindowNames.joined(separator: ", ")
        let until = model.lockState.lockedUntil.map { " · until \($0.string)" } ?? ""
        return "● \(names.isEmpty ? "Blocking" : names)\(until)"
    }

    private var nextLabel: String {
        model.nextWindowNames.isEmpty ? "release" : model.nextWindowNames.joined(separator: ", ")
    }
}
```

- [ ] **Step 3: `SettingsView.swift`** — hosts the challenge sheet and the "locked" alert for every tab:

```swift
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView {
            StatusTab().tabItem { Label("Status", systemImage: "shield") }
            BlockListsTab().tabItem { Label("Block Lists", systemImage: "list.bullet") }
            ScheduleTab().tabItem { Label("Schedule", systemImage: "calendar") }
        }
        .frame(minWidth: 640, minHeight: 460)
        .sheet(item: $model.pendingChallenge) { challenge in
            ChallengeSheet(challenge: challenge) { model.pendingChallenge = nil }
        }
        .alert("Locked", isPresented: Binding(get: { model.lockedMessage != nil }, set: { if !$0 { model.lockedMessage = nil } })) {
            Button("OK") { model.lockedMessage = nil }
        } message: {
            Text(model.lockedMessage ?? "")
        }
        .onAppear { NSApp.activate(ignoringOtherApps: true) }
    }
}
```

- [ ] **Step 4: `StatusTab.swift`**

```swift
import SwiftUI
import ServiceManagement

struct StatusTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let inst = model.installer
        Form {
            Section("Protection") {
                if inst.legacyInstallPresent {
                    row(done: false, "A manual daemon install is present",
                        detail: "Run scripts/uninstall-daemon.sh in Terminal (needs sudo), then come back. The app installs the daemon from its own bundle under the same name.")
                }
                row(done: inst.inApplications, "FocusGuard is in /Applications",
                    detail: inst.inApplications ? nil : "macOS only launches background daemons for apps installed there.") {
                    if !inst.inApplications { Button("Move to Applications") { inst.moveToApplications() } }
                }
                daemonRow(inst)
                row(done: inst.agentStatus == .enabled, "Starts at login and stays running",
                    detail: inst.agentStatus == .enabled ? nil : "Status: \(inst.agentStatus.label)") {
                    if inst.agentStatus == .requiresApproval { Button("Open Login Items settings") { inst.openLoginItems() } }
                }
                if let err = inst.lastError { Text(err).foregroundStyle(.red).font(.callout) }
            }

            Section("Now") {
                if model.isBlocking {
                    LabeledContent("Active", value: model.activeWindowNames.joined(separator: ", "))
                    if let until = model.lockState.lockedUntil { LabeledContent("Until", value: until.string) }
                    LabeledContent("Blocking", value: "\(model.activeSet.domains.count) sites, \(model.activeSet.bundleIDs.count) apps")
                } else {
                    LabeledContent("Active", value: "Nothing")
                }
                if let next = model.nextBoundary {
                    LabeledContent("Next change", value: next.formatted(.dateTime.weekday(.wide).hour().minute()))
                }
                if let err = model.loadError { Text(err).foregroundStyle(.red).font(.callout) }
                if let err = model.saveError { Text(err).foregroundStyle(.red).font(.callout) }
            }

            if inst.daemonStatus == .enabled || inst.daemonStatus == .requiresApproval {
                Section {
                    Button("Uninstall protection", role: .destructive) { model.requestUninstall() }
                    Text("Removes the daemon and login item. Your lists and schedule stay in config.json.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { inst.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in inst.refresh() }
    }

    @ViewBuilder
    private func daemonRow(_ inst: Installer) -> some View {
        switch inst.daemonStatus {
        case .enabled where inst.daemonRunningFromBundle:
            row(done: true, "Background daemon running", detail: "pid \(inst.daemonProcess!.pid)")
        case .enabled:
            row(done: false, "Daemon enabled but not running",
                detail: inst.daemonProcess.map { "A focusguardd is running from \($0.path)" } ?? "launchd should start it within a few seconds; click to re-register if it does not.") {
                Button("Re-install") { inst.install() }
            }
        case .requiresApproval:
            row(done: false, "Approve FocusGuard in Login Items",
                detail: "System Settings → General → Login Items & Extensions → Allow in the Background → FocusGuard.") {
                Button("Open Login Items settings") { inst.openLoginItems() }
            }
        default:
            row(done: false, "Background daemon not installed",
                detail: "Registers focusguardd (root) and FocusGuard as a login item.") {
                Button("Install protection") { inst.install() }.disabled(!inst.canInstall)
            }
        }
    }

    private func row(done: Bool, _ title: String, detail: String? = nil) -> some View {
        row(done: done, title, detail: detail) { EmptyView() }
    }

    private func row<Action: View>(done: Bool, _ title: String, detail: String?, @ViewBuilder action: () -> Action) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            action()
        }
    }
}
```

- [ ] **Step 5: Stubs** so the target builds:

```swift
// BlockListsTab.swift
import SwiftUI
struct BlockListsTab: View { var body: some View { Text("Block lists") } }
```
```swift
// ScheduleTab.swift
import SwiftUI
struct ScheduleTab: View { var body: some View { Text("Schedule") } }
```
```swift
// ChallengeSheet.swift
import SwiftUI
struct ChallengeSheet: View {
    let challenge: PendingChallenge
    let dismiss: () -> Void
    var body: some View { Button("Dismiss", action: dismiss).padding() }
}
```

- [ ] **Step 6: Build and look** `scripts/build-app.sh 2>&1 | tail -1 && open build/FocusGuard.app`. Expect: shield in the menu bar; dropdown shows "Not blocking" or the active window from the current `config.json`; "Open Settings…" opens the window on Status with the checklist (expect "manual daemon install is present" and "not in /Applications" rows on this Mac right now). Quit via the menu (nothing is registered yet, so it quits).

- [ ] **Step 7: Commit** `git add -A && git commit -m "App: scenes, menu, settings shell, Status tab with guided setup" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"`

---

### Task 12: Block Lists tab, `InstalledApps`, Add-app sheet

**Files:**
- Create: `Sources/FocusGuard/Model/InstalledApps.swift`
- Replace: `Sources/FocusGuard/Views/BlockListsTab.swift`
- Create: `Sources/FocusGuard/Views/AddAppSheet.swift`
- Create: `Sources/FocusGuard/Views/LockBadge.swift`

- [ ] **Step 1: `InstalledApps.swift`**

```swift
import AppKit
import Foundation

struct AppEntry: Identifiable, Hashable {
    let bundleID: String
    let name: String
    let url: URL?
    var id: String { bundleID }

    var icon: NSImage {
        url.map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSWorkspace.shared.icon(for: .applicationBundle)
    }
}

/// App discovery for the picker. Everything here runs only when the sheet opens.
enum InstalledApps {
    static func running() -> [AppEntry] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in
                guard let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier else { return nil }
                return AppEntry(bundleID: id, name: app.localizedName ?? id, url: app.bundleURL)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func installed() -> [AppEntry] {
        let fm = FileManager.default
        let dirs = ["/Applications", "/Applications/Utilities", "/System/Applications",
                    fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]
        var seen = Set<String>()
        var out: [AppEntry] = []
        for dir in dirs {
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for name in names where name.hasSuffix(".app") {
                let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
                guard let id = Bundle(url: url)?.bundleIdentifier, !seen.contains(id) else { continue }
                seen.insert(id)
                out.append(AppEntry(bundleID: id, name: fm.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""), url: url))
            }
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// For rows in a block list: resolve a stored bundle ID to a name and icon when the app is installed.
    static func entry(forBundleID id: String) -> AppEntry {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            return AppEntry(bundleID: id, name: FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""), url: url)
        }
        return AppEntry(bundleID: id, name: id, url: nil)
    }
}
```

- [ ] **Step 2: `LockBadge.swift`** — the shared "Locked until 12:00" affordance:

```swift
import FocusGuardCore
import SwiftUI

/// Shown next to controls that an active Impossible window has disabled.
struct LockBadge: View {
    let until: TimeOfDay?
    var body: some View {
        Label(until.map { "Locked until \($0.string)" } ?? "Locked", systemImage: "lock.fill")
            .font(.caption)
            .foregroundStyle(.secondary)
            .help("An active window with the Impossible unlock mode protects this until it ends.")
    }
}
```

- [ ] **Step 3: `BlockListsTab.swift`**

```swift
import FocusGuardCore
import SwiftUI

struct BlockListsTab: View {
    @Environment(AppModel.self) private var model
    @State private var selection: UUID?

    private var lists: [BlockList] { model.config?.blockLists ?? [] }

    var body: some View {
        NavigationSplitView {
            List(lists, selection: $selection) { list in
                HStack {
                    Text(list.name)
                    Spacer()
                    if model.mode(forList: list.id) != nil { Image(systemName: "shield.fill").foregroundStyle(.secondary) }
                }
                .tag(list.id)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 200)
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 4) {
                    Button { addList() } label: { Image(systemName: "plus") }
                    Button { removeSelected() } label: { Image(systemName: "minus") }
                        .disabled(selection == nil || selection.map { model.mode(forList: $0) == .impossible } == true)
                    Spacer()
                }
                .buttonStyle(.borderless).padding(8)
            }
        } detail: {
            if let id = selection, let list = model.config?.list(id) {
                BlockListDetail(list: list)
            } else {
                ContentUnavailableView("No list selected", systemImage: "list.bullet",
                                       description: Text(lists.isEmpty ? "Click + to create your first block list." : "Pick a list on the left."))
            }
        }
        .disabled(model.config == nil)
        .onAppear { if selection == nil { selection = lists.first?.id } }
    }

    private func addList() {
        let new = BlockList(name: "New list")
        if model.apply({ $0.blockLists.append(new) }) == .applied { selection = new.id }
    }

    private func removeSelected() {
        guard let id = selection else { return }
        model.apply { $0.removeList(id: id) }
    }
}

struct BlockListDetail: View {
    @Environment(AppModel.self) private var model
    let list: BlockList

    @State private var name = ""
    @State private var newDomain = ""
    @State private var showAddApp = false

    private var mode: UnlockMode? { model.mode(forList: list.id) }
    private var removalsLocked: Bool { mode == .impossible }

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("List name", text: $name)
                        .onSubmit(commitName)
                        .onChange(of: list.id) { _, _ in name = list.name }
                    if removalsLocked { LockBadge(until: model.lockState.lockedUntil) }
                    else if mode == .friction { Label("Active", systemImage: "shield.fill").font(.caption).foregroundStyle(.secondary) }
                }
            }

            Section("Sites") {
                ForEach(list.domains, id: \.self) { domain in
                    HStack {
                        Text(domain)
                        Spacer()
                        removeButton { model.apply { $0.update(list: list.id) { $0.domains.removeAll { $0 == domain } } } }
                    }
                }
                HStack {
                    TextField("Add a site, e.g. reddit.com", text: $newDomain).onSubmit(addDomain)
                    Button("Add", action: addDomain).disabled(DomainNormalizer.normalize(newDomain).isEmpty)
                }
            }

            Section("Apps") {
                ForEach(list.appBundleIDs, id: \.self) { id in
                    let entry = InstalledApps.entry(forBundleID: id)
                    HStack {
                        Image(nsImage: entry.icon).resizable().frame(width: 20, height: 20)
                        VStack(alignment: .leading) {
                            Text(entry.name)
                            if entry.name != id { Text(id).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        removeButton { model.apply { $0.update(list: list.id) { $0.appBundleIDs.removeAll { $0 == id } } } }
                    }
                }
                Button("Add app…") { showAddApp = true }
            }
        }
        .formStyle(.grouped)
        .onAppear { name = list.name }
        .sheet(isPresented: $showAddApp) {
            AddAppSheet(alreadyAdded: Set(list.appBundleIDs)) { ids in
                model.apply { $0.update(list: list.id) { l in
                    for id in ids where !l.appBundleIDs.contains(id) { l.appBundleIDs.append(id) }
                } }
            }
        }
    }

    private func removeButton(_ action: @escaping () -> Void) -> some View {
        Button(role: .destructive, action: action) { Image(systemName: "minus.circle") }
            .buttonStyle(.borderless)
            .disabled(removalsLocked)
            .help(removalsLocked ? model.lockedUntilText : "Remove")
    }

    private func commitName() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { name = list.name; return }
        model.apply { $0.update(list: list.id) { $0.name = trimmed } }
    }

    private func addDomain() {
        let d = DomainNormalizer.normalize(newDomain)
        guard !d.isEmpty else { return }
        model.apply { $0.update(list: list.id) { if !$0.domains.contains(d) { $0.domains.append(d) } } }
        newDomain = ""
    }
}
```

- [ ] **Step 4: `AddAppSheet.swift`**

```swift
import SwiftUI

struct AddAppSheet: View {
    let alreadyAdded: Set<String>
    let onAdd: ([String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var running: [AppEntry] = []
    @State private var installed: [AppEntry] = []
    @State private var query = ""
    @State private var picked = Set<String>()
    @State private var manualID = ""

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search apps", text: $query).textFieldStyle(.roundedBorder).padding()
            List(selection: $picked) {
                section("Running", running)
                section("Installed", installed.filter { app in !running.contains { $0.bundleID == app.bundleID } })
            }
            Divider()
            HStack {
                TextField("Other bundle ID, e.g. com.example.app", text: $manualID).textFieldStyle(.roundedBorder)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") {
                    var ids = Array(picked)
                    let manual = manualID.trimmingCharacters(in: .whitespaces)
                    if !manual.isEmpty { ids.append(manual) }
                    onAdd(ids)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(picked.isEmpty && manualID.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()
        }
        .frame(width: 480, height: 520)
        .onAppear {
            // One scan, when the sheet opens. Never in the background.
            running = InstalledApps.running()
            installed = InstalledApps.installed()
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ apps: [AppEntry]) -> some View {
        let shown = apps.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.bundleID.localizedCaseInsensitiveContains(query) }
        if !shown.isEmpty {
            Section(title) {
                ForEach(shown) { app in
                    HStack {
                        Image(nsImage: app.icon).resizable().frame(width: 24, height: 24)
                        VStack(alignment: .leading) {
                            Text(app.name)
                            Text(app.bundleID).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if alreadyAdded.contains(app.bundleID) { Text("Added").font(.caption).foregroundStyle(.secondary) }
                    }
                    .tag(app.bundleID)
                    .selectionDisabled(alreadyAdded.contains(app.bundleID))
                }
            }
        }
    }
}
```

- [ ] **Step 5: Build and try** `scripts/build-app.sh 2>&1 | tail -1 && open build/FocusGuard.app`. In Block Lists: create a list, add `Reddit.com` (stored as `reddit.com`), open Add app, search "chess", add com.apple.Chess, remove it again. Check `cat "/Library/Application Support/FocusGuard/config.json"` reflects each step (the file is rewritten on every edit). If the current `config.json` window is active with mode friction (the default for the pre-existing "Test window"), removing shows the stub ChallengeSheet — press Dismiss; that is Task 14.

- [ ] **Step 6: Commit** `git add -A && git commit -m "App: Block Lists tab with site/app editing and running+installed app picker" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"`

---

### Task 13: Schedule tab

**Files:**
- Replace: `Sources/FocusGuard/Views/ScheduleTab.swift`

- [ ] **Step 1: Implement**

```swift
import FocusGuardCore
import SwiftUI

struct ScheduleTab: View {
    @Environment(AppModel.self) private var model

    private var windows: [ScheduleWindow] { model.config?.schedules ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            if windows.isEmpty {
                ContentUnavailableView("No schedule yet", systemImage: "calendar",
                                       description: Text("Add a window: the days and hours when your lists are blocked."))
            } else {
                List(windows) { w in
                    WindowRow(window: w).padding(.vertical, 6)
                }
            }
            Divider()
            HStack {
                Button("Add window") { addWindow() }
                Spacer()
                Text("Unlock mode controls how hard it is to weaken a window while it is active: Basic applies at once, Friction asks you to type a sentence, Impossible waits for the window to end.")
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: 380)
            }
            .padding()
        }
        .disabled(model.config == nil)
    }

    private func addWindow() {
        let lists = model.config?.blockLists.map(\.id) ?? []
        let w = ScheduleWindow(name: "Deep work", days: [.mon, .tue, .wed, .thu, .fri],
                               start: TimeOfDay("09:00")!, end: TimeOfDay("12:00")!, blockListIDs: lists)
        model.apply { $0.schedules.append(w) }
    }
}

struct WindowRow: View {
    @Environment(AppModel.self) private var model
    let window: ScheduleWindow
    @State private var name = ""

    private var mode: UnlockMode? { model.mode(forWindow: window.id) }
    /// Impossible and active: only name, adding lists, and extending the end are allowed.
    private var hardLocked: Bool { mode == .impossible }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Window name", text: $name).textFieldStyle(.roundedBorder).frame(width: 180)
                    .onSubmit { model.apply { $0.update(window: window.id) { $0.name = name } } }
                Toggle("Enabled", isOn: binding(\.enabled)).toggleStyle(.switch).labelsHidden()
                    .disabled(hardLocked)
                if hardLocked { LockBadge(until: model.lockState.lockedUntil) }
                else if mode != nil { Label("Active", systemImage: "shield.fill").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button(role: .destructive) { model.apply { $0.schedules.removeAll { $0.id == window.id } } } label: {
                    Image(systemName: "trash")
                }.buttonStyle(.borderless).disabled(hardLocked)
            }
            HStack(spacing: 12) {
                HStack(spacing: 2) {
                    ForEach(Weekday.allCases, id: \.self) { day in
                        Toggle(day.rawValue.prefix(1).uppercased(), isOn: dayBinding(day))
                            .toggleStyle(.button).controlSize(.small)
                    }
                }.disabled(hardLocked)
                DatePicker("from", selection: timeBinding(\.start), displayedComponents: .hourAndMinute)
                    .disabled(hardLocked)
                DatePicker("to", selection: timeBinding(\.end), displayedComponents: .hourAndMinute)
                Picker("Unlock", selection: binding(\.unlockMode)) {
                    ForEach(UnlockMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).frame(width: 220).disabled(hardLocked)
            }
            HStack(spacing: 10) {
                Text("Lists:").foregroundStyle(.secondary)
                ForEach(model.config?.blockLists ?? []) { list in
                    Toggle(list.name, isOn: listBinding(list.id)).toggleStyle(.checkbox)
                        .disabled(hardLocked && window.blockListIDs.contains(list.id))
                }
                if (model.config?.blockLists ?? []).isEmpty { Text("none yet — create one in Block Lists").font(.caption).foregroundStyle(.secondary) }
            }
        }
        .onAppear { name = window.name }
        .onChange(of: window.name) { _, new in name = new }
    }

    // All bindings write through the gate; the view re-renders from the saved config, so a refused
    // edit simply snaps back.
    private func binding<T>(_ key: WritableKeyPath<ScheduleWindow, T>) -> Binding<T> {
        Binding(get: { window[keyPath: key] },
                set: { v in model.apply { $0.update(window: window.id) { $0[keyPath: key] = v } } })
    }

    private func dayBinding(_ day: Weekday) -> Binding<Bool> {
        Binding(get: { window.days.contains(day) },
                set: { on in model.apply { $0.update(window: window.id) { if on { $0.days.insert(day) } else { $0.days.remove(day) } } } })
    }

    private func listBinding(_ id: UUID) -> Binding<Bool> {
        Binding(get: { window.blockListIDs.contains(id) },
                set: { on in model.apply { $0.update(window: window.id) {
                    if on { if !$0.blockListIDs.contains(id) { $0.blockListIDs.append(id) } } else { $0.blockListIDs.removeAll { $0 == id } }
                } } })
    }

    private func timeBinding(_ key: WritableKeyPath<ScheduleWindow, TimeOfDay>) -> Binding<Date> {
        Binding(get: {
            let t = window[keyPath: key]
            return Calendar.current.date(bySettingHour: t.hour, minute: t.minute, second: 0, of: Date()) ?? Date()
        }, set: { d in
            let c = Calendar.current.dateComponents([.hour, .minute], from: d)
            guard let t = TimeOfDay(hour: c.hour ?? 0, minute: c.minute ?? 0) else { return }
            model.apply { $0.update(window: window.id) { $0[keyPath: key] = t } }
        })
    }
}
```

- [ ] **Step 2: Build and try** `scripts/build-app.sh 2>&1 | tail -1 && open build/FocusGuard.app`. Add a window, toggle days, change times, pick lists, switch mode; confirm `config.json` follows and `focusguardd check` (any user) prints the window. Set a window to Impossible that is active now and confirm its controls grey out except the end picker (moving the end earlier shows the Locked alert and snaps back; later is accepted).

- [ ] **Step 3: Commit** `git add -A && git commit -m "App: Schedule tab with day/time/list/mode editing through the unlock gate" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"`

---

### Task 14: Friction challenge sheet

**Files:**
- Replace: `Sources/FocusGuard/Views/ChallengeSheet.swift`

- [ ] **Step 1: Implement**

```swift
import FocusGuardCore
import SwiftUI

/// Type-the-sentence gate. The sentence is drawn on a Canvas (not selectable, no text layer to
/// copy) with per-glyph jitter, mixed typefaces, strike lines and speckle so a screenshot is hard
/// to OCR. The field refuses any change that adds more than one character, so paste and drag do
/// nothing.
struct ChallengeSheet: View {
    let challenge: PendingChallenge
    let dismiss: () -> Void

    @State private var typed = ""
    @FocusState private var focused: Bool

    private var matches: Bool { Challenge.matches(typed: typed, sentence: challenge.sentence) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Type this sentence to continue").font(.headline)
            Text("This window uses the Friction unlock mode. Copying, pasting and autocorrect will not work; spaces and lowercase must match.")
                .font(.callout).foregroundStyle(.secondary)
            CaptchaText(sentence: challenge.sentence)
                .frame(height: 120)
                .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4)))
            TextField("Type here", text: $typed)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled()
                .focused($focused)
                .onChange(of: typed) { old, new in
                    if new.count > old.count + 1 { typed = old }   // paste / drop / dictation burst
                }
            HStack {
                Text(progress).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: dismiss).keyboardShortcut(.cancelAction)
                Button("Unlock") { challenge.onSuccess(); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!matches)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear { focused = true }
    }

    private var progress: String {
        let ok = zip(typed, challenge.sentence).prefix { $0 == $1 }.count
        if matches { return "Matches." }
        if typed.isEmpty { return "\(challenge.sentence.count) characters" }
        return ok == typed.count ? "\(ok)/\(challenge.sentence.count) correct so far" : "Mismatch at character \(ok + 1)"
    }
}

/// Deterministic jitter so the drawing is stable across redraws (seeded from the sentence).
private struct JitterRNG: RandomNumberGenerator {
    var state: UInt64
    init(seed: String) { state = seed.unicodeScalars.reduce(0x9E3779B97F4A7C15) { ($0 &* 31) &+ UInt64($1.value) } }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

struct CaptchaText: View {
    let sentence: String

    var body: some View {
        Canvas { ctx, size in
            var rng = JitterRNG(seed: sentence)
            let designs: [Font.Design] = [.serif, .rounded, .monospaced, .default]
            let lineHeight: CGFloat = 36
            var x: CGFloat = 14, y: CGFloat = 26
            let words = sentence.split(separator: " ").map(String.init)
            for (wi, word) in words.enumerated() {
                let wordWidth = CGFloat(word.count) * 13.5
                if x + wordWidth > size.width - 14 { x = 14; y += lineHeight }
                for ch in word {
                    let design = designs[Int(rng.next() % UInt64(designs.count))]
                    let weight: Font.Weight = rng.next() % 2 == 0 ? .semibold : .regular
                    let resolved = ctx.resolve(Text(String(ch)).font(.system(size: 22, weight: weight, design: design)))
                    let w = resolved.measure(in: CGSize(width: 60, height: 60)).width
                    let angle = Angle.degrees(Double(Int(rng.next() % 29)) - 14)
                    let dy = CGFloat(Int(rng.next() % 9)) - 4
                    ctx.drawLayer { layer in
                        layer.translateBy(x: x + w / 2, y: y + dy)
                        layer.rotate(by: angle)
                        layer.opacity = 0.75 + Double(rng.next() % 25) / 100
                        layer.draw(resolved, at: .zero, anchor: .center)
                    }
                    x += w + 1.5
                }
                if wi < words.count - 1 { x += 9 }
            }
            // Strike lines through the text band.
            for _ in 0..<7 {
                var p = Path()
                let y0 = CGFloat(Int(rng.next() % UInt64(max(Int(size.height), 1))))
                let y1 = CGFloat(Int(rng.next() % UInt64(max(Int(size.height), 1))))
                p.move(to: CGPoint(x: 0, y: y0))
                p.addQuadCurve(to: CGPoint(x: size.width, y: y1),
                               control: CGPoint(x: size.width / 2, y: CGFloat(Int(rng.next() % UInt64(max(Int(size.height), 1))))))
                ctx.stroke(p, with: .color(.primary.opacity(0.55)), lineWidth: 1.4)
            }
            // Speckle.
            for _ in 0..<350 {
                let px = CGFloat(Int(rng.next() % UInt64(max(Int(size.width), 1))))
                let py = CGFloat(Int(rng.next() % UInt64(max(Int(size.height), 1))))
                ctx.fill(Path(ellipseIn: CGRect(x: px, y: py, width: 1.6, height: 1.6)), with: .color(.primary.opacity(0.5)))
            }
        }
        .accessibilityHidden(true)   // no accessible text to read out or copy
    }
}
```

- [ ] **Step 2: Build and try** `scripts/build-app.sh 2>&1 | tail -1 && open build/FocusGuard.app`. With an active Friction window (the existing "Test window" is 00:00–23:59 all days, default friction), remove a site: the sheet appears; try ⌘V with the sentence on the clipboard → nothing is inserted; type it → Unlock enables → the site is removed and `config.json` updated. Cancel leaves the config unchanged. Visually confirm the sentence is legible to a human but noisy.

- [ ] **Step 3: Commit** `git add -A && git commit -m "App: Friction challenge sheet with captcha-style sentence and paste-proof field" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"`

---

### Task 15: Live acceptance on this Mac

No code unless something fails. Needs the user once (sudo for the legacy uninstall, and the Login Items switch).

- [ ] **Step 1: Retire the manual install.** Ask the user to run, in their own terminal:

```bash
cd /Users/newgen/Projects/FocusGuard && scripts/uninstall-daemon.sh
```

Then confirm: `ls /Library/LaunchDaemons/com.focusguard.daemon.plist /usr/local/libexec/focusguardd 2>&1` → both "No such file"; `grep -c FOCUSGUARD /etc/hosts` → `0`.

- [ ] **Step 2: Build, move, install.** `scripts/build-app.sh && open build/FocusGuard.app`. Settings → Status → "Move to Applications" (the app relaunches from `/Applications/FocusGuard.app`; confirm with `ps -o comm= -p $(pgrep -x FocusGuard)`). Click "Install protection". Expect the daemon row to say "Approve FocusGuard in Login Items"; click the button and ask the user to enable FocusGuard under Allow in the Background. Re-focus the Settings window: the row becomes "Background daemon running · pid N" and the login-item row is checked.

Verify: `launchctl print system/com.focusguard.daemon | grep -E "program identifier|state"` → `Contents/MacOS/focusguardd`, `running`. `ls -la "/Library/Application Support/FocusGuard"` → dir `root:admin drwxrwxr-x`, `config.json` present.

- [ ] **Step 3: Config edits are enforced.** In Block Lists add `example.com` and `com.apple.Chess` to a list attached to a window active now (edit the existing "Test window" or make one 00:00–23:59, mode Basic for this test). Within 30 s: `grep example.com /etc/hosts` shows `0.0.0.0 example.com`; `curl -sI http://example.com --max-time 3; echo $?` → non-zero. Remove `example.com` → line gone within one tick.

- [ ] **Step 4: Kill latency.** With `com.apple.Chess` blocked: `open -a Chess`; Chess vanishes almost immediately. Measure:

```bash
log show --last 2m --predicate 'subsystem == "com.focusguard" AND category == "kill"' --style compact | tail -3
```

Expect `terminate com.apple.Chess … reason=launch sinceLaunch=<n>ms` with n well under 500 (target ~100). Also confirm the daemon log shows it did **not** need to act (`log show --last 2m --predicate 'subsystem == "com.focusguard"' | grep -c "terminated"` is 0 or the app got there first).

- [ ] **Step 5: Boundary timer.** In Schedule, add a window "Timer test" starting 2 minutes from now, 3 minutes long, Basic mode, with the list. Watch the menu-bar icon: it must switch to the filled shield at the start minute and back at the end minute (within a second of the clock). `log show --last 10m --predicate 'subsystem == "com.focusguard" AND category == "app"' --style compact | grep refresh` shows exactly one refresh per boundary and per edit, nothing periodic. Delete the test window afterwards.

- [ ] **Step 6: Unlock modes.** Set the active window to Friction: removing a site shows the challenge; ⌘V does nothing; typed correctly it applies. Set it to Impossible (allowed: raising is not weakening): remove buttons, delete, days, start, enabled, mode are disabled with "Locked until …"; extending the end works; shortening pops "Locked"; Quit from the menu opens Settings and shows "Locked". Set the window's end to one minute ahead; after it passes, everything unlocks.

- [ ] **Step 7: KeepAlive and quit.** With no active window, `kill $(pgrep -x FocusGuard)` → the app reappears in the menu bar within ~10 s (agent KeepAlive). Menu → Quit → it stays gone (agent unregistered). Relaunch from `/Applications` → Status shows the login-item row unchecked with its button; click Install protection again → checked.

- [ ] **Step 8: Record results** in the plan file under this task (one line per step: pass/fail, the measured latency), and commit:

```bash
git add docs/superpowers/plans/2026-10-30-menu-bar-app.md
git commit -m "Plan 2: live acceptance results" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 16: Docs and merge

**Files:**
- Modify: `README.md`
- Modify: `docs/superpowers/specs/2026-08-18-focusguard-design.md` (§10 status line)

- [ ] **Step 1: README.** Replace the "Status" checklist's last line with `- [x] FocusGuard.app — menu-bar editor, SMAppService installer, instant app kill, unlock modes.` Replace the "Install the daemon (manual, until the app exists)" section with:

```markdown
## Install

    scripts/build-app.sh
    open build/FocusGuard.app

Settings → Status walks through it: **Move to Applications** (macOS only runs background
daemons for apps in `/Applications`), **Install protection** (registers `focusguardd` as a
root daemon and FocusGuard as a login item from inside the bundle), then approve FocusGuard
in System Settings → General → Login Items & Extensions → Allow in the Background. The row
turns green when the daemon is running. Ad-hoc signed; no developer account needed.

Config lives at `/Library/Application Support/FocusGuard/config.json`, written by the app,
re-read by the daemon every tick (schema: `Sources/FocusGuardCore/Models.swift`, example:
`examples/config.json`).

    focusguardd check        # what would be blocked right now (any user)
    log stream --predicate 'subsystem == "com.focusguard"' --level info

**Fallback without the app:** `scripts/install-daemon.sh` installs the daemon by hand under
the same launchd label (`/usr/local/libexec/focusguardd`). Never use both; the app's Status
tab refuses to install while the manual plist exists and tells you to run
`scripts/uninstall-daemon.sh`.

## Unlock modes

Each schedule window has an unlock mode that governs anything that would unblock something
while it is active (removing a site or app, disabling or deleting the window, shortening it,
lowering its mode, quitting the app, uninstalling):

- **Basic** — applies immediately.
- **Friction** (default) — type a randomly generated sentence, word for word. It is drawn
  captcha-style and the field refuses pasted text.
- **Impossible** — disabled until the window ends ("Locked until 12:00").

Adding sites, apps or windows, and extending an end time, are always allowed. The strictest
mode among the active windows wins.
```

Also update "How enforcement works → Apps" to add: `The app kills a blocked app the moment it launches (NSWorkspace launch notification, ~100 ms); the daemon's 2 s sweep catches anything else and is the only layer that survives the app being quit.` And in "Recovery" add: `Settings → Status → Uninstall protection removes the daemon and login item (gated by the unlock mode of any active window).`

- [ ] **Step 2: Spec status.** In `docs/superpowers/specs/2026-08-18-focusguard-design.md` §10 change `**Status:** Approved for planning.` to `**Status:** Implemented 2026-10-30 (plan: docs/superpowers/plans/2026-10-30-menu-bar-app.md).`

- [ ] **Step 3: Full test run and commit.** `swift test 2>&1 | tail -2` → all pass. `git add -A && git commit -m "README and spec: Plan 2 install flow, unlock modes, fallback" -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"`

- [ ] **Step 4: Merge.** `git checkout main && git merge --no-ff plan-2-app -m "Merge plan-2-app: FocusGuard.app (Plan 2)" && git log --oneline | head -3`. Use `superpowers:finishing-a-development-branch` if the user wants a different integration path.

---

## Self-review notes

- Spec §10.2 shape → Tasks 11–13. §10.3 model → Task 1. §10.4 modes → Tasks 4, 8 (`gate`), 12–14 (affordances), 15 step 6. §10.5 Core functions → Tasks 3–5 (`statusSummary` was folded into `AppModel` derived properties: `activeWindowNames`, counts, `nextWindowNames`; no separate Core type). §10.6 components → Tasks 8–10. §10.7 install → Tasks 6, 7, 10, 15. §10.8 battery → `ScheduleClock` is the only timer; `DaemonProbe` and `InstalledApps` run on user actions only; `AppKiller` is push. §10.9 errors → `StoreError`, `loadError`/`saveError` on Status, legacy detection, `requiresApproval` row. §10.10 → Tasks 1–5 tests, Task 15.
- Names used consistently: `Config.items(ofLists:)`, `ActiveSet.isSubset(of:)`, `LockState.listModes/windowModes/overall/lockedUntil`, `Config.weakens(from:at:)`, `Config.nextBoundary(after:calendar:)`, `Config.windows(startingAt:)`, `Challenge.sentence/matches/words`, `AppModel.apply/gate/mode(forList:)/mode(forWindow:)/requestQuit/requestUninstall/quitNeedsSettingsWindow/lockedUntilText`, `Installer.install/uninstall/unregisterAgent/openLoginItems/moveToApplications/refresh/canInstall/daemonRunningFromBundle`, `Paths.daemonLabel/agentLabel/legacyDaemonPlist`.
