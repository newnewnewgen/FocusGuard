import AppKit
import Darwin
import FocusGuardCore
import Observation
import ServiceManagement

/// Registers the embedded daemon and the app's own KeepAlive agent with SMAppService, and
/// handles the two things that stop that working: not being in /Applications, and the legacy
/// manual install holding the same launchd label.
@MainActor @Observable
final class Installer {
    private(set) var daemonStatus: SMAppService.Status = .notFound
    private(set) var agentStatus: SMAppService.Status = .notFound
    private(set) var daemonProcess: DaemonProbe.Result?
    private(set) var lastError: String?

    private let daemon = SMAppService.daemon(plistName: Paths.daemonLabel + ".plist")
    private let agent = SMAppService.agent(plistName: Paths.agentLabel + ".plist")

    static let applicationsURL = URL(fileURLWithPath: "/Applications/FocusGuard.app")

    var inApplications: Bool { Bundle.main.bundleURL.path.hasPrefix("/Applications/") }
    var legacyInstallPresent: Bool { FileManager.default.fileExists(atPath: Paths.legacyDaemonPlist) }
    var canInstall: Bool { inApplications && !legacyInstallPresent }

    var daemonRunningFromBundle: Bool { daemonProcess?.isFromBundle == true }
    /// The bundle was updated under a running daemon, which is therefore still the old code.
    var daemonIsStale: Bool { daemonRunningFromBundle && daemonProcess?.isOlderThanBinary == true }
    private(set) var restarting = false

    func refresh() {
        daemonStatus = daemon.status
        agentStatus = agent.status
        daemonProcess = DaemonProbe.find()
        AppModel.log.info("install status: daemon=\(self.daemonStatus.label, privacy: .public) agent=\(self.agentStatus.label, privacy: .public) process=\(self.daemonProcess?.path ?? "none", privacy: .public)")
    }

    /// Set by Install, cleared by Uninstall: lets a later launch tell "the user removed protection"
    /// from "protection should be there and is not" (a failed restart, a lost registration).
    static let installedKey = "protectionInstalled"
    private var wantsProtection: Bool {
        // Installs made before this key existed are recognised by their enabled login item.
        UserDefaults.standard.bool(forKey: Self.installedKey) || agentStatus == .enabled
    }

    /// Called once at launch. Restarts a daemon left running old code by an app update, and
    /// re-registers a daemon that should be installed but is not.
    func repairIfNeeded() {
        refresh()
        if daemonIsStale {
            restartDaemon()
        } else if daemonStatus == .notRegistered, wantsProtection, canInstall {
            AppModel.log.info("daemon should be installed but is not registered; registering")
            registerDaemonWithRetry(attemptsLeft: 2)
        }
    }

    /// Register both. The first daemon registration throws "Operation not permitted" while the
    /// status moves to requiresApproval — that is the normal path, not an error.
    func install() {
        lastError = nil
        UserDefaults.standard.set(true, forKey: Self.installedKey)
        register(daemon, what: "daemon")
        register(agent, what: "login item")
        refresh()
        // launchd needs a moment to start the daemon; one delayed re-probe, not a loop.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.refresh() }
    }

    private func register(_ service: SMAppService, what: String) {
        do {
            try service.register()
            AppModel.log.info("register \(what, privacy: .public): ok, status=\(service.status.label, privacy: .public)")
        } catch {
            AppModel.log.error("register \(what, privacy: .public): \(error.localizedDescription, privacy: .public), status=\(service.status.label, privacy: .public)")
            if service.status != .requiresApproval && service.status != .enabled {
                lastError = "Could not register \(what): \(error.localizedDescription)"
            }
        }
    }

    /// `unregister`'s completion handler fires before launchd has finished removing the job, and a
    /// register that lands in that gap is silently lost (observed: the item is found "enabled",
    /// then the job disappears). So: wait, register, and check that it stuck.
    private func registerDaemonWithRetry(attemptsLeft: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            self.register(self.daemon, what: "daemon")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                guard let self else { return }
                self.refresh()
                let settled = self.daemonStatus == .requiresApproval
                    || (self.daemonStatus == .enabled && self.daemonProcess != nil)
                if settled || attemptsLeft <= 1 {
                    self.restarting = false
                    if !settled { self.lastError = "The daemon did not start. Use Re-install, or Install protection, below." }
                } else {
                    AppModel.log.info("daemon not running after register; retrying")
                    self.registerDaemonWithRetry(attemptsLeft: attemptsLeft - 1)
                }
            }
        }
    }

    /// Replace a running daemon with the binary now in the bundle: unregister (launchd sends
    /// SIGTERM, the daemon clears its hosts region) and register again (launchd starts the new
    /// one, which re-applies the block within a tick). Needs no password. Daemons built since
    /// 0.3.0 also restart themselves when their executable is replaced; this covers older ones
    /// and anything that went wrong.
    func restartDaemon() {
        guard !restarting else { return }
        restarting = true
        lastError = nil
        AppModel.log.info("restarting daemon: unregister then register")
        daemon.unregister { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error { AppModel.log.error("daemon unregister: \(error.localizedDescription, privacy: .public)") }
                self.refresh()
                self.registerDaemonWithRetry(attemptsLeft: 2)
            }
        }
    }

    func uninstall() {
        lastError = nil
        UserDefaults.standard.set(false, forKey: Self.installedKey)
        do { try daemon.unregister() } catch { lastError = "Could not remove daemon: \(error.localizedDescription)" }
        try? agent.unregister()
        refresh()
    }

    func unregisterAgent() throws { try agent.unregister() }

    func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }

    /// Copy this bundle to /Applications, launch the copy, quit. /Applications is admin-writable.
    /// Refused while anything is running from the destination bundle: replacing it under a live
    /// daemon or a second app instance would pull the files out from under them.
    func moveToApplications() {
        lastError = nil
        let fm = FileManager.default
        let dest = Self.applicationsURL
        let daemonFromDest = DaemonProbe.find()?.path.hasPrefix(dest.path) == true
        let appFromDest = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier!)
            .contains { $0.bundleURL?.standardizedFileURL == dest.standardizedFileURL }
        if daemonFromDest || appFromDest {
            lastError = "FocusGuard is already running from /Applications. Quit this copy and use that one."
            return
        }
        do {
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: Bundle.main.bundleURL, to: dest)
        } catch {
            lastError = "Could not copy to /Applications: \(error.localizedDescription)"
            return
        }
        // The copy inherits any quarantine flag from a downloaded bundle; drop it (best effort).
        _ = removexattr(dest.path, "com.apple.quarantine", XATTR_NOFOLLOW)
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: dest, configuration: cfg) { _, error in
            DispatchQueue.main.async {
                if let error {
                    self.lastError = "Copied to /Applications but could not launch it: \(error.localizedDescription)"
                } else {
                    NSApp.terminate(nil)
                }
            }
        }
    }
}

extension SMAppService.Status {
    var label: String {
        switch self {
        case .notRegistered: return "not installed"
        case .enabled: return "enabled"
        case .requiresApproval: return "waiting for approval"
        case .notFound: return "not found in bundle"
        @unknown default: return "unknown"
        }
    }
}
