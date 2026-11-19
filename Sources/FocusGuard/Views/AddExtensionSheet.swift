import SwiftUI

/// Pick installed Chrome extensions; each adds `chrome-extension://<id>`, the extension's own pages (spec §6).
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
                                       description: Text("Looked in Chrome's profiles on this Mac."))
            } else if shown.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                List(shown, selection: $picked) { ext in
                    HStack {
                        ExtensionIcon(url: ext.iconURL)
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

/// The extension's own icon from its folder, or a generic puzzle piece.
struct ExtensionIcon: View {
    let url: URL?
    var body: some View {
        Group {
            if let url, let img = NSImage(contentsOf: url) {
                Image(nsImage: img).resizable().interpolation(.high)
            } else {
                Image(systemName: "puzzlepiece.extension").resizable().foregroundStyle(.secondary).padding(2)
            }
        }
        .frame(width: 20, height: 20)
    }
}
