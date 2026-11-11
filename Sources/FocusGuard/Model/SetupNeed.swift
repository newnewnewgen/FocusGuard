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
            case .legacyDaemon: return "Protection needs reinstalling"
            case .notInstalled: return "Background daemon not installed"
            case .needsUpdate: return "Background daemon needs updating"
            case .notRunning: return "Background daemon installed but not running"
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
}
