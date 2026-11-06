import Foundation

/// Decides which config the daemon enforces. `config.json` is writable by the logged-in user, so
/// the daemon treats it as a *proposal* and keeps its own accepted copy (root-owned on disk).
///
/// **Impossible windows are enforced here, not just in the app.** A proposal that would unblock
/// anything an active Impossible window protects (`weakens(from:at:)`, judged at the daemon's
/// tamper-resistant time) is refused: the accepted config stays in force and the proposal is
/// re-examined, so it is taken up by itself once the window has ended. A file that is missing,
/// unreadable or invalid is judged as what it amounts to — a proposal to block nothing — and
/// refused on the same terms, today or in any later week. Editing, corrupting or deleting the
/// file, or changing the clock, therefore does not get around the lock. The way to drop an
/// Impossible schedule is to save a valid config while none of its windows is active.
/// Friction and Basic are speed bumps in the app only; the daemon accepts those changes.
///
/// **Otherwise an unreadable config is bounded fail-closed.** Keep enforcing the accepted config,
/// but only while one of the windows that was active *when the file vanished* is still active,
/// and never longer than `maxFallback`. After that the fallback is released for the rest of
/// this daemon's lifetime, until a config is read again. A daemon restart re-arms it from the
/// persisted copy — deliberately fail-closed after a reboot. Short of an Impossible window, a
/// bug can never lock the user out for more than `maxFallback` without a restart, and the README
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

    /// Recent judgements for the current minute, reused while the proposal is unchanged: a
    /// refused proposal sits in the file for the rest of the window and would otherwise be
    /// re-judged on every 2 s tick. A few entries, so alternating between proposals (or a held
    /// proposal alongside the missing-file and time-zone checks) does not defeat it. Cleared on a
    /// new minute or a new accepted config.
    private var cachedVerdicts: [(proposal: Config, verdict: UnlockMode?)] = []
    private var cachedMoment: LocalMoment?
    private static let cacheSize = 4
    /// How many judgements were actually computed (for tests).
    public private(set) var verdictsComputed = 0

    public init(lastGood: Config? = nil, maxFallback: TimeInterval = 24 * 3600) {
        self.lastGood = lastGood
        self.maxFallback = maxFallback
    }

    /// Would taking up `proposal` in place of the accepted config break an Impossible window?
    private mutating func breaksImpossible(_ proposal: Config, at moment: LocalMoment) -> Bool {
        guard let accepted = lastGood, proposal != accepted else { return false }
        if cachedMoment != moment {
            cachedMoment = moment
            cachedVerdicts.removeAll()
        }
        if let hit = cachedVerdicts.first(where: { $0.proposal == proposal }) { return hit.verdict == .impossible }
        let verdict = proposal.weakens(from: accepted, at: moment)
        verdictsComputed += 1
        if cachedVerdicts.count >= Self.cacheSize { cachedVerdicts.removeFirst() }
        cachedVerdicts.append((proposal, verdict))
        return verdict == .impossible
    }

    /// Is the accepted config inside an Impossible stretch right now? The daemon also uses this
    /// to decide whether a change of time zone may take effect yet.
    public mutating func isImpossibleLocked(at moment: LocalMoment) -> Bool {
        breaksImpossible(.empty, at: moment)
    }

    public mutating func resolve(live: Config?, at moment: LocalMoment, monotonic: TimeInterval) -> (config: Config, source: Source) {
        if let live {
            fallbackReleased = false
            fallbackWindowIDs = nil
            fallbackSince = nil
            if breaksImpossible(live, at: moment), let accepted = lastGood {
                return (accepted, .held)
            }
            if live != lastGood {
                lastGood = live
                cachedVerdicts.removeAll()
            }
            return (live, .live)
        }
        guard let lastGood else { return (.empty, .none) }

        if fallbackWindowIDs == nil, !fallbackReleased {
            fallbackWindowIDs = Set(lastGood.schedules.filter { $0.isActive(at: moment) }.map(\.id))
            fallbackSince = monotonic
        }
        // No file is a proposal to block nothing; an Impossible window refuses that outright,
        // whatever the softer bookkeeping below has concluded.
        if breaksImpossible(.empty, at: moment) { return (lastGood, .lastGood) }
        if fallbackReleased { return (.empty, .none) }

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
