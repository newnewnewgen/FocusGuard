import FocusGuardCore
import SwiftUI

@main
struct FocusGuardApp: App {
    @NSApplicationDelegateAdaptor(ReopenHandler.self) private var reopen
    @State private var model = AppModel()
    @State private var dock = DockFallback()
    /// Decided once at launch: until protection is installed, a launch opens the settings window
    /// by itself (nothing to click otherwise if the menu-bar icon is hidden). Once the daemon is
    /// installed, launches are silent, as a login item should be.
    private let installedAtLaunch = FileManager.default.fileExists(atPath: Paths.daemonPlist)

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
            SettingsView().environment(model).environment(dock)
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

    /// Put the settings window in front of everything, whatever state it is in. `openWindow`
    /// alone is not enough for a menu-bar app: nothing activates us, so an already-open window
    /// stays behind other apps (or minimised, or on another Space) and the click looks dead.
    /// `activate(ignoringOtherApps:)` rather than the cooperative `activate()`, which macOS may
    /// decline for an app the user was not just using.
    @MainActor static func bringSettingsToFront() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where isSettingsWindow(window) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        }
    }

    @MainActor static func isSettingsWindow(_ window: NSWindow) -> Bool {
        window.identifier?.rawValue.contains(settingsWindowID) == true
            || (window.title == "FocusGuard" && window.styleMask.contains(.titled))
    }

    /// Open (or re-front) the settings window from a menu action. The second pass runs after
    /// SwiftUI has created the window when it did not exist yet.
    @MainActor static func showSettings(_ openWindow: OpenWindowAction) {
        openWindow(id: settingsWindowID)
        bringSettingsToFront()
        DispatchQueue.main.async { bringSettingsToFront() }
    }
}

/// Clicking the app in Finder, Spotlight or the Dock while it is already running opens the
/// settings window (or brings it forward); without this an LSUIElement app silently does nothing
/// on reopen. Unconditional: `hasVisibleWindows` also counts the status-item window.
final class ReopenHandler: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        NSWorkspace.shared.open(FocusGuardApp.settingsURL)
        DispatchQueue.main.async { FocusGuardApp.bringSettingsToFront() }
        return false
    }
}
