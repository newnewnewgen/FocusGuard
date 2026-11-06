import Foundation

/// Decides which config the daemon enforces. `config.json` is writable by the logged-in user, so
/// the daemon treats it as a *proposal* and keeps its own accepted copy (root-owned on disk).
///
/// **Impossible windows are enforced here, not just in the app.** A proposal that would unblock
/// anything an active Impossible window protects (`weakens(from:at:)`, judged at the daemon's
/// tamper-resistant time) is refused: the accepted config stays in force and the proposal is
/// re-examined every tick, so it is taken up by itself once the window has ended. Editing or
/// deleting the file, or changing the clock, therefore does not get around the lock. Friction
/// and Basic are speed bumps in the app only; the daemon accepts those changes.
///
/// **Unreadable config is bounded fail-closed.** Keep enforcing the accepted config, but only
/// while one of the windows that was active *when the live config vanished* is still active, and
/// (unless one of those is Impossible) never longer than `maxFallback`. After that the fallback
/// is released for the rest of this daemon's lifetime, until a config is read again. A daemon
/// restart re-arms it from the persisted copy — deliberately fail-closed after a reboot. A bug
/// can never lock the user out for more than `maxFallback` without a restart, and the README
/// documents `launchctl bootout` as the escape hatch.
public struct ConfigResolver {
    public enum Source: String, Equatable {
        /// The proposal in config.json is in force.
        case live
        /// config.json is missing or unreadable; the accepted copy is in force for now.
        case lastGood
        /// Nothing to enforce.
        case none
        /// config.json is readable but refused; the accepted copy stays in force.
        case held
    }

    /// The accepted config: the last proposal the daemon took up.
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
            fallbackReleased = false
            fallbackWindowIDs = nil
            fallbackSince = nil
            if let accepted = lastGood, live != accepted,
               live.weakens(from: accepted, at: moment) == .impossible {
                return (accepted, .held)
            }
            lastGood = live
            return (live, .live)
        }
        guard let lastGood, !fallbackReleased else { return (.empty, .none) }

        if fallbackWindowIDs == nil {
            fallbackWindowIDs = Set(lastGood.schedules.filter { $0.isActive(at: moment) }.map(\.id))
            fallbackSince = monotonic
        }
        let ids = fallbackWindowIDs ?? []
        let since = fallbackSince ?? monotonic
        let stillActive = lastGood.schedules.filter { ids.contains($0.id) && $0.isActive(at: moment) }
        // Deleting the file must not outlast an Impossible window either, however long it runs.
        let expired = monotonic - since >= maxFallback && !stillActive.contains { $0.unlockMode == .impossible }

        if stillActive.isEmpty || expired {
            fallbackReleased = true
            fallbackWindowIDs = nil
            fallbackSince = nil
            return (.empty, .none)
        }
        return (lastGood, .lastGood)
    }
}
