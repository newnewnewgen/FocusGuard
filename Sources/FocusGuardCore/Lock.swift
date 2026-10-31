import Foundation

/// What the app must not let the user weaken right now, and how hard it should resist.
/// Only `.friction` and `.impossible` change the UI; `.basic` is recorded so callers can tell
/// "protected by a basic window" from "not protected at all".
public struct LockState: Equatable {
    /// Lists attached to at least one active window → strictest mode among those windows.
    public var listModes: [UUID: UnlockMode] = [:]
    /// Active windows → their own mode.
    public var windowModes: [UUID: UnlockMode] = [:]
    /// Strictest mode of any active window; gates quitting the app and uninstalling.
    public var overall: UnlockMode? = nil
    /// When the current active stretch ends, searching 24 h ahead. nil when nothing is active;
    /// nil while `overall` is non-nil means no release within the next 24 h (a gapless schedule).
    public var lockedUntil: TimeOfDay? = nil

    public init(listModes: [UUID: UnlockMode] = [:], windowModes: [UUID: UnlockMode] = [:],
                overall: UnlockMode? = nil, lockedUntil: TimeOfDay? = nil) {
        self.listModes = listModes
        self.windowModes = windowModes
        self.overall = overall
        self.lockedUntil = lockedUntil
    }
}

extension Config {
    /// Longest stretch `weakens` and `lockedUntil` look ahead: a 24/7 schedule must still release.
    static let lockHorizonMinutes = 1440

    public func lockState(at moment: LocalMoment) -> LockState {
        var state = LockState()
        let knownLists = Set(blockLists.map(\.id))
        for w in schedules where w.isActive(at: moment) {
            state.windowModes[w.id] = w.unlockMode
            state.overall = max(state.overall ?? w.unlockMode, w.unlockMode)
            // Dangling list IDs protect nothing (consistent with `items(ofLists:)`).
            for id in w.blockListIDs where knownLists.contains(id) {
                state.listModes[id] = max(state.listModes[id] ?? w.unlockMode, w.unlockMode)
            }
        }
        guard state.overall != nil else { return state }
        for step in 1...Self.lockHorizonMinutes {
            let m = moment.advanced(byMinutes: step)
            if !schedules.contains(where: { $0.isActive(at: m) }) {
                state.lockedUntil = m.timeOfDay
                break
            }
        }
        return state
    }

    /// nil when replacing `old` with `self` unblocks nothing before `old` would have; otherwise the
    /// strictest `old` mode among the items whose protection is cut.
    ///
    /// At each evaluated minute within `old`'s current active stretch (at most 24 h), every blocked
    /// item — a normalized domain or a bundle ID — has an *effective protection*: the strictest
    /// `unlockMode` among the active windows that cover it. An item is cut when `self` gives it no
    /// protection at that minute, or a lower mode than `old` did. Keying on items rather than on
    /// window IDs means disabling an impossible window while a basic one still covers the same
    /// items is a cut, deleting a redundant basic window is not, and delete-plus-recreate is judged
    /// by what it protects. Walking the stretch catches a shortened end time, a removed later window
    /// or a lowered mode on a window that only starts later in the same stretch.
    ///
    /// Cost: item sets are computed once per window; the active set is piecewise constant between
    /// window boundaries, so protection is only recomputed at minutes where the set of active old
    /// or new window IDs changes. Everything else is integer comparisons.
    public func weakens(from old: Config, at moment: LocalMoment) -> UnlockMode? {
        let oldItems = old.itemsPerWindow()
        let newItems = itemsPerWindow()
        var worst: UnlockMode?
        var previousOld: Set<UUID>?
        var previousNew: Set<UUID>?
        for step in 0..<Self.lockHorizonMinutes {
            let m = moment.advanced(byMinutes: step)
            let oldActive = Set(old.schedules.lazy.filter { $0.isActive(at: m) }.map(\.id))
            if oldActive.isEmpty { break }
            let newActive = Set(schedules.lazy.filter { $0.isActive(at: m) }.map(\.id))
            if oldActive == previousOld && newActive == previousNew { continue }
            previousOld = oldActive
            previousNew = newActive

            let oldProtection = Self.protection(of: old.schedules, active: oldActive, items: oldItems)
            let newProtection = Self.protection(of: schedules, active: newActive, items: newItems)
            for (item, oldMode) in oldProtection {
                guard let newMode = newProtection[item], newMode >= oldMode else {
                    worst = max(worst ?? oldMode, oldMode)
                    continue
                }
            }
            if worst == .impossible { break }
        }
        return worst
    }

    /// Each window's blocked items, resolved once. Domain normalization is the expensive part, so
    /// every list is normalized a single time and windows union the results.
    private func itemsPerWindow() -> [UUID: ActiveSet] {
        var perList: [UUID: ActiveSet] = [:]
        for list in blockLists { perList[list.id] = items(ofLists: [list.id]) }
        var out: [UUID: ActiveSet] = [:]
        for w in schedules {
            var set = ActiveSet.empty
            for id in w.blockListIDs {
                guard let l = perList[id] else { continue }
                set.domains.formUnion(l.domains)
                set.bundleIDs.formUnion(l.bundleIDs)
            }
            out[w.id] = set
        }
        return out
    }

    /// Effective protection of every item covered by the `active` windows: strictest mode wins.
    /// Keys carry a kind prefix so a domain and a bundle ID can never collide.
    private static func protection(of windows: [ScheduleWindow], active: Set<UUID>,
                                   items: [UUID: ActiveSet]) -> [String: UnlockMode] {
        var map: [String: UnlockMode] = [:]
        for w in windows where active.contains(w.id) {
            guard let set = items[w.id] else { continue }
            for d in set.domains { map["d:" + d] = max(map["d:" + d] ?? w.unlockMode, w.unlockMode) }
            for b in set.bundleIDs { map["a:" + b] = max(map["a:" + b] ?? w.unlockMode, w.unlockMode) }
        }
        return map
    }
}
