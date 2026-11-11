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
        if model.apply({ $0.removeList(id: id) }) == .applied { selection = lists.first?.id }
    }
}

struct BlockListDetail: View {
    @Environment(AppModel.self) private var model
    let list: BlockList

    @State private var name = ""
    @State private var newDomain = ""
    @State private var newKeyword = ""
    @State private var newMatch: KeywordRule.Match = .contains
    @State private var keywordHint: String?
    @State private var newAllow = ""
    @State private var allowHint: String?
    @State private var showAddApp = false
    @State private var newChromeURL = ""
    @State private var chromeHint: String?
    @State private var showAddExtension = false
    @State private var bulkKind: BulkAddSheet.Kind?
    @FocusState private var nameFocused: Bool
    /// Bumped on every refused edit; `.id(refused)` rebuilds the form from the saved config.
    @State private var refused = 0

    private var mode: UnlockMode? { model.mode(forList: list.id) }
    private var removalsLocked: Bool { mode == .impossible }

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("List name", text: $name)
                        .focused($nameFocused)
                        .onSubmit(commitName)
                        .onChange(of: nameFocused) { _, focused in if !focused { commitName() } }
                        .onChange(of: list.id) { _, _ in name = list.name; newDomain = ""; newChromeURL = "" }
                        .onChange(of: list.name) { _, n in name = n }
                    ProtectionBadge(mode: mode, until: model.lockState.lockedUntil)
                }
            }

            Section("Sites") {
                ForEach(unique(list.domains), id: \.self) { domain in
                    HStack {
                        Text(domain)
                        Spacer()
                        removeButton { commit { $0.update(list: list.id) { $0.domains.removeAll { $0 == domain } } } }
                    }
                }
                // Adding is never gated by an unlock mode; only an empty field disables the button.
                AddRow("Add a site, e.g. reddit.com", text: $newDomain, onSubmit: addDomain) {
                } accessory: {
                    Button("Add many\u{2026}") { bulkKind = .sites }
                }
                if let hint = domainHint {
                    Text(hint).font(.caption).foregroundStyle(.red)
                }
            }

            Section {
                ForEach(uniqueRules(list.keywords)) { rule in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(rule.text).font(.system(.body, design: .monospaced))
                            Picker("", selection: Binding(
                                get: { rule.match },
                                set: { m in commit { $0.update(list: list.id) { l in
                                    if let i = l.keywords.firstIndex(where: { $0.id == rule.id }) { l.keywords[i].match = m }
                                } } }
                            )) {
                                ForEach(KeywordRule.Match.allCases, id: \.self) { Text($0.title).tag($0) }
                            }
                            .labelsHidden().frame(width: 130)
                            .disabled(removalsLocked)
                            Spacer()
                            removeButton { commit { $0.update(list: list.id) { $0.keywords.removeAll { $0.id == rule.id } } } }
                        }
                        let caught = model.learnedNames(for: rule)
                        Text(caught.isEmpty ? "Blocked so far: none yet"
                             : "Blocked so far: " + caught.prefix(10).joined(separator: ", ") + (caught.count > 10 ? " +\(caught.count - 10) more" : ""))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                AddRow("Add a keyword, e.g. manga", text: $newKeyword, onSubmit: addKeyword) {
                    Picker("", selection: $newMatch) {
                        ForEach(KeywordRule.Match.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().frame(width: 130)
                } accessory: {
                    Button("Add many\u{2026}") { bulkKind = .keywords }
                }
                if let hint = keywordHint { Text(hint).font(.caption).foregroundStyle(.red) }
            } header: {
                Text("Keywords")
            } footer: {
                Text("Matches site names only (mangadex.org, not reddit.com/r/manga). Sites are learned as your Mac looks them up and blocked from then on. Whole word, starts with and ends with look at the parts of the name between dots and hyphens.")
            }

            Section("Apps") {
                ForEach(unique(list.appBundleIDs), id: \.self) { id in
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

            Section {
                ForEach(unique(list.chromeURLs), id: \.self) { pattern in
                    HStack {
                        Text(pattern).font(.system(.body, design: .monospaced))
                            .lineLimit(1).truncationMode(.middle).help(pattern)
                        Spacer()
                        removeButton { commit { $0.update(list: list.id) { $0.chromeURLs.removeAll { $0 == pattern } } } }
                    }
                }
                AddRow("chrome-extension://\u{2026} or chrome://extensions/*", text: $newChromeURL, onSubmit: addChromeURL) {
                } accessory: {
                    Button("Add extension\u{2026}") { showAddExtension = true }
                    Button("Add many\u{2026}") { bulkKind = .chromeURLs }
                }
                if let hint = chromeHint { Text(hint).font(.caption).foregroundStyle(.red) }
            } header: {
                Text("Chrome pages")
            } footer: {
                Text("Blocks pages inside Chrome itself. Chrome shows them as blocked by an administrator. Other browsers are not affected.")
            }

            Section {
                ForEach(unique(model.config?.alwaysAllow ?? []), id: \.self) { site in
                    HStack {
                        Text(site)
                        Spacer()
                        // Removing an allow entry only ever blocks more, so it is never locked.
                        Button(role: .destructive) { commit { $0.alwaysAllow.removeAll { $0 == site } } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                AddRow("Never block this site, e.g. mangalore.in", text: $newAllow, buttonTitle: "Allow", onSubmit: addAllow)
                if let hint = allowHint { Text(hint).font(.caption).foregroundStyle(.red) }
            } header: {
                Text("Always allow (all lists)")
            } footer: {
                Text("Keyword rules never block these sites or their subdomains. Sites you list by name are still blocked. Adding an entry while a keyword window is active counts as loosening it.")
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
        .sheet(isPresented: $showAddExtension) {
            AddExtensionSheet(alreadyAdded: Set(list.chromeURLs)) { patterns in
                commit { $0.update(list: list.id) { l in
                    for p in patterns where !l.chromeURLs.contains(p) { l.chromeURLs.append(p) }
                } }
            }
        }
        .sheet(item: $bulkKind) { kind in
            let lists = model.config?.blockLists ?? []
            switch kind {
            case .sites:
                BulkAddSheet(kind: .sites, listName: list.name, existing: Set(list.domains),
                             totalInConfig: lists.reduce(0) { $0 + $1.domains.count }) { sites, _ in
                    // One commit for the whole batch: one config write, one lock judgment.
                    commit { $0.update(list: list.id) { l in
                        for d in sites where !l.domains.contains(d) { l.domains.append(d) }
                    } }
                }
            case .keywords:
                BulkAddSheet(kind: .keywords, listName: list.name, existing: Set(list.keywords.map(\.itemKey)),
                             totalInConfig: lists.reduce(0) { $0 + $1.keywords.count }) { words, match in
                    commit { $0.update(list: list.id) { l in
                        for w in words {
                            let rule = KeywordRule(text: w, match: match)
                            if !l.keywords.contains(where: { $0.itemKey == rule.itemKey }) { l.keywords.append(rule) }
                        }
                    } }
                }
            case .chromeURLs:
                BulkAddSheet(kind: .chromeURLs, listName: list.name, existing: Set(list.chromeURLs),
                             totalInConfig: lists.reduce(0) { $0 + $1.chromeURLs.count }) { patterns, _ in
                    commit { $0.update(list: list.id) { l in
                        for p in patterns where !l.chromeURLs.contains(p) { l.chromeURLs.append(p) }
                    } }
                }
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

    /// Display order preserved, duplicates dropped: `ForEach(id: \.self)` needs unique IDs even
    /// if a hand-edited config.json repeats an entry.
    private func unique(_ items: [String]) -> [String] {
        var seen = Set<String>()
        return items.filter { seen.insert($0).inserted }
    }

    private func uniqueRules(_ rules: [KeywordRule]) -> [KeywordRule] {
        var seen = Set<UUID>()
        return rules.filter { seen.insert($0.id).inserted }
    }

    private func commitName() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { name = list.name; return }
        guard trimmed != list.name else { return }
        commit { $0.update(list: list.id) { $0.name = trimmed } }
    }

    @State private var domainHint: String?

    private func addDomain() {
        let typed = newDomain.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else { return }
        let d = DomainNormalizer.normalize(typed)
        guard !d.isEmpty else {
            domainHint = "\u{201C}\(typed)\u{201D} is not a web address. Use the site\u{2019}s domain, like youtube.com (subdomains are blocked with it)."
            return
        }
        domainHint = nil
        commit { $0.update(list: list.id) { if !$0.domains.contains(d) { $0.domains.append(d) } } }
        newDomain = ""
    }

    private func addKeyword() {
        let typed = newKeyword
        guard let text = KeywordRule.normalize(typed) else {
            keywordHint = "A keyword is one word of 2–63 letters, digits or hyphens, like manga or read-manga."
            return
        }
        keywordHint = nil
        let rule = KeywordRule(text: text, match: newMatch)
        commit { $0.update(list: list.id) { l in if !l.keywords.contains(where: { $0.itemKey == rule.itemKey }) { l.keywords.append(rule) } } }
        newKeyword = ""
    }

    private func addChromeURL() {
        let typed = newChromeURL.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else { return }
        guard let pattern = ChromeURLPattern.normalize(typed) else {
            chromeHint = "\u{201C}\(typed)\u{201D} is not a Chrome URL pattern. Use a full address like chrome://extensions/* or chrome-extension://<id>/*, or a site like example.com \u{2014} no spaces, at most \(ChromeURLPattern.maxLength) characters."
            return
        }
        chromeHint = nil
        commit { $0.update(list: list.id) { if !$0.chromeURLs.contains(pattern) { $0.chromeURLs.append(pattern) } } }
        newChromeURL = ""
    }

    private func addAllow() {
        let typed = newAllow.trimmingCharacters(in: .whitespaces)
        let site = DomainNormalizer.normalize(typed)
        guard !site.isEmpty else {
            allowHint = "\u{201C}\(typed)\u{201D} is not a web address. Use the site\u{2019}s domain, like mangalore.in."
            return
        }
        allowHint = nil
        commit { if !$0.alwaysAllow.contains(site) { $0.alwaysAllow.append(site) } }
        newAllow = ""
    }
}
