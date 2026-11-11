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
/// action goes through. Recomputes only on events (boundary, config change, daemon status
/// change, wake, clock change).
///
/// The app is a convenience layer, not the enforcer. The root daemon blocks sites and apps and
/// itself refuses changes that would break an Impossible window; this class mirrors the daemon's
/// verdicts (its clock, what it is enforcing) so the UI agrees with it, and adds the Friction
/// challenge on top.
@MainActor @Observable
final class AppModel {
    nonisolated static let log = Logger(subsystem: "com.focusguard", category: "app")

    private(set) var config: Config?
    private(set) var loadError: String?
    private(set) var saveError: String?
    private(set) var activeSet = ActiveSet.empty
    private(set) var lockState = LockState()
    private(set) var nextBoundary: Date?
    private(set) var nextWindowNames: [String] = []
    /// The config the daemon has accepted (root-owned file, readable by us).
    private(set) var enforced: Config?

    var pendingChallenge: PendingChallenge?
    var lockedMessage: String?
    /// The Setup sheet is up (`SetupSheet.swift`). Set by `presentSetupIfNeeded()` and by
    /// Status → "Setup…"; cleared by the sheet's Done button or its auto-close.
    var setupSheetPresented = false

    private let store = ConfigStore()
    let installer = Installer()
    private let clock = ScheduleClock()
    private var killer: AppKiller?
    @ObservationIgnored private var statusWatcher: DirectoryWatcher?

    init() {
        killer = AppKiller { [weak self] in self?.activeSet.bundleIDs ?? [] }
        store.onExternalChange = { [weak self] in self?.reload() }
        clock.onFire = { [weak self] in self?.refresh() }
        installer.refresh()
        reload()
    }

    // MARK: What the daemon says

    /// The daemon's clock, which a change to the Mac's date or time does not move. Lock
    /// decisions use this, so they agree with what the daemon will accept.
    var trustedNow: Date { Date().addingTimeInterval(clockOffset) }
    private var clockOffset: TimeInterval { TimeInterval(installer.status?.clockOffsetSeconds ?? 0) }
    var clockTampered: Bool { installer.status?.clockTampered == true }

    /// Schedule times are read in the daemon's time zone. That is the Mac's, except that the
    /// daemon does not follow a zone change while an Impossible window is active.
    private var daemonCalendar: Calendar {
        var calendar = Calendar.current
        if let id = installer.status?.timeZone, let zone = TimeZone(identifier: id) { calendar.timeZone = zone }
        return calendar
    }
    var zoneHeldBack: String? {
        guard let id = installer.status?.timeZone, id != TimeZone.current.identifier else { return nil }
        return id
    }
    private var trustedMoment: LocalMoment { LocalMoment(date: trustedNow, calendar: daemonCalendar) }

    /// config.json holds a change the daemon is refusing (or, within its next tick, will refuse)
    /// until an Impossible window ends. Predicted here as well as read from the daemon so the
    /// window says so at once instead of up to 30 s later.
    var daemonIsHolding: Bool {
        if installer.status?.source == .held { return true }
        guard installer.status != nil, let config, let enforced, config != enforced else { return false }
        return config.weakens(from: enforced, at: trustedMoment) == .impossible
    }

    /// What is really in force when that is not config.json: a refused change, or a file we
    /// cannot read while the daemon carries on with its accepted copy.
    private var enforcedOverride: Config? {
        if daemonIsHolding { return enforced }
        if config == nil, installer.status?.source == .lastGood { return enforced }
        return nil
    }
    private var effective: Config { enforcedOverride ?? config ?? .empty }

    /// config.json cannot be read and the daemon has a copy we could put back.
    var canRestoreConfig: Bool { config == nil && enforced != nil }

    /// What the daemon reports about lookup watching; nil when no daemon status is known.
    var keywordWatch: String? { installer.status?.dnsWatch }
    var hasKeywordRules: Bool { (config ?? .empty).hasKeywordRules }
    /// What the daemon reports about Chrome's policy preference; nil when no daemon status is known.
    var chromePages: String? { installer.status?.chrome }
    var hasChromeURLs: Bool { (config ?? .empty).blockLists.contains { !$0.chromeURLs.isEmpty } }

    // MARK: Derived state

    /// Views may edit only when a config loaded (a parse error disables the editors).
    var canEditConfig: Bool { config != nil }
    var supportDirExists: Bool { store.supportDirExists }

