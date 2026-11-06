import Foundation
import FocusGuardCore

final class Daemon {
    /// Keep in step with CFBundleShortVersionString; logged at start so "which code is running?"
    /// can be answered from the log.
    static let version = "0.3.0"
    /// While a window is active: fast sweep so a blocked app dies within ~2 s.
    static let activeTick: TimeInterval = 2
    /// Outside all windows: nothing to enforce, so wake rarely. A window boundary is therefore honoured within idleTick + leeway (32 s); the Plan 2 app tightens this with an exact timer.
    static let idleTick: TimeInterval = 30

    private let log = OSLogAdapter()
    private let reconciler: Reconciler
    private var timer: DispatchSourceTimer?
    private var currentInterval: TimeInterval = 0
    private var signalSources: [DispatchSourceSignal] = []
    private var lastSavedLastGood: Config?
    private var lastSavedClockState: ClockGuard.State?

    /// Our own executable as it was when we started, so an app update (which replaces the file
    /// under us) is noticed: launchd would otherwise keep this process, the old code, until reboot.
    private let executablePath = Bundle.main.executablePath
    private let startIdentity: FileIdentity?
    private var replacementSeen: FileIdentity?

    private struct FileIdentity: Equatable {
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int
        let modifiedNanos: Int

        init?(path: String?) {
            guard let path else { return nil }
            var st = stat()
            guard stat(path, &st) == 0 else { return nil }
            inode = UInt64(st.st_ino)
            size = Int64(st.st_size)
            modifiedSeconds = Int(st.st_mtimespec.tv_sec)
            modifiedNanos = Int(st.st_mtimespec.tv_nsec)
        }
    }

    init() {
        startIdentity = FileIdentity(path: executablePath)
        do {
            try ConfigFile.ensureSupportDir()
        } catch {
            log.error("cannot create \(Paths.supportDir): \(error)")
        }
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
        restartIfReplaced()
    }

    /// Exit so launchd (KeepAlive) starts the binary now on disk. One `stat` per tick. The new
    /// file must look the same on two consecutive ticks, so a copy still in progress is not
    /// launched half-written. A missing file (app deleted) is ignored: keep enforcing.
    ///
    /// Deliberately no `teardown()`: the hosts region stays in place across the restart and the
    /// new process converges to it, so an update never opens an unblocked gap.
    private func restartIfReplaced() {
        guard timer != nil, let startIdentity, let now = FileIdentity(path: executablePath),
              now != startIdentity else {
            replacementSeen = nil
            return
        }
        guard now == replacementSeen else {
            replacementSeen = now
            return
        }
        log.info("focusguardd executable was replaced; exiting so launchd starts the new version")
        exit(0)
    }

    /// Wall-clock deadlines keep firing on schedule after sleep; a 2 s leeway still lets the kernel
    /// coalesce our wake-ups with everyone else's.
    private func reschedule(interval: TimeInterval) {
        guard let timer, interval != currentInterval else { return }
        currentInterval = interval
        timer.schedule(wallDeadline: .now() + interval, repeating: interval, leeway: .seconds(2))
    }

    func run() -> Never {
        log.info("focusguardd \(Self.version) starting, tick \(Self.activeTick)s active / \(Self.idleTick)s idle")

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
