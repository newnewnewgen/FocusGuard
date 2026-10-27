import Foundation

/// A point in local calendar time: which weekday, and minutes since that day's midnight.
public struct LocalMoment: Equatable {
    public let weekday: Weekday
    public let minutesSinceMidnight: Int

    public init(weekday: Weekday, minutesSinceMidnight: Int) {
        self.weekday = weekday
        self.minutesSinceMidnight = minutesSinceMidnight
    }

    public init(date: Date, calendar: Calendar = .current) {
        let c = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        self.weekday = Weekday(calendarWeekday: c.weekday!)
        self.minutesSinceMidnight = c.hour! * 60 + c.minute!
    }
}

extension ScheduleWindow {
    /// Start is inclusive, end is exclusive. A window whose end is at or before its start
    /// crosses midnight and belongs to its start day.
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
