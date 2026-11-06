import AppKit
import FocusGuardCore
import Observation
import ServiceManagement

/// Installs, updates and removes the daemon, and manages "open at login".
///
/// The daemon binary and its launchd plist are **root-owned** (`Paths.daemonBinary`,
/// `Paths.daemonPlist`), written by `install-daemon-root.sh` behind one macOS password prompt.
/// Up to 0.3 the daemon was registered with `SMAppService` and ran straight out of the app
/// bundle; that bundle is writable by the logged-in user, so any program running as the user
/// could replace the binary and have launchd run it as root. Hence the password, and hence
/// nothing here runs code as root from a user-writable place.
@MainActor @Observable
final class Installer {
    private(set) var daemonProcess: DaemonProbe.Result?
    private(set) var status: DaemonStatus?
    private(set) var loginItemStatus: SMAppService.Status = .notRegistered
    private(set) var lastError: String?
    /// A password prompt or the script behind it is in flight.
    private(set) var working = false

    private let loginItem = SMAppService.mainApp
    private static let bundledDaemon = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/focusguardd").path
    private static let installScript = Bundle.main.url(forResource: "install-daemon-root", withExtension: "sh")?.path
    private static let uninstallScript = Bundle.main.url(forResource: "uninstall-daemon-root", withExtension: "sh")?.path

    // MARK: State

    var daemonInstalled: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: Paths.daemonPlist) && fm.fileExists(atPath: Paths.daemonBinary)
    }
    var daemonRunning: Bool { daemonProcess?.path == Paths.daemonBinary }
    /// A daemon from before 0.4 is still running out of an app bundle or /usr/local.
    var legacyDaemonRunning: Bool { daemonProcess != nil && !daemonRunning }
    /// The installed daemon is not byte-for-byte the one this app ships.
    var needsUpdate: Bool {
        daemonInstalled && !FileManager.default.contentsEqual(atPath: Paths.daemonBinary, andPath: Self.bundledDaemon)
    }
    var opensAtLogin: Bool { loginItemStatus == .enabled }

    func refresh() {
        daemonProcess = DaemonProbe.find()
        status = Self.readStatus()
        loginItemStatus = loginItem.status
        AppModel.log.info("install status: installed=\(self.daemonInstalled) running=\(self.daemonRunning) legacy=\(self.legacyDaemonRunning) update=\(self.needsUpdate) version=\(self.status?.version ?? "?", privacy: .public) source=\(self.status?.source.rawValue ?? "?", privacy: .public) login=\(self.loginItemStatus.label, privacy: .public)")
    }

    /// Only the cheap part: called whenever the daemon rewrites status.json.
    func refreshStatus() { status = Self.readStatus() }

    private static func readStatus() -> DaemonStatus? {
        guard let data = FileManager.default.contents(atPath: Paths.status) else { return nil }
        return try? JSONDecoder().decode(DaemonStatus.self, from: data)
    }

    // MARK: Daemon

    /// Install or update: one password prompt. Also the migration from the pre-0.4 install.
    func install() {
        guard let script = Self.installScript else { lastError = "This copy of FocusGuard is missing its installer script."; return }
        retireLegacyRegistrations { [weak self] in
            self?.runAsRoot([script, Self.bundledDaemon],
                            prompt: "FocusGuard needs your password to install its background daemon.") { ok in
                // Turn on "open at login" with a fresh install; the user can switch it off.
                if ok, self?.opensAtLogin == false { self?.setOpensAtLogin(true) }
            }
        }
    }

    func uninstall() {
        guard let script = Self.uninstallScript else { lastError = "This copy of FocusGuard is missing its uninstaller script."; return }
        retireLegacyRegistrations { [weak self] in
            self?.runAsRoot([script], prompt: "FocusGuard needs your password to remove its background daemon.") { ok in
                if ok { self?.setOpensAtLogin(false) }
            }
        }
    }

    /// `do shell script … with administrator privileges` shows the standard macOS password
    /// dialog and runs the command as root. Run through /usr/bin/osascript so the dialog does not
    /// block the main thread.
    private func runAsRoot(_ command: [String], prompt: String, then: @escaping (Bool) -> Void) {
        guard !working else { return }
        working = true
        lastError = nil
        let shell = (["/bin/bash"] + command).map(Self.shellQuoted).joined(separator: " ")
        let source = "do shell script \(Self.appleScriptQuoted(shell)) with prompt \(Self.appleScriptQuoted(prompt)) with administrator privileges"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        process.terminationHandler = { [weak self] finished in
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            DispatchQueue.main.async {
                guard let self else { return }
                self.working = false
                let ok = finished.terminationStatus == 0
                if !ok, !message.contains("-128") {   // -128: the user clicked Cancel
                    self.lastError = message.trimmingCharacters(in: .whitespacesAndNewlines)
                    AppModel.log.error("privileged step failed: \(message, privacy: .public)")
                }
                self.refresh()
                then(ok)
                // launchd needs a moment to start (or stop) the daemon; one delayed re-probe.
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.refresh() }
            }
        }
        do {
            try process.run()
        } catch {
            working = false
            lastError = "Could not ask for your password: \(error.localizedDescription)"
        }
    }

    nonisolated static func shellQuoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    nonisolated static func appleScriptQuoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    // MARK: Open at login

    func setOpensAtLogin(_ on: Bool) {
        do {
            if on { try loginItem.register() } else { try loginItem.unregister() }
        } catch {
            AppModel.log.error("login item \(on ? "register" : "unregister", privacy: .public): \(error.localizedDescription, privacy: .public)")
            // Unregistering something that is not registered is not worth showing.
            if on { lastError = "Could not add FocusGuard to Login Items: \(error.localizedDescription)" }
        }
        loginItemStatus = loginItem.status
    }

    // MARK: Migration from ≤ 0.3

    /// Up to 0.3 the daemon and a self-relaunching agent were registered with SMAppService from
    /// plists inside the bundle (still shipped, inert, so they can be found and unregistered
    /// here). Drop those registrations before the root-owned install takes the same label.
    /// `unregister` reports back before launchd has finished, hence the pause.
    private func retireLegacyRegistrations(then next: @escaping () -> Void) {
        let legacy = [SMAppService.daemon(plistName: Paths.daemonLabel + ".plist"),
                      SMAppService.agent(plistName: "com.focusguard.app.plist")]
            .filter { $0.status == .enabled || $0.status == .requiresApproval }
        guard !legacy.isEmpty else { next(); return }
        AppModel.log.info("retiring \(legacy.count) SMAppService registration(s) from an older version")
        let group = DispatchGroup()
        for service in legacy {
            group.enter()
            service.unregister { error in
                if let error { AppModel.log.error("legacy unregister: \(error.localizedDescription, privacy: .public)") }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { next() }
        }
    }
}

extension SMAppService.Status {
    var label: String {
        switch self {
        case .notRegistered: return "off"
        case .enabled: return "on"
        case .requiresApproval: return "waiting for approval"
        case .notFound: return "not found"
        @unknown default: return "unknown"
        }
    }
}
