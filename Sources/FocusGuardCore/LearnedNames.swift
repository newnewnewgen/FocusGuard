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
    ///
    /// The cap is hard: recording a new name at `cap` first drops the oldest-seen 5 % (same order
    /// as `evictBeyondCap`). A flood of matching lookups can therefore evict a genuinely learned
    /// name; it is re-learned on its next lookup (the same one-lookup gap as a first visit).
    /// A known name's timestamp is refreshed only when more than an hour stale, to avoid churn.
    @discardableResult
    public mutating func record(_ rawName: String, at date: Date) -> Bool {
        let name = rawName.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard DomainNormalizer.isHostname(name) else { return false }
        if let seen = lastSeen[name] {
            if date.timeIntervalSince(seen) > 3600 { lastSeen[name] = date }
            return false
        }
        if lastSeen.count >= Self.cap { drop(Self.cap / 20 > 0 ? Self.cap / 20 : 1) }
        lastSeen[name] = date
        return true
    }

    private mutating func drop(_ n: Int) {
        let oldest = lastSeen.sorted { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }.prefix(n)
        for (k, _) in oldest { lastSeen[k] = nil }
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
        let matcher = KeywordMatcher(config: config, at: moment)
        return names.filter(matcher.blocks)
    }
}
