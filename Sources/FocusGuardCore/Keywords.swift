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
