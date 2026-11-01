import AppKit
import os

/// Event-driven app kill in the user session. `didLaunchApplicationNotification` arrives within
/// tens of milliseconds of launch; `terminate()` is a polite quit, escalated to `forceTerminate()`
/// from a one-shot 3 s timer. The daemon's 2 s libproc sweep remains the backstop.
@MainActor
final class AppKiller {
    private let blocked: () -> Set<String>
    private var observer: NSObjectProtocol?
    private let log = Logger(subsystem: "com.focusguard", category: "kill")

    deinit {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    init(blocked: @escaping () -> Set<String>) {
        self.blocked = blocked
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            // Delivered on `.main` (queue above); the compiler cannot see that.
            MainActor.assumeIsolated { self?.enforce(app, reason: "launch") }
        }
    }

    /// Runs on every refresh with a non-empty active set (boundary, config change, wake) so
    /// already-running blocked apps die at once.
    func sweep() {
        for app in NSWorkspace.shared.runningApplications { enforce(app, reason: "sweep") }
    }

    private func enforce(_ app: NSRunningApplication, reason: String) {
        guard let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier,
              blocked().contains(id) else { return }
        let ms = app.launchDate.map { Int(Date().timeIntervalSince($0) * 1000) } ?? -1
        log.info("terminate \(id, privacy: .public) pid=\(app.processIdentifier) reason=\(reason, privacy: .public) sinceLaunch=\(ms)ms")
        // An app that is still launching ignores the polite quit (observed: Chess took the full
        // 3 s escalation), and it has nothing to save yet, so a fresh launch is killed outright.
        // A long-running app caught by a sweep gets the polite quit first. Force-killing a fresh
        // launch can leave a stale lock file behind (Chrome SingletonLock), the same risk the
        // daemon's SIGKILL already carries.
        if reason == "launch" || !app.isFinishedLaunching {
            if !app.forceTerminate() { _ = app.terminate() }
        } else if !app.terminate() {
            _ = app.forceTerminate()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [log] in
            if !app.isTerminated {
                log.info("forceTerminate \(id, privacy: .public) pid=\(app.processIdentifier)")
                _ = app.forceTerminate()
            }
        }
    }
}
