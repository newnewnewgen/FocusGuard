import FocusGuardCore
import SwiftUI

/// The one thing FocusGuard needs to work: the background blocker. Presented over the settings
/// window whenever `SetupNeed.shouldPresent` says the blocker is unhealthy and the user has not
/// clicked "Not now" on this exact state — at launch and each time the app becomes active — and
/// on demand from Security → "Setup…". Login and Dock are app preferences (Security → App), and
/// keyword and Chrome problems are notices there; neither is setup.
struct SetupSheet: View {
    @Environment(AppModel.self) private var model
    @State private var closeTask: Task<Void, Never>?

    private var inst: Installer { model.installer }
    private var protectionHealthy: Bool { !inst.working && SetupNeed.evaluate(inst.setupFlags) == nil }
    private var allGreen: Bool { protectionHealthy }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Set up FocusGuard").font(.headline)
            VStack(alignment: .leading, spacing: 10) {
                daemonRow(inst)
                if let err = inst.lastError { Text(err).foregroundStyle(.red).font(.callout) }
            }
            HStack {
                Spacer()
                // The exit while protection is unhealthy (a cancelled password prompt, a failed
                // install, a dev build run from `build/`): the window stays usable, Security keeps
                // its orange row, and the sheet comes back on its own only if something changes.
                Button("Not now") { model.snoozeSetup() }.keyboardShortcut(.cancelAction)
                Button("Done") { close() }.keyboardShortcut(.defaultAction).disabled(!protectionHealthy)
            }
        }
        .padding(20)
        .frame(width: 480)
        // Closes itself 1.5 s after the blocker turns green — only on a transition while it is
        // open, so a sheet opened from "Setup…" in a healthy state stays put.
        .onChange(of: allGreen) { _, green in
            closeTask?.cancel()
            guard green else { return }
            closeTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.5))
                if !Task.isCancelled { close() }
            }
        }
        .onDisappear { closeTask?.cancel() }
    }

    private func close() { model.setupSheetPresented = false }

    @ViewBuilder
    private func daemonRow(_ inst: Installer) -> some View {
        if inst.working {
            row(done: false, "Waiting for your password…")
        } else if inst.legacyDaemonRunning {
            row(done: false, SetupNeed.Reason.legacyDaemon.title,
                detail: "Moves the blocker somewhere other programs can't change it. Your lists and schedule are kept.") {
                Button("Reinstall…") { inst.install() }
            }
        } else if !inst.daemonInstalled {
            row(done: false, SetupNeed.Reason.notInstalled.title,
                detail: "The blocker keeps working even when this app is closed. Asks for your password once.") {
                Button("Install…") { inst.install() }
            }
        } else if inst.needsUpdate {
            row(done: false, SetupNeed.Reason.needsUpdate.title,
                detail: "This version of the app comes with a newer blocker. Asks for your password once.") {
                Button("Update…") { inst.install() }
            }
        } else if inst.daemonRunning {
            row(done: true, "Background blocker running",
                detail: "Sites and apps are blocked on schedule, even when this app is closed.")
        } else {
            row(done: false, SetupNeed.Reason.notRunning.title,
                detail: "Reinstalling starts it again.") {
                Button("Reinstall…") { inst.install() }
            }
        }
    }

    private func row(done: Bool, _ title: String, detail: String? = nil) -> some View {
        row(done: done, title, detail: detail) { EmptyView() }
    }

    private func row<Action: View>(done: Bool, _ title: String, detail: String?, @ViewBuilder action: () -> Action) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail, !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            action()
        }
    }
}
