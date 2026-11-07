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
        guard DomainNormalizer.isHostname(name) else { return false }
        let isNew = lastSeen[name] == nil
        lastSeen[name] = date
        return isNew
    }

    /// Drop the oldest-seen names beyond `cap`. The daemon calls this only while no window with
    /// keyword rules is active, so eviction never unblocks something mid-window.
    public mutating func evictBeyondCap() {
        guard lastSeen.count > Self.cap else { return }
        let keep = lastSeen.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(Self.cap)
        lastSeen = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
    }

    /// The learned names a config blocks right now.
    public func blocked(by config: Config, at moment: LocalMoment) -> Set<String> {
        names.filter { config.keywordBlocks(name: $0, at: moment) }
    }
}
