# Keyword Blocking Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Block sites by keyword (`manga` → mangadex.org, mangaplus.shueisha.co.jp, …) with contains / whole-word / starts-with / ends-with rules and a global allow list, enforced by the root daemon, which learns matching site names by observing the Mac's DNS lookups.

**Architecture:** All decisions are pure Core code (rule matching, DNS packet parsing, the learned-name set, lock items), unit-tested with fixtures. The daemon adds one component, `DNSWatcher`, which uses libpcap (shipped with macOS) to receive outbound DNS questions from the kernel with a BPF filter — no polling — and feeds names to the `Reconciler`, which records matches in root-owned `/var/db/FocusGuard/learned.json` and blocks them through the existing hosts region. The app shows rules, learned names and the allow list; every edit goes through the existing gate. Spec: `docs/superpowers/specs/2026-11-06-keyword-blocking-design.md`.

**Tech Stack:** Swift 5 mode on the 6.2 toolchain, SwiftPM, XCTest, libpcap via a SwiftPM system-library target, `Network.NWPathMonitor` for interface changes, SwiftUI.

**Conventions (same as previous plans):** commit messages end with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`. Run `swift test` from the repo root. Nothing in Tasks 1–11 needs `sudo`; Task 12's live script needs the installed daemon (already on this Mac) but no password.

---

## File structure

```
Sources/FocusGuardCore/
  Models.swift            + KeywordRule, BlockList.keywords, Config.alwaysAllow, limits, validation
  Keywords.swift          NEW  matching: KeywordRule.matches, Config.keywordBlocks/isAlwaysAllowed/…
  LearnedNames.swift      NEW  the learned set: record, cap/evict, blocked(by:at:)
  DNSQuestion.swift       NEW  pure parser: captured frame → question names
  Lock.swift              keyword items and allow-list additions in weakens
  ActiveSet.swift         + activeSet(at:learned:)
  Reconciler.swift        + learned state, observe(name:wall:), keywordWatchWanted
  DaemonStatus.swift      + dnsWatch
  Paths.swift             + learned
Sources/CPcap/            NEW  system library: module.modulemap, shim.h
Sources/focusguardd/
  DNSWatcher.swift        NEW  libpcap capture per interface, NWPathMonitor reopen
  ConfigFile.swift        + loadLearned/saveLearned
  Daemon.swift            + watcher wiring, immediate reconcile on learn
Sources/FocusGuard/
  Model/AppModel.swift    + learned names, keyword-watch status
  Views/BlockListsTab.swift  + Keywords section, Always allow section
  Views/StatusTab.swift   + "Keyword matching" row
Tests/FocusGuardCoreTests/
  KeywordModelTests.swift, KeywordMatchTests.swift, LearnedNamesTests.swift,
  DNSQuestionTests.swift, LockKeywordTests.swift, ReconcilerKeywordTests.swift
scripts/verify-keywords.sh  NEW  live acceptance
README.md, docs/superpowers/specs/2026-08-18-focusguard-design.md (pointer to the new spec)
```

---

### Task 1: Model — `KeywordRule`, `BlockList.keywords`, `Config.alwaysAllow`, limits

**Files:**
- Modify: `Sources/FocusGuardCore/Models.swift`
- Create: `Tests/FocusGuardCoreTests/KeywordModelTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import FocusGuardCore

final class KeywordModelTests: XCTestCase {
    func testNormalizeAcceptsSiteNameCharactersOnly() {
        XCTAssertEqual(KeywordRule.normalize("  Manga "), "manga")
        XCTAssertEqual(KeywordRule.normalize("READ-manga2"), "read-manga2")
        XCTAssertNil(KeywordRule.normalize("m"), "too short")
        XCTAssertNil(KeywordRule.normalize("manga.org"), "no dots: a keyword is one word")
        XCTAssertNil(KeywordRule.normalize("man ga"))
        XCTAssertNil(KeywordRule.normalize(String(repeating: "a", count: 64)))
    }

    func testItemKeyChangesWithTextOrMatch() {
        let a = KeywordRule(text: "manga", match: .contains)
        XCTAssertEqual(a.itemKey, "contains:manga")
        XCTAssertNotEqual(KeywordRule(text: "manga", match: .wholeWord).itemKey, a.itemKey)
    }

    func testOldConfigWithoutKeywordFieldsStillDecodes() throws {
        let json = """
        {"version":1,"blockLists":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"l","domains":["x.com"],"appBundleIDs":[]}],"schedules":[]}
        """
        let config = try Config.decodeJSON(Data(json.utf8))
        XCTAssertEqual(config.blockLists[0].keywords, [])
        XCTAssertEqual(config.alwaysAllow, [])
    }

    func testRoundTrip() throws {
        var config = Config(blockLists: [BlockList(name: "l", keywords: [KeywordRule(text: "manga", match: .startsWith)])])
        config.alwaysAllow = ["mangalore.in"]
        let decoded = try Config.decodeJSON(try config.encodeJSON())
        XCTAssertEqual(decoded, config)
    }

    func testInvalidKeywordTextDoesNotDecode() throws {
        let config = Config(blockLists: [BlockList(name: "l", keywords: [KeywordRule(text: "Manga Pages", match: .contains)])])
        XCTAssertThrowsError(try Config.decodeJSON(try config.encodeJSON()))
    }

    func testKeywordAndAllowLimits() throws {
        var many = Config(blockLists: [BlockList(name: "l")])
        many.blockLists[0].keywords = (0...Config.Limits.maxKeywords).map { KeywordRule(text: "k\($0)xx", match: .contains) }
        XCTAssertThrowsError(try Config.decodeJSON(try many.encodeJSON()))

        var allows = Config()
        allows.alwaysAllow = (0...Config.Limits.maxAllow).map { "a\($0).com" }
        XCTAssertThrowsError(try Config.decodeJSON(try allows.encodeJSON()))
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter KeywordModelTests 2>&1 | grep -E "error:|Executed" | head -3`
Expected: compile errors (`KeywordRule` not found).

- [ ] **Step 3: Add the model**

In `Sources/FocusGuardCore/Models.swift`, replace the whole `BlockList` struct with:

```swift
/// A site-name pattern (keyword spec §2–3). `text` is kept normalized: lowercase, `[a-z0-9-]`,
/// 2…63 characters — the characters that can appear in a site name.
public struct KeywordRule: Codable, Equatable, Hashable, Identifiable {
    public enum Match: String, Codable, CaseIterable, Hashable {
        case contains, wholeWord, startsWith, endsWith

        public var title: String {
            switch self {
            case .contains: return "Contains"
            case .wholeWord: return "Whole word"
            case .startsWith: return "Starts with"
            case .endsWith: return "Ends with"
            }
        }
    }

    public var id: UUID
    public var text: String
    public var match: Match

    public init(id: UUID = UUID(), text: String, match: Match = .contains) {
        self.id = id
        self.text = text
        self.match = match
    }

    /// nil when `raw` cannot be a keyword.
    public static func normalize(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard (2...63).contains(t.count),
              t.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return nil }
        return t
    }

    public var isValid: Bool { KeywordRule.normalize(text) == text }

    /// The lock treats a rule as one item for as long as its text and match are unchanged.
    public var itemKey: String { "\(match.rawValue):\(text)" }
}

public struct BlockList: Codable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var domains: [String]
    public var appBundleIDs: [String]
    public var keywords: [KeywordRule]

    public init(id: UUID = UUID(), name: String, domains: [String] = [], appBundleIDs: [String] = [],
                keywords: [KeywordRule] = []) {
        self.id = id
        self.name = name
        self.domains = domains
        self.appBundleIDs = appBundleIDs
        self.keywords = keywords
    }

    private enum CodingKeys: String, CodingKey { case id, name, domains, appBundleIDs, keywords }

    /// Files written before keyword rules existed have no `keywords` key.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        domains = try c.decode([String].self, forKey: .domains)
        appBundleIDs = try c.decode([String].self, forKey: .appBundleIDs)
        keywords = try c.decodeIfPresent([KeywordRule].self, forKey: .keywords) ?? []
    }
}
```

Then in the `Config` struct: add the stored property and custom decoding. Replace the lines from `public var version: Int` through the end of `public init(version:blockLists:schedules:)` with:

```swift
    public var version: Int
    public var blockLists: [BlockList]
    public var schedules: [ScheduleWindow]
    /// Site names (and their subdomains) that keyword rules never block. Explicit `domains`
    /// entries still do: the allow list beats keyword rules only.
    public var alwaysAllow: [String]

    public init(version: Int = Config.currentVersion, blockLists: [BlockList] = [], schedules: [ScheduleWindow] = [],
                alwaysAllow: [String] = []) {
        self.version = version
        self.blockLists = blockLists
        self.schedules = schedules
        self.alwaysAllow = alwaysAllow
    }

    private enum CodingKeys: String, CodingKey { case version, blockLists, schedules, alwaysAllow }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        blockLists = try c.decode([BlockList].self, forKey: .blockLists)
        schedules = try c.decode([ScheduleWindow].self, forKey: .schedules)
        alwaysAllow = try c.decodeIfPresent([String].self, forKey: .alwaysAllow) ?? []
    }
```

In `Config.Limits` add:

```swift
        /// Across all lists.
        public static let maxKeywords = 200
        public static let maxAllow = 500
