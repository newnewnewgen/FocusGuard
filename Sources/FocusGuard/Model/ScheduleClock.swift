import AppKit
import Foundation

/// The app's only timer: one wall-clock deadline at the next window boundary. Re-armed by the
/// model after every fire or config change, and poked on wake and clock/zone changes so a
/// boundary crossed during sleep is honoured immediately.
final class ScheduleClock {
    var onFire: (() -> Void)?

    private var timer: DispatchSourceTimer?
    private var observers: [NSObjectProtocol] = []

    init() {
        let fire: (Notification) -> Void = { [weak self] _ in self?.onFire?() }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: fire))
        observers.append(NotificationCenter.default.addObserver(
            forName: .NSSystemClockDidChange, object: nil, queue: .main, using: fire))
        observers.append(NotificationCenter.default.addObserver(
            forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main, using: fire))
    }

    /// nil disarms. Fires 50 ms after `date` so `Date()` inside the handler is past the boundary.
    func arm(at date: Date?) {
        timer?.cancel()
        timer = nil
        guard let date else { return }
        let target = date.timeIntervalSince1970 + 0.05
        let deadline = DispatchWallTime(timespec: timespec(
            tv_sec: Int(target.rounded(.down)),
            tv_nsec: Int((target - target.rounded(.down)) * 1_000_000_000)))
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(wallDeadline: deadline, leeway: .milliseconds(100))
        t.setEventHandler { [weak self] in self?.onFire?() }
        t.resume()
        timer = t
    }
}
