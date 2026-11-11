# Chrome Pages Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Block pages inside Chrome that no site rule can reach — extension pages (`chrome-extension://<id>/…`) and internal pages (`chrome://extensions`, `chrome://settings`) — by making Chrome's own `URLBlocklist` policy preference follow the active windows, with the same lock semantics as sites and apps.

**Architecture:** Each block list gains `chromeURLs: [String]`, Chrome `URLBlocklist` patterns kept verbatim. Core validates their shape (`ChromeURLPattern`), unions them into `ActiveSet.chromeURLs` per tick, and treats each as lock item `c:<pattern>`. The `Reconciler` drives a new `ChromePolicyWriter` port exactly as it drives `HostsFileStore`: it writes only when the sorted active set differs from what it last wrote, never touches a key it did not write (ownership record `/var/db/FocusGuard/chrome-policy.json`), and publishes `DaemonStatus.chrome`. The daemon's real writer sets the key with `CFPreferencesSetValue` + `CFPreferencesSynchronize` in the system domain (`/Library/Preferences/com.google.Chrome.plist`, which is `kCFPreferencesAnyUser` + `kCFPreferencesAnyHost`: the plain file; `kCFPreferencesCurrentHost` would land in `/Library/Preferences/ByHost/`, which does not exist on this Mac) and, if the probe says Chrome does not watch that file, also in the console user's domain. The app shows a **Chrome pages** section per list with an `AddRow`, **Add many…** (`BulkAddSheet` kind `.chromeURLs`) and **Add extension…** (installed extensions read from their manifests). Spec: `docs/superpowers/specs/2026-11-11-chrome-pages-design.md`.

**Tech Stack:** Swift 5 mode on the 6.2 toolchain, SwiftPM, XCTest, Core Foundation preferences API, SystemConfiguration (`SCDynamicStoreCopyConsoleUser`), SwiftUI.

**Conventions (same as previous plans):** commit messages end with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`. Run `swift test` from the repo root. Baseline before Task 1: `Executed 237 tests, with 0 failures`.

**Constraints for the implementer (repeated in every task because they are the whole safety story):**
- Never `sudo`. Never run anything under `scripts/` except `scripts/build-app.sh`.
- Never write to `/Library`, `/etc`, `/var/db`, `/Applications`, or the user's Chrome profile. The real preference write is exercised only by the user running `scripts/verify-chrome.sh` later.
- Never launch, kill, install or update the installed app or daemon.
- TDD: write the failing test, run it, implement, run again, commit.

---

## File structure

```
Sources/FocusGuardCore/
  Models.swift            + ChromeURLPattern, BlockList.chromeURLs, Limits.maxChromeURLs, validate, decode compat
  BulkInput.swift         + chromeURLs(from:)
  Lock.swift              c: items in WindowItems / protection
  ActiveSet.swift         + ActiveSet.chromeURLs, items(ofLists:) union
  Ports.swift             + ChromePolicyWriter protocol
  Reconciler.swift        + chrome writer, last-written change detection, Result.chrome, teardown
  DaemonStatus.swift      + chrome (decodeIfPresent "off"), version 0.6.0
  Paths.swift             + chromePolicy
Sources/focusguardd/
  CFChromePolicyWriter.swift  NEW  the real writer (system domain; user domain per probe), ownership record
  ConfigFile.swift        writeRootFile made internal
  Daemon.swift            wiring, status field
  main.swift              `check` prints chrome patterns
Sources/FocusGuard/
  Model/AppModel.swift    + chromePages, hasChromeURLs
  Model/ChromeExtensions.swift  NEW  installed-extension scan, manifest name resolution
  Views/BlockListsTab.swift  + Chrome pages section
  Views/BulkAddSheet.swift   + .chromeURLs kind
  Views/AddExtensionSheet.swift  NEW
  Views/StatusTab.swift   + "Chrome pages: …" row, Now counts
Tests/FocusGuardCoreTests/
  ChromeURLModelTests.swift, LockChromeTests.swift, ReconcilerChromeTests.swift, Fakes.swift (+ fake writer),
  ChallengeKeystrokeTests.swift (DaemonStatusTests)
Tests/FocusGuardAppTests/
  ChromeExtensionsTests.swift
scripts/verify-chrome.sh  NEW  live acceptance (interactive)
scripts/uninstall-daemon-root.sh  belt-and-braces key removal
README.md, docs/superpowers/specs/2026-11-11-chrome-pages-design.md (status line),
docs/superpowers/specs/2026-08-18-focusguard-design.md (§11.6 pointer), docs/qa/2026-11-06-independent-qa.md (stub),
Sources/FocusGuard/Info.plist (0.6.0 / 6)
```

---

### Task 1: Core model — `ChromeURLPattern`, `BlockList.chromeURLs`, limits, bulk parsing

**Constraints:** no sudo; no `scripts/` except `scripts/build-app.sh`; nothing written under `/Library`, `/etc`, `/var/db`, `/Applications`; do not launch, kill, install or update the installed app or daemon; TDD; commit trailer `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.

**Files:**
- Modify: `Sources/FocusGuardCore/Models.swift`
- Modify: `Sources/FocusGuardCore/BulkInput.swift`
- Create: `Tests/FocusGuardCoreTests/ChromeURLModelTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import FocusGuardCore

final class ChromeURLModelTests: XCTestCase {
    func testNormalizeTrimsAndKeepsCase() {
        XCTAssertEqual(ChromeURLPattern.normalize("  chrome://Extensions/* \n"), "chrome://Extensions/*")
        XCTAssertEqual(ChromeURLPattern.normalize("Example.com"), "Example.com", "kept verbatim; Chrome does its own matching")
    }

    func testEverySchemeIsAccepted() {
        for p in ["chrome://extensions/*", "chrome-extension://fjcldmjmjhkklehbacihaiopjklihlgg/*",
                  "chrome-untrusted://x", "devtools://devtools/*", "file:///Users", "http://a.b", "https://a.b/c?d=e",
                  "CHROME://flags"] {
            XCTAssertTrue(ChromeURLPattern.isValid(p), p)
        }
    }

    func testBareHostPatterns() {
        for p in ["example.com", ".exact.host.com", "*", "example.com:8080/path", "1.2.3.4", "localhost"] {
            XCTAssertTrue(ChromeURLPattern.isValid(p), p)
        }
        for p in ["*.example.com", "-bad.com", "ex ample.com", "", "   ", "chrome://", "a\tb", "a\u{7}b", "..", ".", "/path"] {
            XCTAssertNil(ChromeURLPattern.normalize(p), "\u{201C}\(p)\u{201D} should be rejected")
        }
    }

    func testLengthLimit() {
        let long = "https://" + String(repeating: "a", count: ChromeURLPattern.maxLength - 8)
        XCTAssertTrue(ChromeURLPattern.isValid(long))
        XCTAssertNil(ChromeURLPattern.normalize(long + "a"))
    }

    func testOldConfigWithoutChromeURLsDecodes() throws {
        let json = """
        {"version":1,"blockLists":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"l","domains":["x.com"],"appBundleIDs":[],"keywords":[]}],"schedules":[]}
        """
        let config = try Config.decodeJSON(Data(json.utf8))
        XCTAssertEqual(config.blockLists[0].chromeURLs, [])
    }

    func testRoundTrip() throws {
        let config = Config(blockLists: [BlockList(name: "l", chromeURLs: ["chrome://extensions/*", "example.com"])])
        XCTAssertEqual(try Config.decodeJSON(try config.encodeJSON()), config)
    }

    func testInvalidPatternDoesNotDecode() throws {
        let config = Config(blockLists: [BlockList(name: "l", chromeURLs: ["chrome://extensions/*", "has space"])])
        XCTAssertThrowsError(try Config.decodeJSON(try config.encodeJSON())) { error in
            XCTAssertEqual(error as? Config.ValidationError, .invalidChromeURL("has space"))
        }
    }

    func testLimitAcrossLists() throws {
        var many = Config(blockLists: [BlockList(name: "a"), BlockList(name: "b")])
        many.blockLists[0].chromeURLs = (0..<Config.Limits.maxChromeURLs).map { "https://s\($0).test" }
        XCTAssertNoThrow(try Config.decodeJSON(try many.encodeJSON()))
        many.blockLists[1].chromeURLs = ["https://one.more"]
        XCTAssertThrowsError(try Config.decodeJSON(try many.encodeJSON()))
    }

    func testBulkInputChromeURLs() {
        let text = """
        chrome://extensions/*, chrome-extension://fjcldmjmjhkklehbacihaiopjklihlgg/*
        # comment
        example.com bad pattern *.nope.com
        chrome://extensions/*
        """
        let r = BulkInput.chromeURLs(from: text)
        XCTAssertEqual(r.accepted, ["chrome://extensions/*", "chrome-extension://fjcldmjmjhkklehbacihaiopjklihlgg/*", "example.com", "bad", "pattern"])
        XCTAssertEqual(r.rejected, ["*.nope.com"])
        XCTAssertEqual(BulkInput.chromeURLs(from: " \n"), BulkInput.ChromeURLs(accepted: [], rejected: []))
    }
}
```

(`bad` and `pattern` are accepted on purpose: a word with no dot is a valid bare host pattern to Chrome, like `localhost`. The row-level hint in the app says what a pattern should look like; bulk input does not second-guess Chrome.)

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter ChromeURLModelTests 2>&1 | grep -E "error:|Executed" | head -3`
Expected: compile errors (`ChromeURLPattern` not found).

- [ ] **Step 3: Add the model**

In `Sources/FocusGuardCore/Models.swift`, insert before `public struct BlockList`:

```swift
/// A Chrome `URLBlocklist` pattern (chrome pages spec §2). Kept as typed: Chrome does its own
/// matching. The app only trims, rejects whitespace and control characters, and checks the
/// shape — a scheme Chrome knows, or a bare host pattern it accepts without one.
public enum ChromeURLPattern {
    public static let schemes = ["chrome://", "chrome-extension://", "chrome-untrusted://", "devtools://",
                                 "file://", "http://", "https://"]
    public static let maxLength = 2048

    /// The trimmed pattern, or nil when `raw` cannot be one.
    public static func normalize(_ raw: String) -> String? {
        let p = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty, p.count <= maxLength,
              !p.unicodeScalars.contains(where: {
                  CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
              }) else { return nil }
        let lower = p.lowercased()
        if let scheme = schemes.first(where: { lower.hasPrefix($0) }) {
            return p.count > scheme.count ? p : nil
        }
        return isBareHostPattern(p) ? p : nil
    }

    public static func isValid(_ pattern: String) -> Bool { normalize(pattern) == pattern }

