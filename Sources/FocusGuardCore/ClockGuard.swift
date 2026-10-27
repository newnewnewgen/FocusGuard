import Foundation

/// A paired reading of the wall clock and a monotonic clock that keeps counting through sleep.
public struct ClockSample: Codable, Equatable {
    public var wall: Date
    public var monotonic: TimeInterval

    public init(wall: Date, monotonic: TimeInterval) {
        self.wall = wall
        self.monotonic = monotonic
    }
}

public struct ClockGuard {
    public var tolerance: TimeInterval

    public init(tolerance: TimeInterval = 120) {
        self.tolerance = tolerance
    }

    /// The wall-clock time to use for schedule matching. If the wall clock has gone backwards
    /// relative to monotonic progress by more than `tolerance`, the monotonic projection wins.
    /// Callers should feed back `ClockSample(wall: <returned value>, monotonic: current.monotonic)`
    /// as the next `previous`, so a tampered clock stays overridden until it agrees again.
    public func trustedNow(previous: ClockSample?, current: ClockSample) -> Date {
        guard let previous else { return current.wall }
        let projected = previous.wall.addingTimeInterval(current.monotonic - previous.monotonic)
        if current.wall < projected.addingTimeInterval(-tolerance) {
            return projected
        }
        return current.wall
    }
}
