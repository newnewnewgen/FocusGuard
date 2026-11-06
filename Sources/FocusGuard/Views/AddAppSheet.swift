import SwiftUI

struct AddAppSheet: View {
    let alreadyAdded: Set<String>
    let onAdd: ([String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var running: [AppEntry] = []
    @State private var installed: [AppEntry] = []
    @State private var scanning = true
    @State private var query = ""
    @State private var picked = Set<String>()
    @State private var manualID = ""

    private var manualTrimmed: String { manualID.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// A bundle ID has at least one dot and no whitespace; anything else is a typo, not an app.
    private var manualValid: Bool {
        manualTrimmed.contains(".") && manualTrimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
    }
    private var shownRunning: [AppEntry] { matching(running) }
    private var shownInstalled: [AppEntry] {
        matching(installed.filter { app in !running.contains { $0.bundleID == app.bundleID } })
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search apps", text: $query).textFieldStyle(.roundedBorder).padding()
            if !scanning, !query.isEmpty, shownRunning.isEmpty, shownInstalled.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                List(selection: $picked) {
                    section("Running", shownRunning)
                    section("Installed", shownInstalled)
                    if scanning {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Scanning…").foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Divider()
            Text("Blocked apps are quit the moment a window starts and whenever they are opened during it. Unsaved work in them is lost.")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding([.horizontal, .top])
            HStack {
                TextField("Other bundle ID, e.g. com.example.app", text: $manualID).textFieldStyle(.roundedBorder)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") {
                    var ids = Array(picked)
                    if manualValid { ids.append(manualTrimmed) }
                    onAdd(ids)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(picked.isEmpty && !manualValid)
            }
            .padding()
        }
        .frame(width: 480, height: 520)
        .onAppear { running = InstalledApps.running() }
        .task {
            // One scan per sheet, off the main thread: bundle plists for a few hundred apps.
            let found = await Task.detached(priority: .userInitiated) { InstalledApps.installed() }.value
            InstalledApps.remember(found)
            installed = found
            scanning = false
        }
    }

    private func matching(_ apps: [AppEntry]) -> [AppEntry] {
        apps.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.bundleID.localizedCaseInsensitiveContains(query) }
    }

    @ViewBuilder
    private func section(_ title: String, _ shown: [AppEntry]) -> some View {
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
