import AppKit
import FocusGuardCore
import Observation
import os

/// One pending Friction challenge. `onSuccess` is the gated action.
struct PendingChallenge: Identifiable {
    let id = UUID()
    let sentence: String
    let onSuccess: () -> Void
}

/// Hub for the UI: the config, what is active/locked right now, and the gate every weakening
/// action goes through. Recomputes only on events (boundary, config change, wake, clock change).
@MainActor @Observable
final class AppModel {
    static let log = Logger(subsystem: "com.focusguard", category: "app")

    private(set) var config: Config?
    private(set) var loadError: String?
    private(set) var saveError: String?
    private(set) var activeSet = ActiveSet.empty
    private(set) var lockState = LockState()
    private(set) var nextBoundary: Date?
    private(set) var nextWindowNames: [String] = []

    var pendingChallenge: PendingChallenge?
    var lockedMessage: String?

    private let store = ConfigStore()
    let installer = Installer()
    private let clock = ScheduleClock()
    private var killer: AppKiller?

    init() {
        killer = AppKiller { [weak self] in self?.activeSet.bundleIDs ?? [] }
        store.onExternalChange = { [weak self] in self?.reload() }
        clock.onFire = { [weak self] in self?.refresh() }
        reload()
        // An app update replaces the daemon's binary under it. Daemons since 0.3.0 restart
        // themselves; an older one is restarted here, once, when the updated app first launches.
        DispatchQueue.main.async { [installer] in
            Self.log.info("launched by \(ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] ?? "?", privacy: .public)")
            installer.repairIfNeeded()
        }
    }

    // MARK: Derived state

    /// Views may edit only when a config loaded (a parse error disables the editors).
    var canEditConfig: Bool { config != nil }
    var supportDirExists: Bool { store.supportDirExists }

    var isBlocking: Bool { lockState.overall != nil }
    var activeWindowNames: [String] {
        guard let config else { return [] }
        return config.schedules.filter { lockState.windowModes[$0.id] != nil }.map(\.name)
    }
    var lockedUntilText: String {
        lockState.lockedUntil.map { "Locked until \($0.string)" } ?? "Locked while a window is active"
    }
    func mode(forList id: UUID) -> UnlockMode? { lockState.listModes[id] }
    func mode(forWindow id: UUID) -> UnlockMode? { lockState.windowModes[id] }

    // MARK: Loading

    func reload() {
        do {
            config = try store.load()
            loadError = nil
        } catch {
            config = nil
            loadError = "config.json is not valid: \(error.localizedDescription)"
        }
        refresh()
    }

    /// Recompute everything time-dependent and re-arm the single timer.
    func refresh() {
        let now = Date()
        let moment = LocalMoment(date: now)
        let cfg = config ?? .empty
        let wasBlocking = isBlocking
        activeSet = cfg.activeSet(at: moment)
        lockState = cfg.lockState(at: moment)
        nextBoundary = cfg.nextBoundary(after: now)
        nextWindowNames = nextBoundary.map { cfg.windows(startingAt: LocalMoment(date: $0)).map(\.name) } ?? []
        clock.arm(at: nextBoundary)
        if !activeSet.bundleIDs.isEmpty { killer?.sweep() }
        Self.log.info("refresh: blocking=\(self.isBlocking) was=\(wasBlocking) domains=\(self.activeSet.domains.count) apps=\(self.activeSet.bundleIDs.count) next=\(self.nextBoundary?.description ?? "none", privacy: .public)")
    }

    // MARK: Editing through the gate

    enum Outcome { case applied, challenge, locked, noChange, failed }

    /// Apply `edit` to a copy of the config; save it now, after a challenge, or refuse, depending on
    /// the strictest unlock mode the edit cuts through. Views never mutate config directly.
    ///
    /// The edit is re-applied to the *current* config when a challenge succeeds: a stricter window
    /// may have started, or the file may have changed under us, while the sheet was open.
    @discardableResult
    func apply(_ edit: @escaping (inout Config) -> Void) -> Outcome {
        guard let old = config else { return .failed }
        var new = old
        edit(&new)
        guard new != old else { return .noChange }
        // Both closures re-apply the edit to whatever the config is *when they run*. Immediately,
        // that is `new`; after a challenge it is the edit on top of any change made meanwhile.
        let fresh: () -> (current: Config, edited: Config)? = { [weak self] in
            guard let current = self?.config else { return nil }
            var edited = current
            edit(&edited)
            return (current, edited)
        }
        return gate(new.weakens(from: old, at: LocalMoment(date: Date())), recheck: {
            guard let (current, edited) = fresh() else { return .impossible }
            return edited.weakens(from: current, at: LocalMoment(date: Date()))
        }) { [weak self] in
            if let (_, edited) = fresh() { self?.commit(edited) }
        }
    }

    /// Run `action` now (nil / basic), after a typed challenge (friction), or never (impossible).
    /// `recheck` is consulted when the challenge is passed: the world may have moved while the
    /// sheet was open, and if it now reports `.impossible` the action is refused instead of run.
    /// Anything ≤ friction goes ahead — the user just passed a challenge, do not ask for another.
    @discardableResult
    func gate(_ mode: UnlockMode?, recheck: @escaping () -> UnlockMode? = { nil },
              action: @escaping () -> Void) -> Outcome {
        switch mode {
        case nil, .basic?:
            action()
            return .applied
        case .friction?:
            pendingChallenge = PendingChallenge(sentence: Challenge.sentence()) { [weak self] in
                guard let self else { return }
                if recheck() == .impossible {
                    self.lockedMessage = self.lockedUntilText
                    return
                }
                action()
            }
            return .challenge
        case .impossible?:
            lockedMessage = lockedUntilText
            return .locked
        }
    }

    private func commit(_ new: Config) {
        do {
            try store.save(new)
            config = new
            saveError = nil
            refresh()
        } catch {
            saveError = error.localizedDescription
        }
    }

    // MARK: Whole-app actions (gated by the strictest active mode)

    /// Quit needs a window to show the challenge in when the mode is friction/impossible.
    var quitNeedsSettingsWindow: Bool { (lockState.overall ?? .basic) > .basic }

    func requestQuit() {
        gate(lockState.overall, recheck: { [weak self] in self?.lockState.overall }) { [installer] in
            try? installer.unregisterAgent()   // otherwise KeepAlive relaunches us
            NSApp.terminate(nil)
        }
    }

    func requestUninstall() {
        gate(lockState.overall, recheck: { [weak self] in self?.lockState.overall }) { [installer] in installer.uninstall() }
    }
}
