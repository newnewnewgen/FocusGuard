import Foundation
import FocusGuardCore

enum SystemClock {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    /// `mach_continuous_time` keeps counting while the machine sleeps, unlike `mach_absolute_time`.
    static func monotonicSeconds() -> TimeInterval {
        let ticks = mach_continuous_time()
        let nanos = Double(ticks) * Double(timebase.numer) / Double(timebase.denom)
        return nanos / 1_000_000_000
    }

    /// Monotonic values are only comparable within one boot; samples carry the boot session so a
    /// persisted anchor from a previous boot is never projected from.
    private static let bootSessionID: String = {
        if let uuid = sysctlString("kern.bootsessionuuid"), !uuid.isEmpty { return uuid }
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        if sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0 { return "boottime-\(tv.tv_sec)" }
        return "unknown-\(UUID().uuidString)"  // never matches a persisted anchor: fail safe
    }()

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }

    static func sample() -> ClockSample {
        ClockSample(wall: Date(), monotonic: monotonicSeconds(), boot: bootSessionID)
    }
}