```

In `ValidationError` add a case and its description:

```swift
        case tooLarge(String), duplicateID(String), invalidKeyword(String)
        public var errorDescription: String? {
            switch self {
            case .tooLarge(let what): return "Config too large: \(what)."
            case .duplicateID(let what): return "Two \(what) share one id."
            case .invalidKeyword(let text): return "\u{201C}\(text)\u{201D} is not a valid keyword (2–63 letters, digits or hyphens)."
            }
        }
```

At the end of `validate()` (before its closing brace) add:

```swift
        let keywords = blockLists.flatMap(\.keywords)
        guard keywords.count <= Limits.maxKeywords else { throw ValidationError.tooLarge("\(keywords.count) keywords; the limit is \(Limits.maxKeywords)") }
        if let bad = keywords.first(where: { !$0.isValid }) { throw ValidationError.invalidKeyword(bad.text) }
        guard alwaysAllow.count <= Limits.maxAllow else { throw ValidationError.tooLarge("\(alwaysAllow.count) allow entries; the limit is \(Limits.maxAllow)") }
```

- [ ] **Step 4: Run tests**

Run: `swift test 2>&1 | grep -E "error:|failed|Executed [0-9]+ tests" | tail -2`
Expected: `Executed 170 tests, with 0 failures` (164 + 6; the exact total may differ by the count of tests added so far — zero failures is the requirement).

- [ ] **Step 5: Commit**

```bash
git add Sources/FocusGuardCore/Models.swift Tests/FocusGuardCoreTests/KeywordModelTests.swift
git commit -m "Core: KeywordRule, BlockList.keywords, Config.alwaysAllow, limits

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: Matching

**Files:**
- Create: `Sources/FocusGuardCore/Keywords.swift`
- Create: `Tests/FocusGuardCoreTests/KeywordMatchTests.swift`

- [ ] **Step 1: Write the failing tests** (the table from spec §3)

```swift
import XCTest
@testable import FocusGuardCore

final class KeywordMatchTests: XCTestCase {
    func rule(_ match: KeywordRule.Match) -> KeywordRule { KeywordRule(text: "manga", match: match) }

    func testContains() {
        XCTAssertTrue(rule(.contains).matches(name: "mangadex.org"))
        XCTAssertTrue(rule(.contains).matches(name: "mangalore.in"))
        XCTAssertTrue(rule(.contains).matches(name: "yamanga.com"))
        XCTAssertFalse(rule(.contains).matches(name: "comics.org"))
    }

    func testWholeWord() {
        XCTAssertTrue(rule(.wholeWord).matches(name: "manga.example.com"))
        XCTAssertTrue(rule(.wholeWord).matches(name: "read-manga.net"))
        XCTAssertFalse(rule(.wholeWord).matches(name: "mangadex.org"))
        XCTAssertFalse(rule(.wholeWord).matches(name: "mangalore.in"))
    }

    func testStartsWith() {
        XCTAssertTrue(rule(.startsWith).matches(name: "mangadex.org"))
        XCTAssertTrue(rule(.startsWith).matches(name: "mangaplus.shueisha.co.jp"))
        XCTAssertTrue(rule(.startsWith).matches(name: "www.mangadex.org"), "www. is just another word")
        XCTAssertFalse(rule(.startsWith).matches(name: "yamanga.com"))
    }

    func testEndsWith() {
        XCTAssertTrue(rule(.endsWith).matches(name: "yamanga.com"))
        XCTAssertTrue(rule(.endsWith).matches(name: "read-manga.net"))
        XCTAssertFalse(rule(.endsWith).matches(name: "mangadex.org"))
    }

    func testCaseAndTrailingDot() {
        XCTAssertTrue(rule(.contains).matches(name: "MangaDex.ORG."))
    }

    func testKeywordBlocksUsesActiveWindowsAndAllowList() {
        let list = BlockList(name: "l", keywords: [rule(.contains)])
        let window = ScheduleWindow(name: "w", days: [.mon], start: TimeOfDay("09:00")!, end: TimeOfDay("12:00")!, blockListIDs: [list.id])
        var config = Config(blockLists: [list], schedules: [window], alwaysAllow: ["mangalore.in"])
        let inside = LocalMoment(weekday: .mon, minutesSinceMidnight: 600)
        let outside = LocalMoment(weekday: .mon, minutesSinceMidnight: 800)
        XCTAssertTrue(config.keywordBlocks(name: "mangadex.org", at: inside))
        XCTAssertFalse(config.keywordBlocks(name: "mangadex.org", at: outside), "window not active")
        XCTAssertFalse(config.keywordBlocks(name: "mangalore.in", at: inside), "allowed")
        XCTAssertFalse(config.keywordBlocks(name: "www.mangalore.in", at: inside), "subdomain of an allowed name")
        config.alwaysAllow = ["https://MangaLore.in/"]
        XCTAssertFalse(config.keywordBlocks(name: "mangalore.in", at: inside), "allow entries are normalized")
    }

    func testAllKeywordRulesComesFromEnabledWindowsOnly() {
        let a = BlockList(name: "a", keywords: [rule(.contains)])
        let b = BlockList(name: "b", keywords: [KeywordRule(text: "anime", match: .contains)])
        let on = ScheduleWindow(name: "on", days: [.mon], start: TimeOfDay("09:00")!, end: TimeOfDay("12:00")!, blockListIDs: [a.id])
        let off = ScheduleWindow(name: "off", days: [.mon], start: TimeOfDay("09:00")!, end: TimeOfDay("12:00")!, blockListIDs: [b.id], enabled: false)
        let config = Config(blockLists: [a, b], schedules: [on, off])
        XCTAssertEqual(config.allKeywordRules.map(\.text), ["manga"])
        XCTAssertTrue(config.hasKeywordRules)
        XCTAssertFalse(Config(blockLists: [b], schedules: [off]).hasKeywordRules)
    }

    func testShouldLearnIgnoresAllowedAndNonMatching() {
        let list = BlockList(name: "l", keywords: [rule(.contains)])
        let window = ScheduleWindow(name: "w", days: [.mon], start: TimeOfDay("09:00")!, end: TimeOfDay("12:00")!, blockListIDs: [list.id])
        let config = Config(blockLists: [list], schedules: [window], alwaysAllow: ["mangalore.in"])
        XCTAssertTrue(config.shouldLearn(name: "mangadex.org"), "learned even outside the window")
        XCTAssertFalse(config.shouldLearn(name: "mangalore.in"))
        XCTAssertFalse(config.shouldLearn(name: "comics.org"))
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter KeywordMatchTests 2>&1 | grep -E "error:|Executed" | head -3`
Expected: compile errors (`matches(name:)` not found).

- [ ] **Step 3: Implement**

`Sources/FocusGuardCore/Keywords.swift`:

```swift
import Foundation

extension KeywordRule {
    /// Words of a site name: split on dots and hyphens, so "read-manga.net" → read, manga, net.
    public static func words(of name: String) -> [String] {
        name.split(whereSeparator: { $0 == "." || $0 == "-" }).map(String.init)
    }

    /// `name` is a site name as looked up; case and a trailing dot are ignored.
    public func matches(name rawName: String) -> Bool {
        let name = rawName.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        switch match {
        case .contains: return name.contains(text)
        case .wholeWord: return Self.words(of: name).contains(text)
        case .startsWith: return Self.words(of: name).contains { $0.hasPrefix(text) }
        case .endsWith: return Self.words(of: name).contains { $0.hasSuffix(text) }
        }
    }
}

extension Config {
    /// Equal to an `alwaysAllow` entry or a subdomain of one. Entries are normalized here as
    /// well as by the app, so a hand-edited "https://Site.com/" still works.
    public func isAlwaysAllowed(_ name: String) -> Bool {
        let host = name.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return alwaysAllow.lazy.map(DomainNormalizer.normalize).contains { !$0.isEmpty && DomainNormalizer.host(host, isUnder: $0) }
    }

    /// Rules in lists attached to windows active at `moment`.
    public func keywordRules(activeAt moment: LocalMoment) -> [KeywordRule] {
        let ids = Set(schedules.filter { $0.isActive(at: moment) }.flatMap(\.blockListIDs))
        return blockLists.filter { ids.contains($0.id) }.flatMap(\.keywords)
    }

    /// Rules in lists attached to any enabled window: what the daemon learns against, so a site
    /// seen outside a window is already known when the window opens.
    public var allKeywordRules: [KeywordRule] {
        let ids = Set(schedules.filter(\.enabled).flatMap(\.blockListIDs))
        return blockLists.filter { ids.contains($0.id) }.flatMap(\.keywords)
    }

    /// Whether the daemon should be watching lookups at all.
    public var hasKeywordRules: Bool { !allKeywordRules.isEmpty }

    /// Blocked right now by a keyword rule (and not allowed).
    public func keywordBlocks(name: String, at moment: LocalMoment) -> Bool {
        guard !isAlwaysAllowed(name) else { return false }
        return keywordRules(activeAt: moment).contains { $0.matches(name: name) }
    }

    /// Worth remembering: matches some rule of an enabled window and is not allowed.
    public func shouldLearn(name: String) -> Bool {
        guard !isAlwaysAllowed(name) else { return false }
        return allKeywordRules.contains { $0.matches(name: name) }
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter KeywordMatchTests 2>&1 | grep -E "failed|Executed"`
Expected: `Executed 8 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Sources/FocusGuardCore/Keywords.swift Tests/FocusGuardCoreTests/KeywordMatchTests.swift
git commit -m "Core: keyword matching, allow list, rules per window

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: `LearnedNames`

**Files:**
- Create: `Sources/FocusGuardCore/LearnedNames.swift`
- Create: `Tests/FocusGuardCoreTests/LearnedNamesTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import FocusGuardCore

