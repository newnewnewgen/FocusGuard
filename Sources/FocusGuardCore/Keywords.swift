import Foundation

extension KeywordRule {
    /// Words of a site name: split on dots and hyphens, so "read-manga.net" → read, manga, net.
    public static func words(of name: String) -> [String] {
        name.split(whereSeparator: { $0 == "." || $0 == "-" }).map(String.init)
    }

    /// `name` is a site name as looked up; case and a trailing dot are ignored.
    public func matches(name rawName: String) -> Bool {
        let name = rawName.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return matches(normalized: name, words: Self.words(of: name))
    }

    /// The same test against a name already lowercased, trimmed and split, so a caller judging
    /// one name against many rules (or many names against many rules, every tick) normalizes
    /// each name once rather than once per rule.
    public func matches(normalized name: String, words: [String]) -> Bool {
        guard isValid else { return false }
        switch match {
        case .contains: return name.contains(text)
        case .wholeWord: return words.contains(text)
        case .startsWith: return words.contains { $0.hasPrefix(text) }
        case .endsWith: return words.contains { $0.hasSuffix(text) }
        }
    }
}

extension Config {
    /// Equal to an `alwaysAllow` entry or a subdomain of one. Entries are normalized here as
    /// well as by the app, so a hand-edited "https://Site.com/" still works.
    public func isAlwaysAllowed(_ name: String) -> Bool {
        let host = name.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return KeywordMatcher(allowOnly: self).isAllowed(host)
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
        KeywordMatcher(config: self, at: moment).blocks(name)
    }

    /// Worth remembering: matches some rule of an enabled window and is not allowed.
    public func shouldLearn(name: String) -> Bool {
        guard DomainNormalizer.isHostname(name.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))) else { return false }
        guard !isAlwaysAllowed(name) else { return false }
        let host = name.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let words = KeywordRule.words(of: host)
        return allKeywordRules.contains { $0.matches(normalized: host, words: words) }
    }
}

/// The keyword rules in force at one moment and the normalized allow list, computed once so a
/// whole learned set can be judged at a few microseconds per name.
public struct KeywordMatcher {
    public let rules: [KeywordRule]
    public let allowed: [String]

    public init(config: Config, at moment: LocalMoment) {
        rules = config.keywordRules(activeAt: moment)
        allowed = config.alwaysAllow.map(DomainNormalizer.normalize).filter { !$0.isEmpty }
    }

    /// Allow list only (no rules): for callers that just need `isAllowed`.
    init(allowOnly config: Config) {
        rules = []
        allowed = config.alwaysAllow.map(DomainNormalizer.normalize).filter { !$0.isEmpty }
    }

    private static func normalized(_ name: String) -> String {
        name.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    public func isAllowed(_ name: String) -> Bool {
        let host = Self.normalized(name)
        return allowed.contains { DomainNormalizer.host(host, isUnder: $0) }
    }

    public func blocks(_ name: String) -> Bool {
        guard !rules.isEmpty else { return false }
        let host = Self.normalized(name)
        guard !allowed.contains(where: { DomainNormalizer.host(host, isUnder: $0) }) else { return false }
        let words = KeywordRule.words(of: host)
        return rules.contains { $0.matches(normalized: host, words: words) }
    }
}
