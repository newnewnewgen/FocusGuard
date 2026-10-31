import SwiftUI

@main
struct FocusGuardApp: App {
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
        let window = Window("FocusGuard", id: Self.settingsWindowID) {
            SettingsView().environment(model)
        }
        .windowResizability(.contentSize)
        if #available(macOS 15, *) {
            return window
                .defaultLaunchBehavior(installedAtLaunch ? .suppressed : .presented)
                .restorationBehavior(.disabled)
        } else {
            return window
        }
    }

    static let settingsWindowID = "settings"
}
