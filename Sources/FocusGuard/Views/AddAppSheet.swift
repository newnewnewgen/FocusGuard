import SwiftUI

struct AddAppSheet: View {
    let alreadyAdded: Set<String>
    let onAdd: ([String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var running: [AppEntry] = []
    @State private var installed: [AppEntry] = []
    @State private var query = ""
    @State private var picked = Set<String>()
    @State private var manualID = ""

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search apps", text: $query).textFieldStyle(.roundedBorder).padding()
            List(selection: $picked) {
                section("Running", running)
                section("Installed", installed.filter { app in !running.contains { $0.bundleID == app.bundleID } })
            }
            Divider()
            HStack {
                TextField("Other bundle ID, e.g. com.example.app", text: $manualID).textFieldStyle(.roundedBorder)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") {
                    var ids = Array(picked)
                    let manual = manualID.trimmingCharacters(in: .whitespaces)
                    if !manual.isEmpty { ids.append(manual) }
                    onAdd(ids)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(picked.isEmpty && manualID.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()
        }
        .frame(width: 480, height: 520)
        .onAppear {
            // One scan, when the sheet opens. Never in the background.
            running = InstalledApps.running()
            installed = InstalledApps.installed()
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ apps: [AppEntry]) -> some View {
        let shown = apps.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.bundleID.localizedCaseInsensitiveContains(query) }
        if !shown.isEmpty {
            Section(title) {
                ForEach(shown) { app in
                    HStack {
                        Image(nsImage: app.icon).resizable().frame(width: 24, height: 24)
                        VStack(alignment: .leading) {
                            Text(app.name)
                            Text(app.bundleID).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if alreadyAdded.contains(app.bundleID) { Text("Added").font(.caption).foregroundStyle(.secondary) }
                    }
                    .tag(app.bundleID)
                    .selectionDisabled(alreadyAdded.contains(app.bundleID))
                }
            }
        }
    }
}
