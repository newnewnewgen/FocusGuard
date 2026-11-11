import Foundation

/// Filesystem locations shared by the daemon and the app.
///
/// The split matters for security. Everything the daemon *trusts* is root-owned and lives where
/// the logged-in user cannot rename or replace it; the one user-writable file, `config.json`, is
/// only ever a proposal the daemon judges against its own accepted copy.
public enum Paths {
    /// root:admin 0775. Holds only config.json, so the app can save without a password.
    public static let supportDir = "/Library/Application Support/FocusGuard"
    public static let config = supportDir + "/config.json"

    /// root:wheel 0755 under /var/db (itself root-only to modify): cannot be renamed aside.
    public static let stateDir = "/var/db/FocusGuard"
    /// The config the daemon has accepted and is enforcing. World-readable (0644) so the app can
    /// show it and offer to discard a refused change; it holds nothing but the user's own lists.
    public static let lastGood = stateDir + "/last-good.json"
    /// Clock-guard anchor, 0600.
    public static let clockState = stateDir + "/clock-state.json"
    /// `DaemonStatus`, 0644.
    public static let status = stateDir + "/status.json"
    /// Identifier of the time zone the daemon is reading the schedule in, 0644.
    public static let timeZone = stateDir + "/time-zone"
    /// `LearnedNames`, 0644: names learned from lookups that matched a keyword rule.
    public static let learned = stateDir + "/learned.json"
    /// Ownership record for Chrome's URLBlocklist key, 0644: the patterns the daemon last wrote,
    /// so a restart can tell its own key from a user's. Absent when FocusGuard holds no key.
    public static let chromePolicy = stateDir + "/chrome-policy.json"
    /// The plist `defaults import` reads for the user-domain mirror of that key, 0644 so the
    /// console user can read it; rewritten before every mirror write.
    public static let chromeUserImport = stateDir + "/chrome-user-import.plist"
    /// Where state lived before 0.4.0, inside the user-writable support dir; migrated once.
    public static let legacyStateDir = supportDir + "/state"

    public static let hosts = "/etc/hosts"

    public static let daemonLabel = "com.focusguard.daemon"
    /// Root-owned install: the binary that runs as root must not be replaceable without a password.
    public static let daemonPlist = "/Library/LaunchDaemons/" + daemonLabel + ".plist"
    public static let daemonBinary = "/Library/PrivilegedHelperTools/" + daemonLabel
}
