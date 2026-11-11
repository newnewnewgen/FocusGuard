import SwiftUI

/// Pick installed Chrome extensions; each adds `chrome-extension://<id>/*` and
/// `chrome://extensions/*` — the page where the extension could be disabled (spec §6).
struct AddExtensionSheet: View {
    /// Patterns the list already holds.
    let alreadyAdded: Set<String>
    let onAdd: ([String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var extensions: [ChromeExtension] = []
    @State private var scanning = true
    @State private var query = ""
    @State private var picked = Set<String>()

    private var shown: [ChromeExtension] {
        extensions.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.id.localizedCaseInsensitiveContains(query) }
    }
    private func fullyAdded(_ ext: ChromeExtension) -> Bool { ext.patterns.allSatisfy(alreadyAdded.contains) }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search extensions", text: $query).textFieldStyle(.roundedBorder).padding()
            if scanning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading Chrome's extensions…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if extensions.isEmpty {
                ContentUnavailableView("No Chrome extensions found", systemImage: "puzzlepiece.extension",
                                       description: Text("Looked in ~/Library/Application Support/Google/Chrome/*/Extensions. You can still type a pattern in the list."))
            } else if shown.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                List(shown, selection: $picked) { ext in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(ext.name)
                            Text(ext.id).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if fullyAdded(ext) { Text("Added").font(.caption).foregroundStyle(.secondary) }
                    }
                    .tag(ext.id)
                    .selectionDisabled(fullyAdded(ext))
                }
            }
            Divider()
            Text("Each extension adds two patterns: its own pages (chrome-extension://<id>/*) and chrome://extensions/*, which also blocks the page where the extension could be disabled.")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding([.horizontal, .top])
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") {
                    onAdd(picked.sorted().flatMap(ChromeExtensions.patterns(forExtensionID:)))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(picked.isEmpty)
            }
            .padding()
        }
        .frame(width: 480, height: 440)
        .task {
            // One scan per sheet, off the main thread: a manifest and a messages file per extension.
            let found = await Task.detached(priority: .userInitiated) { ChromeExtensions.installed() }.value
            extensions = found
            scanning = false
        }
    }
}