    /// `*`, `example.com`, `.exact.host.com`, optionally followed by `:port` and `/path` — the
    /// shapes Chrome accepts without a scheme. `*` is allowed only as the whole pattern.
    static func isBareHostPattern(_ p: String) -> Bool {
        if p == "*" { return true }
        var rest = Substring(p)
        if rest.hasPrefix(".") { rest = rest.dropFirst() }
        let host = rest.prefix { $0 != "/" && $0 != ":" }
        guard let first = host.first, first.isLetter || first.isNumber,
              host.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".") }),
              !host.contains("..") else { return false }
        return true
    }
}
```

Replace the whole `BlockList` struct with:

```swift
public struct BlockList: Codable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var domains: [String]
    public var appBundleIDs: [String]
    public var keywords: [KeywordRule]
    /// Chrome `URLBlocklist` patterns, as typed and trimmed (chrome pages spec §2).
    public var chromeURLs: [String]

    public init(id: UUID = UUID(), name: String, domains: [String] = [], appBundleIDs: [String] = [],
                keywords: [KeywordRule] = [], chromeURLs: [String] = []) {
        self.id = id
        self.name = name
        self.domains = domains
        self.appBundleIDs = appBundleIDs
        self.keywords = keywords
        self.chromeURLs = chromeURLs
    }

    private enum CodingKeys: String, CodingKey { case id, name, domains, appBundleIDs, keywords, chromeURLs }

    /// Files written before keyword rules (0.5) or Chrome pages (0.6) existed lack those keys.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        domains = try c.decode([String].self, forKey: .domains)
        appBundleIDs = try c.decode([String].self, forKey: .appBundleIDs)
        keywords = try c.decodeIfPresent([KeywordRule].self, forKey: .keywords) ?? []
        chromeURLs = try c.decodeIfPresent([String].self, forKey: .chromeURLs) ?? []
    }
}
```

In `Config.Limits`, after `public static let maxAllow = 500` add:

```swift
        /// Across all lists.
        public static let maxChromeURLs = 200
```

Replace the `ValidationError` enum with:

```swift
    public enum ValidationError: LocalizedError, Equatable {
        case tooLarge(String), duplicateID(String), invalidKeyword(String), invalidChromeURL(String)
        public var errorDescription: String? {
            switch self {
            case .tooLarge(let what): return "Config too large: \(what)."
            case .duplicateID(let what): return "Two \(what) share one id."
            case .invalidKeyword(let text): return "\u{201C}\(text)\u{201D} is not a valid keyword (2–63 letters, digits or hyphens)."
            case .invalidChromeURL(let p): return "\u{201C}\(p)\u{201D} is not a Chrome URL pattern (a scheme such as chrome:// or chrome-extension://, or a site name; no spaces; at most \(ChromeURLPattern.maxLength) characters)."
            }
        }
    }
```

At the end of `validate()` (after the `alwaysAllow` guard) add:

```swift
        let chromeURLs = blockLists.flatMap(\.chromeURLs)
        guard chromeURLs.count <= Limits.maxChromeURLs else { throw ValidationError.tooLarge("\(chromeURLs.count) Chrome patterns; the limit is \(Limits.maxChromeURLs)") }
        if let bad = chromeURLs.first(where: { !ChromeURLPattern.isValid($0) }) { throw ValidationError.invalidChromeURL(bad) }
```

- [ ] **Step 4: Bulk parsing**

In `Sources/FocusGuardCore/BulkInput.swift`, after the `Keywords` struct add:

```swift
    public struct ChromeURLs: Equatable {
        public var accepted: [String]
        public var rejected: [String]
        public init(accepted: [String], rejected: [String]) {
            self.accepted = accepted
            self.rejected = rejected
        }
    }
```

and after `keywords(from:)` add:

```swift
    /// Same splitting and comment handling (no hosts-file handling), each token through
    /// `ChromeURLPattern.normalize`. A pattern never needs a `#` (Chrome ignores fragments), so
    /// the comment rule costs nothing.
    public static func chromeURLs(from text: String) -> ChromeURLs {
        var accepted: [String] = []
        var rejected: [String] = []
        var seenAccepted = Set<String>()
        var seenRejected = Set<String>()
        for line in lines(of: text) {
            for token in split(line) {
                if let pattern = ChromeURLPattern.normalize(token) {
                    if seenAccepted.insert(pattern).inserted { accepted.append(pattern) }
                } else if seenRejected.insert(token).inserted {
                    rejected.append(token)
                }
            }
        }
        return ChromeURLs(accepted: accepted, rejected: rejected)
    }
```

- [ ] **Step 5: Run tests**

Run: `swift test 2>&1 | grep -E "error:|failed|Executed [0-9]+ tests" | tail -2`
Expected: `Executed 246 tests, with 0 failures` (237 + 9; zero failures is the requirement).

- [ ] **Step 6: Commit**

```bash
git add Sources/FocusGuardCore/Models.swift Sources/FocusGuardCore/BulkInput.swift Tests/FocusGuardCoreTests/ChromeURLModelTests.swift
git commit -m "Core: ChromeURLPattern, BlockList.chromeURLs, limit, bulk parsing

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: Core lock — `c:` items

**Constraints:** no sudo; no `scripts/` except `scripts/build-app.sh`; nothing written under `/Library`, `/etc`, `/var/db`, `/Applications`; do not launch, kill, install or update the installed app or daemon; TDD; commit trailer `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.

**Files:**
- Modify: `Sources/FocusGuardCore/Lock.swift`
- Create: `Tests/FocusGuardCoreTests/LockChromeTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import FocusGuardCore

final class LockChromeTests: XCTestCase {
    let ext = "chrome-extension://fjcldmjmjhkklehbacihaiopjklihlgg/*"
    let page = "chrome://extensions/*"
    lazy var list = BlockList(name: "l", domains: ["x.com"], chromeURLs: [ext, page])
    func window(_ lists: [UUID], mode: UnlockMode = .impossible) -> ScheduleWindow {
        ScheduleWindow(name: "w", days: [.mon], start: TimeOfDay("09:00")!, end: TimeOfDay("12:00")!, blockListIDs: lists, unlockMode: mode)
    }
    let at10 = LocalMoment(weekday: .mon, minutesSinceMidnight: 600)
    let at16 = LocalMoment(weekday: .mon, minutesSinceMidnight: 960)

    func testRemovingAProtectedPatternIsACut() {
        let old = Config(blockLists: [list], schedules: [window([list.id])])
        var new = old
        new.blockLists[0].chromeURLs = [ext]
        XCTAssertEqual(new.weakens(from: old, at: at10), .impossible)
        XCTAssertNil(new.weakens(from: old, at: at16))
    }

    func testEditingAPatternIsACut() {
        let old = Config(blockLists: [list], schedules: [window([list.id], mode: .friction)])
        var new = old
        new.blockLists[0].chromeURLs[1] = "chrome://settings/*"
        XCTAssertEqual(new.weakens(from: old, at: at10), .friction)
    }

    func testAddingAPatternIsNotACut() {
        let old = Config(blockLists: [list], schedules: [window([list.id])])
        var new = old
        new.blockLists[0].chromeURLs.append("chrome://settings/*")
        XCTAssertNil(new.weakens(from: old, at: at10))
    }

    func testMovingAPatternToAnotherAttachedListIsNotACut() {
        let other = BlockList(name: "o")
        let old = Config(blockLists: [list, other], schedules: [window([list.id, other.id])])
        var new = old
        new.blockLists[0].chromeURLs = [ext]
        new.blockLists[1].chromeURLs = [page]
        XCTAssertNil(new.weakens(from: old, at: at10))
    }

