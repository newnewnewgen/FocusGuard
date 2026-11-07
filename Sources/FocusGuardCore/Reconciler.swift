import Foundation

/// Converges the system to the active set. Every tick rebuilds desired state from scratch,
/// so running it from any starting state (fresh boot, crash mid-window) is safe.
public final class Reconciler {
    public struct Result: Equatable {
        public var activeSet: ActiveSet
        public var source: ConfigResolver.Source
        public var hostsChanged: Bool
        public var terminated: [Int32]
        public var killed: [Int32]
        /// The time schedule matching used this tick, and whether it differs from the wall clock
        /// because the clock guard is overriding it. Published to the app in `DaemonStatus`.
        public var trusted: Date
        public var clockTampered: Bool
        /// The zone schedule matching used: the system's, unless a change is being held back.
        public var timeZone: String
        /// Some enabled list has keyword rules: the daemon should be observing lookups.
        public var keywordWatchWanted: Bool
    }

    private let hosts: HostsFileStore
    private let dns: DNSCacheFlusher
    private let processes: ProcessController
    private let log: ReconcilerLog
    private let clockGuard: ClockGuard
    private let killGrace: TimeInterval
    /// Schedule times are local times in this calendar's zone. The zone follows the system's,
    /// except that a change is not taken up while an Impossible window is active: `Date` does
    /// not move when the zone does, so the clock guard cannot see it, and without this a zone
    /// change would slide the window out from under the present moment.
    private var calendar: Calendar
    private var refusedZone: String?

    private var resolver: ConfigResolver
    /// Persisted by the daemon so a restart within the same boot cannot reset the clock anchor.
    public private(set) var clockState: ClockGuard.State?
    private var wasTampered = false
    private var lastSource: ConfigResolver.Source?
    private var hostsFailing = false
    /// pid → monotonic deadline for SIGKILL; `.infinity` once SIGKILL has been sent (waiting for it to disappear).
    private var pendingKill: [Int32: TimeInterval] = [:]
    /// Names seen looked up that matched a keyword rule. Persisted by the daemon.
    public private(set) var learned: LearnedNames
    /// What the last tick enforced, so `observe` can judge a name between ticks.
    private var lastEffective: Config?

    public init(hosts: HostsFileStore, dns: DNSCacheFlusher, processes: ProcessController, log: ReconcilerLog,
                clockGuard: ClockGuard = ClockGuard(), clockState: ClockGuard.State? = nil,
                killGrace: TimeInterval = 3,
                resolver: ConfigResolver = ConfigResolver(), calendar: Calendar = .current,
                zone: TimeZone? = nil, learned: LearnedNames = LearnedNames()) {
        self.hosts = hosts
        self.dns = dns
        self.processes = processes
        self.log = log
        self.clockGuard = clockGuard
        self.clockState = clockState
        self.killGrace = killGrace
        self.resolver = resolver
        self.calendar = calendar
        self.learned = learned
        if let zone { self.calendar.timeZone = zone }
    }

    public var lastGoodConfig: Config? { resolver.lastGood }
    /// Persisted by the daemon so a restart cannot be used to adopt a zone change mid-window.
    public var timeZoneIdentifier: String { calendar.timeZone.identifier }

    /// `systemZone` is the Mac's current time zone as read this tick (nil: keep the zone we have).
    @discardableResult
    public func tick(live: Config?, clock: ClockSample, systemZone: TimeZone? = nil) -> Result {
        let step = clockGuard.step(state: clockState, now: clock)
        clockState = step.state
        if step.tampered != wasTampered {
            wasTampered = step.tampered
            if step.tampered {
                log.error("wall clock \(clock.wall) disagrees with monotonic projection; using \(step.trusted) until they agree")
            } else {
                log.info("wall clock agrees with projection again")
            }
        }

        adoptZoneIfAllowed(systemZone, trusted: step.trusted)
        let moment = LocalMoment(date: step.trusted, calendar: calendar)
        let (config, source) = resolver.resolve(live: live, at: moment, monotonic: clock.monotonic)
        if source != lastSource {
            lastSource = source
            switch source {
            case .live: log.info("config source: live")
            case .lastGood: log.error("config unreadable; enforcing last-known-good until its window ends")
            case .none: log.error("no readable config and no fallback; nothing is enforced")
            case .held: log.error("config.json refused: it would unblock something an Impossible window protects; still enforcing the accepted config until that window ends")
            }
        }
        lastEffective = config
        if learned.count > LearnedNames.cap, config.keywordRules(activeAt: moment).isEmpty {
            learned.evictBeyondCap()
        }
        let active = config.activeSet(at: moment, learned: learned.names)

        let hostsChanged = reconcileHosts(domains: active.domains)
        let (terminated, killed) = reconcileApps(bundleIDs: active.bundleIDs, monotonic: clock.monotonic)

        return Result(activeSet: active, source: source, hostsChanged: hostsChanged,
                      terminated: terminated, killed: killed,
                      trusted: step.trusted, clockTampered: step.tampered,
                      timeZone: calendar.timeZone.identifier,
                      keywordWatchWanted: config.hasKeywordRules)
    }

