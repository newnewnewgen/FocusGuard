import Foundation
import FocusGuardCore

final class Daemon {
    /// While a window is active: fast sweep so a blocked app dies within ~2 s.
    static let activeTick: TimeInterval = 2
    /// Outside all windows: nothing to enforce, so wake rarely. A window boundary is
    /// therefore honoured within 30 s; the Plan 2 app tightens this with an exact timer.
    static let idleTick: TimeInterval = 30

    private let log = OSLogAdapter()
    private let reconciler: Reconciler
    private var timer: DispatchSourceTimer?
    private var currentInterval: TimeInterval = 0
    private var signalSources: [DispatchSourceSignal] = []
    private var lastSavedLastGood: Config?
    private var lastSavedClockState: ClockGuard.State?

    init() {
        lastSavedClockState = ConfigFile.loadClockState()
        reconciler = Reconciler(
            hosts: EtcHostsStore(path: Paths.hosts),
            dns: DSCacheFlusher(),
            processes: LibprocProcessController(),
            log: log,
            clockState: lastSavedClockState,
            resolver: ConfigResolver(lastGood: ConfigFile.loadLastGood()))
    }

    /// One reconcile pass. Safe to call from `once` or from the timer.
    func tick() {
        let live = ConfigFile.load(log: log)
        let result = reconciler.tick(live: live, clock: SystemClock.sample())
        if let good = reconciler.lastGoodConfig, good != lastSavedLastGood {
            ConfigFile.saveLastGood(good)
            lastSavedLastGood = good
        }
        // The anchor changes rarely (first run, reboot, 24 h reconverge), so this almost never writes.
        if let state = reconciler.clockState, state != lastSavedClockState {
            ConfigFile.saveClockState(state)
            lastSavedClockState = state
        }
        if result.hostsChanged || !result.terminated.isEmpty || !result.killed.isEmpty {
            log.info("tick: source=\(result.source) domains=\(result.activeSet.domains.count) apps=\(result.activeSet.bundleIDs.count)")
        }
        reschedule(interval: result.activeSet.bundleIDs.isEmpty ? Self.idleTick : Self.activeTick)
    }

    /// Generous leeway lets the kernel coalesce our wake-ups with everyone else's (timer coalescing),
    /// which is what keeps a periodic daemon off the battery radar.
    private func reschedule(interval: TimeInterval) {
        guard let timer, interval != currentInterval else { return }
        currentInterval = interval
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(Int(interval * 250)))
    }

    func run() -> Never {
        do {
            try ConfigFile.ensureSupportDir()
        } catch {
            log.error("cannot create \(Paths.supportDir): \(error)")
        }
        log.info("focusguardd starting, tick \(Self.activeTick)s active / \(Self.idleTick)s idle")

        // launchd sends SIGTERM on bootout; strip our hosts region before exiting.
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [self] in shutdown() }
            src.resume()
            signalSources.append(src)
        }

        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: Self.activeTick, leeway: .milliseconds(500))
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
