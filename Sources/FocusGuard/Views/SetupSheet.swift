import FocusGuardCore
import SwiftUI

/// The checklist that was the Status tab's "Protection" section (UI polish spec §3). Presented
/// over the settings window whenever `SetupNeed.shouldPresent` says protection is unhealthy and
/// the user has not clicked "Not now" on this exact state — at launch and each time the app
/// becomes active — and on demand from Status → "Setup…", which is how the login and Dock
/// toggles stay reachable once everything is green.
struct SetupSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(DockFallback.self) private var dock
    @State private var closeTask: Task<Void, Never>?

    private var inst: Installer { model.installer }
    private var protectionHealthy: Bool { !inst.working && SetupNeed.evaluate(inst.setupFlags) == nil }
    private var keywordWatch: String { model.keywordWatch ?? "unknown (daemon status not available)" }
    private var keywordsHealthy: Bool { keywordWatch.hasPrefix("watching") }
    private var chromePages: String { model.chromePages ?? "unknown (daemon status not available)" }
    private var chromeHealthy: Bool { chromePages.hasPrefix("applied") }
    /// Reachable: the menu-bar icon is on screen, or the Dock icon stands in for it.
    private var dockHealthy: Bool { !dock.menuBarIconHidden || dock.showsInDock }

    /// Every step that is shown is green.
    private var allGreen: Bool {
        protectionHealthy && inst.opensAtLogin && dockHealthy
            && (!model.hasKeywordRules || keywordsHealthy) && (!model.hasChromeURLs || chromeHealthy)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Set up FocusGuard").font(.headline)
            VStack(alignment: .leading, spacing: 10) {
                daemonRow(inst)
                if let err = inst.lastError { Text(err).foregroundStyle(.red).font(.callout) }
                Divider()
                row(done: inst.opensAtLogin, "Open FocusGuard at login",
                    detail: "So the app is there to close blocked apps the moment they launch and to show what is active.") {
                    Toggle("Open FocusGuard at login", isOn: Binding(get: { inst.opensAtLogin }, set: { inst.setOpensAtLogin($0) }))
                        .toggleStyle(.switch).labelsHidden()
                }
                if model.hasKeywordRules {
                    Divider()
                    row(done: keywordsHealthy, "Keyword matching: \(keywordWatch)",
                        detail: keywordsHealthy ? "Sites whose names match your keywords are learned from the Mac's lookups and blocked." :
                                "Keyword rules are inert until the daemon can watch lookups; sites and apps listed by name still work.")
                }
                if model.hasChromeURLs {
                    Divider()
                    row(done: chromeHealthy, "Chrome pages: \(chromePages)",
                        detail: chromeHealthy ? "Chrome's URLBlocklist policy holds the patterns of every active window; Chrome shows those pages as blocked by an administrator." :
                                chromePages.hasPrefix("not applied") ? "Something else has set Chrome's URLBlocklist. FocusGuard never overwrites it. To let FocusGuard manage it: sudo defaults delete /Library/Preferences/com.google.Chrome URLBlocklist" :
                                chromePages.hasPrefix("error: ") ? "The daemon could not write Chrome's policy: \(chromePages.dropFirst("error: ".count)). It retries every tick." :
                                "Chrome patterns are written to Chrome's policy when a window that has them starts.")
                }
                Divider()
                row(done: dockHealthy, dock.menuBarIconHidden ? "Menu-bar icon hidden by macOS" : "Menu-bar icon showing",
                    detail: dock.menuBarIconHidden
                        ? "The menu bar is full, so FocusGuard shows in the Dock instead. You can always open this window from Spotlight too."
                        : "FocusGuard lives in the menu bar (shield icon). If macOS hides that icon when the menu bar is full, it shows in the Dock automatically.") {
                    Toggle("Show in Dock", isOn: Binding(get: { dock.showsInDock }, set: { dock.setShowsInDock($0) }))
                        .toggleStyle(.switch).controlSize(.small)
                }
            }
            Text("The background daemon blocks sites and apps whether or not this app is open. The app is where you edit lists and schedules; while it is open, blocked apps close instantly rather than within two seconds.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                // The exit while protection is unhealthy (a cancelled password prompt, a failed
                // install, a dev build run from `build/`): the window stays usable, Status keeps
                // its orange row, and the sheet comes back on its own only if something changes.
                Button("Not now") { model.snoozeSetup() }.keyboardShortcut(.cancelAction)
                Button("Done") { close() }.keyboardShortcut(.defaultAction).disabled(!protectionHealthy)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear { dock.check() }
        // Closes itself 1.5 s after the last shown step turns green — only on a transition while
        // it is open, so a sheet opened from "Setup…" in a healthy state stays for the toggles.
        .onChange(of: allGreen) { _, green in
            closeTask?.cancel()
            guard green else { return }
            closeTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.5))
                if !Task.isCancelled { close() }
            }
        }
        .onDisappear { closeTask?.cancel() }
    }

    private func close() { model.setupSheetPresented = false }

    @ViewBuilder
    private func daemonRow(_ inst: Installer) -> some View {
        if inst.working {
            row(done: false, "Waiting for your password…")
        } else if inst.legacyDaemonRunning {
            row(done: false, SetupNeed.Reason.legacyDaemon.title,
                detail: "This version keeps the daemon in a system folder other programs cannot change. One password prompt; your settings are kept.") {
                Button("Reinstall…") { inst.install() }
            }
        } else if !inst.daemonInstalled {
            row(done: false, SetupNeed.Reason.notInstalled.title,
                detail: "Installs the root daemon that does the blocking. macOS asks for your password once.") {
                Button("Install protection…") { inst.install() }
            }
        } else if inst.needsUpdate {
            row(done: false, SetupNeed.Reason.needsUpdate.title,
                detail: "This app is newer than the installed daemon\(inst.status.map { " (\($0.version))" } ?? ""). Blocking continues meanwhile.") {
                Button("Update…") { inst.install() }
            }
        } else if inst.daemonRunning {
            row(done: true, "Background daemon running",
                detail: [inst.status.map { "version \($0.version)" }, inst.daemonProcess.map { "pid \($0.pid)" }]
                    .compactMap { $0 }.joined(separator: " · "))
        } else {
            row(done: false, SetupNeed.Reason.notRunning.title,
                detail: "launchd normally restarts it within seconds. Reinstalling re-registers it.") {
                Button("Reinstall…") { inst.install() }
            }
        }
    }

    private func row(done: Bool, _ title: String, detail: String? = nil) -> some View {
        row(done: done, title, detail: detail) { EmptyView() }
    }

    private func row<Action: View>(done: Bool, _ title: String, detail: String?, @ViewBuilder action: () -> Action) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail, !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            action()
        }
    }
}