    func testBasicWindowReportsBasic() {
        let old = Config(blockLists: [list], schedules: [window([list.id], mode: .basic)])
        var new = old
        new.blockLists[0].chromeURLs = []
        XCTAssertEqual(new.weakens(from: old, at: at10), .basic)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter LockChromeTests 2>&1 | grep -E "failed|Executed"`
Expected: three failures (`testRemovingAProtectedPatternIsACut`, `testEditingAPatternIsACut`, `testBasicWindowReportsBasic`); patterns are not items yet.

- [ ] **Step 3: Implement**

In `Sources/FocusGuardCore/Lock.swift`:

Replace the `WindowItems` struct with:

```swift
    private struct WindowItems {
        var set = ActiveSet.empty
        var keywords = Set<String>()
        var chromeURLs = Set<String>()
    }
```

In `itemsPerWindow()`, after the line `perList[list.id]!.keywords.formUnion(list.keywords.map(\.itemKey))` add:

```swift
            perList[list.id]!.chromeURLs.formUnion(list.chromeURLs.compactMap(ChromeURLPattern.normalize))
```

and after `out.keywords.formUnion(l.keywords)` add:

```swift
                out.chromeURLs.formUnion(l.chromeURLs)
```

In `protection(of:active:items:)`, after the `k:` line add:

```swift
            for c in items[i].chromeURLs { map["c:" + c] = max(map["c:" + c] ?? mode, mode) }
```

Update the doc comment on `weakens(from:at:)`: change "a normalized domain, a bundle ID or a keyword rule" to "a normalized domain, a bundle ID, a keyword rule or a Chrome URL pattern".

- [ ] **Step 4: Run the whole suite**

Run: `swift test 2>&1 | grep -E "error:|failed|Executed [0-9]+ tests" | tail -2`
Expected: `Executed 251 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Sources/FocusGuardCore/Lock.swift Tests/FocusGuardCoreTests/LockChromeTests.swift
git commit -m "Core: Chrome URL patterns are lock items

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: Core active set, `ChromePolicyWriter`, Reconciler, status

**Constraints:** no sudo; no `scripts/` except `scripts/build-app.sh`; nothing written under `/Library`, `/etc`, `/var/db`, `/Applications`; do not launch, kill, install or update the installed app or daemon; TDD; commit trailer `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.

**Files:**
- Modify: `Sources/FocusGuardCore/ActiveSet.swift`
- Modify: `Sources/FocusGuardCore/Ports.swift`
- Modify: `Sources/FocusGuardCore/Reconciler.swift`
- Modify: `Sources/FocusGuardCore/DaemonStatus.swift`
- Modify: `Sources/FocusGuardCore/Paths.swift`
- Modify: `Tests/FocusGuardCoreTests/Fakes.swift`
- Modify: `Tests/FocusGuardCoreTests/ChallengeKeystrokeTests.swift` (the `DaemonStatusTests` class lives there)
- Create: `Tests/FocusGuardCoreTests/ReconcilerChromeTests.swift`

- [ ] **Step 1: The fake writer**

Append to `Tests/FocusGuardCoreTests/Fakes.swift`:

```swift
/// Stands in for Chrome's policy preference. `present` is what the key holds right now (nil =
/// absent, whoever set it); `record` is what FocusGuard's ownership record says it last wrote.
final class RecordingChromePolicyWriter: ChromePolicyWriter {
    var present: [String]?
    var record: [String]?
    var applied: [[String]] = []
    var clears = 0
    var failWith: String?
    var chromeInstalled = true

    func recordedPatterns() -> [String]? { record }
    func keyIsPresent() -> Bool { present != nil }
    func apply(patterns: [String]) -> String? {
        if let failWith { return failWith }
        applied.append(patterns)
        present = patterns
        record = patterns
        return nil
    }
    func clear() -> String? {
        if let failWith { return failWith }
        clears += 1
        present = nil
        record = nil
        return nil
    }
}
```

- [ ] **Step 2: Write the failing tests**

`Tests/FocusGuardCoreTests/ReconcilerChromeTests.swift`:

```swift
import XCTest
@testable import FocusGuardCore

final class ReconcilerChromeTests: XCTestCase {
    let base = "127.0.0.1 localhost\n"
    let ext = "chrome-extension://fjcldmjmjhkklehbacihaiopjklihlgg/*"
    let page = "chrome://extensions/*"
    lazy var a = BlockList(name: "a", chromeURLs: [page, ext])
    lazy var b = BlockList(name: "b", chromeURLs: [ext, "chrome://settings/*"])
    lazy var cfg = Config(blockLists: [a, b], schedules: [
        ScheduleWindow(name: "w", days: [.mon], start: TimeOfDay("09:00")!, end: TimeOfDay("12:00")!, blockListIDs: [a.id, b.id])])
    /// Sorted union: what the writer must receive. "-" sorts before ":", so the extension
    /// pattern comes first.
    lazy var all = [ext, "chrome://extensions/*", "chrome://settings/*"]

    var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Vancouver")!
        return c
    }()
    func monday(_ h: Int, _ m: Int) -> Date {   // 2026-10-26 is a Monday
        cal.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: h, minute: m))!
    }

    var hosts: FakeHosts!
    var chrome: RecordingChromePolicyWriter!
    var log: FakeLog!
    var sut: Reconciler!

    override func setUp() {
        hosts = FakeHosts(base)
        chrome = RecordingChromePolicyWriter()
        log = FakeLog()
        sut = Reconciler(hosts: hosts, dns: FakeDNS(), processes: FakeProcesses(), log: log, chrome: chrome, calendar: cal)
    }

    func testActiveSetUnionsPatternsOfActiveLists() {
        let inside = cfg.activeSet(at: LocalMoment(weekday: .mon, minutesSinceMidnight: 600))
        XCTAssertEqual(inside.chromeURLs, Set(all))
        XCTAssertFalse(inside.isEmpty)
        XCTAssertEqual(cfg.activeSet(at: LocalMoment(weekday: .mon, minutesSinceMidnight: 800)).chromeURLs, [])
        XCTAssertFalse(ActiveSet(domains: [], bundleIDs: [], chromeURLs: ["x"]).isEmpty)
        XCTAssertFalse(ActiveSet(domains: [], bundleIDs: [], chromeURLs: ["x"]).isSubset(of: .empty))
        XCTAssertEqual(Array(inside.chromeURLs).sorted(), all)
    }

    func testWindowStartWritesSortedPatternsOnceAndWindowEndClears() {
        let r = sut.tick(live: cfg, clock: ClockSample(wall: monday(10, 0), monotonic: 100))
        XCTAssertEqual(chrome.applied, [all])
        XCTAssertEqual(r.chrome, "applied (3 patterns)")
        _ = sut.tick(live: cfg, clock: ClockSample(wall: monday(10, 0, 2), monotonic: 102))
        XCTAssertEqual(chrome.applied.count, 1, "unchanged set: no second write")
        let r2 = sut.tick(live: cfg, clock: ClockSample(wall: monday(12, 0), monotonic: 7300))
        XCTAssertEqual(chrome.clears, 1)
        XCTAssertNil(chrome.present)
        XCTAssertEqual(r2.chrome, "off")
        XCTAssertTrue(log.infos.contains { $0.contains("chrome policy updated: 3") })
        XCTAssertTrue(log.infos.contains { $0.contains("chrome policy removed") })
    }

    func testAnEditedSetIsRewritten() {
        _ = sut.tick(live: cfg, clock: ClockSample(wall: monday(10, 0), monotonic: 100))
        var smaller = cfg
        smaller.blockLists[1].chromeURLs = []
        let r = sut.tick(live: smaller, clock: ClockSample(wall: monday(10, 1), monotonic: 160))
        XCTAssertEqual(chrome.applied.last, [page, ext].sorted())
        XCTAssertEqual(r.chrome, "applied (2 patterns)")
    }

    func testNothingIsWrittenWhileNothingIsWantedAndNothingWasEverWritten() {
        var plain = cfg
        plain.blockLists = [BlockList(name: "p", domains: ["x.com"])]
        plain.schedules[0].blockListIDs = [plain.blockLists[0].id]
        chrome.present = ["https://theirs.example"]   // someone else's, must survive untouched
        let r = sut.tick(live: plain, clock: ClockSample(wall: monday(10, 0), monotonic: 100))
        XCTAssertEqual(r.chrome, "off")
        XCTAssertEqual(chrome.applied, [])
        XCTAssertEqual(chrome.clears, 0)
        XCTAssertEqual(chrome.present, ["https://theirs.example"])
    }

    func testForeignKeyIsLeftAloneAndLoggedOnce() {
        chrome.present = ["https://theirs.example"]
        let r = sut.tick(live: cfg, clock: ClockSample(wall: monday(10, 0), monotonic: 100))
        XCTAssertEqual(r.chrome, "not applied (URLBlocklist already set by someone else)")
        XCTAssertEqual(chrome.applied, [])
        _ = sut.tick(live: cfg, clock: ClockSample(wall: monday(10, 0, 2), monotonic: 102))
        XCTAssertEqual(log.errors.filter { $0.contains("already set by someone else") }.count, 1, "latched")
        // Once they remove it, FocusGuard takes over.
        chrome.present = nil
        let r2 = sut.tick(live: cfg, clock: ClockSample(wall: monday(10, 0, 4), monotonic: 104))
        XCTAssertEqual(r2.chrome, "applied (3 patterns)")
        XCTAssertEqual(chrome.applied, [all])
    }

    func testRestartWithARecordOwnsTheKey() {
        // A previous daemon wrote these and the window is now over: clear.
        chrome.record = all
        chrome.present = all
        var plain = cfg
        plain.blockLists = []
        plain.schedules = []
        let r = sut.tick(live: plain, clock: ClockSample(wall: monday(13, 0), monotonic: 100))
        XCTAssertEqual(chrome.clears, 1)
        XCTAssertEqual(r.chrome, "off")
    }

    func testRestartWithARecordDoesNotRewriteAnIdenticalSet() {
        chrome.record = all
        chrome.present = all
        let r = sut.tick(live: cfg, clock: ClockSample(wall: monday(10, 0), monotonic: 100))
        XCTAssertEqual(chrome.applied, [], "already what we want")
        XCTAssertEqual(r.chrome, "applied (3 patterns)")
    }

    func testWriteFailureIsReportedLatchedAndRetried() {
        chrome.failWith = "cfprefsd said no"
        let r = sut.tick(live: cfg, clock: ClockSample(wall: monday(10, 0), monotonic: 100))
        XCTAssertEqual(r.chrome, "error: cfprefsd said no")
        _ = sut.tick(live: cfg, clock: ClockSample(wall: monday(10, 0, 2), monotonic: 102))
        XCTAssertEqual(log.errors.filter { $0.contains("chrome policy write failed") }.count, 1)
        chrome.failWith = nil
        let r2 = sut.tick(live: cfg, clock: ClockSample(wall: monday(10, 0, 4), monotonic: 104))
        XCTAssertEqual(r2.chrome, "applied (3 patterns)")
        XCTAssertTrue(log.infos.contains { $0.contains("chrome policy writes recovered") })
    }

    func testChromeNotFoundIsOnlyASuffix() {
        chrome.chromeInstalled = false
        let r = sut.tick(live: cfg, clock: ClockSample(wall: monday(10, 0), monotonic: 100))
        XCTAssertEqual(r.chrome, "applied (3 patterns; Chrome not found)")
        XCTAssertEqual(chrome.applied, [all], "still written: Chrome installed later picks it up")
    }

    func testNoWriterMeansOffAndNoWrites() {
        let none = Reconciler(hosts: hosts, dns: FakeDNS(), processes: FakeProcesses(), log: log, calendar: cal)
        XCTAssertEqual(none.tick(live: cfg, clock: ClockSample(wall: monday(10, 0), monotonic: 100)).chrome, "off")
    }

    func testTeardownClearsOnlyOurOwnKey() {
        chrome.present = ["https://theirs.example"]
        _ = sut.tick(live: cfg, clock: ClockSample(wall: monday(10, 0), monotonic: 100))
        sut.teardown()
        XCTAssertEqual(chrome.clears, 0, "foreign key: not ours to remove")
        chrome.present = nil
        _ = sut.tick(live: cfg, clock: ClockSample(wall: monday(10, 0, 2), monotonic: 102))
        sut.teardown()
        XCTAssertEqual(chrome.clears, 1)
        XCTAssertEqual(hosts.contents, base)
    }
}

