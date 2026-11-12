import Foundation

/// Whether the Setup sheet must be shown, decided from the installer's four facts alone so it
/// can be tested without an `Installer` (UI polish spec §3, §8).
enum SetupNeed {
    struct Flags: Equatable {
        var daemonInstalled: Bool
        var legacyDaemonRunning: Bool
        var needsUpdate: Bool
        var daemonRunning: Bool
    }

    /// In the order `SetupSheet.daemonRow` tells them: the first that applies is the one shown.
    enum Reason: Equatable {
        case legacyDaemon, notInstalled, needsUpdate, notRunning

        var title: String {
            switch self {
            case .legacyDaemon: return "Blocker needs reinstalling"
            case .notInstalled: return "Background blocker not installed"
            case .needsUpdate: return "Background blocker needs updating"
            case .notRunning: return "Background blocker not running"
            }
        }
    }

    /// nil when protection is healthy: installed, current, and running from the installed path.
    static func evaluate(_ f: Flags) -> Reason? {
        if f.legacyDaemonRunning { return .legacyDaemon }
        if !f.daemonInstalled { return .notInstalled }
        if f.needsUpdate { return .needsUpdate }
        if !f.daemonRunning { return .notRunning }
        return nil
    }

    /// Whether to put the sheet up on its own (launch, `didBecomeActive`). `snoozed` is the
    /// flags as they were when the user clicked "Not now": while they are unchanged the sheet
    /// stays down — the user has seen this exact state and declined — and any change (the daemon
    /// stops, the install lands) is a new state and shows it again. Status → "Setup…" bypasses
    /// this and always opens the sheet.
    static func shouldPresent(flags: Flags, snoozed: Flags?) -> Bool {
        guard evaluate(flags) != nil else { return false }
        return flags != snoozed
    }
}