    private func adoptZoneIfAllowed(_ systemZone: TimeZone?, trusted: Date) {
        guard let systemZone, systemZone.identifier != calendar.timeZone.identifier else {
            refusedZone = nil
            return
        }
        if resolver.isImpossibleLocked(at: LocalMoment(date: trusted, calendar: calendar)) {
            if refusedZone != systemZone.identifier {
                refusedZone = systemZone.identifier
                log.error("time zone changed to \(systemZone.identifier); keeping \(calendar.timeZone.identifier) until the Impossible window ends")
            }
        } else {
            log.info("time zone is now \(systemZone.identifier) (was \(calendar.timeZone.identifier))")
            calendar.timeZone = systemZone
            refusedZone = nil
        }
    }

    /// Remove our hosts region. Called on daemon shutdown.
    public func teardown() {
        _ = reconcileHosts(domains: [])
        pendingKill.removeAll()
    }

    /// A site name the Mac just looked up. Returns true when it is a new match worth acting on:
    /// the daemon then runs a tick at once so the hosts region catches it without waiting.
    /// Judged against what the last tick enforced (so a held proposal cannot widen learning).
    @discardableResult
    public func observe(name rawName: String, wall: Date) -> Bool {
        let name = rawName.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !name.isEmpty, !name.hasSuffix(".arpa"), !name.hasSuffix(".local"),
              let config = lastEffective, config.shouldLearn(name: name) else { return false }
        let isNew = learned.record(name, at: wall)
        if isNew { log.info("learned \(name)") }
        return isNew
    }

    private func reconcileHosts(domains: Set<String>) -> Bool {
        do {
            let current = try hosts.read()
            let desired = HostsRegion.apply(domains: domains, to: current)
            var changed = false
            if desired != current {
                try hosts.write(desired)
                dns.flush()
                log.info("hosts region updated: \(domains.count) domain(s)")
                changed = true
            }
            if hostsFailing {
                hostsFailing = false
                log.info("hosts access recovered")
            }
            return changed
        } catch {
            // Latched: a persistent failure at a 2 s tick must not log every tick.
            if !hostsFailing {
                hostsFailing = true
                log.error("hosts access failed: \(error)")
            }
            return false
        }
    }

    private func reconcileApps(bundleIDs: Set<String>, monotonic: TimeInterval) -> ([Int32], [Int32]) {
        // Battery: outside any window we never enumerate processes at all.
        guard !bundleIDs.isEmpty else {
            pendingKill.removeAll()
            return ([], [])
        }

        var terminated: [Int32] = []
        var killed: [Int32] = []
        let running = processes.runningApps()
        let runningPIDs = Set(running.map(\.pid))
        pendingKill = pendingKill.filter { runningPIDs.contains($0.key) }

        for app in running {
            guard let id = app.bundleID, bundleIDs.contains(id) else { continue }
            if let deadline = pendingKill[app.pid] {
                if deadline.isFinite, monotonic >= deadline {
                    processes.kill(pid: app.pid)
                    pendingKill[app.pid] = .infinity
                    killed.append(app.pid)
                    log.info("killed \(id) pid \(app.pid)")
                }
            } else {
                processes.terminate(pid: app.pid)
                pendingKill[app.pid] = monotonic + killGrace
                terminated.append(app.pid)
                log.info("terminated \(id) pid \(app.pid)")
            }
        }
        return (terminated, killed)
    }
}
