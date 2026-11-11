import FocusGuardCore
import SwiftUI

struct StatusTab: View {
    @Environment(AppModel.self) private var model
    @Environment(DockFallback.self) private var dock

    var body: some View {
        Form {
            // A broken state is never silent: one orange row pointing at the Setup sheet (spec §3).
            if let first = problems.first { problemSection(first, more: problems.count - 1) }
            if model.daemonIsHolding || model.clockTampered || model.zoneHeldBack != nil || model.canRestoreConfig { noticeSection }

            Section("Now") {
                if model.isBlocking {
                    LabeledContent("Active", value: model.activeWindowNames.joined(separator: ", "))
                    if let until = model.lockState.lockedUntil { LabeledContent("Until", value: until.string) }
                    LabeledContent("Blocking", value: "\(model.activeSet.domains.count) sites, \(model.activeSet.bundleIDs.count) apps"
                                   + (model.activeSet.chromeURLs.isEmpty ? "" : ", \(model.activeSet.chromeURLs.count) Chrome pages"))
                } else {
                    LabeledContent("Active", value: "Nothing")
                }
                if let next = model.nextBoundary {
                    LabeledContent("Next change", value: next.formatted(.dateTime.weekday(.wide).hour().minute()))
                }
                if let err = model.loadError { Text(err).foregroundStyle(.red).font(.callout) }
                if let err = model.saveError { Text(err).foregroundStyle(.red).font(.callout) }
            }

            Section {
                HStack {
                    Spacer()
                    // The login and Dock toggles live on the sheet; this is how they stay reachable.
                    Button("Setup…") { model.setupSheetPresented = true }.buttonStyle(.link)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { dock.check() }
    }

    /// Everything the Setup sheet would show as not green, in the sheet's order. Only a keyword
    /// capture *error* counts ("waiting for network" is not a problem), and a Chrome policy that
    /// errored or was not applied; the Dock row counts only when the icon is hidden and the Dock
    /// stand-in is off, which is the one unreachable state.
    private var problems: [String] {
        var out: [String] = []
        if let reason = SetupNeed.evaluate(model.installer.setupFlags) { out.append(reason.title) }
        if model.hasKeywordRules, let watch = model.keywordWatch, watch.hasPrefix("error:") {
            out.append("Keyword matching: \(watch)")
        }
        if model.hasChromeURLs, let chrome = model.chromePages, chrome.hasPrefix("error:") || chrome.hasPrefix("not applied") {
            out.append("Chrome pages: \(chrome)")
        }
        if dock.menuBarIconHidden, !dock.showsInDock {
            out.append("The menu-bar icon is hidden by macOS and the Dock icon is off")
        }
        return out
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
