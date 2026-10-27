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
