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
        .sheet(item: $model.pendingChallenge) { challenge in
            ChallengeSheet(challenge: challenge) { model.pendingChallenge = nil }
        }
        .alert("Locked", isPresented: Binding(get: { model.lockedMessage != nil }, set: { if !$0 { model.lockedMessage = nil } })) {
            Button("OK") { model.lockedMessage = nil }
        } message: {
            Text(model.lockedMessage ?? "")
        }
        .onAppear { FocusGuardApp.bringSettingsToFront() }
        // A second `open focusguard://settings` (Spotlight, Dock, Terminal) lands here when the
        // window already exists; front it rather than leaving it wherever it was.
        .onOpenURL { _ in FocusGuardApp.bringSettingsToFront() }
    }
}
