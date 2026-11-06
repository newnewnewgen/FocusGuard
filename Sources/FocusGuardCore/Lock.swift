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
    /// The time of day at which the current active stretch ends, searching a week ahead (so for a
    /// stretch longer than a day it is the time on a later day). nil when nothing is active; nil
    /// while `overall` is non-nil means the schedule has no gap all week.
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
    /// How far `weakens` and `lockedUntil` look ahead: one week. The schedule repeats weekly, so
    /// a week covers every boundary there is; a shorter horizon let a lock longer than itself be
    /// cut down to the horizon. A schedule with no gap all week is therefore never weakenable.
    static let lockHorizonMinutes = 7 * 1440

    public func lockState(at moment: LocalMoment) -> LockState {
        var state = LockState()
        let knownLists = Set(blockLists.map(\.id))
        for w in schedules where w.isActive(at: moment) {
            state.windowModes[w.id] = max(state.windowModes[w.id] ?? w.unlockMode, w.unlockMode)
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
    /// At each evaluated minute within `old`'s current active stretch (at most a week), every
    /// blocked item — a normalized domain or a bundle ID — has an *effective protection*: the
    /// strictest `unlockMode` among the active windows that cover it. An item is cut when `self`
    /// gives it no protection at that minute, or a lower mode than `old` did. Keying on items
    /// rather than on windows means disabling an impossible window while a basic one still covers
    /// the same items is a cut, deleting a redundant basic window is not, and delete-plus-recreate
    /// is judged by what it protects. Walking the stretch catches a shortened end time, a removed
    /// later window or a lowered mode on a window that only starts later in the same stretch.
    ///
    /// Windows are handled by position, never looked up by ID: two entries sharing an ID are two
    /// windows, each counted only while it is itself active.
    ///
    /// Cost: item sets are computed once per window; the active set is piecewise constant between
    /// window boundaries, so protection is only recomputed at minutes where the set of active old
    /// or new windows changes. Everything else is integer comparisons. `Config.Limits` bounds it.
    public func weakens(from old: Config, at moment: LocalMoment) -> UnlockMode? {
        let oldItems = old.itemsPerWindow()
        let newItems = itemsPerWindow()
        var worst: UnlockMode?
        var previousOld: [Int]?
        var previousNew: [Int]?
        for step in 0..<Self.lockHorizonMinutes {
            let m = moment.advanced(byMinutes: step)
            let oldActive = old.schedules.indices.filter { old.schedules[$0].isActive(at: m) }
            if oldActive.isEmpty { break }
            let newActive = schedules.indices.filter { schedules[$0].isActive(at: m) }
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

    /// Each window's blocked items, by position in `schedules`. Domain normalization is the
    /// expensive part, so every list is normalized a single time and windows union the results.
    private func itemsPerWindow() -> [ActiveSet] {
        var perList: [UUID: ActiveSet] = [:]
        for list in blockLists where perList[list.id] == nil { perList[list.id] = items(ofLists: [list.id]) }
        return schedules.map { w in
            var set = ActiveSet.empty
            for id in w.blockListIDs {
                guard let l = perList[id] else { continue }
                set.domains.formUnion(l.domains)
                set.bundleIDs.formUnion(l.bundleIDs)
            }
            return set
        }
    }

    /// Effective protection of every item covered by the windows at the `active` positions:
    /// strictest mode wins. Keys carry a kind prefix so a domain and a bundle ID never collide.
    private static func protection(of windows: [ScheduleWindow], active: [Int],
                                   items: [ActiveSet]) -> [String: UnlockMode] {
        var map: [String: UnlockMode] = [:]
        for i in active {
            let mode = windows[i].unlockMode
            for d in items[i].domains { map["d:" + d] = max(map["d:" + d] ?? mode, mode) }
            for b in items[i].bundleIDs { map["a:" + b] = max(map["a:" + b] ?? mode, mode) }
        }
        return map
    }
}
