import SwiftUI

@main
struct FocusGuardApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra("FocusGuard", systemImage: model.isBlocking ? "shield.fill" : "shield") {
            MenuView().environment(model)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView().environment(model)
        }
    }
}
