import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView {
            StatusTab().tabItem { Label("Status", systemImage: "shield") }
            BlockListsTab().tabItem { Label("Block Lists", systemImage: "list.bullet") }
            ScheduleTab().tabItem { Label("Schedule", systemImage: "calendar") }
        }
        .frame(minWidth: 640, minHeight: 460)
        // onDismiss: a Setup presentation deferred while the challenge was up (see
        // `presentSetupIfNeeded`) is retried once the challenge sheet is actually gone.
        .sheet(item: $model.pendingChallenge, onDismiss: { model.presentSetupIfNeeded() }) { challenge in
            ChallengeSheet(challenge: challenge) { model.pendingChallenge = nil }
        }
        // The window opens at launch until protection is installed (`FocusGuardApp.settingsWindow`);
        // this is what turns that launch into the Setup sheet.
        .sheet(isPresented: $model.setupSheetPresented) { SetupSheet() }
        .alert("Locked", isPresented: Binding(get: { model.lockedMessage != nil }, set: { if !$0 { model.lockedMessage = nil } })) {
            Button("OK") { model.lockedMessage = nil }
        } message: {
            Text(model.lockedMessage ?? "")
        }
        .onAppear { FocusGuardApp.bringSettingsToFront(); model.presentSetupIfNeeded() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.presentSetupIfNeeded() }
        // A second `open focusguard://settings` (Spotlight, Dock, Terminal) lands here when the
        // window already exists; front it rather than leaving it wherever it was.
        .onOpenURL { _ in FocusGuardApp.bringSettingsToFront() }
    }
}
