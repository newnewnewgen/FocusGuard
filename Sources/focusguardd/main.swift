import Foundation
import FocusGuardCore

let usage = """
usage: focusguardd <command>
  run     enforce forever (launchd entry point; needs root)
  once    single reconcile pass and exit (needs root)
  check   print what would be blocked right now (any user)
"""

func check() {
    let data = FileManager.default.contents(atPath: Paths.config)
    guard let data else {
        print("no config at \(Paths.config)")
        exit(1)
    }
    let config: Config
    do {
        config = try Config.decodeJSON(data)
    } catch {
        print("config.json invalid: \(error)")
        exit(1)
    }
    let moment = LocalMoment(date: Date())
    let active = config.activeSet(at: moment)
    print("now: \(moment.weekday) \(moment.minutesSinceMidnight / 60):\(String(format: "%02d", moment.minutesSinceMidnight % 60))")
    for w in config.schedules {
        print("  [\(w.isActive(at: moment) ? "ACTIVE" : "      ")] \(w.name) \(w.days.map(\.rawValue).sorted().joined(separator: ",")) \(w.start.string)-\(w.end.string)\(w.enabled ? "" : " (disabled)")")
    }
    print("domains: \(active.domains.sorted().joined(separator: " "))")
    print("apps:    \(active.bundleIDs.sorted().joined(separator: " "))")
    // What a write would be judged against: the strictest active window protects its items until
    // the active stretch ends (Lock.swift). "lock: none" means any edit is accepted right now.
    let lock = config.lockState(at: moment)
    if let mode = lock.overall {
        print("lock:    \(mode.rawValue) until \(lock.lockedUntil?.string ?? "the schedule has no gap all week")")
    } else {
        print("lock:    none")
    }
}

func requireRoot() {
    if getuid() != 0 {
        fputs("focusguardd: this command needs root (run with sudo)\n", stderr)
        exit(2)
    }
}

switch CommandLine.arguments.dropFirst().first {
case "run":
    requireRoot()
    Daemon().run()
case "once":
    requireRoot()
    Daemon().tick()
case "check":
    check()
default:
    print(usage)
    exit(64)
}