private extension ReconcilerChromeTests {
    func monday(_ h: Int, _ m: Int, _ s: Int) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: h, minute: m, second: s))!
    }
}
```

In `Tests/FocusGuardCoreTests/ChallengeKeystrokeTests.swift`, in `DaemonStatusTests`, change the `testRoundTripsThroughJSON` constructor call to end with `dnsWatch: "watching en0", chrome: "applied (2 patterns)")` and add:

```swift
    func testStatusWithoutChromeDecodes() throws {
        let old = Data(#"{"clockOffsetSeconds":0,"clockTampered":false,"dnsWatch":"off","pid":1,"source":"live","timeZone":"UTC","version":"0.5.0"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(DaemonStatus.self, from: old).chrome, "off")
    }
```

- [ ] **Step 3: Run to verify failure**

Run: `swift test --filter "ReconcilerChromeTests|DaemonStatusTests" 2>&1 | grep -E "error:|Executed" | head -3`
Expected: compile errors (`ChromePolicyWriter`, `chrome:`, `chromeURLs`).

- [ ] **Step 4: ActiveSet**

Replace the `ActiveSet` struct in `Sources/FocusGuardCore/ActiveSet.swift` with:

```swift
/// Everything that should be blocked right now.
public struct ActiveSet: Equatable {
    public var domains: Set<String>
    public var bundleIDs: Set<String>
    /// Chrome `URLBlocklist` patterns (chrome pages spec §3). Sorted when written.
    public var chromeURLs: Set<String>

    public init(domains: Set<String>, bundleIDs: Set<String>, chromeURLs: Set<String> = []) {
        self.domains = domains
        self.bundleIDs = bundleIDs
        self.chromeURLs = chromeURLs
    }

    public static let empty = ActiveSet(domains: [], bundleIDs: [])
    public var isEmpty: Bool { domains.isEmpty && bundleIDs.isEmpty && chromeURLs.isEmpty }

    public func isSubset(of other: ActiveSet) -> Bool {
        domains.isSubset(of: other.domains) && bundleIDs.isSubset(of: other.bundleIDs)
            && chromeURLs.isSubset(of: other.chromeURLs)
    }
}
```

In `items(ofLists:)`, after the `out.bundleIDs.formUnion(...)` statement add:

```swift
            out.chromeURLs.formUnion(list.chromeURLs.compactMap(ChromeURLPattern.normalize))
```

- [ ] **Step 5: The port**

Append to `Sources/FocusGuardCore/Ports.swift`:

```swift
/// Chrome's `URLBlocklist` policy preference (chrome pages spec §3). The daemon's implementation
/// writes CFPreferences and keeps an ownership record; tests use a recording fake. Every method
/// is cheap enough to call on a 2 s tick, but the Reconciler calls `apply`/`clear` only when the
/// wanted set changes.
public protocol ChromePolicyWriter {
    /// The patterns FocusGuard itself last wrote, from its ownership record on disk; nil when it
    /// has never written the key, or has since cleared it. Read once, at the first tick, so a
    /// restarted daemon can tell its own key from a user's.
    func recordedPatterns() -> [String]?
    /// Whether `URLBlocklist` is set at all right now, by anyone.
    func keyIsPresent() -> Bool
    /// Make the key equal `patterns` (never empty) and update the record. nil on success,
    /// otherwise a short reason for the status line.
    func apply(patterns: [String]) -> String?
    /// Remove the key and the record. nil on success.
    func clear() -> String?
    /// For the status line only: nothing is skipped when Chrome is absent.
    var chromeInstalled: Bool { get }
}
```

- [ ] **Step 6: Reconciler**

In `Sources/FocusGuardCore/Reconciler.swift`:

Add to `Result` after `keywordWatchWanted`:
```swift
        /// "off", "applied (N patterns)", "applied (N patterns; Chrome not found)",
        /// "not applied (…)" or "error: …" — `DaemonStatus.chrome` (chrome pages spec §5).
        public var chrome: String
```

Add stored properties after `private let log: ReconcilerLog`:
```swift
    /// nil in `check`-style and test contexts that never touch Chrome: status stays "off".
    private let chrome: ChromePolicyWriter?
```
and after `private var lastRenderedLearned: Set<String> = []`:
```swift
    /// What this process (or, via the record, a previous one) last wrote to Chrome. nil: the
    /// key is not ours. Change detection keys on this, as the hosts region keys on file contents.
    private var chromeLastWritten: [String]?
    private var chromeRecordRead = false
    private var chromeForeignLogged = false
    private var chromeFailing = false
```

Add the init parameter `chrome: ChromePolicyWriter? = nil` immediately after `log: ReconcilerLog,` and `self.chrome = chrome` in the body.

In `tick`, replace the `return Result(...)` statement with:
```swift
        let chromeStatus = reconcileChrome(patterns: active.chromeURLs.sorted())

        return Result(activeSet: active, source: source, hostsChanged: hostsChanged,
                      terminated: terminated, killed: killed,
                      trusted: step.trusted, clockTampered: step.tampered,
                      timeZone: calendar.timeZone.identifier,
                      keywordWatchWanted: config.hasKeywordRules,
                      chrome: chromeStatus)
```

Replace `teardown()` with:
```swift
    /// Remove our hosts region and, if we wrote it, Chrome's URLBlocklist key. Called on daemon
    /// shutdown.
    public func teardown() {
        _ = reconcileHosts(domains: [])
        pendingKill.removeAll()
        _ = reconcileChrome(patterns: [])
    }
```

Add after `observe(name:wall:)`:
```swift
    /// Make Chrome's URLBlocklist equal `wanted` (sorted). Writes only when the set differs from
    /// what was last written, and never touches a key it did not write: on first run with the
    /// key already set and no record, it logs once and reports "not applied" (chrome pages spec §3).
    private func reconcileChrome(patterns wanted: [String]) -> String {
        guard let chrome else { return "off" }
        if !chromeRecordRead {
            chromeRecordRead = true
            chromeLastWritten = chrome.recordedPatterns()
        }
        if wanted.isEmpty {
            guard chromeLastWritten != nil else { return "off" }
            if let reason = chrome.clear() { return chromeFailure(reason) }
            chromeLastWritten = nil
            chromeRecovered()
            log.info("chrome policy removed")
            return "off"
        }
        if chromeLastWritten == nil, chrome.keyIsPresent() {
            if !chromeForeignLogged {
                chromeForeignLogged = true
                log.error("Chrome URLBlocklist is already set by someone else; leaving it alone")
            }
            return "not applied (URLBlocklist already set by someone else)"
        }
        if chromeLastWritten != wanted {
            if let reason = chrome.apply(patterns: wanted) { return chromeFailure(reason) }
            chromeLastWritten = wanted
            chromeRecovered()
            log.info("chrome policy updated: \(wanted.count) pattern(s)")
        }
        return "applied (\(wanted.count) patterns\(chrome.chromeInstalled ? "" : "; Chrome not found"))"
    }

    /// Latched like hosts failures: one error line per outage, not one per tick.
    private func chromeFailure(_ reason: String) -> String {
        if !chromeFailing {
            chromeFailing = true
            log.error("chrome policy write failed: \(reason)")
        }
        return "error: \(reason)"
    }

    private func chromeRecovered() {
        if chromeFailing {
            chromeFailing = false
            log.info("chrome policy writes recovered")
        }
    }
```

- [ ] **Step 7: Status and paths**

In `Sources/FocusGuardCore/DaemonStatus.swift`:
- after `public var dnsWatch: String` add:
  ```swift
      /// "off", "applied (N patterns)", "not applied (…)" or "error: …" (chrome pages spec §5).
      public var chrome: String
  ```
- add `chrome: String = "off"` as the last `init` parameter with `self.chrome = chrome`;
- add `chrome` to `CodingKeys`;
- in `init(from:)` add `chrome = try c.decodeIfPresent(String.self, forKey: .chrome) ?? "off"` and extend the doc comment: "`dnsWatch` and `chrome` are optional on decode so a newer app reading the status.json of a still-running older daemon sees a status rather than none."

Leave `FocusGuardVersion.current` at `0.5.0` for now; Task 6 bumps it with the plist.

In `Sources/FocusGuardCore/Paths.swift`, after `learned` add:
```swift
    /// Ownership record for Chrome's URLBlocklist key, 0644: the patterns the daemon last wrote,
    /// so a restart can tell its own key from a user's. Absent when FocusGuard holds no key.
    public static let chromePolicy = stateDir + "/chrome-policy.json"
```

- [ ] **Step 8: Run the whole suite**

Run: `swift test 2>&1 | grep -E "error:|failed|Executed [0-9]+ tests" | tail -2`
Expected: `Executed 263 tests, with 0 failures` (251 + 11 + 1). `ReconcilerTests`, `ReconcilerZoneTests` and `ReconcilerKeywordTests` construct `Reconciler` without `chrome:` and `Result` only through `tick`, so they need no change.

- [ ] **Step 9: Commit**

```bash
git add Sources/FocusGuardCore/ActiveSet.swift Sources/FocusGuardCore/Ports.swift Sources/FocusGuardCore/Reconciler.swift Sources/FocusGuardCore/DaemonStatus.swift Sources/FocusGuardCore/Paths.swift Tests/FocusGuardCoreTests/Fakes.swift Tests/FocusGuardCoreTests/ChallengeKeystrokeTests.swift Tests/FocusGuardCoreTests/ReconcilerChromeTests.swift
git commit -m "Core: ChromePolicyWriter port, reconciler keeps Chrome's URLBlocklist in step, status chrome

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: Daemon — the real writer

**Constraints:** no sudo; no `scripts/` except `scripts/build-app.sh`; nothing written under `/Library`, `/etc`, `/var/db`, `/Applications`; do not launch, kill, install or update the installed app or daemon; TDD where there is logic to test (the CF/`launchctl` calls are tested live only, by the user in Task 6); commit trailer `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`. **Never run `.build/debug/focusguardd once` or `run`; `check` is fine (no root).**

**Spec §3 is decided by the probe, not by you.** Before writing code, ask the user for the `VERDICT:` line printed by `sudo scripts/probe-chrome-policy.sh` (they run it; you do not). The two outcomes are variants of one file that share every line except one constant and one method body:

| Verdict printed by the probe | Variant | `alsoWritesUserDomain` |
|---|---|---|
| `VERDICT: system domain only (sudo-grade guarantee)` | **A: system domain only** | `false` |
| `VERDICT: write both domains …` | **B: both domains** | `true` |

If no verdict is available, stop and report BLOCKED with the question; do not guess. (Variant B's code is present in both builds so flipping is a one-line change later; the constant is what the README's guarantee is written against.)

**Files:**
- Create: `Sources/focusguardd/CFChromePolicyWriter.swift`
- Modify: `Sources/focusguardd/ConfigFile.swift` (`writeRootFile` becomes internal)
- Modify: `Sources/focusguardd/Daemon.swift`
- Modify: `Sources/focusguardd/main.swift`
- Modify: `scripts/uninstall-daemon-root.sh` (edit only; never run it)

- [ ] **Step 1: Expose the atomic root write**

In `Sources/focusguardd/ConfigFile.swift`, change `private static func writeRootFile(` to `static func writeRootFile(` (same body). The Chrome writer uses it for its record.

- [ ] **Step 2: The writer (shared code, both variants)**

`Sources/focusguardd/CFChromePolicyWriter.swift`:

```swift
import CoreFoundation
import Darwin
import Foundation
import FocusGuardCore
import SystemConfiguration

/// Chrome's `URLBlocklist` policy as a CFPreferences write (chrome pages spec §3).
///
/// The durable copy is the **system domain**: `kCFPreferencesAnyUser` + `kCFPreferencesAnyHost`,
/// which is the plain file `/Library/Preferences/com.google.Chrome.plist` (`kCFPreferencesCurrentHost`
/// would be `/Library/Preferences/ByHost/…`, which Chrome does not read). The directory is
/// `root:wheel 0755`, so changing it without a password is impossible — the same guarantee as the
/// hosts region. Written in-process (`CFPreferencesSetValue` + `CFPreferencesSynchronize`): a
/// cfprefsd round trip, no shelling out.
///
/// `alsoWritesUserDomain` is decided by `scripts/probe-chrome-policy.sh`. When Chrome does not
/// notice the system file on its own, the console user's domain is written too (that one Chrome
/// watches), as that user: cfprefsd keys the user domain by uid, so the daemon runs
/// `launchctl asuser <uid> sudo -u <name> defaults …`. `launchctl asuser` alone only switches the
/// Mach bootstrap context and would leave `defaults` running as root with root's home; `sudo -u`
/// (root to user, no password) makes it the user's write. A user can delete that copy, which
/// makes Chrome reload policy and find the system copy; the next tick re-asserts it anyway.
///
/// The ownership record `Paths.chromePolicy` holds the patterns last written, so a restarted
/// daemon knows the key is its own to update or remove; it never touches a key without a record.
struct CFChromePolicyWriter: ChromePolicyWriter {
    /// Variant A (system domain only): false. Variant B (both domains): true. See the plan's
    /// Task 4 table; this is the only line that differs between the two.
    static let alsoWritesUserDomain = false   // ← set per the probe's VERDICT

    static let domain = "com.google.Chrome" as CFString
    static let key = "URLBlocklist" as CFString

    private struct Record: Codable {
        var patterns: [String]
        var writtenAt: Date
    }

    // MARK: ChromePolicyWriter

    func recordedPatterns() -> [String]? {
        guard let data = FileManager.default.contents(atPath: Paths.chromePolicy),
              let record = try? JSONDecoder().decode(Record.self, from: data) else { return nil }
        return record.patterns
    }

    func keyIsPresent() -> Bool {
        if CFPreferencesCopyValue(Self.key, Self.domain, kCFPreferencesAnyUser, kCFPreferencesAnyHost) != nil { return true }
        guard Self.alsoWritesUserDomain, let user = Self.consoleUser(),
              let home = NSHomeDirectoryForUser(user.name) else { return false }
        // The user's plist read directly: cheap, no process spawn, and `defaults write` flushes
        // it at once so the file is current.
        guard let data = FileManager.default.contents(atPath: home + "/Library/Preferences/com.google.Chrome.plist"),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
        else { return false }
        return plist["URLBlocklist"] != nil
    }

    /// Order matters for a restart mid-write: the record is saved as soon as the system key is
    /// ours, so a failed user-domain step (retried next tick; `apply` is idempotent) can never
    /// leave a key of ours that a restarted daemon would take for someone else's.
    func apply(patterns: [String]) -> String? {
        CFPreferencesSetValue(Self.key, patterns as CFArray, Self.domain, kCFPreferencesAnyUser, kCFPreferencesAnyHost)
        guard CFPreferencesSynchronize(Self.domain, kCFPreferencesAnyUser, kCFPreferencesAnyHost) else {
            return "CFPreferencesSynchronize failed for the system domain"
        }
        guard saveRecord(patterns) else { return "could not write \(Paths.chromePolicy)" }
        if Self.alsoWritesUserDomain, let reason = writeUserDomain(patterns) { return reason }
        return nil
    }

    /// The record goes last here, for the same reason: while any copy of the key may still be
    /// ours, the record must say so.
    func clear() -> String? {
        CFPreferencesSetValue(Self.key, nil, Self.domain, kCFPreferencesAnyUser, kCFPreferencesAnyHost)
        guard CFPreferencesSynchronize(Self.domain, kCFPreferencesAnyUser, kCFPreferencesAnyHost) else {
            return "CFPreferencesSynchronize failed for the system domain"
        }
        if Self.alsoWritesUserDomain, let reason = writeUserDomain(nil) { return reason }
        if unlink(Paths.chromePolicy) != 0, errno != ENOENT { return "could not remove \(Paths.chromePolicy)" }
        return nil
    }

    /// `/Applications/Google Chrome.app` or the console user's `~/Applications/Google Chrome.app`
    /// (the daemon's own home is root's). Two stats, and only on a tick that has patterns.
    var chromeInstalled: Bool {
        var candidates = ["/Applications/Google Chrome.app"]
        if let user = Self.consoleUser(), let home = NSHomeDirectoryForUser(user.name) {
            candidates.append(home + "/Applications/Google Chrome.app")
        }
        return candidates.contains { FileManager.default.fileExists(atPath: $0) }
    }

    // MARK: Pieces

    private func saveRecord(_ patterns: [String]) -> Bool {
        guard let data = try? JSONEncoder().encode(Record(patterns: patterns, writtenAt: Date())) else { return false }
        return ConfigFile.writeRootFile(Paths.chromePolicy, data, mode: 0o644)
    }

    /// The user at the console (nil at the login window or when no one is logged in).
    static func consoleUser() -> (name: String, uid: uid_t)? {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard let name = SCDynamicStoreCopyConsoleUser(nil, &uid, &gid) as String?,
              name != "loginwindow", uid != 0 else { return nil }
        return (name, uid)
    }

    /// Variant B only. `patterns == nil` deletes the key. Returns a reason on failure; with no
    /// console user the write cannot be done yet, which is reported so the tick retries it once
    /// someone is logged in (Chrome is not running for anyone meanwhile).
    private func writeUserDomain(_ patterns: [String]?) -> String? {
        guard let user = Self.consoleUser() else { return "no console user for the user-domain write" }
        var args = ["asuser", String(user.uid), "/usr/bin/sudo", "-n", "-u", user.name, "/usr/bin/defaults"]
        if let patterns {
            args += ["write", "com.google.Chrome", "URLBlocklist", "-array"] + patterns
        } else {
            args += ["delete", "com.google.Chrome", "URLBlocklist"]
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            return "launchctl asuser: \(error.localizedDescription)"
        }
        // `defaults delete` exits 1 when the key is already absent — the state we want.
        guard patterns == nil || p.terminationStatus == 0 else {
            return "defaults write (user domain) exited \(p.terminationStatus)"
        }
        return nil
    }
}
```

**Variant A: system domain only** — leave `static let alsoWritesUserDomain = false`. `writeUserDomain` and the user-plist branch of `keyIsPresent` are then dead code kept for the flip; do not delete them.

**Variant B: both domains** — set `static let alsoWritesUserDomain = true`. Nothing else changes in this file.

- [ ] **Step 3: Wire it**

In `Sources/focusguardd/Daemon.swift`:
- in the `Reconciler(` call in `init()`, add `chrome: CFChromePolicyWriter(),` immediately after `log: log,`;
- make `let previousChrome = lastSavedStatus?.chrome` the first line of `tick()` (the status is overwritten further down, so capture it first);
- in the `DaemonStatus(` construction, add `chrome: result.chrome` after `dnsWatch: watcher.state`;
- replace the tick log statement with:
  ```swift
          if result.hostsChanged || !result.terminated.isEmpty || !result.killed.isEmpty || result.chrome != previousChrome {
              log.info("tick: source=\(result.source.rawValue) domains=\(result.activeSet.domains.count) apps=\(result.activeSet.bundleIDs.count) chrome=\(result.activeSet.chromeURLs.count) (\(result.chrome))")
          }
  ```

In `Sources/focusguardd/main.swift`, in `check()`, after the `print("apps:    …")` line add:
```swift
    print("chrome:  \(active.chromeURLs.sorted().joined(separator: " "))")
```

- [ ] **Step 4: Uninstaller belt and braces**

In `scripts/uninstall-daemon-root.sh`, insert immediately before the line `rm -rf /var/db/FocusGuard "/Library/Application Support/FocusGuard/state"`:

```bash
# The daemon removes its Chrome URLBlocklist key on SIGTERM. If it was killed instead, the
# ownership record is still here and the key is ours to remove (never anyone else's).
if [ -f /var/db/FocusGuard/chrome-policy.json ]; then
    defaults delete /Library/Preferences/com.google.Chrome URLBlocklist 2>/dev/null || true
    console_user=$(stat -f %Su /dev/console 2>/dev/null || true)
    if [ -n "$console_user" ] && [ "$console_user" != root ]; then
        console_uid=$(id -u "$console_user")
        launchctl asuser "$console_uid" sudo -n -u "$console_user" defaults delete com.google.Chrome URLBlocklist 2>/dev/null || true
    fi
fi
```
(The user-domain line is harmless under variant A: the key is absent there and `defaults delete` exits 1, swallowed.)

- [ ] **Step 5: Build, syntax-check, smoke**

Run: `swift build 2>&1 | grep -E "error|Build complete" && bash -n scripts/uninstall-daemon-root.sh && echo syntax-ok && .build/debug/focusguardd check | head -4`
Expected: `Build complete!`, `syntax-ok`, and `check` output now ending in a `chrome:` line before `lock:` (no root needed; `check` never writes). If `SCDynamicStoreCopyConsoleUser` or the `kCFPreferences*` constants fail to resolve, the imports above are what the toolchain needs (type-checked on this Mac on 2026-11-11); report the exact compiler line rather than working around it.

- [ ] **Step 6: Commit**

```bash
git add Sources/focusguardd/CFChromePolicyWriter.swift Sources/focusguardd/ConfigFile.swift Sources/focusguardd/Daemon.swift Sources/focusguardd/main.swift scripts/uninstall-daemon-root.sh
git commit -m "Daemon: Chrome URLBlocklist via CFPreferences (<variant A: system domain | variant B: both domains>), ownership record

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```
(Replace the angle-bracket phrase with the variant you built.)

---

### Task 5: App — Chrome pages section, Add many…, Add extension…, status row

**Constraints:** no sudo; no `scripts/` except `scripts/build-app.sh`; nothing written under `/Library`, `/etc`, `/var/db`, `/Applications`; do not launch, kill, install or update the installed app or daemon (do not `open build/FocusGuard.app` either — the installed app is the user's); TDD for the extension scan; commit trailer `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`. The scan reads the user's Chrome profile read-only; the test uses a temp fixture, never the real profile.

**Files:**
- Create: `Sources/FocusGuard/Model/ChromeExtensions.swift`
- Create: `Tests/FocusGuardAppTests/ChromeExtensionsTests.swift`
- Create: `Sources/FocusGuard/Views/AddExtensionSheet.swift`
- Modify: `Sources/FocusGuard/Views/BulkAddSheet.swift`
- Modify: `Sources/FocusGuard/Views/BlockListsTab.swift`
- Modify: `Sources/FocusGuard/Model/AppModel.swift`
- Modify: `Sources/FocusGuard/Views/StatusTab.swift`

- [ ] **Step 1: Write the failing tests** (app target; `@testable import FocusGuard` is already how `ConfigStoreTests` works)

`Tests/FocusGuardAppTests/ChromeExtensionsTests.swift`:

```swift
import XCTest
@testable import FocusGuard

final class ChromeExtensionsTests: XCTestCase {
    private var root: URL!
    let a = String(repeating: "a", count: 32)
    let b = String(repeating: "b", count: 32)
    let c = String(repeating: "c", count: 32)
    let d = String(repeating: "d", count: 32)

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("focusguard-chrome-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    /// Writes `<profile>/Extensions/<id>/<version>/manifest.json` (+ locales) under the fixture root.
    private func install(_ id: String, version: String, profile: String = "Default", manifest: [String: Any],
                         locales: [String: [String: Any]] = [:]) throws {
        let dir = root.appendingPathComponent("\(profile)/Extensions/\(id)/\(version)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: manifest).write(to: dir.appendingPathComponent("manifest.json"))
        for (locale, messages) in locales {
            let l = dir.appendingPathComponent("_locales/\(locale)")
            try FileManager.default.createDirectory(at: l, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: messages).write(to: l.appendingPathComponent("messages.json"))
        }
    }

    func testPlainNameAndSortedByName() throws {
        try install(a, version: "3.0.5_0", manifest: ["name": "News Feed Eradicator"])
        try install(b, version: "1.0_0", manifest: ["name": "Another"])
        let found = ChromeExtensions.installed(under: root)
        XCTAssertEqual(found.map(\.name), ["Another", "News Feed Eradicator"])
        XCTAssertEqual(found.map(\.id), [b, a])
    }

    func testMessageNameResolvedFromDefaultLocaleThenEnThenEnUS() throws {
        try install(a, version: "1_0", manifest: ["name": "__MSG_name__", "default_locale": "fr"],
                    locales: ["fr": ["name": ["message": "Pince-notes"]], "en": ["name": ["message": "Web Clipper"]]])
        try install(b, version: "1_0", manifest: ["name": "__MSG_extName__", "default_locale": "en_US"],
                    locales: ["en_US": ["extName": ["message": "Docs Offline"]]])
        try install(c, version: "1_0", manifest: ["name": "__MSG_appName__"],
                    locales: ["en": ["APPNAME": ["message": "Case Insensitive Key"]]])
        try install(d, version: "1_0", manifest: ["name": "__MSG_missing__"])
        let byID = Dictionary(uniqueKeysWithValues: ChromeExtensions.installed(under: root).map { ($0.id, $0.name) })
        XCTAssertEqual(byID[a], "Pince-notes")
        XCTAssertEqual(byID[b], "Docs Offline")
        XCTAssertEqual(byID[c], "Case Insensitive Key")
        XCTAssertEqual(byID[d], d, "falls back to the id")
    }

    func testNewestVersionWinsAndProfilesMerge() throws {
        try install(a, version: "1.6.0_0", manifest: ["name": "Old"])
        try install(a, version: "1.11_0", manifest: ["name": "New"])
        try install(a, version: "1.11_0", profile: "Profile 1", manifest: ["name": "New"])
        let found = ChromeExtensions.installed(under: root)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].name, "New")
        XCTAssertEqual(found[0].profiles, ["Default", "Profile 1"])
    }

    func testNonExtensionEntriesAreSkipped() throws {
        try install(a, version: "1_0", manifest: ["name": "Real"])
        try install("Temp", version: "1_0", manifest: ["name": "Not an id"])
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Default/Extensions/\(b)/.DS_Store-ish"), withIntermediateDirectories: true)
        XCTAssertEqual(ChromeExtensions.installed(under: root).map(\.id), [a])
        XCTAssertEqual(ChromeExtensions.installed(under: root.appendingPathComponent("missing")), [])
    }

    func testPatternsForAnExtension() {
        XCTAssertEqual(ChromeExtensions.patterns(forExtensionID: a), ["chrome-extension://\(a)/*", "chrome://extensions/*"])
        XCTAssertTrue(ChromeExtensions.isExtensionID("fjcldmjmjhkklehbacihaiopjklihlgg"))
        XCTAssertFalse(ChromeExtensions.isExtensionID("fjcldmjmjhkklehbacihaiopjklihlgq"), "q is outside a–p")
        XCTAssertTrue(ChromeExtensions.versionLess("1.6.0_0", "1.11_0"))
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter ChromeExtensionsTests 2>&1 | grep -E "error:|Executed" | head -3`
Expected: compile errors (`ChromeExtensions` not found).

- [ ] **Step 3: The scan**

`Sources/FocusGuard/Model/ChromeExtensions.swift`:

```swift
import Foundation

/// An extension installed in some Chrome profile on this Mac, read from its unpacked manifest.
struct ChromeExtension: Identifiable, Hashable {
    let id: String
    let name: String
    /// Profile folders it was found in ("Default", "Profile 1"), sorted.
    let profiles: [String]

    var patterns: [String] { ChromeExtensions.patterns(forExtensionID: id) }
}

/// Reads `~/Library/Application Support/Google/Chrome/*/Extensions/<id>/<version>/manifest.json`
/// (chrome pages spec §6). Read-only; safe off the main thread.
enum ChromeExtensions {
    static let chromeRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Google/Chrome")

    /// The extension's own pages, and the page where it could be disabled.
    static func patterns(forExtensionID id: String) -> [String] {
        ["chrome-extension://\(id)/*", "chrome://extensions/*"]
    }

    static func installed() -> [ChromeExtension] { installed(under: chromeRoot) }

    static func installed(under root: URL) -> [ChromeExtension] {
        let fm = FileManager.default
        guard let profiles = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
        var byID: [String: (name: String, profiles: [String])] = [:]
        for profile in profiles.sorted() {
            let extensions = root.appendingPathComponent(profile).appendingPathComponent("Extensions")
            guard let ids = try? fm.contentsOfDirectory(atPath: extensions.path) else { continue }
            for id in ids where isExtensionID(id) {
                let dir = extensions.appendingPathComponent(id)
                guard let versions = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
                // Chrome keeps the previous version until the next launch; show the newest.
                let candidates = versions.filter { !$0.hasPrefix(".") }.sorted { versionLess($1, $0) }
                guard let (manifest, versionDir) = candidates.lazy.compactMap({ v -> ([String: Any], URL)? in
                    let d = dir.appendingPathComponent(v)
                    return readJSON(d.appendingPathComponent("manifest.json")).map { ($0, d) }
                }).first else { continue }
                let name = resolveName(manifest, in: versionDir) ?? id
                if let seen = byID[id] {
                    byID[id] = (seen.name, seen.profiles + [profile])
                } else {
                    byID[id] = (name, [profile])
                }
            }
        }
        return byID.map { ChromeExtension(id: $0.key, name: $0.value.name, profiles: $0.value.profiles) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Chrome extension ids are 32 letters in a–p (a hex digest spelled with letters).
    static func isExtensionID(_ s: String) -> Bool {
        s.count == 32 && s.allSatisfy { $0 >= "a" && $0 <= "p" }
    }

    /// "1.6.0_0" < "1.11_0": numeric components compared in order.
    static func versionLess(_ a: String, _ b: String) -> Bool {
        let pa = a.split(whereSeparator: { $0 == "." || $0 == "_" }).map { Int($0) ?? 0 }
        let pb = b.split(whereSeparator: { $0 == "." || $0 == "_" }).map { Int($0) ?? 0 }
        return pa.lexicographicallyPrecedes(pb)
    }

    static func readJSON(_ url: URL) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// `name`, with `__MSG_key__` resolved from `_locales/<default_locale>/messages.json`, then
    /// `en`, then `en_US`; keys are matched exactly, then case-insensitively (Chrome treats
    /// them so). nil when nothing usable is found.
    static func resolveName(_ manifest: [String: Any], in dir: URL) -> String? {
        guard let raw = (manifest["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        guard raw.hasPrefix("__MSG_"), raw.hasSuffix("__"), raw.count > 8 else { return raw }
        let key = String(raw.dropFirst(6).dropLast(2))
        var locales = ["en", "en_US"]
        if let def = manifest["default_locale"] as? String, !def.isEmpty { locales.insert(def, at: 0) }
        for locale in locales {
            guard let messages = readJSON(dir.appendingPathComponent("_locales/\(locale)/messages.json")) else { continue }
            let entry = messages[key] ?? messages.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
            if let message = (entry as? [String: Any])?["message"] as? String,
               !message.trimmingCharacters(in: .whitespaces).isEmpty {
                return message.trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}
```

- [ ] **Step 4: Run the scan tests**

Run: `swift test --filter ChromeExtensionsTests 2>&1 | grep -E "failed|Executed"`
Expected: `Executed 5 tests, with 0 failures`.

- [ ] **Step 5: The sheet**

`Sources/FocusGuard/Views/AddExtensionSheet.swift`:

```swift
import SwiftUI

/// Pick installed Chrome extensions; each adds `chrome-extension://<id>/*` and
/// `chrome://extensions/*` — the page where the extension could be disabled (spec §6).
struct AddExtensionSheet: View {
    /// Patterns the list already holds.
    let alreadyAdded: Set<String>
    let onAdd: ([String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var extensions: [ChromeExtension] = []
    @State private var scanning = true
    @State private var query = ""
    @State private var picked = Set<String>()

    private var shown: [ChromeExtension] {
        extensions.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.id.localizedCaseInsensitiveContains(query) }
    }
    private func fullyAdded(_ ext: ChromeExtension) -> Bool { ext.patterns.allSatisfy(alreadyAdded.contains) }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search extensions", text: $query).textFieldStyle(.roundedBorder).padding()
            if scanning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading Chrome's extensions…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if extensions.isEmpty {
                ContentUnavailableView("No Chrome extensions found", systemImage: "puzzlepiece.extension",
                                       description: Text("Looked in ~/Library/Application Support/Google/Chrome/*/Extensions. You can still type a pattern in the list."))
            } else if shown.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                List(shown, selection: $picked) { ext in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(ext.name)
                            Text(ext.id).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if fullyAdded(ext) { Text("Added").font(.caption).foregroundStyle(.secondary) }
                    }
                    .tag(ext.id)
                    .selectionDisabled(fullyAdded(ext))
                }
            }
            Divider()
            Text("Each extension adds two patterns: its own pages (chrome-extension://<id>/*) and chrome://extensions/*, which also blocks the page where the extension could be disabled.")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding([.horizontal, .top])
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") {
                    onAdd(picked.sorted().flatMap(ChromeExtensions.patterns(forExtensionID:)))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(picked.isEmpty)
            }
            .padding()
        }
        .frame(width: 480, height: 440)
        .task {
            // One scan per sheet, off the main thread: a manifest and a messages file per extension.
            let found = await Task.detached(priority: .userInitiated) { ChromeExtensions.installed() }.value
            extensions = found
            scanning = false
        }
    }
}
```

- [ ] **Step 6: Bulk add kind**

In `Sources/FocusGuard/Views/BulkAddSheet.swift`:

Replace the `Kind` enum with:
```swift
    enum Kind: String, Identifiable {
        case sites, keywords, chromeURLs
        var id: String { rawValue }
    }
