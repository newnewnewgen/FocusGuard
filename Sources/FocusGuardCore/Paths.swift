import Foundation

/// Filesystem locations shared by the daemon (writer of state, reader of config) and the app
/// (writer of config). Permissions are set by the daemon at start (spec §9).
public enum Paths {
    public static let supportDir = "/Library/Application Support/FocusGuard"   // root:admin 0775
    public static let config = supportDir + "/config.json"                      // admin-writable 0664
    public static let stateDir = supportDir + "/state"                          // root:wheel 0700
    public static let lastGood = stateDir + "/last-good.json"
    public static let clockState = stateDir + "/clock-state.json"
    public static let hosts = "/etc/hosts"

    public static let daemonLabel = "com.focusguard.daemon"
    public static let agentLabel = "com.focusguard.app"
    /// Where the manual installer (scripts/install-daemon.sh) puts things; the app refuses to
    /// register while these exist because the label would collide.
    public static let legacyDaemonPlist = "/Library/LaunchDaemons/" + daemonLabel + ".plist"
    public static let legacyDaemonBinary = "/usr/local/libexec/focusguardd"
}
