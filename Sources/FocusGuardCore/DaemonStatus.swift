import Foundation

/// The one version string, logged by the daemon and compared by the app to tell whether the
/// installed daemon is the one this app ships. Keep in step with CFBundleShortVersionString.
public enum FocusGuardVersion {
    public static let current = "0.6.0"
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
    /// "off", "applied (N patterns)", "not applied (…)" or "error: …" (chrome pages spec §5).
    public var chrome: String

    public init(version: String = FocusGuardVersion.current, pid: Int32, source: ConfigResolver.Source,
                clockOffsetSeconds: Int, clockTampered: Bool, timeZone: String, dnsWatch: String = "off",
                chrome: String = "off") {
        self.version = version
        self.pid = pid
        self.source = source
        self.clockOffsetSeconds = clockOffsetSeconds
        self.clockTampered = clockTampered
        self.timeZone = timeZone
        self.dnsWatch = dnsWatch
        self.chrome = chrome
    }

    private enum CodingKeys: String, CodingKey {
        case version, pid, source, clockOffsetSeconds, clockTampered, timeZone, dnsWatch, chrome
    }

    /// `dnsWatch` and `chrome` are optional on decode so a newer app reading the status.json of
    /// a still-running older daemon sees a status rather than none. Encoding stays synthesized.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(String.self, forKey: .version)
        pid = try c.decode(Int32.self, forKey: .pid)
        source = try c.decode(ConfigResolver.Source.self, forKey: .source)
        clockOffsetSeconds = try c.decode(Int.self, forKey: .clockOffsetSeconds)
        clockTampered = try c.decode(Bool.self, forKey: .clockTampered)
        timeZone = try c.decode(String.self, forKey: .timeZone)
        dnsWatch = try c.decodeIfPresent(String.self, forKey: .dnsWatch) ?? "off"
        chrome = try c.decodeIfPresent(String.self, forKey: .chrome) ?? "off"
    }

    /// Offset to publish: nothing while the clocks agree (the small drift inside the guard's
    /// tolerance would only churn the file), otherwise rounded so jitter does not rewrite it.
    public static func publishedOffset(trusted: Date, wall: Date, tampered: Bool) -> Int {
        guard tampered else { return 0 }
        return Int((trusted.timeIntervalSince(wall) / 5).rounded()) * 5
    }
}

extension ConfigResolver.Source: Codable {}