```

Update the doc comment on `existing` to: `/// What the list already holds: site names for `.sites`, `KeywordRule.itemKey`s for `.keywords`, patterns for `.chromeURLs`.`

Replace the `parsed` computed property with:
```swift
    private var parsed: (accepted: [String], rejected: [String]) {
        switch kind {
        case .sites:
            let r = BulkInput.sites(from: text)
            return (r.accepted, r.rejected)
        case .keywords:
            let r = BulkInput.keywords(from: text)
            return (r.accepted, r.rejected)
        case .chromeURLs:
            let r = BulkInput.chromeURLs(from: text)
            return (r.accepted, r.rejected)
        }
    }
```

Replace `key(_:)`, `limit` and `noun` with:
```swift
    private func key(_ item: String) -> String {
        kind == .keywords ? KeywordRule(text: item, match: match).itemKey : item
    }
```
```swift
    private var limit: Int {
        switch kind {
        case .sites: return Config.Limits.maxDomains
        case .keywords: return Config.Limits.maxKeywords
        case .chromeURLs: return Config.Limits.maxChromeURLs
        }
    }
```
```swift
    private var noun: String {
        switch kind {
        case .sites: return "sites"
        case .keywords: return "keywords"
        case .chromeURLs: return "Chrome patterns"
        }
    }
```

