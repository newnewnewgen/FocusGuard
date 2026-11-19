import SwiftUI

/// A small `?` beside a section title that opens the explanation in a popover. Words that only
/// words can say live here instead of in a grey paragraph under every section.
struct HelpButton: View {
    let text: String
    @State private var shown = false

    var body: some View {
        Button { shown.toggle() } label: {
            Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Help")
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            Text(text).font(.callout).frame(width: 320, alignment: .leading).padding(16)
        }
    }
}

/// Section title with a `?` on the right.
struct SectionTitle: View {
    let title: String
    let help: String
    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            HelpButton(text: help)
        }
    }
}

/// Features that are hidden until switched on in Security → Beta. App-side only: the
/// daemon enforces whatever the config holds whether or not the switch is on.
enum Beta {
    static let chromeExtensionsKey = "beta.chromeExtensions"
}
