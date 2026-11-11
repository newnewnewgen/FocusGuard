import Foundation
import FocusGuardCore

final class Daemon {
    /// While a window is active: fast sweep so a blocked app dies within ~2 s.
    static let activeTick: TimeInterval = 2
    /// Outside all windows: nothing to enforce, so wake rarely. A window boundary is therefore
    /// honoured within idleTick + leeway (32 s) for sites; the app kills apps at the exact minute.
    static let idleTick: TimeInterval = 30

    private let log = OSLogAdapter()
    private let reconciler: Reconciler
    private var timer: DispatchSourceTimer?
    private var currentInterval: TimeInterval = 0
    private var signalSources: [DispatchSourceSignal] = []
    private var lastSavedLastGood: Config?
    private var lastSavedClockState: ClockGuard.State?
    private var lastSavedStatus: DaemonStatus?
    private var lastSavedZone: String?
    private let watcher: DNSWatcher
    private var lastSavedLearned: LearnedNames?
    private var lastLearnedSave: Date = .distantPast
    private var tickPending = false

    init() {
        do {
            try ConfigFile.ensureDirectories()
        } catch {
            log.error("cannot prepare \(Paths.supportDir) / \(Paths.stateDir): \(error)")
        }
        lastSavedClockState = ConfigFile.loadClockState()
        lastSavedLastGood = ConfigFile.loadLastGood()
        lastSavedZone = ConfigFile.loadTimeZone()
        lastSavedLearned = ConfigFile.loadLearned()
        watcher = DNSWatcher(log: log)
        reconciler = Reconciler(
            hosts: EtcHostsStore(path: Paths.hosts),
            dns: DSCacheFlusher(),
            processes: LibprocProcessController(),
            log: log,
            chrome: CFChromePolicyWriter(log: log),
            clockState: lastSavedClockState,
            resolver: ConfigResolver(lastGood: lastSavedLastGood),
            zone: lastSavedZone.flatMap(TimeZone.init(identifier:)),
            learned: lastSavedLearned ?? LearnedNames())
        watcher.onName = { [weak self] name in self?.observed(name) }
    }

    /// One reconcile pass. Safe to call from `once` or from the timer.
    func tick() {
        let previousChrome = lastSavedStatus?.chrome
        let live = ConfigFile.load(log: log)
        let clock = SystemClock.sample()
        // Foundation caches the system zone for the life of the process unless told to look again.
        NSTimeZone.resetSystemTimeZone()
        let result = reconciler.tick(live: live, clock: clock, systemZone: NSTimeZone.system)
        if let good = reconciler.lastGoodConfig, good != lastSavedLastGood, ConfigFile.saveLastGood(good) {
            lastSavedLastGood = good
        }
        if result.timeZone != lastSavedZone, ConfigFile.saveTimeZone(result.timeZone) {
            lastSavedZone = result.timeZone
        }
        // Only the long-running daemon watches; `once` must never open BPF devices.
        if result.keywordWatchWanted, timer != nil, !watcher.isRunning {
            watcher.start()
        } else if !result.keywordWatchWanted, watcher.isRunning {
            watcher.stop()
        }
        // `record` refreshes lastSeen on every repeat lookup, so "changed" alone would rewrite the
        // file every tick: save when the set of names changes, or at most every 10 minutes otherwise.
        let learnedNow = reconciler.learned
        if learnedNow != lastSavedLearned,
           learnedNow.names != lastSavedLearned?.names ?? [] || Date().timeIntervalSince(lastLearnedSave) > 600,
           ConfigFile.saveLearned(learnedNow) {
            lastSavedLearned = learnedNow
            lastLearnedSave = Date()
        }
        // The anchor changes rarely (first run, reboot, 24 h reconverge), so this almost never writes.
        if let state = reconciler.clockState, state != lastSavedClockState {
            ConfigFile.saveClockState(state)
            lastSavedClockState = state
        }
        // Likewise the status: it changes when the config source or the clock verdict does.
        let status = DaemonStatus(
            pid: getpid(), source: result.source,
            clockOffsetSeconds: DaemonStatus.publishedOffset(trusted: result.trusted, wall: clock.wall, tampered: result.clockTampered),
            clockTampered: result.clockTampered, timeZone: result.timeZone, dnsWatch: watcher.state,
            chrome: result.chrome)
        if status != lastSavedStatus, ConfigFile.saveStatus(status) {
            lastSavedStatus = status
        }
        if result.hostsChanged || !result.terminated.isEmpty || !result.killed.isEmpty || result.chrome != previousChrome {
            log.info("tick: source=\(result.source.rawValue) domains=\(result.activeSet.domains.count) apps=\(result.activeSet.bundleIDs.count) chrome=\(result.activeSet.chromeURLs.count) (\(result.chrome))")
        }
        reschedule(interval: result.activeSet.bundleIDs.isEmpty ? Self.idleTick : Self.activeTick)
    }

    /// A DNS question from the watcher. New matches are applied on the next run-loop turn,
    /// once per turn however many arrive: never from inside the packet loop (which still holds
    /// the capture handle a tick may close), and a page load that reveals several new names
    /// costs one hosts rewrite, not one per name.
    private func observed(_ name: String) {
        guard reconciler.observe(name: name, wall: Date()), !tickPending else { return }
        tickPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.tickPending = false
            self.tick()
        }
    }

    /// Wall-clock deadlines keep firing on schedule after sleep; a 2 s leeway still lets the kernel
    /// coalesce our wake-ups with everyone else's.
    private func reschedule(interval: TimeInterval) {
        guard let timer, interval != currentInterval else { return }
        currentInterval = interval
        timer.schedule(wallDeadline: .now() + interval, repeating: interval, leeway: .seconds(2))
    }

    func run() -> Never {
        log.info("focusguardd \(FocusGuardVersion.current) starting, tick \(Self.activeTick)s active / \(Self.idleTick)s idle")

        // launchd sends SIGTERM on bootout; strip our hosts region before exiting.
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [self] in shutdown() }
            src.resume()
            signalSources.append(src)
        }

        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(wallDeadline: .now(), repeating: Self.activeTick, leeway: .milliseconds(500))
        t.setEventHandler { [self] in tick() }
        timer = t
        currentInterval = Self.activeTick
        t.resume()

        dispatchMain()
    }

    private func shutdown() -> Never {
        log.info("focusguardd shutting down; clearing hosts region")
        reconciler.teardown()
        exit(0)
    }
}
