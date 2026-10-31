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

    let store = ConfigStore()
    let installer = Installer()
    private let clock = ScheduleClock()
    private var killer: AppKiller?

    init() {
        killer = AppKiller { [weak self] in self?.activeSet.bundleIDs ?? [] }
        store.onExternalChange = { [weak self] in self?.reload() }
        clock.onFire = { [weak self] in self?.refresh() }
        reload()
    }

    // MARK: Derived state

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
    @discardableResult
    func apply(_ edit: (inout Config) -> Void) -> Outcome {
        guard let old = config else { return .failed }
        var new = old
        edit(&new)
        guard new != old else { return .noChange }
        return gate(new.weakens(from: old, at: LocalMoment(date: Date()))) { [weak self] in self?.commit(new) }
    }

    /// Run `action` now (nil / basic), after a typed challenge (friction), or never (impossible).
    @discardableResult
    func gate(_ mode: UnlockMode?, action: @escaping () -> Void) -> Outcome {
        switch mode {
        case nil, .basic?:
            action()
            return .applied
        case .friction?:
            pendingChallenge = PendingChallenge(sentence: Challenge.sentence(), onSuccess: action)
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
        gate(lockState.overall) { [installer] in
            try? installer.unregisterAgent()   // otherwise KeepAlive relaunches us
            NSApp.terminate(nil)
        }
    }

    func requestUninstall() {
        gate(lockState.overall) { [installer] in installer.uninstall() }
    }
}
