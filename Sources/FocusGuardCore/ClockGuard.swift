import Foundation

/// A paired reading of the wall clock and a monotonic clock that keeps counting through sleep.
/// `boot` identifies the boot session: monotonic values from different boots are incomparable.
public struct ClockSample: Codable, Equatable {
    public var wall: Date
    public var monotonic: TimeInterval
    public var boot: String

    public init(wall: Date, monotonic: TimeInterval, boot: String = "") {
        self.wall = wall
        self.monotonic = monotonic
        self.boot = boot
    }
}

/// Defends schedule matching against the wall clock being changed.
///
/// Trusted time is always projected from an *anchor* sample along the monotonic clock
/// (`mach_continuous_time`: counts through sleep, cannot be set). The anchor moves only on the
/// first sample, in a new boot session (the sample's `boot` tag changed), or after the wall clock has disagreed
/// with the projection continuously for `reconvergeAfter` — long enough that a genuine correction
/// eventually wins, far too long for a clock change to shorten or delay a window. Because the
/// anchor is sticky, drift is measured cumulatively and small steps cannot creep past `tolerance`.
public struct ClockGuard {
    public struct State: Codable, Equatable {
        public var anchor: ClockSample
        /// Monotonic time at which the wall clock started disagreeing; nil while it agrees.
        public var disagreeingSince: TimeInterval?

        public init(anchor: ClockSample, disagreeingSince: TimeInterval? = nil) {
            self.anchor = anchor
            self.disagreeingSince = disagreeingSince
        }
    }

    public struct Step: Equatable {
        public var trusted: Date
        public var state: State
        public var tampered: Bool
    }

    public var tolerance: TimeInterval
    public var reconvergeAfter: TimeInterval

    public init(tolerance: TimeInterval = 120, reconvergeAfter: TimeInterval = 24 * 3600) {
        self.tolerance = tolerance
        self.reconvergeAfter = reconvergeAfter
    }

    public func step(state: State?, now: ClockSample) -> Step {
        guard let state, now.boot == state.anchor.boot, now.monotonic >= state.anchor.monotonic else {
            // First sample, or a different boot session: nothing to project from.
            return Step(trusted: now.wall, state: State(anchor: now), tampered: false)
        }
        let projected = state.anchor.wall.addingTimeInterval(now.monotonic - state.anchor.monotonic)
        let diff = now.wall.timeIntervalSince(projected)
        if abs(diff) <= tolerance {
            return Step(trusted: projected, state: State(anchor: state.anchor), tampered: false)
        }
        let since = state.disagreeingSince ?? now.monotonic
        if now.monotonic - since >= reconvergeAfter {
            return Step(trusted: now.wall, state: State(anchor: now), tampered: false)
        }
        return Step(trusted: projected, state: State(anchor: state.anchor, disagreeingSince: since), tampered: true)
    }
}