final class LearnedNamesTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testRecordReportsNewNamesOnly() {
        var learned = LearnedNames()
        XCTAssertTrue(learned.record("mangadex.org", at: t0))
        XCTAssertFalse(learned.record("mangadex.org", at: t0.addingTimeInterval(60)), "already known; last-seen updated")
        XCTAssertEqual(learned.lastSeen["mangadex.org"], t0.addingTimeInterval(60))
        XCTAssertEqual(learned.names, ["mangadex.org"])
    }

    func testRecordNormalizes() {
        var learned = LearnedNames()
        XCTAssertTrue(learned.record("MangaDex.org.", at: t0))
        XCTAssertFalse(learned.record("mangadex.org", at: t0))
    }

    func testEvictionDropsTheOldestBeyondTheCap() {
        var learned = LearnedNames()
        for i in 0..<(LearnedNames.cap + 10) {
            learned.record("site\(i).com", at: t0.addingTimeInterval(Double(i)))
        }
        learned.evictBeyondCap()
        XCTAssertEqual(learned.count, LearnedNames.cap)
        XCTAssertFalse(learned.names.contains("site0.com"), "oldest gone")
        XCTAssertTrue(learned.names.contains("site\(LearnedNames.cap + 9).com"), "newest kept")
    }

    func testBlockedByConfig() {
        let list = BlockList(name: "l", keywords: [KeywordRule(text: "manga", match: .contains)])
        let window = ScheduleWindow(name: "w", days: [.mon], start: TimeOfDay("09:00")!, end: TimeOfDay("12:00")!, blockListIDs: [list.id])
        let config = Config(blockLists: [list], schedules: [window], alwaysAllow: ["mangalore.in"])
        var learned = LearnedNames()
        for n in ["mangadex.org", "mangalore.in", "comics.org"] { learned.record(n, at: t0) }
        XCTAssertEqual(learned.blocked(by: config, at: LocalMoment(weekday: .mon, minutesSinceMidnight: 600)), ["mangadex.org"])
        XCTAssertEqual(learned.blocked(by: config, at: LocalMoment(weekday: .mon, minutesSinceMidnight: 800)), [])
    }

    func testRoundTripsThroughJSON() throws {
        var learned = LearnedNames()
        learned.record("mangadex.org", at: t0)
        let data = try JSONEncoder().encode(learned)
        XCTAssertEqual(try JSONDecoder().decode(LearnedNames.self, from: data), learned)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter LearnedNamesTests 2>&1 | grep -E "error:|Executed" | head -3`
Expected: compile errors.

- [ ] **Step 3: Implement**

`Sources/FocusGuardCore/LearnedNames.swift`:

```swift
import Foundation

/// Site names the daemon has seen looked up that matched a keyword rule (keyword spec §4).
/// Only matches are ever stored, never general lookup history. Persisted root-owned by the
/// daemon; readable by the app for "Blocked so far".
public struct LearnedNames: Codable, Equatable {
    public static let cap = 2000

    public private(set) var lastSeen: [String: Date]

    public init(lastSeen: [String: Date] = [:]) {
        self.lastSeen = lastSeen
    }

    public var names: Set<String> { Set(lastSeen.keys) }
    public var count: Int { lastSeen.count }

    /// True when `name` was not known before. Names are kept lowercased without a trailing dot.
    @discardableResult
    public mutating func record(_ rawName: String, at date: Date) -> Bool {
        let name = rawName.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let isNew = lastSeen[name] == nil
        lastSeen[name] = date
        return isNew
    }

    /// Drop the oldest-seen names beyond `cap`. The daemon calls this only while no window with
    /// keyword rules is active, so eviction never unblocks something mid-window.
    public mutating func evictBeyondCap() {
        guard lastSeen.count > Self.cap else { return }
        let keep = lastSeen.sorted { $0.value > $1.value }.prefix(Self.cap)
        lastSeen = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
    }

    /// The learned names a config blocks right now.
    public func blocked(by config: Config, at moment: LocalMoment) -> Set<String> {
        names.filter { config.keywordBlocks(name: $0, at: moment) }
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter LearnedNamesTests 2>&1 | grep -E "failed|Executed"`
Expected: `Executed 5 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Sources/FocusGuardCore/LearnedNames.swift Tests/FocusGuardCoreTests/LearnedNamesTests.swift
git commit -m "Core: LearnedNames with cap and eviction

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: DNS question parser

**Files:**
- Create: `Sources/FocusGuardCore/DNSQuestion.swift`
- Create: `Tests/FocusGuardCoreTests/DNSQuestionTests.swift`

- [ ] **Step 1: Write the failing tests** (fixtures are built by helpers so every byte is explained)

```swift
import XCTest
@testable import FocusGuardCore

final class DNSQuestionTests: XCTestCase {
    // MARK: fixture builders

    func dnsQuery(_ name: String, id: UInt16 = 0x1234, qr: Bool = false, qdcount: UInt16 = 1) -> [UInt8] {
        var b: [UInt8] = []
        b += [UInt8(id >> 8), UInt8(id & 0xff)]
        b += [qr ? 0x81 : 0x01, 0x00]                 // flags: QR bit, RD set
        b += [UInt8(qdcount >> 8), UInt8(qdcount & 0xff), 0, 0, 0, 0, 0, 0]   // QD, AN, NS, AR
        for label in name.split(separator: ".") {
            b.append(UInt8(label.utf8.count))
            b += Array(label.utf8)
        }
        b.append(0)                                   // root label
        b += [0, 1, 0, 1]                             // QTYPE A, QCLASS IN
        return b
    }

    func udp(dstPort: UInt16 = 53, payload: [UInt8]) -> [UInt8] {
        let len = UInt16(8 + payload.count)
        return [0xc0, 0x00, UInt8(dstPort >> 8), UInt8(dstPort & 0xff), UInt8(len >> 8), UInt8(len & 0xff), 0, 0] + payload
    }

    func ipv4(proto: UInt8 = 17, ihl: UInt8 = 5, payload: [UInt8]) -> [UInt8] {
        let headerLen = Int(ihl) * 4
        let total = UInt16(headerLen + payload.count)
        var h: [UInt8] = [0x40 | ihl, 0, UInt8(total >> 8), UInt8(total & 0xff), 0, 0, 0, 0, 64, proto, 0, 0,
                          10, 0, 0, 2, 1, 1, 1, 1]
        h += [UInt8](repeating: 0, count: headerLen - 20)   // options, if ihl > 5
        return h + payload
    }

    func ipv6(nextHeader: UInt8 = 17, payload: [UInt8]) -> [UInt8] {
        let len = UInt16(payload.count)
        var h: [UInt8] = [0x60, 0, 0, 0, UInt8(len >> 8), UInt8(len & 0xff), nextHeader, 64]
        h += [UInt8](repeating: 0, count: 32)   // src + dst
        return h + payload
    }

    func ethernet(type: UInt16, payload: [UInt8]) -> [UInt8] {
        [UInt8](repeating: 0, count: 12) + [UInt8(type >> 8), UInt8(type & 0xff)] + payload
    }

    /// BSD loopback/utun framing: 4-byte address family in host byte order.
    func nullFrame(family: UInt32, payload: [UInt8]) -> [UInt8] {
        withUnsafeBytes(of: family) { Array($0) } + payload
    }

    // MARK: tests

    func testEthernetIPv4Query() {
        let frame = ethernet(type: 0x0800, payload: ipv4(payload: udp(payload: dnsQuery("mangadex.org"))))
        XCTAssertEqual(DNSQuestion.names(in: frame, link: .ethernet), ["mangadex.org"])
    }

    func testEthernetIPv6Query() {
        let frame = ethernet(type: 0x86DD, payload: ipv6(payload: udp(payload: dnsQuery("MangaPlus.Shueisha.co.jp"))))
        XCTAssertEqual(DNSQuestion.names(in: frame, link: .ethernet), ["mangaplus.shueisha.co.jp"])
    }

    func testNullLinkIPv4Query() {
        let frame = nullFrame(family: 2, payload: ipv4(payload: udp(payload: dnsQuery("read-manga.net"))))
        XCTAssertEqual(DNSQuestion.names(in: frame, link: .null), ["read-manga.net"])
    }

    func testNullLinkIPv6Query() {
        let frame = nullFrame(family: 30, payload: ipv6(payload: udp(payload: dnsQuery("example.com"))))
        XCTAssertEqual(DNSQuestion.names(in: frame, link: .null), ["example.com"])
    }

    func testIPv4OptionsAreSkipped() {
        let frame = ethernet(type: 0x0800, payload: ipv4(ihl: 6, payload: udp(payload: dnsQuery("example.com"))))
        XCTAssertEqual(DNSQuestion.names(in: frame, link: .ethernet), ["example.com"])
    }

    func testAnswersAndNonDNSAreIgnored() {
        XCTAssertEqual(DNSQuestion.names(in: ethernet(type: 0x0800, payload: ipv4(payload: udp(payload: dnsQuery("a.com", qr: true)))), link: .ethernet), [])
        XCTAssertEqual(DNSQuestion.names(in: ethernet(type: 0x0800, payload: ipv4(payload: udp(dstPort: 443, payload: dnsQuery("a.com")))), link: .ethernet), [])
        XCTAssertEqual(DNSQuestion.names(in: ethernet(type: 0x0800, payload: ipv4(proto: 6, payload: udp(payload: dnsQuery("a.com")))), link: .ethernet), [], "TCP")
        XCTAssertEqual(DNSQuestion.names(in: ethernet(type: 0x0806, payload: [0, 1, 2, 3]), link: .ethernet), [], "ARP")
    }

    func testCompressedOrMalformedNamesAreRejected() {
        var compressed = dnsQuery("a.com")
        compressed[12] = 0xC0   // first label byte is a pointer
        XCTAssertEqual(DNSQuestion.names(in: ethernet(type: 0x0800, payload: ipv4(payload: udp(payload: compressed))), link: .ethernet), [])

        let truncated = Array(ethernet(type: 0x0800, payload: ipv4(payload: udp(payload: dnsQuery("example.com")))).dropLast(6))
        XCTAssertEqual(DNSQuestion.names(in: truncated, link: .ethernet), [])

        XCTAssertEqual(DNSQuestion.names(in: [UInt8](repeating: 0, count: 10), link: .ethernet), [])
        XCTAssertEqual(DNSQuestion.names(in: [], link: .null), [])
    }

    func testMultipleQuestions() {
        var two = dnsQuery("a.com", qdcount: 2)
        two += dnsQuery("b.org").dropFirst(12)   // second question only
        XCTAssertEqual(DNSQuestion.names(in: ethernet(type: 0x0800, payload: ipv4(payload: udp(payload: two))), link: .ethernet), ["a.com", "b.org"])
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter DNSQuestionTests 2>&1 | grep -E "error:|Executed" | head -3`
Expected: compile errors.

- [ ] **Step 3: Implement**

`Sources/FocusGuardCore/DNSQuestion.swift`:

```swift
import Foundation

/// Extracts the question names from a captured DNS query frame (keyword spec §5). Pure: the
/// daemon hands it bytes from libpcap. Anything that is not a plain UDP query to port 53 with
/// uncompressed names yields no names; nothing here trusts the packet.
public enum DNSQuestion {
    public enum LinkType {
        /// 14-byte Ethernet header (Wi-Fi and wired).
        case ethernet
        /// BSD "null" framing: a 4-byte address family in host byte order (loopback, `utun`).
        case null
    }

    private static let maxQuestions = 4

    public static func names(in frame: [UInt8], link: LinkType) -> [String] {
        guard let (ipStart, isV6) = ipStart(of: frame, link: link),
              let udpStart = udpStart(of: frame, at: ipStart, isV6: isV6),
              frame.count >= udpStart + 8 else { return [] }
        let dstPort = UInt16(frame[udpStart + 2]) << 8 | UInt16(frame[udpStart + 3])
        guard dstPort == 53 else { return [] }
        return questions(in: frame, at: udpStart + 8)
    }

    /// Offset of the IP header and whether it is IPv6, from the link-layer framing.
    private static func ipStart(of frame: [UInt8], link: LinkType) -> (Int, Bool)? {
        switch link {
        case .ethernet:
            guard frame.count >= 14 else { return nil }
            let type = UInt16(frame[12]) << 8 | UInt16(frame[13])
            if type == 0x0800 { return (14, false) }
            if type == 0x86DD { return (14, true) }
            return nil
        case .null:
            guard frame.count >= 4 else { return nil }
            // Host byte order; macOS is little-endian. AF_INET = 2, AF_INET6 = 30.
            let family = UInt32(frame[0]) | UInt32(frame[1]) << 8 | UInt32(frame[2]) << 16 | UInt32(frame[3]) << 24
            if family == 2 { return (4, false) }
            if family == 30 { return (4, true) }
            return nil
        }
    }

    /// Offset of the UDP header, or nil when the transport is not UDP (IPv6 extension headers
    /// are not followed; a DNS query never carries them in practice).
    private static func udpStart(of frame: [UInt8], at ip: Int, isV6: Bool) -> Int? {
        if isV6 {
            guard frame.count >= ip + 40, frame[ip] >> 4 == 6, frame[ip + 6] == 17 else { return nil }
            return ip + 40
        }
        guard frame.count >= ip + 20, frame[ip] >> 4 == 4, frame[ip + 9] == 17 else { return nil }
        let headerLen = Int(frame[ip] & 0x0f) * 4
        guard headerLen >= 20 else { return nil }
        return ip + headerLen
    }

    private static func questions(in frame: [UInt8], at dns: Int) -> [String] {
        guard frame.count >= dns + 12, frame[dns + 2] & 0x80 == 0 else { return [] }   // QR = query
        let qdcount = Int(frame[dns + 4]) << 8 | Int(frame[dns + 5])
        guard (1...maxQuestions).contains(qdcount) else { return [] }
        var names: [String] = []
        var i = dns + 12
        for _ in 0..<qdcount {
            var labels: [String] = []
            var total = 0
            while true {
                guard i < frame.count else { return [] }
                let len = Int(frame[i])
                if len == 0 { i += 1; break }
                guard len & 0xC0 == 0 else { return [] }   // compression pointer: not in a query
                guard i + 1 + len <= frame.count else { return [] }
                total += len + 1
                guard total <= 255 else { return [] }
                labels.append(String(decoding: frame[(i + 1)..<(i + 1 + len)], as: UTF8.self))
                i += 1 + len
            }
            guard i + 4 <= frame.count, !labels.isEmpty else { return [] }
            i += 4   // QTYPE, QCLASS
            names.append(labels.joined(separator: ".").lowercased())
        }
        return names
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter DNSQuestionTests 2>&1 | grep -E "failed|Executed"`
Expected: `Executed 8 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Sources/FocusGuardCore/DNSQuestion.swift Tests/FocusGuardCoreTests/DNSQuestionTests.swift
git commit -m "Core: DNS question parser for captured frames

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: Lock — keyword items and allow-list additions

**Files:**
- Modify: `Sources/FocusGuardCore/Lock.swift`
- Create: `Tests/FocusGuardCoreTests/LockKeywordTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import FocusGuardCore

final class LockKeywordTests: XCTestCase {
    let manga = KeywordRule(text: "manga", match: .contains)
    lazy var list = BlockList(name: "l", domains: ["x.com"], keywords: [manga])
    lazy var plain = BlockList(name: "p", domains: ["y.com"])
    func window(_ lists: [UUID], mode: UnlockMode = .impossible) -> ScheduleWindow {
        ScheduleWindow(name: "w", days: [.mon], start: TimeOfDay("09:00")!, end: TimeOfDay("12:00")!, blockListIDs: lists, unlockMode: mode)
    }
    let at10 = LocalMoment(weekday: .mon, minutesSinceMidnight: 600)
    let at16 = LocalMoment(weekday: .mon, minutesSinceMidnight: 960)

    func testRemovingAProtectedRuleIsACut() {
        let old = Config(blockLists: [list], schedules: [window([list.id])])
        var new = old
        new.blockLists[0].keywords = []
        XCTAssertEqual(new.weakens(from: old, at: at10), .impossible)
        XCTAssertNil(new.weakens(from: old, at: at16))
    }

    func testChangingTextOrMatchIsACut() {
        let old = Config(blockLists: [list], schedules: [window([list.id])])
        var text = old
        text.blockLists[0].keywords[0].text = "mang"
        XCTAssertEqual(text.weakens(from: old, at: at10), .impossible)
        var match = old
        match.blockLists[0].keywords[0].match = .wholeWord
        XCTAssertEqual(match.weakens(from: old, at: at10), .impossible)
    }

    func testAddingARuleIsNotACut() {
        let old = Config(blockLists: [list], schedules: [window([list.id])])
        var new = old
        new.blockLists[0].keywords.append(KeywordRule(text: "anime", match: .contains))
        XCTAssertNil(new.weakens(from: old, at: at10))
    }

    func testAddingAnAllowEntryIsACutAtTheKeywordWindowsMode() {
        let old = Config(blockLists: [list, plain], schedules: [window([list.id], mode: .friction), window([plain.id], mode: .impossible)])
        var new = old
        new.alwaysAllow.append("mangalore.in")
        XCTAssertEqual(new.weakens(from: old, at: at10), .friction, "only the window with keyword rules counts")
        XCTAssertNil(new.weakens(from: old, at: at16))
    }

    func testAddingAnAllowEntryWithNoActiveKeywordWindowIsFree() {
        let old = Config(blockLists: [plain], schedules: [window([plain.id])])
        var new = old
        new.alwaysAllow.append("mangalore.in")
        XCTAssertNil(new.weakens(from: old, at: at10))
    }

    func testRemovingAnAllowEntryIsNotACut() {
        var old = Config(blockLists: [list], schedules: [window([list.id])])
        old.alwaysAllow = ["mangalore.in"]
        var new = old
        new.alwaysAllow = []
        XCTAssertNil(new.weakens(from: old, at: at10))
    }

    func testMovingARuleToAnotherAttachedListIsNotACut() {
        let other = BlockList(name: "o")
        let old = Config(blockLists: [list, other], schedules: [window([list.id, other.id])])
        var new = old
        new.blockLists[0].keywords = []
        new.blockLists[1].keywords = [manga]
        XCTAssertNil(new.weakens(from: old, at: at10))
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter LockKeywordTests 2>&1 | grep -E "failed|Executed"`
Expected: several failures (rules are not items yet; allow additions are free).

- [ ] **Step 3: Implement**

In `Sources/FocusGuardCore/Lock.swift`, replace `weakens(from:at:)`, `itemsPerWindow()` and `protection(of:active:items:)` with:

```swift
    /// nil when replacing `old` with `self` unblocks nothing before `old` would have; otherwise the
    /// strictest `old` mode among the items whose protection is cut.
    ///
    /// At each evaluated minute within `old`'s current active stretch (at most a week), every
    /// blocked item — a normalized domain, a bundle ID or a keyword rule — has an *effective
    /// protection*: the strictest `unlockMode` among the active windows that cover it. An item is
    /// cut when `self` gives it no protection at that minute, or a lower mode than `old` did.
    /// Keying on items rather than on windows means disabling an impossible window while a basic
    /// one still covers the same items is a cut, deleting a redundant basic window is not, and
    /// delete-plus-recreate is judged by what it protects. Walking the stretch catches a shortened
    /// end time, a removed later window or a lowered mode on a window that only starts later.
    ///
    /// Adding an `alwaysAllow` entry may uncover a learned name, so it counts as cutting every
    /// keyword rule that is protected at that minute (keyword spec §6).
    ///
    /// Windows are handled by position, never looked up by ID: two entries sharing an ID are two
    /// windows, each counted only while it is itself active.
    public func weakens(from old: Config, at moment: LocalMoment) -> UnlockMode? {
        let oldItems = old.itemsPerWindow()
        let newItems = itemsPerWindow()
        let allowAdded = !Set(alwaysAllow.map(DomainNormalizer.normalize))
            .subtracting(old.alwaysAllow.map(DomainNormalizer.normalize)).isEmpty
        var worst: UnlockMode?
        var previousOld: [Int]?
        var previousNew: [Int]?
        for step in 0..<Self.lockHorizonMinutes {
            let m = moment.advanced(byMinutes: step)
            let oldActive = old.schedules.indices.filter { old.schedules[$0].isActive(at: m) }
            if oldActive.isEmpty { break }
            let newActive = schedules.indices.filter { schedules[$0].isActive(at: m) }
            if oldActive == previousOld && newActive == previousNew { continue }
            previousOld = oldActive
            previousNew = newActive

            let oldProtection = Self.protection(of: old.schedules, active: oldActive, items: oldItems)
            let newProtection = Self.protection(of: schedules, active: newActive, items: newItems)
            for (item, oldMode) in oldProtection {
                let kept = newProtection[item].map { $0 >= oldMode } ?? false
                let uncovered = allowAdded && item.hasPrefix("k:")
                if !kept || uncovered {
                    worst = max(worst ?? oldMode, oldMode)
                }
            }
            if worst == .impossible { break }
        }
        return worst
    }

    /// Each window's blocked items, by position in `schedules`. Domain normalization is the
    /// expensive part, so every list is normalized a single time and windows union the results.
    private struct WindowItems {
        var set = ActiveSet.empty
        var keywords = Set<String>()
    }

    private func itemsPerWindow() -> [WindowItems] {
        var perList: [UUID: WindowItems] = [:]
        for list in blockLists where perList[list.id] == nil {
            perList[list.id] = WindowItems(set: items(ofLists: [list.id]), keywords: Set(list.keywords.map(\.itemKey)))
        }
        return schedules.map { w in
            var out = WindowItems()
            for id in w.blockListIDs {
                guard let l = perList[id] else { continue }
                out.set.domains.formUnion(l.set.domains)
                out.set.bundleIDs.formUnion(l.set.bundleIDs)
                out.keywords.formUnion(l.keywords)
            }
            return out
        }
    }

    /// Effective protection of every item covered by the windows at the `active` positions:
    /// strictest mode wins. Keys carry a kind prefix so the kinds can never collide.
    private static func protection(of windows: [ScheduleWindow], active: [Int],
                                   items: [WindowItems]) -> [String: UnlockMode] {
        var map: [String: UnlockMode] = [:]
        for i in active {
            let mode = windows[i].unlockMode
            for d in items[i].set.domains { map["d:" + d] = max(map["d:" + d] ?? mode, mode) }
            for b in items[i].set.bundleIDs { map["a:" + b] = max(map["a:" + b] ?? mode, mode) }
            for k in items[i].keywords { map["k:" + k] = max(map["k:" + k] ?? mode, mode) }
        }
        return map
    }
```

- [ ] **Step 4: Run the whole suite**

Run: `swift test 2>&1 | grep -E "error:|failed|Executed [0-9]+ tests" | tail -2`
Expected: 0 failures (every earlier lock test still passes).

- [ ] **Step 5: Commit**

```bash
git add Sources/FocusGuardCore/Lock.swift Tests/FocusGuardCoreTests/LockKeywordTests.swift
git commit -m "Core: keyword rules are lock items; adding an allow entry weakens

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: Reconciler — learned names, `observe`, watch wanted

**Files:**
- Modify: `Sources/FocusGuardCore/ActiveSet.swift`
- Modify: `Sources/FocusGuardCore/Reconciler.swift`
- Create: `Tests/FocusGuardCoreTests/ReconcilerKeywordTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
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

    func testEvictionOnlyOutsideKeywordWindows() {
        var full = LearnedNames()
        for i in 0..<(LearnedNames.cap + 5) { full.record("site\(i).com", at: monday(1, 0).addingTimeInterval(Double(i))) }
        let r = Reconciler(hosts: hosts, dns: dns, processes: FakeProcesses(), log: log, calendar: cal, learned: full)
        _ = r.tick(live: cfg, clock: ClockSample(wall: monday(10, 0), monotonic: 100))
        XCTAssertEqual(r.learned.count, LearnedNames.cap + 5, "window active: nothing evicted")
        _ = r.tick(live: cfg, clock: ClockSample(wall: monday(14, 0), monotonic: 14500))
        XCTAssertEqual(r.learned.count, LearnedNames.cap)
    }
}

private extension ReconcilerKeywordTests {
    func monday(_ h: Int, _ m: Int, _ s: Int) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: h, minute: m, second: s))!
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter ReconcilerKeywordTests 2>&1 | grep -E "error:|Executed" | head -3`
Expected: compile errors (`activeSet(at:learned:)`, `observe`, `learned`, `keywordWatchWanted`).

- [ ] **Step 3: ActiveSet with learned names**

Append to `Sources/FocusGuardCore/ActiveSet.swift` inside `extension Config` (after `activeSet(at:)`):

```swift
    /// The active set plus every learned name a keyword rule blocks right now.
    public func activeSet(at moment: LocalMoment, learned: Set<String>) -> ActiveSet {
        var set = activeSet(at: moment)
        set.domains.formUnion(learned.filter { keywordBlocks(name: $0, at: moment) })
        return set
    }
```

- [ ] **Step 4: Reconciler changes**

In `Sources/FocusGuardCore/Reconciler.swift`:

Add to `Result`:
```swift
        /// Some enabled list has keyword rules: the daemon should be observing lookups.
        public var keywordWatchWanted: Bool
```

Add stored properties after `private var pendingKill`:
```swift
    /// Names seen looked up that matched a keyword rule. Persisted by the daemon.
    public private(set) var learned: LearnedNames
    /// What the last tick enforced, so `observe` can judge a name between ticks.
    private var lastEffective: Config?
```

Add an `init` parameter `learned: LearnedNames = LearnedNames()` (after `zone: TimeZone? = nil`) and `self.learned = learned` in the body.

In `tick`, replace `let active = config.activeSet(at: moment)` with:
```swift
        lastEffective = config
        if learned.count > LearnedNames.cap, config.keywordRules(activeAt: moment).isEmpty {
            learned.evictBeyondCap()
        }
        let active = config.activeSet(at: moment, learned: learned.names)
```

In the `return Result(...)` add `keywordWatchWanted: config.hasKeywordRules` as the last argument.

Add the method after `teardown()`:
```swift
    /// A site name the Mac just looked up. Returns true when it is a new match worth acting on:
    /// the daemon then runs a tick at once so the hosts region catches it without waiting.
    /// Judged against what the last tick enforced (so a held proposal cannot widen learning).
    @discardableResult
    public func observe(name rawName: String, wall: Date) -> Bool {
        let name = rawName.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !name.isEmpty, !name.hasSuffix(".arpa"), !name.hasSuffix(".local"),
              let config = lastEffective, config.shouldLearn(name: name) else { return false }
        let isNew = learned.record(name, at: wall)
        if isNew { log.info("learned \(name)") }
        return isNew
    }
```

- [ ] **Step 5: Run the whole suite**

Run: `swift test 2>&1 | grep -E "error:|failed|Executed [0-9]+ tests" | tail -2`
Expected: 0 failures. (`ReconcilerTests` constructs `Result` only through `tick`, so the new field needs no change there.)

- [ ] **Step 6: Commit**

```bash
git add Sources/FocusGuardCore/ActiveSet.swift Sources/FocusGuardCore/Reconciler.swift Tests/FocusGuardCoreTests/ReconcilerKeywordTests.swift
git commit -m "Core: reconciler learns names and blocks them with the active set

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 7: Status, paths, persistence

**Files:**
- Modify: `Sources/FocusGuardCore/DaemonStatus.swift`
- Modify: `Sources/FocusGuardCore/Paths.swift`
- Modify: `Sources/focusguardd/ConfigFile.swift`
- Modify: `Tests/FocusGuardCoreTests/ChallengeKeystrokeTests.swift` (the `DaemonStatusTests` class lives there)

- [ ] **Step 1: Status field**

In `DaemonStatus.swift` add after `timeZone`:
```swift
    /// "off" (no keyword rules), "watching en0, utun4", or "error: …" (keyword spec §7).
    public var dnsWatch: String
```
and add `dnsWatch: String = "off"` as the last `init` parameter with `self.dnsWatch = dnsWatch`. Bump `FocusGuardVersion.current` to `"0.5.0"`.

In `DaemonStatusTests.testRoundTripsThroughJSON`, change the constructor call to end with `timeZone: "America/Vancouver", dnsWatch: "watching en0")`.

- [ ] **Step 2: Paths**

In `Paths.swift` add after `timeZone`:
```swift
    /// `LearnedNames`, 0644: names learned from lookups that matched a keyword rule.
    public static let learned = stateDir + "/learned.json"
```

- [ ] **Step 3: ConfigFile**

Add to `Sources/focusguardd/ConfigFile.swift` before `writeRootFile`:
```swift
    static func loadLearned() -> LearnedNames {
        guard let data = FileManager.default.contents(atPath: Paths.learned),
              let learned = try? JSONDecoder().decode(LearnedNames.self, from: data) else { return LearnedNames() }
        return learned
    }

    @discardableResult
    static func saveLearned(_ learned: LearnedNames) -> Bool {
        guard let data = try? JSONEncoder().encode(learned) else { return false }
        return writeRootFile(Paths.learned, data, mode: 0o644)
    }
```

- [ ] **Step 4: Build and test**

Run: `swift build 2>&1 | grep -E "error|Build complete"; swift test 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1`
Expected: `Build complete!`, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add Sources/FocusGuardCore/DaemonStatus.swift Sources/FocusGuardCore/Paths.swift Sources/focusguardd/ConfigFile.swift Tests/FocusGuardCoreTests/ChallengeKeystrokeTests.swift
git commit -m "Daemon status dnsWatch, learned.json persistence, version 0.5.0

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 8: libpcap system library + `DNSWatcher`

No unit tests (it wraps the OS); verified by Task 12. Must not be run by the implementer with sudo.

**Files:**
- Create: `Sources/CPcap/module.modulemap`, `Sources/CPcap/shim.h`
- Modify: `Package.swift`
- Create: `Sources/focusguardd/DNSWatcher.swift`

- [ ] **Step 1: System library target**

`Sources/CPcap/shim.h`:
```c
#include <pcap/pcap.h>
```

`Sources/CPcap/module.modulemap`:
```
module CPcap [system] {
    header "shim.h"
    link "pcap"
    export *
}
```

In `Package.swift` add to `targets`:
```swift
        .systemLibrary(name: "CPcap", path: "Sources/CPcap"),
```
and change the daemon target to `.executableTarget(name: "focusguardd", dependencies: ["FocusGuardCore", "CPcap"]),`.

Run: `swift build --product focusguardd 2>&1 | grep -E "error|Build complete"`
Expected: `Build complete!` (nothing uses the module yet; this proves the header and link line resolve). If the header is not found, replace `shim.h`'s line with the SDK path: `#include "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/usr/include/pcap/pcap.h"` is **not** acceptable (machine-specific); instead report BLOCKED with the compiler output.

- [ ] **Step 2: The watcher**

`Sources/focusguardd/DNSWatcher.swift`:

```swift
import CPcap
import Darwin
import FocusGuardCore
import Foundation
import Network

/// Receives the Mac's outbound DNS questions (keyword spec §5). One libpcap handle per active
/// interface (`en*`, `utun*`) with the kernel filter `udp and dst port 53`, so the process is
/// woken for DNS questions only; frames are parsed by `DNSQuestion` and names handed to
/// `onName` on the main queue. Interfaces are re-enumerated when the network path changes
/// (`NWPathMonitor`), never on a timer. Needs root to open BPF devices; the daemon has it.
final class DNSWatcher {
    var onName: ((String) -> Void)?
    /// Human-readable, published in `DaemonStatus.dnsWatch`.
    private(set) var state = "off"
    var isRunning: Bool { monitor != nil }

    private struct Capture {
        let interface: String
        let handle: OpaquePointer
        let source: DispatchSourceRead
        let link: DNSQuestion.LinkType
    }

    private let log: ReconcilerLog
    private var captures: [Capture] = []
    private var monitor: NWPathMonitor?

    init(log: ReconcilerLog) {
        self.log = log
    }

    func start() {
        guard monitor == nil else { return }
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.reopen() }
        }
        m.start(queue: .main)
        monitor = m
        reopen()
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
        closeAll()
        state = "off"
    }

    // MARK: Interfaces

    /// Up, running, non-loopback interfaces with an address, named en* or utun*.
    private static func activeInterfaces() -> [String] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var names = Set<String>()
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cursor {
            defer { cursor = ifa.pointee.ifa_next }
            let flags = Int32(ifa.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0,
                  let addr = ifa.pointee.ifa_addr, addr.pointee.sa_family == AF_INET || addr.pointee.sa_family == AF_INET6
            else { continue }
            let name = String(cString: ifa.pointee.ifa_name)
            if name.hasPrefix("en") || name.hasPrefix("utun") { names.insert(name) }
        }
        return names.sorted()
    }

    private func reopen() {
        let wanted = Self.activeInterfaces()
        guard wanted != captures.map(\.interface) else { return }
        closeAll()
        for name in wanted { open(name) }
        let watching = captures.map(\.interface)
        state = watching.isEmpty ? "error: no interface could be opened" : "watching " + watching.joined(separator: ", ")
        log.info("keyword watch: \(state)")
    }

    private func closeAll() {
        for c in captures {
            c.source.cancel()
            pcap_close(c.handle)
        }
        captures = []
    }

    private func open(_ interface: String) {
        var errbuf = [CChar](repeating: 0, count: Int(PCAP_ERRBUF_SIZE))
        guard let handle = pcap_create(interface, &errbuf) else {
            log.error("keyword watch: pcap_create \(interface): \(String(cString: errbuf))")
            return
        }
        pcap_set_snaplen(handle, 512)            // a DNS question fits; nothing more is read
        pcap_set_promisc(handle, 0)
        pcap_set_timeout(handle, 100)
        pcap_set_immediate_mode(handle, 1)       // deliver each packet as it arrives
        guard pcap_activate(handle) == 0 else {
            log.error("keyword watch: activate \(interface): \(String(cString: pcap_geterr(handle)))")
            pcap_close(handle)
            return
        }
        var program = bpf_program()
        guard pcap_compile(handle, &program, "udp and dst port 53", 1, PCAP_NETMASK_UNKNOWN) == 0,
              pcap_setfilter(handle, &program) == 0 else {
            log.error("keyword watch: filter \(interface): \(String(cString: pcap_geterr(handle)))")
            pcap_close(handle)
            return
        }
        pcap_freecode(&program)
        pcap_setnonblock(handle, 1, &errbuf)
        let link: DNSQuestion.LinkType
        switch pcap_datalink(handle) {
        case DLT_EN10MB: link = .ethernet
        case DLT_NULL, DLT_LOOP: link = .null
        default:
            log.error("keyword watch: \(interface) has link type \(pcap_datalink(handle)); skipped")
            pcap_close(handle)
            return
        }
        let fd = pcap_get_selectable_fd(handle)
        guard fd >= 0 else {
            log.error("keyword watch: \(interface) has no selectable descriptor; skipped")
            pcap_close(handle)
            return
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in self?.drain(handle, link: link) }
        source.resume()
        captures.append(Capture(interface: interface, handle: handle, source: source, link: link))
    }

    /// Read every packet the kernel has queued, parse, hand names up.
    private func drain(_ handle: OpaquePointer, link: DNSQuestion.LinkType) {
        var header: UnsafeMutablePointer<pcap_pkthdr>?
        var data: UnsafePointer<UInt8>?
        while pcap_next_ex(handle, &header, &data) == 1 {
            guard let h = header?.pointee, let d = data else { continue }
            let frame = Array(UnsafeBufferPointer(start: d, count: Int(h.caplen)))
            for name in DNSQuestion.names(in: frame, link: link) { onName?(name) }
        }
    }
}
```

- [ ] **Step 3: Build**

Run: `swift build 2>&1 | grep -E "error|Build complete"`
Expected: `Build complete!`. If `DLT_LOOP`, `PCAP_NETMASK_UNKNOWN` or `IFF_*` fail to import as the expected types, cast explicitly (e.g. `Int32(DLT_EN10MB)`) and report the change.

- [ ] **Step 4: Commit**

```bash
git add Package.swift Sources/CPcap Sources/focusguardd/DNSWatcher.swift
git commit -m "Daemon: DNSWatcher over libpcap, one capture per interface

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 9: Daemon wiring

**Files:**
- Modify: `Sources/focusguardd/Daemon.swift`

- [ ] **Step 1: Wire the watcher and learned names**

Add stored properties:
```swift
    private let watcher: DNSWatcher
    private var lastSavedLearned: LearnedNames?
```

In `init()`: after `lastSavedZone = ConfigFile.loadTimeZone()` add `lastSavedLearned = ConfigFile.loadLearned()`; add `learned: lastSavedLearned ?? LearnedNames()` as the last `Reconciler(...)` argument; then, after the reconciler is created:
```swift
        watcher = DNSWatcher(log: log)
        watcher.onName = { [weak self] name in self?.observed(name) }
```
(`watcher` must be assigned before `reconciler` is used; order the two `let` assignments as: `watcher = DNSWatcher(log: log)` first, then `reconciler = Reconciler(...)`, then set `onName`.)

In `tick()`, after the time-zone save block, add:
```swift
        if result.keywordWatchWanted, !watcher.isRunning {
            watcher.start()
        } else if !result.keywordWatchWanted, watcher.isRunning {
            watcher.stop()
        }
        if reconciler.learned != lastSavedLearned, ConfigFile.saveLearned(reconciler.learned) {
            lastSavedLearned = reconciler.learned
        }
```
and pass `dnsWatch: watcher.state` as the last argument of the `DaemonStatus(...)` construction.

Add the method:
```swift
    /// A DNS question from the watcher. A new match is applied immediately rather than at the
    /// next tick, so the gap between the lookup and the block is one tick of the kernel, not 30 s.
    private func observed(_ name: String) {
        if reconciler.observe(name: name, wall: Date()) { tick() }
    }
```

- [ ] **Step 2: Build and smoke**

Run: `swift build 2>&1 | grep -E "error|Build complete" && .build/debug/focusguardd check | head -3`
Expected: `Build complete!` and the usual `check` output (no root needed).

- [ ] **Step 3: Commit**

```bash
git add Sources/focusguardd/Daemon.swift
git commit -m "Daemon: observe lookups when keyword rules exist; persist learned names

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 10: App model — learned names and watch status

**Files:**
- Modify: `Sources/FocusGuard/Model/AppModel.swift`
- Modify: `Sources/FocusGuard/Views/StatusTab.swift`

- [ ] **Step 1: AppModel**

Add a stored property after `enforced`:
```swift
    /// Names the daemon has learned (root-owned file, readable). Shown under each rule.
    private(set) var learned: Set<String> = []
```
In `refresh()`, after the `enforced = …` line:
```swift
        learned = FileManager.default.contents(atPath: Paths.learned)
            .flatMap { try? JSONDecoder().decode(LearnedNames.self, from: $0) }?.names ?? []
```
Add derived accessors after `canRestoreConfig`:
```swift
    /// Learned names this rule catches, for "Blocked so far".
    func learnedNames(for rule: KeywordRule) -> [String] {
        learned.filter { rule.matches(name: $0) && !(config ?? .empty).isAlwaysAllowed($0) }.sorted()
    }
    /// What the daemon reports about lookup watching; nil when no daemon status is known.
    var keywordWatch: String? { installer.status?.dnsWatch }
    var hasKeywordRules: Bool { (config ?? .empty).hasKeywordRules }
```
(`learned.json` is in the state directory, which `watchDaemonStateIfPossible` already watches, so a newly learned name refreshes the UI by itself.)

- [ ] **Step 2: Status tab row**

In `StatusTab.swift`, inside `Section("Protection")` after the `Toggle("Open FocusGuard at login", …)` line, add:
```swift
                if model.hasKeywordRules || (model.keywordWatch ?? "off") != "off" {
                    let watch = model.keywordWatch ?? "unknown (daemon status not available)"
                    row(done: watch.hasPrefix("watching"), "Keyword matching: \(watch)",
                        detail: watch.hasPrefix("watching") ? "Sites whose names match your keywords are learned from the Mac's lookups and blocked." :
                                "Keyword rules are inert until the daemon can watch lookups; sites and apps listed by name still work.")
                }
```

- [ ] **Step 3: Build**

Run: `swift build 2>&1 | grep -E "error|Build complete"`
Expected: `Build complete!`.

- [ ] **Step 4: Commit**

```bash
git add Sources/FocusGuard/Model/AppModel.swift Sources/FocusGuard/Views/StatusTab.swift
git commit -m "App: learned names and keyword-watch status

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 11: App UI — Keywords section and Always allow

**Files:**
- Modify: `Sources/FocusGuard/Views/BlockListsTab.swift`

- [ ] **Step 1: Keywords section**

In `BlockListDetail`, add state after `@State private var newDomain = ""`:
```swift
    @State private var newKeyword = ""
    @State private var newMatch: KeywordRule.Match = .contains
    @State private var keywordHint: String?
    @State private var newAllow = ""
    @State private var allowHint: String?
```

Insert a new section between `Section("Sites") { … }` and `Section("Apps") { … }`:
```swift
            Section {
                ForEach(list.keywords) { rule in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(rule.text).font(.system(.body, design: .monospaced))
                            Picker("", selection: Binding(
                                get: { rule.match },
                                set: { m in commit { $0.update(list: list.id) { l in
                                    if let i = l.keywords.firstIndex(where: { $0.id == rule.id }) { l.keywords[i].match = m }
                                } } }
                            )) {
                                ForEach(KeywordRule.Match.allCases, id: \.self) { Text($0.title).tag($0) }
                            }
                            .labelsHidden().frame(width: 130)
                            .disabled(removalsLocked)
                            Spacer()
                            removeButton { commit { $0.update(list: list.id) { $0.keywords.removeAll { $0.id == rule.id } } } }
                        }
                        let caught = model.learnedNames(for: rule)
                        Text(caught.isEmpty ? "Blocked so far: none yet"
                             : "Blocked so far: " + caught.prefix(10).joined(separator: ", ") + (caught.count > 10 ? " +\(caught.count - 10) more" : ""))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    TextField("Add a keyword, e.g. manga", text: $newKeyword).onSubmit(addKeyword)
                    Picker("", selection: $newMatch) {
                        ForEach(KeywordRule.Match.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().frame(width: 130)
                    Button("Add", action: addKeyword).disabled(newKeyword.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let hint = keywordHint { Text(hint).font(.caption).foregroundStyle(.red) }
            } header: {
                Text("Keywords")
            } footer: {
                Text("Matches site names only (mangadex.org, not reddit.com/r/manga). Sites are learned as your Mac looks them up and blocked from then on. Whole word, starts with and ends with look at the parts of the name between dots and hyphens.")
            }
```

Insert an **Always allow** section after `Section("Apps") { … }`, before the closing brace of `Form`:
```swift
            Section {
                ForEach(unique(model.config?.alwaysAllow ?? []), id: \.self) { site in
                    HStack {
                        Text(site)
                        Spacer()
                        // Removing an allow entry only ever blocks more, so it is never locked.
                        Button(role: .destructive) { commit { $0.alwaysAllow.removeAll { $0 == site } } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("Never block this site, e.g. mangalore.in", text: $newAllow).onSubmit(addAllow)
                    Button("Allow", action: addAllow).disabled(newAllow.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let hint = allowHint { Text(hint).font(.caption).foregroundStyle(.red) }
            } header: {
                Text("Always allow (all lists)")
            } footer: {
                Text("Keyword rules never block these sites or their subdomains. Sites you list by name are still blocked. Adding an entry while a keyword window is active counts as loosening it.")
            }
```

Add the two actions after `addDomain()`:
```swift
    private func addKeyword() {
        let typed = newKeyword
        guard let text = KeywordRule.normalize(typed) else {
            keywordHint = "A keyword is one word of 2–63 letters, digits or hyphens, like manga or read-manga."
            return
        }
        keywordHint = nil
        let rule = KeywordRule(text: text, match: newMatch)
        commit { $0.update(list: list.id) { l in if !l.keywords.contains(where: { $0.itemKey == rule.itemKey }) { l.keywords.append(rule) } } }
        newKeyword = ""
    }

    private func addAllow() {
        let typed = newAllow.trimmingCharacters(in: .whitespaces)
        let site = DomainNormalizer.normalize(typed)
        guard !site.isEmpty else {
            allowHint = "\u{201C}\(typed)\u{201D} is not a web address. Use the site\u{2019}s domain, like mangalore.in."
            return
        }
        allowHint = nil
        commit { if !$0.alwaysAllow.contains(site) { $0.alwaysAllow.append(site) } }
        newAllow = ""
    }
```

- [ ] **Step 2: Build the app bundle**

Run: `scripts/build-app.sh 2>&1 | grep -E "error|built"`
Expected: `built build/FocusGuard.app`.

- [ ] **Step 3: Commit**

```bash
git add Sources/FocusGuard/Views/BlockListsTab.swift
git commit -m "App: keyword rules and the always-allow list in Block Lists

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 12: Live acceptance, README, spec pointer

**Files:**
- Create: `scripts/verify-keywords.sh`
- Modify: `README.md`, `docs/superpowers/specs/2026-08-18-focusguard-design.md`, `Sources/FocusGuard/Info.plist` (version 0.5.0 / build 5)

- [ ] **Step 1: Live script**

`scripts/verify-keywords.sh`:
```bash
#!/bin/bash
# Live acceptance for keyword blocking (keyword spec §10). Needs the installed daemon, no
# password. Uses a rule "example" in a window active now: looks up example.org, expects it in
# /etc/hosts within a few seconds, checks the allow list, and that an Impossible window holds
# when the rule is removed. ~2 minutes. Your config.json is backed up and restored.
set -uo pipefail
CFG="/Library/Application Support/FocusGuard/config.json"
STATUS=/var/db/FocusGuard/status.json
BACKUP=$(mktemp -t focusguard-config)
fail=0
check() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1"; fail=1; fi; }
wait_for() { for _ in $(seq "$2"); do eval "$1" && return 0; sleep 1; done; return 1; }
field() { /usr/bin/python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$STATUS" "$1" 2>/dev/null; }

[ -f "$STATUS" ] || { echo "the daemon is not installed (no $STATUS)"; exit 1; }
cp "$CFG" "$BACKUP" 2>/dev/null || echo '{"version":1,"blockLists":[],"schedules":[]}' > "$BACKUP"

day=$(date +%a | tr 'A-Z' 'a-z'); start=$(date -v-1M +%H:%M); end=$(date -v+4M +%H:%M)
LIST=0B1C2D3E-0000-4000-8000-0000000000B1; WIN=0B1C2D3E-0000-4000-8000-0000000000B2
write() {  # $1 keywords json, $2 mode, $3 allow json
    printf '{"version":1,"blockLists":[{"id":"%s","name":"kw","domains":[],"appBundleIDs":[],"keywords":%s}],"schedules":[{"id":"%s","name":"Keyword test","days":["%s"],"start":"%s","end":"%s","blockListIDs":["%s"],"enabled":true,"unlockMode":"%s"}],"alwaysAllow":%s}\n' \
        "$LIST" "$1" "$WIN" "$day" "$start" "$end" "$LIST" "$2" "$3" > "$CFG"
}
RULE='[{"id":"0B1C2D3E-0000-4000-8000-0000000000B3","text":"example","match":"startsWith"}]'

echo "--- keyword rule 'example' (starts with), window $start-$end"
write "$RULE" basic '[]'
check "daemon is watching lookups" 'wait_for "field dnsWatch | grep -q ^watching" 40'
dig +short example.org >/dev/null 2>&1
check "example.org learned and in /etc/hosts within 5 s" 'wait_for "grep -q \"^0.0.0.0 example.org\" /etc/hosts" 5'
check "example.org does not resolve" '! curl -sS -m 5 -o /dev/null https://example.org 2>/dev/null'
check "learned.json lists it" 'grep -q example.org /var/db/FocusGuard/learned.json'

echo "--- allow list"
write "$RULE" basic '["example.org"]'
check "allowed site is released within a tick" 'wait_for "! grep -q example.org /etc/hosts" 35'
dig +short example.org >/dev/null 2>&1; sleep 3
check "and not re-learned" '! grep -q "^0.0.0.0 example.org" /etc/hosts'

echo "--- Impossible holds the rule"
write "$RULE" impossible '[]'
check "blocked again" 'wait_for "grep -q \"^0.0.0.0 example.org\" /etc/hosts" 35'
write '[]' impossible '[]'; sleep 6
check "removing the rule is held" '[ "$(field source)" = held ]'
check "still blocked" 'grep -q "^0.0.0.0 example.org" /etc/hosts'

echo "--- restore"
cp "$BACKUP" "$CFG"; rm -f "$BACKUP"
check "config restored (window gone), region clears within a tick" 'wait_for "! grep -q FOCUSGUARD /etc/hosts" 35'
if [ $fail = 0 ]; then echo "ALL OK"; else echo "SOME CHECKS FAILED"; fi
exit $fail
```
Note for the engineer: restoring the config while the Impossible window is still active is *also* a held change (the window is removed). The last check therefore passes only because `cp` restores the user's config, which has no active Impossible window of its own — the daemon holds the *test* window until `end`. If the last check fails with `source=held`, wait until `$end` and re-check; the script should then print a note rather than FAIL. Implement that: replace the last `check` with
```bash
if [ "$(field source)" = held ]; then echo "note: test window is Impossible until $end; the restored config is taken up then"; else
check "region clears within a tick" 'wait_for "! grep -q FOCUSGUARD /etc/hosts" 35'; fi
```

- [ ] **Step 2: README**

In `README.md`:
- In **Unlock modes**' "What Impossible actually guarantees" paragraph, after "quitting or deleting the app:" keep as is; no change.
- Add a section after **Unlock modes**:

```markdown
## Keywords

A block list can hold keyword rules as well as site names: `manga` with **starts with** blocks
mangadex.org and mangaplus.shueisha.co.jp; **whole word** blocks manga.example.com and
read-manga.net but not mangalore.in; **contains** and **ends with** do what they say. Rules
match the **site name only** — never a page path, a search or a title, which HTTPS hides.
Whole word, starts with and ends with look at the parts of the name between dots and hyphens.

While any list has keyword rules, the daemon watches the Mac's outgoing DNS questions (a
kernel filter wakes it for those alone; a busy day costs about a second of CPU). A name that
matches is learned, stored in `/var/db/FocusGuard/learned.json` and blocked from then on in
every browser and app, during any window whose list has a matching rule. Only matches are
stored, never your lookup history. The **Always allow** list stops keyword rules (not names
you listed yourself) from blocking a site and its subdomains.

The first ever lookup of a never-seen matching site succeeds — the answer is already on its
way back — so that one page may load, and a browser's own cache may keep it working for up to
about a minute. Sites you have visited before, inside or outside a window, are known already.
Encrypted DNS configured system-wide and iCloud Private Relay hide lookups from the daemon,
as they already hide them from the hosts layer.
```
- In **Known gaps**, add: `- Keyword rules see site names only; a page about manga on a site whose name does not match is not caught.`
- In **Development**, add `scripts/verify-keywords.sh` (keyword rules, learning, allow list, Impossible hold; ~2 minutes, no sudo) to the acceptance-script list.

- [ ] **Step 3: Spec pointer and version**

Append to `docs/superpowers/specs/2026-08-18-focusguard-design.md` §11.6, a line: `- Keyword blocking: see 2026-11-06-keyword-blocking-design.md (implemented in 0.5.0).` and remove nothing.

In `Sources/FocusGuard/Info.plist` set `CFBundleShortVersionString` to `0.5.0` and `CFBundleVersion` to `5`.

- [ ] **Step 4: Build, test, commit**

Run: `chmod +x scripts/verify-keywords.sh && bash -n scripts/verify-keywords.sh && scripts/build-app.sh 2>&1 | grep -E "error|built" && swift test 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1`
Expected: `built build/FocusGuard.app`, 0 failures.

```bash
git add scripts/verify-keywords.sh README.md docs/superpowers/specs/2026-08-18-focusguard-design.md Sources/FocusGuard/Info.plist
git commit -m "Keyword blocking: live acceptance script, README, version 0.5.0

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

- [ ] **Step 5: Live run (with the user present; the daemon update needs their password)**

1. `ditto build/FocusGuard.app /Applications/FocusGuard.app`, relaunch the app; Status shows "Background daemon needs updating" → the user clicks **Update…** and types the password.
2. Confirm `/var/db/FocusGuard/status.json` has `"version":"0.5.0"`.
3. Run `scripts/verify-keywords.sh` → `ALL OK`.
4. Battery baseline: note `ps -o time -p $(pgrep -f PrivilegedHelperTools/com.focusguard.daemon)` now; compare after a day with a keyword rule configured.

---

## Self-review

**Spec coverage:** §2 model/limits/old-file decode → T1. §3 matching table, allow list, explicit-beats-allow → T2 (allow only consulted in `keywordBlocks`/`shouldLearn`; explicit domains flow through `items(ofLists:)` unchanged). §4 learned set, cap, eviction only outside keyword windows, only matches stored, readable file → T3, T6, T7 (0644). §5 capture (interfaces, kernel filter, framings, parser, immediate rewrite, NWPathMonitor, independent of windows) → T4, T8, T9 (`observed` ticks at once; `keywordWatchWanted` uses `hasKeywordRules` = any enabled window). §5 gaps → README T12. §6 lock items and allow additions → T5. §7 status → T7, T10. §8 UI → T10, T11 (the Always-allow section sits in the list detail form rather than at the tab's bottom edge — it is visible from every list, which meets the intent; the engineer should not relocate it). §9 battery → design of T8 (no polling; `NWPathMonitor` is event-driven). §10 tests → T1–T6 unit, T12 live. §11 out of scope → nothing planned for it.

**Placeholder scan:** none; every code step is complete; T8 step 1 names the one failure mode that must be reported rather than patched.

**Type consistency:** `KeywordRule(text:match:)`, `.itemKey`, `.matches(name:)`, `KeywordRule.Match.title/allCases` used identically in T1, T2, T5, T10, T11. `Config.keywordBlocks(name:at:)`, `.shouldLearn(name:)`, `.hasKeywordRules`, `.allKeywordRules`, `.isAlwaysAllowed(_:)`, `.keywordRules(activeAt:)` defined in T2, used in T3, T6, T10. `LearnedNames.record(_:at:)`, `.names`, `.count`, `.evictBeyondCap()`, `.blocked(by:at:)`, `.cap` defined in T3, used in T6, T7, T10. `DNSQuestion.names(in:link:)` and `LinkType.ethernet/.null` in T4 and T8. `Reconciler.observe(name:wall:)`, `.learned`, `Result.keywordWatchWanted`, init `learned:` in T6 and T9. `DaemonStatus.dnsWatch` in T7, T9, T10. `DNSWatcher.start()/stop()/isRunning/state/onName` in T8 and T9. `Paths.learned` in T7, T10.
