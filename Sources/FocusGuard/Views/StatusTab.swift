import SwiftUI
import ServiceManagement

struct StatusTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let inst = model.installer
        Form {
            Section("Protection") {
                if inst.legacyInstallPresent {
                    row(done: false, "A manual daemon install is present",
                        detail: "Run scripts/uninstall-daemon.sh in Terminal (needs sudo), then come back. The app installs the daemon from its own bundle under the same name.")
                }
                row(done: inst.inApplications, "FocusGuard is in /Applications",
                    detail: inst.inApplications ? nil : "macOS only launches background daemons for apps installed there.") {
                    if !inst.inApplications { Button("Move to Applications") { inst.moveToApplications() } }
                }
                daemonRow(inst)
                row(done: inst.agentStatus == .enabled, "Starts at login and stays running",
                    detail: inst.agentStatus == .enabled ? nil : "Status: \(inst.agentStatus.label)") {
                    // The daemon row already offers this button while the daemon itself needs approval.
                    if inst.agentStatus == .requiresApproval, inst.daemonStatus != .requiresApproval {
                        Button("Open Login Items settings") { inst.openLoginItems() }
                    }
                }
                if let err = inst.lastError { Text(err).foregroundStyle(.red).font(.callout) }
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

            if inst.daemonStatus == .enabled || inst.daemonStatus == .requiresApproval {
                Section {
                    HStack {
                        Button("Uninstall protection", role: .destructive) { model.requestUninstall() }
                            .disabled(model.lockState.overall == .impossible)
                        if model.lockState.overall == .impossible { LockBadge(until: model.lockState.lockedUntil) }
                    }
                    Text("Removes the daemon and login item. Your lists and schedule stay in config.json; the FocusGuard folder in /Library/Application Support remains (it is root-owned).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { inst.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in inst.refresh() }
    }

    @ViewBuilder
    private func daemonRow(_ inst: Installer) -> some View {
        switch inst.daemonStatus {
        case .enabled where inst.daemonRunningFromBundle:
            if let proc = inst.daemonProcess {
                row(done: true, "Background daemon running", detail: "pid \(proc.pid)")
            } else {
                row(done: true, "Background daemon running")
            }
        case .enabled:
            row(done: false, "Daemon enabled but not running",
                detail: inst.daemonProcess.map { "A focusguardd is running from \($0.path)" } ?? "launchd should start it within a few seconds; Re-install re-registers it if it does not.") {
                Button("Re-install") { inst.install() }
            }
        case .requiresApproval:
            row(done: false, "Approve FocusGuard in Login Items",
                detail: "System Settings → General → Login Items & Extensions → Allow in the Background → FocusGuard.") {
                Button("Open Login Items settings") { inst.openLoginItems() }
            }
        default:
            row(done: false, "Background daemon not installed",
                detail: "Registers focusguardd (root) and FocusGuard as a login item.") {
                Button("Install protection") { inst.install() }.disabled(!inst.canInstall)
                    .help(installHelp(inst))
            }
        }
    }

    private func installHelp(_ inst: Installer) -> String {
        if inst.legacyInstallPresent { return "Remove the manual daemon install first (scripts/uninstall-daemon.sh)" }
        if !inst.inApplications { return "Move FocusGuard to /Applications first" }
        return "Registers the daemon and login item"
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
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            action()
        }
    }
}
