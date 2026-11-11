import SwiftUI

/// The drop target for the eye under the last window (UI polish spec §2): a dashed outline with
/// a plus and the window it would add, faint until the pointer is over it. With no windows at
/// all it is drawn at full opacity permanently and carries the caption that used to be the
/// empty-state text; with no block list it is disabled and says why.
struct GhostWindowRow: View {
    let caption: String?
    let enabled: Bool
    /// Always fully visible (the empty state) rather than only on hover.
    let permanent: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: action) {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle")
                    Text("New window · Mon–Fri 09:00–12:00")
                    Spacer()
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(.secondary, style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .accessibilityLabel("Add window")
            if let caption {
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
        }
        .opacity(permanent || hovering ? 1 : 0.35)
        .animation(.easeInOut(duration: 0.15), value: hovering)
        .onHover { hovering = $0 }
    }
}