    var isBlocking: Bool { lockState.overall != nil }
    var activeWindowNames: [String] {
        effective.schedules.filter { lockState.windowModes[$0.id] != nil }.map(\.name)
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
            loadError = "config.json could not be read: \(error.localizedDescription)"
        }
        refresh()
    }

    /// Recompute everything time-dependent and re-arm the single timer.
    func refresh() {
        watchDaemonStateIfPossible()
        enforced = FileManager.default.contents(atPath: Paths.lastGood).flatMap { try? Config.decodeJSON($0) }
        let now = trustedNow
        let calendar = daemonCalendar
        let moment = LocalMoment(date: now, calendar: calendar)
        let cfg = effective
        let wasBlocking = isBlocking
        activeSet = cfg.activeSet(at: moment)
        lockState = cfg.lockState(at: moment)
        nextBoundary = cfg.nextBoundary(after: now, calendar: calendar)
        nextWindowNames = nextBoundary.map { cfg.windows(startingAt: LocalMoment(date: $0, calendar: calendar)).map(\.name) } ?? []
        // The boundary is on the daemon's timeline; the timer runs on the wall clock.
        clock.arm(at: nextBoundary?.addingTimeInterval(-clockOffset))
        if !activeSet.bundleIDs.isEmpty { killer?.sweep() }
        Self.log.info("refresh: blocking=\(self.isBlocking) was=\(wasBlocking) domains=\(self.activeSet.domains.count) apps=\(self.activeSet.bundleIDs.count) held=\(self.daemonIsHolding) next=\(self.nextBoundary?.description ?? "none", privacy: .public)")
    }

    /// The daemon rewrites status.json when its verdict changes (a refused config, a clock
    /// change). The directory exists only once the daemon has run, so this is retried on refresh.
    private func watchDaemonStateIfPossible() {
        guard statusWatcher == nil else { return }
        statusWatcher = DirectoryWatcher(path: Paths.stateDir) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let before = self.installer.status
                self.installer.refreshStatus()
                if self.installer.status != before { self.refresh() }
            }
        }
    }

    // MARK: Editing through the gate

    enum Outcome { case applied, challenge, locked, noChange, failed }

    /// Apply `edit` to a copy of the config; save it now, after a challenge, or refuse, depending on
    /// the strictest unlock mode the edit cuts through. Views never mutate config directly.
    ///
    /// Weakening is judged against what the daemon is enforcing, at the daemon's time, so the
    /// answer here matches the one the daemon will give. The edit is re-applied to the *current*
    /// config when a challenge succeeds: a stricter window may have started, or the file may have
    /// changed under us, while the sheet was open.
    @discardableResult
    func apply(_ edit: @escaping (inout Config) -> Void) -> Outcome {
        guard let old = config else { return .failed }
        var new = old
        edit(&new)
        guard new != old else { return .noChange }
        if new.isPermanentlyLocked, !old.isPermanentlyLocked {
            lockedMessage = "That would leave no free minute anywhere in the week while an Impossible window exists. An Impossible lock lasts until blocking next stops, so nothing could ever be removed or loosened again without sudo. Leave a gap somewhere, or use Friction."
            return .locked
        }
        let fresh: () -> (baseline: Config, edited: Config)? = { [weak self] in
            guard let self, let current = self.config else { return nil }
            var edited = current
            edit(&edited)
            return (self.enforcedOverride ?? current, edited)
        }
        let verdict: () -> UnlockMode? = { [weak self] in
            guard let self, let (baseline, edited) = fresh() else { return .impossible }
            return edited.weakens(from: baseline, at: self.trustedMoment)
        }
        return gate(verdict(), recheck: verdict) { [weak self] in
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

    /// Put config.json back to what the daemon is enforcing: drops a change it refused, or
    /// replaces a file that can no longer be read. Never a weakening, so it is not gated.
    func restoreEnforcedConfig() {
        guard let enforced else { return }
        commit(enforced)
        if saveError == nil { loadError = nil }
    }

    /// Re-probe the install and put the Setup sheet up if protection is not healthy. Called
    /// when the settings window appears and whenever the app becomes active (spec §3).
    func presentSetupIfNeeded() {
        installer.refresh()
        if SetupNeed.evaluate(installer.setupFlags) != nil { setupSheetPresented = true }
    }
}
