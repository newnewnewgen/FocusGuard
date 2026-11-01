import Foundation

/// A point in local calendar time: which weekday, and minutes since that day's midnight.
public struct LocalMoment: Equatable {
    public let weekday: Weekday
    public let minutesSinceMidnight: Int

    /// Invariant: `0 <= minutesSinceMidnight < 1440`, so `timeOfDay` always exists.
    public init(weekday: Weekday, minutesSinceMidnight: Int) {
        precondition((0..<1440).contains(minutesSinceMidnight), "minutesSinceMidnight must be within one day")
        self.weekday = weekday
        self.minutesSinceMidnight = minutesSinceMidnight
    }

    public init(date: Date, calendar: Calendar = .current) {
        let c = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        self.weekday = Weekday(calendarWeekday: c.weekday!)
        self.minutesSinceMidnight = c.hour! * 60 + c.minute!
    }

    /// Same clock, `n` minutes later (n >= 0), rolling over weekdays.
    public func advanced(byMinutes n: Int) -> LocalMoment {
        precondition(n >= 0, "advanced(byMinutes:) only moves forward")
        let total = minutesSinceMidnight + n
        return LocalMoment(weekday: weekday.shifted(by: total / 1440), minutesSinceMidnight: total % 1440)
    }

    public var timeOfDay: TimeOfDay {
        TimeOfDay(hour: minutesSinceMidnight / 60, minute: minutesSinceMidnight % 60)!
    }
}

extension ScheduleWindow {
    /// Start is inclusive, end is exclusive. A window whose end is before its start crosses
    /// midnight and belongs to its start day; equal start and end is an empty window.
    public func isActive(at m: LocalMoment) -> Bool {
        guard enabled else { return false }
        let s = start.minutesSinceMidnight
        let e = end.minutesSinceMidnight
        let t = m.minutesSinceMidnight
        if s == e { return false }
        if s < e {
            return days.contains(m.weekday) && t >= s && t < e
        }
        return (days.contains(m.weekday) && t >= s)
            || (days.contains(m.weekday.previous) && t < e)
    }
}
