import Foundation

/// Decides which config to enforce when the live one is unreadable.
///
/// Bounded fail-closed: keep enforcing the last-known-good config, but only while one of the
/// windows that was active *when the live config vanished* is still active, and never longer
/// than `maxFallback`. After that the fallback is released for the rest of this daemon's
/// lifetime, until a live config is read again. A daemon restart re-arms it from the persisted
/// last-good config — deliberately fail-closed after a reboot — so the bound is per lifetime,
/// not cumulative. A bug can never lock the user out for more than `maxFallback` without a
/// restart, and the README documents `launchctl bootout` as the escape hatch.
public struct ConfigResolver {
    public enum Source: Equatable { case live, lastGood, none }

    public private(set) var lastGood: Config?
    public private(set) var fallbackReleased = false
    public var maxFallback: TimeInterval

    private var fallbackWindowIDs: Set<UUID>?
    private var fallbackSince: TimeInterval?

    public init(lastGood: Config? = nil, maxFallback: TimeInterval = 24 * 3600) {
        self.lastGood = lastGood
        self.maxFallback = maxFallback
    }

    public mutating func resolve(live: Config?, at moment: LocalMoment, monotonic: TimeInterval) -> (config: Config, source: Source) {
        if let live {
            lastGood = live
            fallbackReleased = false
            fallbackWindowIDs = nil
            fallbackSince = nil
            return (live, .live)
        }
        guard let lastGood, !fallbackReleased else { return (.empty, .none) }

        if fallbackWindowIDs == nil {
            fallbackWindowIDs = Set(lastGood.schedules.filter { $0.isActive(at: moment) }.map(\.id))
            fallbackSince = monotonic
        }
        let ids = fallbackWindowIDs ?? []
        let since = fallbackSince ?? monotonic
        let stillActive = lastGood.schedules.contains { ids.contains($0.id) && $0.isActive(at: moment) }
        let expired = monotonic - since >= maxFallback

        if !stillActive || expired {
            fallbackReleased = true
            fallbackWindowIDs = nil
            fallbackSince = nil
            return (.empty, .none)
        }
        return (lastGood, .lastGood)
    }
}
