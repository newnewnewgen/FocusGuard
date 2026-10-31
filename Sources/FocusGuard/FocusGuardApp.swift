import SwiftUI

@main
struct FocusGuardApp: App {
    var body: some Scene {
        MenuBarExtra("FocusGuard", systemImage: "shield") {
            Button("Quit FocusGuard") { NSApp.terminate(nil) }.keyboardShortcut("q")
        }
    }
}
