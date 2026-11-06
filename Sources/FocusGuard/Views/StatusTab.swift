import FocusGuardCore
import SwiftUI

struct StatusTab: View {
    @Environment(AppModel.self) private var model
    @Environment(DockFallback.self) private var dock

    var body: some View {
        let inst = model.installer
        Form {
            if model.daemonIsHolding || model.clockTampered { noticeSection }

            Section("Protection") {
                daemonRow(inst)
                Toggle("Open FocusGuard at login", isOn: Binding(get: { inst.opensAtLogin }, set: { inst.setOpensAtLogin($0) }))
                Text("The background daemon blocks sites and apps whether or not this app is open. The app is where you edit lists and schedules; while it is open, blocked apps close instantly rather than within two seconds.")
                    .font(.caption).foregroundStyle(.secondary)
                if let err = inst.lastError { Text(err).foregroundStyle(.red).font(.callout) }
            }

            Section {
                Toggle("Show FocusGuard in the Dock", isOn: Binding(get: { dock.showsInDock }, set: { dock.setShowsInDock($0) }))
                Text(dock.menuBarIconHidden
                     ? "macOS is hiding the menu-bar icon because the menu bar is full, so FocusGuard shows in the Dock. You can always open this window from Spotlight too."
                     : "FocusGuard lives in the menu bar (shield icon). If macOS hides that icon when the menu bar is full, it shows in the Dock automatically.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Now") {
                if model.isBlocking {
                    LabeledContent("Active", value: model.activeWindowNames.joined(separator: ", "))
                    if let until = model.lockState.lockedUntil { LabeledContent("Until", value: until.string) }
                    LabeledContent("Blocking", value: "\(model.activeSet.domains.count) sites, \(model.activeSet.bundleIDs.count) apps")
                } else {
                    LabeledContent("Active", value: "Nothing")
                }
                if let next = model.nextBoundary {
                    LabeledContent("Next change", value: next.formatted(.dateTime.weekday(.wide).hour().minute()))
                }
                if let err = model.loadError { Text(err).foregroundStyle(.red).font(.callout) }
                if let err = model.saveError { Text(err).foregroundStyle(.red).font(.callout) }
            }

            if inst.daemonInstalled || inst.legacyDaemonRunning {
                Section {
                    let mode = model.uninstallMode
                    HStack {
                        Button("Uninstall protection…", role: .destructive) { model.requestUninstall() }
                            .disabled(mode == .impossible || inst.working)
                        if mode == .impossible { LockBadge(until: model.lockState.lockedUntil) }
                    }
                    Text("Asks for your password, then removes the daemon and unblocks everything. Your lists and schedule stay in config.json.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { inst.refresh(); dock.check() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in inst.refresh() }
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
                    Button("Discard the change") { model.discardRefusedChange() }
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

    @ViewBuilder
    private func daemonRow(_ inst: Installer) -> some View {
        if inst.working {
            row(done: false, "Waiting for your password…")
        } else if inst.legacyDaemonRunning {
            row(done: false, "Protection needs reinstalling",
                detail: "This version keeps the daemon in a system folder other programs cannot change. One password prompt; your settings are kept.") {
                Button("Reinstall…") { inst.install() }
            }
        } else if !inst.daemonInstalled {
            row(done: false, "Background daemon not installed",
                detail: "Installs the root daemon that does the blocking. macOS asks for your password once.") {
                Button("Install protection…") { inst.install() }
            }
        } else if inst.needsUpdate {
            row(done: false, "Background daemon needs updating",
                detail: "This app is newer than the installed daemon\(inst.status.map { " (\($0.version))" } ?? ""). Blocking continues meanwhile.") {
                Button("Update…") { inst.install() }
            }
        } else if inst.daemonRunning {
            row(done: true, "Background daemon running",
                detail: [inst.status.map { "version \($0.version)" }, inst.daemonProcess.map { "pid \($0.pid)" }]
                    .compactMap { $0 }.joined(separator: " · "))
        } else {
            row(done: false, "Background daemon installed but not running",
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
