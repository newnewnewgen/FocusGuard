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

    public var previous: Weekday { shifted(by: -1) }
    public var next: Weekday { shifted(by: 1) }

    /// `n` days later (negative moves back), wrapping the week.
    func shifted(by n: Int) -> Weekday {
        let all = Weekday.allCases
        let i = all.firstIndex(of: self)!
        let count = all.count
        return all[((i + n) % count + count) % count]
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

    // A new stored property must be added here, to the struct, and to `init(from:)` below.
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

public struct Config: Codable, Equatable {
    public static let currentVersion = 1

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

    public static let empty = Config()

    public func encodeJSON() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(self)
    }

    /// Decodes and validates. Anything that fails here is, to the daemon, an unreadable file:
    /// it carries on with the config it had accepted.
    public static func decodeJSON(_ data: Data) throws -> Config {
        guard data.count <= Limits.maxBytes else { throw ValidationError.tooLarge("file is \(data.count) bytes; the limit is \(Limits.maxBytes)") }
        let config = try JSONDecoder().decode(Config.self, from: data)
        try config.validate()
        return config
    }

    /// Far above anything a person would set up, and low enough that the daemon judges the worst
    /// allowed config in about a second (measured; ordinary ones take milliseconds). Without them a crafted config.json could keep the
    /// daemon's only thread busy for minutes, during which it kills no apps.
    public enum Limits {
        public static let maxBytes = 512 * 1024
        public static let maxWindows = 48
        public static let maxLists = 32
        /// Across all lists.
        public static let maxDomains = 2000
        public static let maxApps = 300
        /// Across all lists.
        public static let maxKeywords = 200
        public static let maxAllow = 500
    }

    public enum ValidationError: LocalizedError, Equatable {
        case tooLarge(String), duplicateID(String), invalidKeyword(String)
        public var errorDescription: String? {
            switch self {
            case .tooLarge(let what): return "Config too large: \(what)."
            case .duplicateID(let what): return "Two \(what) share one id."
            case .invalidKeyword(let text): return "\u{201C}\(text)\u{201D} is not a valid keyword (2–63 letters, digits or hyphens)."
            }
        }
    }

    /// IDs must be unique: with two windows sharing an ID, "is this window still protecting its
    /// items?" has no single answer, which was once enough to slip a weakening past the lock.
    /// Keyword rule ids are unique across all lists: the app keys learned names by rule id.
    public func validate() throws {
        guard schedules.count <= Limits.maxWindows else { throw ValidationError.tooLarge("\(schedules.count) windows; the limit is \(Limits.maxWindows)") }
        guard blockLists.count <= Limits.maxLists else { throw ValidationError.tooLarge("\(blockLists.count) lists; the limit is \(Limits.maxLists)") }
        let domains = blockLists.reduce(0) { $0 + $1.domains.count }
        guard domains <= Limits.maxDomains else { throw ValidationError.tooLarge("\(domains) sites; the limit is \(Limits.maxDomains)") }
        let apps = blockLists.reduce(0) { $0 + $1.appBundleIDs.count }
        guard apps <= Limits.maxApps else { throw ValidationError.tooLarge("\(apps) apps; the limit is \(Limits.maxApps)") }
        guard Set(schedules.map(\.id)).count == schedules.count else { throw ValidationError.duplicateID("windows") }
        guard Set(blockLists.map(\.id)).count == blockLists.count else { throw ValidationError.duplicateID("lists") }
        let keywords = blockLists.flatMap(\.keywords)
        guard keywords.count <= Limits.maxKeywords else { throw ValidationError.tooLarge("\(keywords.count) keywords; the limit is \(Limits.maxKeywords)") }
        if let bad = keywords.first(where: { !$0.isValid }) { throw ValidationError.invalidKeyword(bad.text) }
        guard Set(keywords.map(\.id)).count == keywords.count else { throw ValidationError.duplicateID("keyword rules") }
        guard alwaysAllow.count <= Limits.maxAllow else { throw ValidationError.tooLarge("\(alwaysAllow.count) allow entries; the limit is \(Limits.maxAllow)") }
    }
}
