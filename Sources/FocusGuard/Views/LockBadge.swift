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
