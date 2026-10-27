import Foundation

/// Everything that should be blocked right now.
public struct ActiveSet: Equatable {
    public var domains: Set<String>
    public var bundleIDs: Set<String>

    public init(domains: Set<String>, bundleIDs: Set<String>) {
        self.domains = domains
        self.bundleIDs = bundleIDs
    }

    public static let empty = ActiveSet(domains: [], bundleIDs: [])
    public var isEmpty: Bool { domains.isEmpty && bundleIDs.isEmpty }
}

extension Config {
    public func activeSet(at moment: LocalMoment) -> ActiveSet {
        let activeListIDs = Set(schedules.filter { $0.isActive(at: moment) }.flatMap(\.blockListIDs))
        var out = ActiveSet.empty
        for list in blockLists where activeListIDs.contains(list.id) {
            out.domains.formUnion(list.domains.map(DomainNormalizer.normalize).filter { !$0.isEmpty })
            out.bundleIDs.formUnion(list.appBundleIDs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        }
        return out
    }
}
