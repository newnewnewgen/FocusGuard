import Foundation

/// The one version string, logged by the daemon and compared by the app to tell whether the
/// installed daemon is the one this app ships. Keep in step with CFBundleShortVersionString.
public enum FocusGuardVersion {
    public static let current = "0.5.0"
}

/// What the daemon tells the app, in a root-owned, world-readable file the user cannot forge.
/// Rewritten only when it changes.
public struct DaemonStatus: Codable, Equatable {
    public var version: String
    public var pid: Int32
    /// Which config is in force (`ConfigResolver.Source`). `held` means config.json is being
    /// refused because it would unblock something an Impossible window protects.
    public var source: ConfigResolver.Source
    /// Daemon's trusted time minus the wall clock, in seconds. 0 unless the wall clock has been
    /// changed; the app adds it to `Date()` so its lock decisions agree with the daemon's.
    public var clockOffsetSeconds: Int
    public var clockTampered: Bool
    /// The time zone the daemon reads the schedule in. Normally the Mac's; during an Impossible
    /// window a change of zone is held back, and the app must use this one to agree.
    public var timeZone: String
    /// "off" (no keyword rules), "watching en0, utun4", or "error: …" (keyword spec §7).
    public var dnsWatch: String

    public init(version: String = FocusGuardVersion.current, pid: Int32, source: ConfigResolver.Source,
                clockOffsetSeconds: Int, clockTampered: Bool, timeZone: String, dnsWatch: String = "off") {
        self.version = version
        self.pid = pid
        self.source = source
        self.clockOffsetSeconds = clockOffsetSeconds
        self.clockTampered = clockTampered
        self.timeZone = timeZone
        self.dnsWatch = dnsWatch
    }

    /// Offset to publish: nothing while the clocks agree (the small drift inside the guard's
    /// tolerance would only churn the file), otherwise rounded so jitter does not rewrite it.
    public static func publishedOffset(trusted: Date, wall: Date, tampered: Bool) -> Int {
        guard tampered else { return 0 }
        return Int((trusted.timeIntervalSince(wall) / 5).rounded()) * 5
    }
}

extension ConfigResolver.Source: Codable {}
