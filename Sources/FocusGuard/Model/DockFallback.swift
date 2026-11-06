import AppKit
import Observation

/// A menu-bar-only app is unreachable when macOS does not draw its status item, which it silently
/// stops doing when the menu bar is full (routinely so on a notched MacBook: the item is laid out
/// behind the notch). This asks the window server whether our item is actually on screen and, if
/// not, turns the app into a regular Dock app so there is always something to click.
///
/// Sticky by design: which items fit depends on the frontmost app's menus, so visibility flips as
/// the user switches apps. Once the icon has been seen hidden the Dock icon stays (remembered
/// across launches) until the user turns it off in Settings → Status.
///
/// Event-driven only: one check shortly after launch, then on occlusion, screen and activation
/// changes. Nothing polls, and the observers are dropped once the Dock icon is showing.
@MainActor @Observable
final class DockFallback {
    static let defaultsKey = "showInDock"

    /// The last probe found the status item off screen.
    private(set) var menuBarIconHidden = false
    /// Mirrors the stored preference so views update when the fallback flips it.
    private(set) var showsInDock: Bool

    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init() {
        showsInDock = UserDefaults.standard.bool(forKey: Self.defaultsKey)
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            NSWindow.didChangeOcclusionStateNotification,
            NSApplication.didChangeScreenParametersNotification,
            NSApplication.didBecomeActiveNotification,
        ]
        for name in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.check() }
            })
        }
        // The status item does not exist until SwiftUI has built the scene.
        DispatchQueue.main.async { [weak self] in self?.applyPolicy() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.check() }
    }

    /// User toggle. Turning it off while the icon is hidden is allowed: the window stays reachable
    /// through Spotlight and `open focusguard://settings`, and the next hidden probe turns it back on.
    func setShowsInDock(_ on: Bool) {
        showsInDock = on
        UserDefaults.standard.set(on, forKey: Self.defaultsKey)
        applyPolicy()
    }

    func check() {
        guard let onScreen = Self.statusItemIsOnScreen() else { return }
        menuBarIconHidden = !onScreen
        guard menuBarIconHidden, !showsInDock else { return }
        AppModel.log.info("menu-bar icon is not on screen; showing in the Dock instead")
        setShowsInDock(true)
    }

    private func applyPolicy() {
        let wanted: NSApplication.ActivationPolicy = showsInDock ? .regular : .accessory
        if NSApp.activationPolicy() != wanted { NSApp.setActivationPolicy(wanted) }
    }

    /// nil when we have no status-item window yet. `kCGStatusWindowLevel` is 25.
    static func statusItemIsOnScreen() -> Bool? {
        guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let pid = getpid()
        let items = list.filter {
            ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == 25
        }
        guard !items.isEmpty else { return nil }
        return items.contains { ($0[kCGWindowIsOnscreen as String] as? Bool) == true }
    }
}
