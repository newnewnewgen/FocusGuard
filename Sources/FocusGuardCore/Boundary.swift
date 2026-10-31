import Foundation

extension Config {
    /// The next instant strictly after `date` at which any enabled window starts or ends, or nil
    /// when no window can ever fire. Searches nine calendar days so a once-a-week window wraps.
    /// The app arms its single timer on this.
    public func nextBoundary(after date: Date, calendar: Calendar = .current) -> Date? {
        let startOfToday = calendar.startOfDay(for: date)
        for dayOffset in 0...8 {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: startOfToday) else { continue }
            let weekday = Weekday(calendarWeekday: calendar.component(.weekday, from: day))
            var best: Date?
            for w in schedules where w.enabled && w.start != w.end {
                var times: [TimeOfDay] = []
                if w.days.contains(weekday) {
                    times.append(w.start)
                    if w.start < w.end { times.append(w.end) }
                }
                // A midnight-crossing window started yesterday ends today.
                if w.start > w.end && w.days.contains(weekday.previous) { times.append(w.end) }
                for t in times {
                    guard let d = calendar.date(bySettingHour: t.hour, minute: t.minute, second: 0, of: day), d > date else { continue }
                    if best == nil || d < best! { best = d }
                }
            }
            if let best { return best }
        }
        return nil
    }

    /// Enabled windows whose start is exactly `moment`, in config order (for "Next: Evening at 19:00").
    public func windows(startingAt moment: LocalMoment) -> [ScheduleWindow] {
        schedules.filter { $0.enabled && $0.start != $0.end && $0.days.contains(moment.weekday) && $0.start.minutesSinceMidnight == moment.minutesSinceMidnight }
    }
}
