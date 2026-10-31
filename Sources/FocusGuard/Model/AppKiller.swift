import AppKit
import os

/// Event-driven app kill in the user session. `didLaunchApplicationNotification` arrives within
/// tens of milliseconds of launch; `terminate()` is a polite quit, escalated to `forceTerminate()`
/// from a one-shot 3 s timer. The daemon's 2 s libproc sweep remains the backstop.
final class AppKiller {
    private let blocked: () -> Set<String>
    private var observer: NSObjectProtocol?
    private let log = Logger(subsystem: "com.focusguard", category: "kill")

    init(blocked: @escaping () -> Set<String>) {
        self.blocked = blocked
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.enforce(app, reason: "launch")
        }
    }

    /// Called when a window becomes active so already-running blocked apps die at once.
    func sweep() {
        for app in NSWorkspace.shared.runningApplications { enforce(app, reason: "sweep") }
    }

    private func enforce(_ app: NSRunningApplication, reason: String) {
        guard let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier,
              blocked().contains(id) else { return }
        let ms = app.launchDate.map { Int(Date().timeIntervalSince($0) * 1000) } ?? -1
        log.info("terminate \(id, privacy: .public) pid=\(app.processIdentifier) reason=\(reason, privacy: .public) sinceLaunch=\(ms)ms")
        if !app.terminate() { _ = app.forceTerminate() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [log] in
            if !app.isTerminated {
                log.info("forceTerminate \(id, privacy: .public) pid=\(app.processIdentifier)")
                _ = app.forceTerminate()
            }
        }
    }
}
