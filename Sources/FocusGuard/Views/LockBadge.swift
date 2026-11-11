import FocusGuardCore
import SwiftUI

/// Shown next to controls that an active Impossible window has disabled.
struct LockBadge: View {
    let until: TimeOfDay?
    var body: some View {
        Label(until.map { "Locked until \($0.string)" } ?? "Locked", systemImage: "lock.fill")
            .font(.caption)
            .foregroundStyle(.secondary)
            .help("An active window with the Impossible unlock mode protects this until it ends.")
    }
}

/// What an active window does to the control group beside it: a lock badge under Impossible, an
/// "Active" shield under Basic/Friction (edits still go through the gate), nothing when no
/// window covers it.
struct ProtectionBadge: View {
    let mode: UnlockMode?
    let until: TimeOfDay?
    var body: some View {
        switch mode {
        case .impossible?:
            LockBadge(until: until)
        case .basic?, .friction?:
            Label("Active", systemImage: "shield.fill").font(.caption).foregroundStyle(.secondary)
                .help("A window covering this is active; weakening it goes through its unlock mode.")
        case nil:
            EmptyView()
        }
    }
}

/// The minus button on a list row: disabled, with the reason as its tooltip, while an active
/// Impossible window protects the row. Block Lists uses it for real; the unlock-mode explainer
/// shows the same view locked, so the preview follows the real control.
struct RemoveButton: View {
    let locked: Bool
    let lockedHelp: String
    let action: () -> Void

    var body: some View {
        Button(role: .destructive, action: action) { Image(systemName: "minus.circle") }
            .buttonStyle(.borderless)
            .disabled(locked)
            .help(locked ? lockedHelp : "Remove")
    }
}