Add a case to `placeholder`'s switch:
```swift
        case .chromeURLs: return "One pattern per line, or separated by spaces or commas, e.g. chrome://extensions/* or chrome-extension://<id>/*. No hosts-file handling."
        }
```

(The `Picker("Match", …)` is already shown only for `.keywords`; `Import file…` stays for every kind.)

- [ ] **Step 7: Chrome pages section**

In `Sources/FocusGuard/Views/BlockListsTab.swift`, in `BlockListDetail`:

Add state after `@State private var showAddApp = false`:
```swift
    @State private var newChromeURL = ""
    @State private var chromeHint: String?
    @State private var showAddExtension = false
```

Change the `.onChange(of: list.id)` modifier on the name field to `.onChange(of: list.id) { _, _ in name = list.name; newDomain = ""; newChromeURL = "" }`.

Insert a new section between `Section("Apps") { … }` and the **Always allow** section:
```swift
            Section {
                ForEach(unique(list.chromeURLs), id: \.self) { pattern in
                    HStack {
                        Text(pattern).font(.system(.body, design: .monospaced))
                            .lineLimit(1).truncationMode(.middle).help(pattern)
                        Spacer()
                        removeButton { commit { $0.update(list: list.id) { $0.chromeURLs.removeAll { $0 == pattern } } } }
                    }
                }
                AddRow("chrome-extension://\u{2026} or chrome://extensions/*", text: $newChromeURL, onSubmit: addChromeURL) {
                } accessory: {
                    Button("Add extension\u{2026}") { showAddExtension = true }
                    Button("Add many\u{2026}") { bulkKind = .chromeURLs }
                }
                if let hint = chromeHint { Text(hint).font(.caption).foregroundStyle(.red) }
            } header: {
                Text("Chrome pages")
            } footer: {
                Text("Blocks pages inside Chrome itself. Chrome shows them as blocked by an administrator. Other browsers are not affected.")
            }
```

Add a second sheet modifier after `.sheet(isPresented: $showAddApp) { … }`:
```swift
        .sheet(isPresented: $showAddExtension) {
            AddExtensionSheet(alreadyAdded: Set(list.chromeURLs)) { patterns in
                commit { $0.update(list: list.id) { l in
                    for p in patterns where !l.chromeURLs.contains(p) { l.chromeURLs.append(p) }
                } }
            }
        }
```

Add a case to the `switch kind` inside `.sheet(item: $bulkKind)`:
```swift
            case .chromeURLs:
                BulkAddSheet(kind: .chromeURLs, listName: list.name, existing: Set(list.chromeURLs),
                             totalInConfig: lists.reduce(0) { $0 + $1.chromeURLs.count }) { patterns, _ in
                    commit { $0.update(list: list.id) { l in
                        for p in patterns where !l.chromeURLs.contains(p) { l.chromeURLs.append(p) }
                    } }
                }
```

Add the action after `addKeyword()`:
```swift
    private func addChromeURL() {
        let typed = newChromeURL.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else { return }
        guard let pattern = ChromeURLPattern.normalize(typed) else {
            chromeHint = "\u{201C}\(typed)\u{201D} is not a Chrome URL pattern. Use a full address like chrome://extensions/* or chrome-extension://<id>/*, or a site like example.com \u{2014} no spaces, at most \(ChromeURLPattern.maxLength) characters."
            return
        }
        chromeHint = nil
        commit { $0.update(list: list.id) { if !$0.chromeURLs.contains(pattern) { $0.chromeURLs.append(pattern) } } }
        newChromeURL = ""
    }
```

- [ ] **Step 8: Model and Status tab**

