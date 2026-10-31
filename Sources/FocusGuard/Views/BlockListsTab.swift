import FocusGuardCore
import SwiftUI

struct BlockListsTab: View {
    @Environment(AppModel.self) private var model
    @State private var selection: UUID?

    private var lists: [BlockList] { model.config?.blockLists ?? [] }

    var body: some View {
        NavigationSplitView {
            List(lists, selection: $selection) { list in
                HStack {
                    Text(list.name)
                    Spacer()
                    if model.mode(forList: list.id) != nil { Image(systemName: "shield.fill").foregroundStyle(.secondary) }
                }
                .tag(list.id)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 200)
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 4) {
                    Button { addList() } label: { Image(systemName: "plus") }
                    Button { removeSelected() } label: { Image(systemName: "minus") }
                        .disabled(selection == nil || selection.map { model.mode(forList: $0) == .impossible } == true)
                    Spacer()
                }
                .buttonStyle(.borderless).padding(8)
            }
        } detail: {
            if let id = selection, let list = model.config?.list(id) {
                BlockListDetail(list: list)
            } else {
                ContentUnavailableView("No list selected", systemImage: "list.bullet",
                                       description: Text(lists.isEmpty ? "Click + to create your first block list." : "Pick a list on the left."))
            }
        }
        .disabled(model.config == nil)
        .onAppear { if selection == nil { selection = lists.first?.id } }
    }

    private func addList() {
        let new = BlockList(name: "New list")
        if model.apply({ $0.blockLists.append(new) }) == .applied { selection = new.id }
    }

    private func removeSelected() {
        guard let id = selection else { return }
        model.apply { $0.removeList(id: id) }
    }
}

struct BlockListDetail: View {
    @Environment(AppModel.self) private var model
    let list: BlockList

    @State private var name = ""
    @State private var newDomain = ""
    @State private var showAddApp = false
    /// Bumped on every refused edit; `.id(refused)` rebuilds the form from the saved config.
    @State private var refused = 0

    private var mode: UnlockMode? { model.mode(forList: list.id) }
    private var removalsLocked: Bool { mode == .impossible }

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("List name", text: $name)
                        .onSubmit(commitName)
                        .onChange(of: list.id) { _, _ in name = list.name }
                    if removalsLocked { LockBadge(until: model.lockState.lockedUntil) }
                    else if mode == .friction { Label("Active", systemImage: "shield.fill").font(.caption).foregroundStyle(.secondary) }
                }
            }

            Section("Sites") {
                ForEach(list.domains, id: \.self) { domain in
                    HStack {
                        Text(domain)
                        Spacer()
                        removeButton { commit { $0.update(list: list.id) { $0.domains.removeAll { $0 == domain } } } }
                    }
                }
                HStack {
                    TextField("Add a site, e.g. reddit.com", text: $newDomain).onSubmit(addDomain)
                    Button("Add", action: addDomain).disabled(DomainNormalizer.normalize(newDomain).isEmpty)
                }
            }

            Section("Apps") {
                ForEach(list.appBundleIDs, id: \.self) { id in
                    let entry = InstalledApps.entry(forBundleID: id)
                    HStack {
                        Image(nsImage: entry.icon).resizable().frame(width: 20, height: 20)
                        VStack(alignment: .leading) {
                            Text(entry.name)
                            if entry.name != id { Text(id).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        removeButton { commit { $0.update(list: list.id) { $0.appBundleIDs.removeAll { $0 == id } } } }
                    }
                }
                Button("Add app…") { showAddApp = true }
            }
        }
        .formStyle(.grouped)
        .id(refused)
        .onAppear { name = list.name }
        .sheet(isPresented: $showAddApp) {
            AddAppSheet(alreadyAdded: Set(list.appBundleIDs)) { ids in
                commit { $0.update(list: list.id) { l in
                    for id in ids where !l.appBundleIDs.contains(id) { l.appBundleIDs.append(id) }
                } }
            }
        }
    }

    /// Every mutation goes through here. A refused edit bumps `refused` so the form is rebuilt
    /// from the saved config and the refusal visibly snaps back.
    private func commit(_ edit: @escaping (inout Config) -> Void) {
        switch model.apply(edit) {
        case .applied, .noChange: break
        case .challenge, .locked, .failed: refused += 1
        }
    }

    private func removeButton(_ action: @escaping () -> Void) -> some View {
        Button(role: .destructive, action: action) { Image(systemName: "minus.circle") }
            .buttonStyle(.borderless)
            .disabled(removalsLocked)
            .help(removalsLocked ? model.lockedUntilText : "Remove")
    }

    private func commitName() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { name = list.name; return }
        commit { $0.update(list: list.id) { $0.name = trimmed } }
    }

    private func addDomain() {
        let d = DomainNormalizer.normalize(newDomain)
        guard !d.isEmpty else { return }
        commit { $0.update(list: list.id) { if !$0.domains.contains(d) { $0.domains.append(d) } } }
        newDomain = ""
    }
}
