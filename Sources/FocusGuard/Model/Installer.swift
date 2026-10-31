import AppKit
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

    func refresh() {
        daemonStatus = daemon.status
        agentStatus = agent.status
        daemonProcess = DaemonProbe.find()
    }

    /// Register both. The first daemon registration throws "Operation not permitted" while the
    /// status moves to requiresApproval — that is the normal path, not an error.
    func install() {
        lastError = nil
        register(daemon, what: "daemon")
        register(agent, what: "login item")
        refresh()
        // launchd needs a moment to start the daemon; one delayed re-probe, not a loop.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.refresh() }
    }

    private func register(_ service: SMAppService, what: String) {
        do {
            try service.register()
        } catch {
            if service.status != .requiresApproval && service.status != .enabled {
                lastError = "Could not register \(what): \(error.localizedDescription)"
            }
        }
    }

    func uninstall() {
        lastError = nil
        do { try daemon.unregister() } catch { lastError = "Could not remove daemon: \(error.localizedDescription)" }
        try? agent.unregister()
        refresh()
    }

    func unregisterAgent() throws { try agent.unregister() }

    func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }

    /// Copy this bundle to /Applications, launch the copy, quit. /Applications is admin-writable.
    func moveToApplications() {
        lastError = nil
        let fm = FileManager.default
        let dest = Self.applicationsURL
        do {
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: Bundle.main.bundleURL, to: dest)
        } catch {
            lastError = "Could not copy to /Applications: \(error.localizedDescription)"
            return
        }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: dest, configuration: cfg) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
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
