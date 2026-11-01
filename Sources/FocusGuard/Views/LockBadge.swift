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
