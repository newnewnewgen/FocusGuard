import SwiftUI

struct MenuView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if model.isBlocking {
            Text(activeLine)
            Text("\(model.activeSet.domains.count) sites, \(model.activeSet.bundleIDs.count) apps blocked")
        } else {
            Text("Not blocking")
        }
        if let next = model.nextBoundary {
            Text("Next: \(nextLabel) at \(next, format: .dateTime.weekday(.abbreviated).hour().minute())")
        }
        if model.loadError != nil {
            Text("⚠︎ config.json is unreadable")
        }
        Divider()
        SettingsLink { Text("Open Settings…") }.keyboardShortcut(",")
        Button("Quit FocusGuard (and stop at login)") {
            if model.quitNeedsSettingsWindow { openSettings() }
            model.requestQuit()
        }.keyboardShortcut("q")
    }

    private var activeLine: String {
        let names = model.activeWindowNames.joined(separator: ", ")
        let until = model.lockState.lockedUntil.map { " · until \($0.string)" } ?? ""
        return "● \(names.isEmpty ? "Blocking" : names)\(until)"
    }

    private var nextLabel: String {
        model.nextWindowNames.isEmpty ? "release" : model.nextWindowNames.joined(separator: ", ")
    }
}
