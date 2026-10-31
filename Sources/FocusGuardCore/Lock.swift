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
    /// When the current active stretch ends (max 24 h out); nil when nothing is active.
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
        for w in schedules where w.isActive(at: moment) {
            state.windowModes[w.id] = w.unlockMode
            state.overall = max(state.overall ?? w.unlockMode, w.unlockMode)
            for id in w.blockListIDs {
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
    /// strictest unlock mode among the `old` windows whose protection is cut. Walks minute by minute
    /// from `moment` until `old` has no active window (at most 24 h), so shortening an end time or
    /// deleting a window that starts later in the same stretch is caught even though the active set
    /// at `moment` is unchanged. Lowering a window's mode is itself a cut (it weakens what guards it).
    public func weakens(from old: Config, at moment: LocalMoment) -> UnlockMode? {
        var worst: UnlockMode?
        for step in 0..<Self.lockHorizonMinutes {
            let m = moment.advanced(byMinutes: step)
            let oldActive = old.schedules.filter { $0.isActive(at: m) }
            if oldActive.isEmpty { break }
            let newSet = activeSet(at: m)
            for w in oldActive {
                let protected = old.items(ofLists: w.blockListIDs)
                let newMode = schedules.first { $0.id == w.id }?.unlockMode
                let cut = !protected.isSubset(of: newSet) || (newMode ?? .basic) < w.unlockMode
                if cut { worst = max(worst ?? w.unlockMode, w.unlockMode) }
            }
            if worst == .impossible { break }
        }
        return worst
    }
}
