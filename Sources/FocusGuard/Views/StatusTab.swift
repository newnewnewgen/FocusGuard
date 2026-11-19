import FocusGuardCore
import SwiftUI

/// The Security tab: the app-wide unlock mode, what is blocked now, notices, and app settings.
struct SecurityTab: View {
    @Environment(AppModel.self) private var model
    @Environment(DockFallback.self) private var dock
    @AppStorage(Beta.chromeExtensionsKey) private var chromeExtensionsBeta = false
    @State private var showModeHelp = false
    /// Bumped on a refused mode change so the segmented control snaps back to the saved value.
    @State private var refused = 0

    var body: some View {
        Form {
            // A broken state is never silent: one orange row pointing at the Setup sheet (spec §3).
            if let first = problems.first { problemSection(first, more: problems.count - 1) }
            if model.daemonIsHolding || model.clockTampered || model.zoneHeldBack != nil || model.canRestoreConfig
                || keywordProblem != nil || chromeProblem != nil { noticeSection }

            Section {
                HStack {
                    Picker("Unlock mode", selection: Binding(
                        get: { model.config?.unlockMode ?? .basic },
                        set: { m in
                            switch model.apply({ $0.unlockMode = m }) {
                            case .applied, .noChange: break
                            case .challenge, .locked, .failed: refused += 1
                            }
                        }
                    )) {
                        ForEach(UnlockMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().id(refused)
                    // Learning only; stays enabled under Impossible.
                    Button { showModeHelp = true } label: { Image(systemName: "info.circle") }
                        .buttonStyle(.borderless)
                        .help("What the unlock modes do")
                        .popover(isPresented: $showModeHelp, arrowEdge: .bottom) { UnlockModeHelp(mode: model.config?.unlockMode ?? .basic) }
                }
                Text(modeCaption).font(.caption).foregroundStyle(.secondary)
            } header: {
                SectionTitle(title: "Unlock mode",
                             help: "While any window is active, this is what it takes to give yourself more access: removing a site, app, keyword or extension, turning a window off, ending it early, deleting a list, allowing a site, or lowering this mode. Adding blocks and raising the mode are always allowed. When no window is active, everything can be changed.")
            }

            Section("Now") {
                if model.isBlocking {
                    LabeledContent("Active", value: model.activeWindowNames.joined(separator: ", "))
                    if let until = model.lockState.lockedUntil { LabeledContent("Until", value: until.string) }
                    LabeledContent("Blocking", value: "\(model.activeSet.domains.count) sites, \(model.activeSet.bundleIDs.count) apps"
                                   + (model.activeSet.chromeURLs.isEmpty || !chromeExtensionsBeta ? "" : ", \(model.activeSet.chromeURLs.count) Chrome extensions"))
                } else {
                    LabeledContent("Active", value: "Nothing")
                }
                if let next = model.nextBoundary {
                    LabeledContent("Next change", value: next.formatted(.dateTime.weekday(.wide).hour().minute()))
                }
                if let err = model.loadError { Text(err).foregroundStyle(.red).font(.callout) }
                if let err = model.saveError { Text(err).foregroundStyle(.red).font(.callout) }
            }

            Section("App") {
                Toggle(isOn: Binding(get: { model.installer.opensAtLogin }, set: { model.installer.setOpensAtLogin($0) })) {
                    Text("Open FocusGuard at login")
                    Text("So blocking is set up every time you start your Mac.")
                }
                Toggle(isOn: Binding(get: { dock.showsInDock }, set: { dock.setShowsInDock($0) })) {
                    Text("Show in Dock")
                    Text(dock.menuBarIconHidden
                         ? "Your menu bar is full, so the shield icon is hidden. The Dock is the other way to find FocusGuard."
                         : "FocusGuard lives in the menu bar (shield icon). The Dock is a second way to find it.")
                }
                HStack {
                    Spacer()
                    Button("Setup…") { model.setupSheetPresented = true }.buttonStyle(.link)
                }
            }

            Section("Beta") {
                Toggle(isOn: $chromeExtensionsBeta) {
                    Text("Chrome extension blocking")
                    Text("Adds a Chrome extensions section to each block list. Extensions already in a list stay blocked with this off.")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { dock.check() }
    }

    private var modeCaption: String {
        guard let mode = model.lockState.overall else { return "No window is active, so anything can be changed right now." }
        let until = model.lockState.lockedUntil.map { " until \($0.string)" } ?? " all week (no gap in the schedule)"
        switch mode {
        case .basic: return "A window is active\(until). Changes apply at once."
        case .friction: return "A window is active\(until). Loosening anything asks you to type the letters first."
        case .impossible: return "A window is active\(until). Nothing can be loosened, including this mode."
        }
    }

    /// What the Setup sheet would show as not green, in the sheet's order: the blocker, and the
    /// Dock row only when the icon is hidden and the Dock stand-in is off, which is the one
    /// unreachable state. Keyword and Chrome trouble is not setup; it is a notice below.
    private var problems: [String] {
        var out: [String] = []
        if let reason = SetupNeed.evaluate(model.installer.setupFlags) { out.append(reason.title) }
        if dock.menuBarIconHidden, !dock.showsInDock {
            out.append("FocusGuard is hard to find: the menu bar icon is hidden and the Dock icon is off")
        }
        return out
    }

    /// Only a keyword capture *error* counts ("waiting for network" is not a problem), and a
    /// Chrome policy that errored or was not applied.
    private var keywordProblem: String? {
        guard model.hasKeywordRules, let watch = model.keywordWatch, watch.hasPrefix("error:") else { return nil }
        return String(watch.dropFirst("error: ".count))
    }
    private var chromeProblem: String? {
        guard model.hasChromeURLs, let chrome = model.chromePages else { return nil }
        if chrome.hasPrefix("not applied") {
            return "Something else is already managing which pages Chrome blocks, so FocusGuard is leaving it alone."
        }
        if chrome.hasPrefix("error: ") { return String(chrome.dropFirst("error: ".count)) }
        return nil
    }

    private func problemSection(_ title: String, more: Int) -> some View {
        Section {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    if more > 0 { Text("and \(more) more in Setup").font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                Button("Setup…") { model.setupSheetPresented = true }
            }
        }
    }

    /// Things the daemon is doing that the rest of the window would otherwise contradict.
    private var noticeSection: some View {
        Section {
            if model.daemonIsHolding {
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: "lock.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("A change is on hold")
                        Text("config.json was changed in a way that would unblock something an Impossible window protects. The daemon is still enforcing the previous settings (shown here) and will take the change up when the window ends\(model.lockState.lockedUntil.map { " at \($0.string)" } ?? "").")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Discard the change") { model.restoreEnforcedConfig() }
                }
            }
            if model.canRestoreConfig {
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("config.json cannot be read")
                        Text("Lists and schedules cannot be edited until it can. The daemon has a copy of the last settings it accepted; restoring writes that copy back.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Restore") { model.restoreEnforcedConfig() }
                }
            }
            if let zone = model.zoneHeldBack {
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: "globe").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Time zone change on hold")
                        Text("Schedules are still read in \(zone) until the Impossible window ends.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let keywordProblem {
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Keyword rules are not working")
                        Text("Sites and apps you listed by name are still blocked. \(keywordProblem)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let chromeProblem {
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Chrome extensions are not being blocked")
                        Text(chromeProblem).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if model.clockTampered {
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: "clock.badge.exclamationmark").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("This Mac's clock was changed")
                        Text("Schedules keep running on the real time (\(model.trustedNow.formatted(date: .omitted, time: .shortened))) until the clock agrees with it again.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
