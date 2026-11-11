import Foundation

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

/// Apps FocusGuard never kills, whatever a block list says. macOS relaunches these the moment
/// they exit, so blocking one is a kill loop that makes the Mac unusable (and burns battery);
/// FocusGuard itself is here so a list cannot take away the way to edit lists.
public enum ProtectedApps {
    public static let bundleIDs: Set<String> = [
        "com.apple.finder", "com.apple.dock", "com.apple.loginwindow", "com.apple.systemuiserver",
        "com.apple.controlcenter", "com.apple.WindowManager", "com.apple.Spotlight",
        "com.focusguard.app",
    ]
    public static func contains(_ bundleID: String) -> Bool {
        bundleIDs.contains { $0.caseInsensitiveCompare(bundleID) == .orderedSame }
    }
}

extension Config {
    /// Normalized domains and trimmed bundle IDs of the given lists; dangling IDs and
    /// `ProtectedApps` are ignored.
    public func items(ofLists ids: [UUID]) -> ActiveSet {
        let wanted = Set(ids)
        var out = ActiveSet.empty
        for list in blockLists where wanted.contains(list.id) {
            out.domains.formUnion(list.domains.map(DomainNormalizer.normalize).filter { !$0.isEmpty })
            out.bundleIDs.formUnion(list.appBundleIDs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && !ProtectedApps.contains($0) })
            out.chromeURLs.formUnion(list.chromeURLs.compactMap(ChromeURLPattern.normalize))
        }
        return out
    }

    public func activeSet(at moment: LocalMoment) -> ActiveSet {
        items(ofLists: schedules.filter { $0.isActive(at: moment) }.flatMap(\.blockListIDs))
    }

    /// The active set plus every learned name a keyword rule blocks right now.
    public func activeSet(at moment: LocalMoment, learned: Set<String>) -> ActiveSet {
        var set = activeSet(at: moment)
        let matcher = KeywordMatcher(config: self, at: moment)
        set.domains.formUnion(learned.filter(matcher.blocks))
        return set
    }
}