In `Sources/FocusGuard/Model/AppModel.swift`, after `var hasKeywordRules: Bool { … }` add:
```swift
    /// What the daemon reports about Chrome's policy preference; nil when no daemon status is known.
    var chromePages: String? { installer.status?.chrome }
    var hasChromeURLs: Bool { (config ?? .empty).blockLists.contains { !$0.chromeURLs.isEmpty } }
```

In `Sources/FocusGuard/Views/StatusTab.swift`, inside `Section("Protection")` right after the keyword-matching `if` block, add:
```swift
                if model.hasChromeURLs || (model.chromePages ?? "off") != "off" {
                    let chrome = model.chromePages ?? "unknown (daemon status not available)"
                    row(done: chrome.hasPrefix("applied"), "Chrome pages: \(chrome)",
                        detail: chrome.hasPrefix("applied") ? "Chrome's URLBlocklist policy holds the patterns of every active window; Chrome shows those pages as blocked by an administrator." :
                                chrome.hasPrefix("not applied") ? "Something else has set Chrome's URLBlocklist. FocusGuard never overwrites it. To let FocusGuard manage it: sudo defaults delete /Library/Preferences/com.google.Chrome URLBlocklist" :
                                "Chrome patterns are written to Chrome's policy when a window that has them starts.")
                }
```

In `Section("Now")`, replace the `LabeledContent("Blocking", …)` line with:
```swift
                    LabeledContent("Blocking", value: "\(model.activeSet.domains.count) sites, \(model.activeSet.bundleIDs.count) apps"
                                   + (model.activeSet.chromeURLs.isEmpty ? "" : ", \(model.activeSet.chromeURLs.count) Chrome pages"))
```

- [ ] **Step 9: Build the app bundle and run everything**

Run: `scripts/build-app.sh 2>&1 | grep -E "error|built" && swift test 2>&1 | grep -E "error:|failed|Executed [0-9]+ tests" | tail -2`
Expected: `built build/FocusGuard.app`, `Executed 268 tests, with 0 failures` (263 + 5). Do **not** open or copy the built app anywhere.

- [ ] **Step 10: Commit**

```bash
git add Sources/FocusGuard/Model/ChromeExtensions.swift Tests/FocusGuardAppTests/ChromeExtensionsTests.swift Sources/FocusGuard/Views/AddExtensionSheet.swift Sources/FocusGuard/Views/BulkAddSheet.swift Sources/FocusGuard/Views/BlockListsTab.swift Sources/FocusGuard/Model/AppModel.swift Sources/FocusGuard/Views/StatusTab.swift
git commit -m "App: Chrome pages section, Add extension…, bulk add kind, status row

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: Live acceptance script, README, spec status, version 0.6.0, QA stub

**Constraints:** no sudo; no `scripts/` except `scripts/build-app.sh` — **you write `scripts/verify-chrome.sh` but never run it** (`bash -n` only); nothing written under `/Library`, `/etc`, `/var/db`, `/Applications`; do not launch, kill, install or update the installed app or daemon; commit trailer `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.

**Files:**
- Create: `scripts/verify-chrome.sh`
- Modify: `README.md`
- Modify: `docs/superpowers/specs/2026-11-11-chrome-pages-design.md` (status line)
- Modify: `docs/superpowers/specs/2026-08-18-focusguard-design.md` (§11.6 pointer)
- Modify: `docs/qa/2026-11-06-independent-qa.md` (stub section)
- Modify: `Sources/FocusGuardCore/DaemonStatus.swift` (`FocusGuardVersion.current`), `Sources/FocusGuard/Info.plist`

Version plumbing, for reference: `FocusGuardVersion.current` (Core) is what the daemon writes to `status.json` and what the app compares against (`Installer.needsUpdate`); `Info.plist`'s `CFBundleShortVersionString` / `CFBundleVersion` are copied verbatim into the bundle by `scripts/build-app.sh` (`cp Sources/FocusGuard/Info.plist "$APP/Contents/Info.plist"`). Both must say 0.6.0; the build number goes 5 → 6.

- [ ] **Step 1: Live script**

`scripts/verify-chrome.sh`:

```bash
#!/bin/bash
# Live acceptance for Chrome pages (chrome pages spec §8). Needs the installed 0.6.0 daemon, no
# password, Google Chrome running, and you at the keyboard: the script can read the policy
# preference but cannot see what Chrome shows, so it asks. Puts the two News Feed Eradicator
# patterns in a window active now, checks the preference follows the window (set, removed,
# held under Impossible), and asks whether Chrome blocks chrome://extensions. ~3 minutes.
# Your config.json is backed up and restored.
set -uo pipefail
CFG="/Library/Application Support/FocusGuard/config.json"
STATUS=/var/db/FocusGuard/status.json
RECORD=/var/db/FocusGuard/chrome-policy.json
SYS=/Library/Preferences/com.google.Chrome
EXT=fjcldmjmjhkklehbacihaiopjklihlgg
fail=0
check() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1"; fail=1; fi; }
wait_for() { for _ in $(seq "$2"); do eval "$1" && return 0; sleep 1; done; return 1; }
field() { /usr/bin/python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$STATUS" "$1" 2>/dev/null; }
ask() { local a; while :; do read -r -p "$1 [y/n] " a </dev/tty; case "$a" in y|Y) return 0;; n|N) return 1;; esac; done; }
# The system-domain plist is world-readable; `defaults read` by path needs no root.
sys_has() { defaults read "$SYS" URLBlocklist 2>/dev/null | grep -qF -- "$1"; }
sys_absent() { ! defaults read "$SYS" URLBlocklist >/dev/null 2>&1; }
user_domain() { defaults read com.google.Chrome URLBlocklist 2>/dev/null | tr -d '\n ' || echo absent; }

[ -f "$STATUS" ] || { echo "the daemon is not installed (no $STATUS)"; exit 1; }
[ "$(field version)" = 0.6.0 ] || { echo "installed daemon is $(field version), not 0.6.0: update it from the app's Status tab first"; exit 1; }
# Every write below is a proposal the daemon may refuse: under an Impossible window of your own
# config it would be held, and nothing here would be exercised.
source=$(field source)
[ "$source" = live ] || { echo "config source is '${source:-unknown}', not live: config.json is not what the daemon enforces (held or unreadable), so this run could not be judged. Fix that first."; exit 1; }
# `live` only says your current config is accepted. A write is judged by weakens(): while any
# window of yours is active, its items are protected until that active stretch ends, and this
# script replaces your whole config, so it must run in a gap. `check` prints that lock state.
cd "$(dirname "$0")/.." || exit 1
swift build --product focusguardd 2>&1 | tail -1
lock=$(.build/debug/focusguardd check | awk '/^lock:/ {sub(/^lock: */, ""); print}')
[ "$lock" = none ] || { echo "your own config has an active window (lock: ${lock:-unknown}): replacing it with the test config would be refused as a weakening. Rerun in a gap of your schedule."; exit 1; }
pgrep -xq "Google Chrome" || { echo "start Google Chrome first (and keep it running); the Chrome-visible checks need it"; exit 1; }
[ -f "$RECORD" ] && { echo "$RECORD exists: the daemon believes it holds URLBlocklist right now, so no window of yours with Chrome patterns may be active. Rerun in a gap."; exit 1; }
sys_absent || { echo "URLBlocklist is already set in $SYS by something else; the daemon will refuse to touch it. Remove it (sudo defaults delete $SYS URLBlocklist) and rerun."; exit 1; }

day=$(LC_ALL=C date +%a | tr 'A-Z' 'a-z'); start=$(LC_ALL=C date -v-1M +%H:%M); end=$(LC_ALL=C date -v+5M +%H:%M)
# A window is start < end on one day; across midnight it would never activate.
[[ "$start" < "$end" ]] || { echo "too close to midnight (window $start-$end would wrap), rerun in 6 minutes"; exit 1; }

BACKUP=$(mktemp -t focusguard-config)
cp "$CFG" "$BACKUP" 2>/dev/null || echo '{"version":1,"blockLists":[],"schedules":[]}' > "$BACKUP"
# From here every exit, including an abort, puts your config back.
trap 'cp "$BACKUP" "$CFG" 2>/dev/null; rm -f "$BACKUP"' EXIT
LIST=0C1C2D3E-0000-4000-8000-0000000000C1; WIN=0C1C2D3E-0000-4000-8000-0000000000C2
# The daemon reads config.json only at its tick (30 s + 2 s leeway with no apps to watch), so
# every write carries a sentinel domain named after the step; its line appearing in /etc/hosts
# is the proof that this write is what the daemon now enforces.
write() {  # $1 chromeURLs json, $2 mode, $3 step name (sentinel domain)
    printf '{"version":1,"blockLists":[{"id":"%s","name":"chrome","domains":["%s.focusguard-test.invalid"],"appBundleIDs":[],"keywords":[],"chromeURLs":%s}],"schedules":[{"id":"%s","name":"Chrome test","days":["%s"],"start":"%s","end":"%s","blockListIDs":["%s"],"enabled":true,"unlockMode":"%s"}],"alwaysAllow":[]}\n' \
        "$LIST" "$3" "$1" "$WIN" "$day" "$start" "$end" "$LIST" "$2" > "$CFG"
}
adopted() { wait_for "grep -q \"^0.0.0.0 $1.focusguard-test.invalid\" /etc/hosts" 35; }
BOTH='["chrome-extension://'"$EXT"'/*","chrome://extensions/*"]'
ONE='["chrome-extension://'"$EXT"'/*"]'

echo "--- two patterns, Basic, window $start-$end"
write "$BOTH" basic both
check "daemon adopted the test config within a tick" 'adopted both'
check "URLBlocklist in the system domain lists chrome://extensions/* within 5 s" 'wait_for "sys_has chrome://extensions/\\*" 5'
check "and the extension pattern" 'sys_has "chrome-extension://$EXT/"'
check "status says applied (2 patterns)" 'field chrome | grep -q "^applied (2 patterns"'
check "ownership record written" '[ -f "$RECORD" ]'
echo "    user domain now: $(user_domain)   (set only under variant B)"
echo "    In Chrome, open a NEW tab at chrome://extensions  (do not click Reload policies anywhere)."
check "Chrome blocks chrome://extensions" 'ask "Does Chrome show it as blocked by your administrator?"'
echo "    Now open chrome-extension://$EXT/entrypoints/options-page/index.html in a new tab."
check "Chrome blocks the extension's options page" 'ask "Blocked too?"'

echo "--- window without patterns removes the key"
write '[]' basic none
check "daemon adopted the patternless config within a tick" 'adopted none'
check "URLBlocklist removed in the same tick" 'wait_for sys_absent 5'
check "status is off" '[ "$(field chrome)" = off ]'
check "ownership record gone" '[ ! -f "$RECORD" ]'
echo "    user domain now: $(user_domain)"
echo "    Reload the chrome://extensions tab."
check "chrome://extensions loads again" 'ask "Does the page load now?"'

echo "--- Impossible holds a pattern"
write "$BOTH" impossible impossible
check "daemon adopted the Impossible window within a tick" 'adopted impossible'
check "both patterns back within 5 s" 'wait_for "sys_has chrome://extensions/\\*" 5'
write "$ONE" impossible removed
check "removing a pattern is held" 'wait_for "[ \"\$(field source)\" = held ]" 35'
check "chrome://extensions/* still in the policy" 'sys_has "chrome://extensions/*"'
check "status still applied (2 patterns)" 'field chrome | grep -q "^applied (2 patterns"'

echo "--- restore"
cp "$BACKUP" "$CFG" && rm -f "$BACKUP" && trap - EXIT
if [ "$(field source)" = held ]; then echo "note: test window is Impossible until $end; the key is removed when the restored config is taken up then"; else
check "key removed within a tick" 'wait_for sys_absent 35'; fi
if [ $fail = 0 ]; then echo "ALL OK"; else echo "SOME CHECKS FAILED"; fi
exit $fail
```

