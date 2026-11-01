import SwiftUI

@main
struct FocusGuardApp: App {
    @NSApplicationDelegateAdaptor(ReopenHandler.self) private var reopen
    @State private var model = AppModel()
    /// Decided once at launch: a fresh install opens the settings window by itself (a menu-bar-only
    /// app whose icon sits behind the notch would otherwise give a first-time user nothing to
    /// click). Once the daemon is enabled, launches are silent, as a login item should be.
    private let installedAtLaunch: Bool = {
        let installer = Installer()
        installer.refresh()
        return installer.daemonStatus == .enabled
    }()

    var body: some Scene {
        settingsWindow
        MenuBarExtra("FocusGuard", systemImage: model.isBlocking ? "shield.fill" : "shield") {
            MenuView().environment(model)
        }
        .menuBarExtraStyle(.menu)
    }

    /// A plain `Window` rather than the `Settings` scene: it can be opened with `openWindow` and
    /// presented at launch, neither of which the Settings scene allows.
    private var settingsWindow: some Scene {
        Window("FocusGuard", id: Self.settingsWindowID) {
            SettingsView().environment(model)
        }
        .windowResizability(.contentSize)
        // `open focusguard://settings` (and a reopen of the app) brings this window up even when
        // the menu-bar icon is hidden behind the notch. LaunchServices routes the URL by bundle
        // ID, so with a second copy on disk (build/FocusGuard.app during development) it may go
        // to the other copy.
        .handlesExternalEvents(matching: [Self.settingsURLHost])
        // macOS 15 API (hence the deployment target): without it the window would open on
        // every login-item and KeepAlive launch.
        .defaultLaunchBehavior(installedAtLaunch ? .suppressed : .presented)
        .restorationBehavior(.disabled)
    }

    static let settingsWindowID = "settings"
    static let settingsURLHost = "settings"
    static let settingsURL = URL(string: "focusguard://settings")!
}

/// Clicking the app in Finder or the Dock while it is already running opens the settings
/// window; without this an LSUIElement app silently does nothing on reopen.
final class ReopenHandler: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { NSWorkspace.shared.open(FocusGuardApp.settingsURL) }
        return false
    }
}
