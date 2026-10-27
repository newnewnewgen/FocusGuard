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
    }

    private let hosts: HostsFileStore
    private let dns: DNSCacheFlusher
    private let processes: ProcessController
    private let log: ReconcilerLog
    private let clockGuard: ClockGuard
    private let killGrace: TimeInterval
    private let calendar: Calendar

    private var resolver: ConfigResolver
    /// Persisted by the daemon so a restart within the same boot cannot reset the clock anchor.
    public private(set) var clockState: ClockGuard.State?
    private var wasTampered = false
    /// pid → monotonic deadline after which SIGKILL is sent.
    private var pendingKill: [Int32: TimeInterval] = [:]

    public init(hosts: HostsFileStore, dns: DNSCacheFlusher, processes: ProcessController, log: ReconcilerLog,
                clockGuard: ClockGuard = ClockGuard(), clockState: ClockGuard.State? = nil,
                killGrace: TimeInterval = 3,
                resolver: ConfigResolver = ConfigResolver(), calendar: Calendar = .current) {
        self.hosts = hosts
        self.dns = dns
        self.processes = processes
        self.log = log
        self.clockGuard = clockGuard
        self.clockState = clockState
        self.killGrace = killGrace
        self.resolver = resolver
        self.calendar = calendar
    }

    public var lastGoodConfig: Config? { resolver.lastGood }

    @discardableResult
    public func tick(live: Config?, clock: ClockSample) -> Result {
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

        let moment = LocalMoment(date: step.trusted, calendar: calendar)
        let (config, source) = resolver.resolve(live: live, at: moment, monotonic: clock.monotonic)
        let active = config.activeSet(at: moment)

        let hostsChanged = reconcileHosts(domains: active.domains)
        let (terminated, killed) = reconcileApps(bundleIDs: active.bundleIDs, monotonic: clock.monotonic)

        return Result(activeSet: active, source: source, hostsChanged: hostsChanged,
                      terminated: terminated, killed: killed)
    }

    /// Remove our hosts region. Called on daemon shutdown.
    public func teardown() {
        _ = reconcileHosts(domains: [])
        pendingKill.removeAll()
    }

    private func reconcileHosts(domains: Set<String>) -> Bool {
        let current: String
        do {
            current = try hosts.read()
        } catch {
            log.error("hosts read failed: \(error)")
            return false
        }
        let desired = HostsRegion.apply(domains: domains, to: current)
        guard desired != current else { return false }
        do {
            try hosts.write(desired)
        } catch {
            log.error("hosts write failed: \(error)")
            return false
        }
        dns.flush()
        log.info("hosts region updated: \(domains.count) domain(s)")
        return true
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
                if monotonic >= deadline {
                    processes.kill(pid: app.pid)
                    pendingKill[app.pid] = nil
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