- [ ] **Step 2: README**

In `README.md`, add a section after **Keywords** (before **How enforcement works**). Use the paragraph for the variant Task 4 built:

```markdown
## Chrome pages

Site rules cannot reach pages inside Chrome that never cause a lookup: an extension's own pages
(`chrome-extension://<id>/…`) and Chrome's internal pages (`chrome://extensions`,
`chrome://settings`). A block list's **Chrome pages** are patterns for Chrome's own
`URLBlocklist` policy — `chrome://extensions/*`, `chrome-extension://<id>/*`, or a site name — and
**Add extension…** lists what is installed and adds both patterns for one. While a window with
Chrome patterns is active the daemon writes them to Chrome's policy preference in
`/Library/Preferences/com.google.Chrome.plist` (root-only to change); Chrome shows those pages as
blocked by an administrator. When the window ends the key is removed. Other browsers are not
affected. If something else has already set `URLBlocklist`, FocusGuard leaves it alone and the
Status tab says so.
```
Then **one** of:

- Variant A: append to that section:
  ```markdown
  Changing the preference under an Impossible window needs `sudo`, like the hosts region.
  ```
- Variant B: append instead:
  ```markdown
  Chrome only notices the user-level copy of that preference, so the daemon writes both: the
  system copy is the durable one, the user copy the one Chrome watches. Chrome pages: re-asserted
  within 30 s; a determined loop can keep deleting the preference, which the hosts region cannot
  suffer.
  ```

In **How enforcement works**, after the **Apps** bullet add:
```markdown
- **Chrome pages:** Chrome's `URLBlocklist` policy preference, written in-process through
  CFPreferences only when the active pattern set changes, with an ownership record in
  `/var/db/FocusGuard/chrome-policy.json` so a restarted daemon never removes a key it did not
  write.
```
In the same section's **Unreadable or missing config** bullet, change "2000 sites, 300 apps" to "2000 sites, 300 apps, 200 keywords, 200 Chrome patterns".

In **Known gaps** add:
```markdown
- Chrome pages cover Google Chrome only. Brave, Edge, Arc and Vivaldi use the same policy under
  other preference domains (a follow-up); Safari and Firefox have no equivalent without a profile.
```

In **Development**, after the `verify-keywords.sh` line add:
```markdown
`scripts/verify-chrome.sh` checks Chrome pages: the policy preference follows a window, Chrome
blocks the page (it asks you), and an Impossible window holds a pattern (~3 minutes, no `sudo`,
Chrome running).
```

- [ ] **Step 3: Spec status, pointer, version**

In `docs/superpowers/specs/2026-11-11-chrome-pages-design.md` line 3, replace `**Status:** approved in conversation; §3 to be settled by `scripts/probe-chrome-policy.sh` before the plan` with `**Status:** implemented in 0.6.0 (plan `2026-11-11-chrome-pages.md`); §3 settled by the probe: variant <A: system domain only | B: both domains>` — fill in the one Task 4 built.

In `docs/superpowers/specs/2026-08-18-focusguard-design.md` §11.6, after the keyword-blocking line add: `- Chrome pages: see 2026-11-11-chrome-pages-design.md (implemented in 0.6.0).`

In `Sources/FocusGuardCore/DaemonStatus.swift` set `FocusGuardVersion.current` to `"0.6.0"`. In `Sources/FocusGuard/Info.plist` set `CFBundleShortVersionString` to `0.6.0` and `CFBundleVersion` to `6`.

- [ ] **Step 4: QA stub**

Append to `docs/qa/2026-11-06-independent-qa.md`:

```markdown
## Live acceptance of Chrome pages (pending — daemon 0.6.0)

To be filled in after the user updates the daemon from the Status tab and runs
`scripts/verify-chrome.sh` with Chrome open. Record here: probe verdict and variant built;
`status.json` `chrome` values seen; whether `chrome://extensions` and the News Feed Eradicator
options page were blocked and how long after adoption; key removal on window end; the held
removal under Impossible; daemon CPU over the run (nothing periodic was added, so it should not
move). Still untested until then: Chrome absent (`Chrome not found` suffix); the "already set by
someone else" path; a restart mid-window (record-based ownership); uninstall with a key held.
```

- [ ] **Step 5: Build, test, commit**

Run: `chmod +x scripts/verify-chrome.sh && bash -n scripts/verify-chrome.sh && echo syntax-ok && scripts/build-app.sh 2>&1 | grep -E "error|built" && swift test 2>&1 | grep -E "error:|failed|Executed [0-9]+ tests" | tail -2 && grep -c "0.6.0" Sources/FocusGuard/Info.plist Sources/FocusGuardCore/DaemonStatus.swift`
Expected: `syntax-ok`, `built build/FocusGuard.app`, `Executed 268 tests, with 0 failures`, and `1` for each of the two version files.

```bash
git add scripts/verify-chrome.sh README.md docs/superpowers/specs/2026-11-11-chrome-pages-design.md docs/superpowers/specs/2026-08-18-focusguard-design.md docs/qa/2026-11-06-independent-qa.md Sources/FocusGuardCore/DaemonStatus.swift Sources/FocusGuard/Info.plist
git commit -m "Chrome pages: live acceptance script, README, version 0.6.0

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

- [ ] **Step 6: Live run (the user does this; the implementer only reports that it is next)**

1. `ditto build/FocusGuard.app /Applications/FocusGuard.app`, relaunch the app; Status shows "Background daemon needs updating" → **Update…** and the password.
2. Confirm `/var/db/FocusGuard/status.json` has `"version":"0.6.0"` and `"chrome":"off"`.
3. With Chrome open and in a gap of the schedule: `scripts/verify-chrome.sh` → `ALL OK`.
4. Fill in the QA stub from Step 4 with what was observed.

---

## Self-review

**Spec coverage:** §1 purpose → the two News Feed Eradicator patterns are the fixture in T2, T3, T6. §2 model (verbatim, trimmed, no whitespace/control, ≤ 2048, schemes or bare host pattern, 200 across lists, empty on old files, exact-string dedup) → T1 (`ChromeURLPattern`, `BlockList.chromeURLs`, `Limits.maxChromeURLs`, decodeIfPresent; dedup is `!contains` in T5's commits). §3 enforcement (sorted union; non-empty → key = array, empty → key removed; write only on change; nothing else written; system domain via `CFPreferencesSetValue`/`Synchronize` in-process; `chrome-policy.json` record; never write when nothing wanted and never written; first-run foreign key → log once, leave alone, `not applied (…)`; Chrome absent → still written, status suffix) → T3 (`reconcileChrome` + tests) and T4 (writer; variants A/B with the probe deciding; B uses `launchctl asuser <uid>` + `sudo -u` + `defaults`, console user from `SCDynamicStoreCopyConsoleUser`). §4 lock (`c:` items; remove/edit = cut; add never weakens; no allow-list interaction) → T2. §5 status strings and decode default → T3, shown in T5's Status tab. §6 UI (monospaced rows, gated remove, `AddRow` with the spec's placeholder, validation hint, Add many… via `.chromeURLs` with no hosts-file handling, Add extension… with manifest/`__MSG_…__`/id fallback and the two-pattern preset explained, footer text) → T5. §7 battery (nothing periodic; write only on change) → T3 design; T4 stats only on ticks with patterns. §8 testing (validation table, sorted union, lock items, status decode, 0.5 config decode, `ChromePolicyWriter` + recording fake, live script with Chrome-visible y/n) → T1, T2, T3, T6. §9 out of scope → README Known gaps only.

**Ambiguities resolved (and how):**
- *Protocol shape.* The brief suggested `apply/clear -> Bool`; the status line needs an `error: <reason>` text and the first-run rule needs to know both "is the key present" and "did we write it", so the port is `recordedPatterns() / keyIsPresent() / apply -> String? / clear -> String? / chromeInstalled`. The ownership record is owned by the writer (written in `apply`, removed in `clear`); the Reconciler reads it once through `recordedPatterns()`.
- *Which CF host constant.* `/Library/Preferences/com.google.Chrome.plist` is `kCFPreferencesAnyUser` + `kCFPreferencesAnyHost`; `kCFPreferencesCurrentHost` writes `/Library/Preferences/ByHost/…`, which does not exist here. Verified on this Mac 2026-11-11 and type-checked the exact calls.
- *`launchctl asuser` alone keeps uid 0*, so variant B adds `sudo -n -u <name>` (root → user, no password) so `defaults` writes the user's own domain. Variant B's `keyIsPresent` reads the user's plist file directly rather than spawning a process every tick.
- *Teardown.* The spec says nothing about shutdown; the daemon strips its hosts region on SIGTERM, so it also removes a key it owns (never a foreign one). The uninstaller gets a belt-and-braces `defaults delete` guarded by the record.
- *Reconciler constructor.* 16 existing `Reconciler(` call sites; the writer is an optional parameter defaulting to nil ("off", never writes) so no existing test changes.
- *Bare host validation.* `*` only as the whole pattern; a dotless word (`localhost`) is accepted because Chrome accepts it; `..`, leading `-`, spaces and control characters are rejected.
- *Version bump.* 0.6.0 / build 6; `FocusGuardVersion.current` and `Info.plist` are the only two places, and `build-app.sh` copies the plist unchanged.

**Placeholder scan:** none. The only deliberately open item is the variant choice in T4 (one constant), which the plan refuses to guess and tells the implementer to get from the probe's `VERDICT:` line; T6's README and spec status carry the matching alternative text.

**Type consistency:** `ChromeURLPattern.normalize/isValid/maxLength/schemes` (T1) used in T2 (Lock), T3 (ActiveSet), T5 (`addChromeURL`, hint). `BlockList(name:…chromeURLs:)` in T1–T3, T5. `Config.Limits.maxChromeURLs` in T1, T5 (BulkAddSheet). `Config.ValidationError.invalidChromeURL` in T1. `BulkInput.chromeURLs(from:) -> ChromeURLs` in T1, T5. `ActiveSet(domains:bundleIDs:chromeURLs:)`, `.chromeURLs`, `.isEmpty`, `.isSubset` in T3, T4 (`main.swift`, `Daemon.swift` log), T5 (Status "Now"). `ChromePolicyWriter` methods `recordedPatterns/keyIsPresent/apply(patterns:)/clear/chromeInstalled` in T3 (port, fake, Reconciler) and T4 (`CFChromePolicyWriter`). `Reconciler.init(… log:, chrome:, …)` in T3 tests and T4 daemon; `Result.chrome` in T3 and T4. `DaemonStatus(…dnsWatch:chrome:)`, `.chrome` in T3, T4, T5 (`AppModel.chromePages`). `Paths.chromePolicy` in T3, T4 (writer, `verify-chrome.sh` reads the same path literally). `ConfigFile.writeRootFile` internal in T4. `BulkAddSheet.Kind.chromeURLs` in T5 only. `ChromeExtensions.installed(under:)/installed()/patterns(forExtensionID:)/isExtensionID/versionLess/resolveName`, `ChromeExtension.id/name/profiles/patterns` in T5 (model, tests, sheet). `AddExtensionSheet(alreadyAdded:onAdd:)` in T5. `FocusGuardVersion.current` "0.6.0" in T6, checked by `verify-chrome.sh`'s `field version`.
