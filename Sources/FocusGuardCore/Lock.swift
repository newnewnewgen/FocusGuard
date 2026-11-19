import Foundation

/// What the app must not let the user weaken right now, and how hard it should resist. The
/// mode is the config's one `unlockMode` (0.7); it applies while any window is active. Only
/// `.friction` and `.impossible` change the UI; `.basic` is recorded so callers can tell
/// "protected by an active window" from "not protected at all".
public struct LockState: Equatable {
    /// Lists attached to at least one active window → the app mode.
    public var listModes: [UUID: UnlockMode] = [:]
    /// Active windows → the app mode.
    public var windowModes: [UUID: UnlockMode] = [:]
    /// The app mode while any window is active, else nil; gates quitting the app.
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
            state.windowModes[w.id] = unlockMode
            state.overall = unlockMode
            // Dangling list IDs protect nothing (consistent with `items(ofLists:)`).
            for id in w.blockListIDs where knownLists.contains(id) { state.listModes[id] = unlockMode }
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

    /// True when the mode is Impossible and there is no minute in the whole week with nothing
    /// active: the active stretch never ends, so nothing could be removed or loosened again
    /// without sudo. The app refuses to save such a config.
    public var isPermanentlyLocked: Bool {
        guard unlockMode == .impossible,
              schedules.contains(where: { $0.enabled && $0.start != $0.end && !$0.days.isEmpty }) else { return false }
        let start = LocalMoment(weekday: .mon, minutesSinceMidnight: 0)
        for step in 0..<Self.lockHorizonMinutes {
            let m = start.advanced(byMinutes: step)
            if !schedules.contains(where: { $0.isActive(at: m) }) { return false }
        }
        return true
    }

    /// nil when replacing `old` with `self` unblocks nothing before `old` would have; otherwise
    /// `old`'s mode, the one that protected what is cut.
    ///
    /// At each evaluated minute within `old`'s current active stretch (at most a week), every
    /// blocked item — a normalized domain, a bundle ID, a keyword rule or a Chrome URL pattern —
    /// is *protected* at `old.unlockMode` when an active window covers it. An item is cut when
    /// `self` leaves it uncovered at that minute, or covers it at a lower mode (`self.unlockMode`
    /// lowered). Keying on items rather than on windows means deleting a window while another
    /// still covers the same items is not a cut, deleting a redundant window is not, and
    /// delete-plus-recreate is judged by what it protects. Walking the stretch catches a shortened
    /// end time or a removed later window.
    ///
    /// Adding an `alwaysAllow` entry may uncover a learned name, so it counts as cutting every
    /// keyword rule that is protected at that minute (keyword spec §6).
    ///
    /// Windows are handled by position, never looked up by ID: two entries sharing an ID are two
    /// windows, each counted only while it is itself active.
    public func weakens(from old: Config, at moment: LocalMoment) -> UnlockMode? {
        let oldItems = old.itemsPerWindow()
        let newItems = itemsPerWindow()
        let allowAdded = !Set(alwaysAllow.map(DomainNormalizer.normalize))
            .subtracting(old.alwaysAllow.map(DomainNormalizer.normalize)).isEmpty
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

            let oldProtection = Self.protection(active: oldActive, items: oldItems, mode: old.unlockMode)
            let newProtection = Self.protection(active: newActive, items: newItems, mode: unlockMode)
            for (item, oldMode) in oldProtection {
                let kept = newProtection[item].map { $0 >= oldMode } ?? false
                let uncovered = allowAdded && item.hasPrefix("k:")
                if !kept || uncovered {
                    worst = max(worst ?? oldMode, oldMode)
                }
            }
            if worst == .impossible { break }
        }
        return worst
    }

    /// Each window's blocked items, by position in `schedules`. Domain normalization is the
    /// expensive part, so every list is normalized a single time and windows union the results.
    private struct WindowItems {
        var set = ActiveSet.empty
        var keywords = Set<String>()
    }

    private func itemsPerWindow() -> [WindowItems] {
        var perList: [UUID: WindowItems] = [:]
        // `items(ofLists:)` already unions every list sharing an id; keywords are merged here.
        for list in blockLists {
            if perList[list.id] == nil { perList[list.id] = WindowItems(set: items(ofLists: [list.id])) }
            perList[list.id]!.keywords.formUnion(list.keywords.map(\.itemKey))
        }
        return schedules.map { w in
            var out = WindowItems()
            for id in w.blockListIDs {
                guard let l = perList[id] else { continue }
                out.set.domains.formUnion(l.set.domains)
                out.set.bundleIDs.formUnion(l.set.bundleIDs)
                out.set.chromeURLs.formUnion(l.set.chromeURLs)
                out.keywords.formUnion(l.keywords)
            }
            return out
        }
    }

    /// Every item covered by the windows at the `active` positions, at `mode`. Keys carry a
    /// kind prefix so the kinds can never collide.
    private static func protection(active: [Int], items: [WindowItems], mode: UnlockMode) -> [String: UnlockMode] {
        var map: [String: UnlockMode] = [:]
        for i in active {
            for d in items[i].set.domains { map["d:" + d] = mode }
            for b in items[i].set.bundleIDs { map["a:" + b] = mode }
            for k in items[i].keywords { map["k:" + k] = mode }
            for c in items[i].set.chromeURLs { map["c:" + c] = mode }
        }
        return map
    }
}
