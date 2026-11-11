import Foundation

/// Site names the daemon has seen looked up that matched a keyword rule (keyword spec §4).
/// Only matches are ever stored, never general lookup history. Persisted root-owned by the
/// daemon; readable by the app.
public struct LearnedNames: Codable, Equatable {
    public static let cap = 2000

    public private(set) var lastSeen: [String: Date]

    public init(lastSeen: [String: Date] = [:]) {
        self.lastSeen = lastSeen
    }

    private enum CodingKeys: String, CodingKey { case lastSeen }

    /// A file written by an older build is not trusted to hold only site names: anything that is
    /// not one is dropped here, so it can never reach /etc/hosts.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decode([String: Date].self, forKey: .lastSeen)
        lastSeen = raw.filter { DomainNormalizer.isHostname($0.key) }
    }

    public var names: Set<String> { Set(lastSeen.keys) }
    public var count: Int { lastSeen.count }

    /// True when `name` was not known before. Names are kept lowercased without a trailing dot.
    ///
    /// The cap is hard: recording a new name at `cap` first drops the oldest-seen 5 %. `protected`
    /// is what the caller is blocking right now: a name in /etc/hosts never produces a lookup, so
    /// its timestamp freezes while unblocked names keep refreshing, and without this the drop
    /// would remove exactly the enforced names mid-window. Unprotected names go first, oldest
    /// seen; only when every name is protected does the oldest overall go. A flood of matching
    /// lookups can still evict a genuinely learned name; it is re-learned on its next lookup
    /// (the same one-lookup gap as a first visit).
    /// A known name's timestamp is refreshed only when more than an hour stale, to avoid churn.
    @discardableResult
    public mutating func record(_ rawName: String, at date: Date, protected: Set<String> = []) -> Bool {
        let name = rawName.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard DomainNormalizer.isHostname(name) else { return false }
        if let seen = lastSeen[name] {
            if date.timeIntervalSince(seen) > 3600 { lastSeen[name] = date }
            return false
        }
        if lastSeen.count >= Self.cap { drop(max(Self.cap / 20, 1), sparing: protected) }
        lastSeen[name] = date
        return true
    }

    /// Oldest seen first; the key breaks ties so the order is the same on every run.
    private static func oldestFirst(_ a: (key: String, value: Date), _ b: (key: String, value: Date)) -> Bool {
        a.value != b.value ? a.value < b.value : a.key > b.key
    }

    private mutating func drop(_ n: Int, sparing protected: Set<String>) {
        let unprotected = lastSeen.filter { !protected.contains($0.key) }
        let pool = unprotected.isEmpty ? lastSeen : unprotected
        for (k, _) in pool.sorted(by: Self.oldestFirst).prefix(n) { lastSeen[k] = nil }
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
