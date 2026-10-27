import Foundation

/// Decides which config to enforce when the live one is unreadable.
///
/// Bounded fail-closed: keep enforcing the last-known-good config, but only until the
/// moment it says nothing is active. After that it is released and stays released until a
/// live config is read again. A bug can therefore never lock the user out indefinitely.
public struct ConfigResolver {
    public enum Source: Equatable { case live, lastGood, none }

    public private(set) var lastGood: Config?
    public private(set) var fallbackReleased = false

    public init(lastGood: Config? = nil) {
        self.lastGood = lastGood
    }

    public mutating func resolve(live: Config?, at moment: LocalMoment) -> (config: Config, source: Source) {
        if let live {
            lastGood = live
            fallbackReleased = false
            return (live, .live)
        }
        guard let lastGood, !fallbackReleased else { return (.empty, .none) }
        if lastGood.activeSet(at: moment).isEmpty {
            fallbackReleased = true
            return (.empty, .none)
        }
        return (lastGood, .lastGood)
    }
}
