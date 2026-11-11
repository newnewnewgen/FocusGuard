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
        /// "off", "applied (N patterns)", "applied (N patterns; Chrome not found)",
        /// "not applied (…)" or "error: …" — `DaemonStatus.chrome` (chrome pages spec §5).
        public var chrome: String
    }

    private let hosts: HostsFileStore
    private let dns: DNSCacheFlusher
    private let processes: ProcessController
    private let log: ReconcilerLog
    /// nil in `check`-style and test contexts that never touch Chrome: status stays "off".
    private let chrome: ChromePolicyWriter?
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
    /// The learned names the last tick rendered into the hosts region. A name in /etc/hosts is
    /// never looked up again, so its last-seen time freezes; `record` spares these when the cap
    /// forces an eviction, or the drop would take exactly the names being enforced.
    private var lastRenderedLearned: Set<String> = []
    /// What this process (or, via the record, a previous one) last wrote to Chrome. nil: the
    /// key is not ours. Change detection keys on this, as the hosts region keys on file contents.
    private var chromeLastWritten: [String]?
    /// `apply` has been called in this process and no `clear` has succeeded since. While true a
    /// key with no record is a write of ours that failed part-way, not someone else's: the
    /// foreign-key rule is skipped so the write is retried instead of refused forever.
    private var chromeAttempted = false
    private var chromeRecordRead = false
    private var chromeForeignLogged = false
    /// The user's copy of our key has been seen missing and not yet seen back: one log line per
    /// such episode, however many ticks it takes (a loop deleting it is one episode).
    private var chromeUserCopyMissing = false
    private var chromeFailing = false

    public init(hosts: HostsFileStore, dns: DNSCacheFlusher, processes: ProcessController, log: ReconcilerLog,
                chrome: ChromePolicyWriter? = nil,
                clockGuard: ClockGuard = ClockGuard(), clockState: ClockGuard.State? = nil,
                killGrace: TimeInterval = 3,
                resolver: ConfigResolver = ConfigResolver(), calendar: Calendar = .current,
                zone: TimeZone? = nil, learned: LearnedNames = LearnedNames()) {
        self.hosts = hosts
        self.dns = dns
        self.processes = processes
        self.log = log
        self.chrome = chrome
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
        let matcher = KeywordMatcher(config: config, at: moment)
        lastRenderedLearned = learned.names.filter(matcher.blocks)
        var active = config.activeSet(at: moment)
        active.domains.formUnion(lastRenderedLearned)

        let hostsChanged = reconcileHosts(domains: active.domains)
        let (terminated, killed) = reconcileApps(bundleIDs: active.bundleIDs, monotonic: clock.monotonic)

        let chromeStatus = reconcileChrome(patterns: active.chromeURLs.sorted())

        return Result(activeSet: active, source: source, hostsChanged: hostsChanged,
                      terminated: terminated, killed: killed,
                      trusted: step.trusted, clockTampered: step.tampered,
                      timeZone: calendar.timeZone.identifier,
                      keywordWatchWanted: config.hasKeywordRules,
                      chrome: chromeStatus)
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

    /// Remove our hosts region and, if we wrote it, Chrome's URLBlocklist key. Called on daemon
    /// shutdown.
    public func teardown() {
        _ = reconcileHosts(domains: [])
        pendingKill.removeAll()
        _ = reconcileChrome(patterns: [])
    }

    /// A site name the Mac just looked up. Returns true when it is a new match worth acting on:
    /// the daemon then runs a tick at once so the hosts region catches it without waiting.
    /// Judged against what the last tick enforced (so a held proposal cannot widen learning).
    @discardableResult
    public func observe(name rawName: String, wall: Date) -> Bool {
        let name = rawName.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !name.isEmpty, !name.hasSuffix(".arpa"), !name.hasSuffix(".local"),
              let config = lastEffective, config.shouldLearn(name: name) else { return false }
        let isNew = learned.record(name, at: wall, protected: lastRenderedLearned)
        if isNew { log.info("learned \(name)") }
        return isNew
    }

    /// Make Chrome's URLBlocklist equal `wanted` (sorted). Writes when the set differs from what
    /// was last written, or when the user's copy of it (the one Chrome watches) has been deleted
    /// — re-asserted on the tick that notices, at most one tick after the deletion. Never touches
    /// a key it did not write: on first run with the key already set and no record, it logs once
    /// and reports "not applied" (chrome pages spec §3).
    private func reconcileChrome(patterns wanted: [String]) -> String {
        guard let chrome else { return "off" }
        if !chromeRecordRead {
            chromeRecordRead = true
            chromeLastWritten = chrome.recordedPatterns()
        }
        if wanted.isEmpty {
            guard chromeLastWritten != nil else { return "off" }
            if let reason = chrome.clear() { return chromeFailure(reason) }
            chromeLastWritten = nil
            chromeAttempted = false
            chromeUserCopyMissing = false
            chromeRecovered()
            log.info("chrome policy removed")
            return "off"
        }
        if chromeLastWritten == nil, !chromeAttempted, chrome.keyIsPresent() {
            if !chromeForeignLogged {
                chromeForeignLogged = true
                log.error("Chrome URLBlocklist is already set by someone else; leaving it alone")
            }
            return "not applied (URLBlocklist already set by someone else)"
        }
        if chromeLastWritten != wanted {
            chromeAttempted = true
            if let reason = chrome.apply(patterns: wanted) { return chromeFailure(reason) }
            chromeLastWritten = wanted
            chromeRecovered()
            log.info("chrome policy updated: \(wanted.count) pattern(s)")
        } else if !chrome.userCopyPresent() {
            chromeAttempted = true
            if let reason = chrome.apply(patterns: wanted) { return chromeFailure(reason) }
            chromeRecovered()
            if !chromeUserCopyMissing {
                chromeUserCopyMissing = true
                log.info("chrome: user copy was removed; re-asserted")
            }
        } else {
            chromeUserCopyMissing = false
        }
        return "applied (\(wanted.count) patterns\(chrome.chromeInstalled ? "" : "; Chrome not found"))"
    }

    /// Latched like hosts failures: one error line per outage, not one per tick.
    private func chromeFailure(_ reason: String) -> String {
        if !chromeFailing {
            chromeFailing = true
            log.error("chrome policy write failed: \(reason)")
        }
        return "error: \(reason)"
    }

    /// After a successful write of ours: the failure latch opens, and a foreign key seen later
    /// is a new episode worth logging again.
    private func chromeRecovered() {
        chromeForeignLogged = false
        if chromeFailing {
            chromeFailing = false
            log.info("chrome policy writes recovered")
        }
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
