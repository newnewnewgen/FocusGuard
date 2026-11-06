import SwiftUI

struct MenuView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if model.isBlocking {
            Text(activeLine)
            Text("\(model.activeSet.domains.count) sites, \(model.activeSet.bundleIDs.count) apps blocked")
        } else {
            Text("Not blocking")
        }
        if let next = model.nextBoundary {
            let when = Text(next, format: .dateTime.weekday(.abbreviated).hour().minute())
            if model.nextWindowNames.isEmpty {
                Text("Blocking ends \(when)")
            } else {
                Text("Next: \(model.nextWindowNames.joined(separator: ", ")) at \(when)")
            }
        }
        if model.loadError != nil {
            Text("⚠︎ config.json is unreadable")
        }
        Divider()
        Button("Open Settings…") { FocusGuardApp.showSettings(openWindow) }.keyboardShortcut(",")
        Button("Quit FocusGuard (and stop at login)") {
            if model.quitNeedsSettingsWindow {
                // The challenge sheet / locked alert attach to the settings window; let it exist
                // (and be in front) before the gate presents them.
                FocusGuardApp.showSettings(openWindow)
                DispatchQueue.main.async { model.requestQuit() }
            } else {
                model.requestQuit()
            }
        }.keyboardShortcut("q")
    }

    private var activeLine: String {
        let names = model.activeWindowNames.joined(separator: ", ")
        let until = model.lockState.lockedUntil.map { " · until \($0.string)" } ?? ""
        return "● \(names.isEmpty ? "Blocking" : names)\(until)"
    }
}
