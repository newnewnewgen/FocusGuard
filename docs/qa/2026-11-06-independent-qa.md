# Independent QA of FocusGuard.app (Plan 2)

**Date:** 2026-11-06 · **Commit reviewed:** `6f44d01` · **Machine:** 14" MacBook Pro, macOS 15.6.1

Three independent reviews (unlock logic; app, installer and battery; the intermittent test)
plus direct inspection of the installed, running system. Reviewers worked from the code, built
and probed in scratch copies, and did not touch the repo or the installed app.

## Verdict

The enforcement engine is sound and the app does what its UI says in normal use. It is **not**
"fully debugged": the app is undiscoverable on this Mac, the unlock modes promise more than they
deliver, the running daemon is stale, and nothing has ever been tested across a reboot. The app
target (1,574 lines) has no unit tests.

## Findings

### Critical

| # | Finding | Evidence |
|---|---------|----------|
| C1 | **The app cannot be found.** The menu-bar icon sits at x=647 on a 1512-pt display, inside the notch; macOS hides it. `LSUIElement` means no Dock icon either. The user could not open the app for five days and configured nothing. Workarounds exist (`open focusguard://settings`, relaunch via Spotlight) but are not surfaced anywhere. | Measured with `CGWindowListCopyWindowInfo`: status item `onscreen=false`; 8 items hidden. |
| C2 | **Setting the clock or time zone forward defeats Friction and Impossible.** The app's lock gate reads raw `Date()` (`AppModel.swift:74,110,112`) and refreshes on clock change, so controls unlock at once; the daemon then enforces whatever weakened config is saved. `ClockGuard` protects only the daemon's schedule evaluation. README "Clock changes don't help" is false for the product as a whole. | Reproduced by probe test. |
| C3 | **`config.json` is writable without `sudo`, and nothing resists a hand edit.** The daemon re-reads it every tick with no mode check. Deleting the file loads as empty; one app save then ends the daemon's fail-closed fallback. A corrupt file leaves Uninstall ungated. README and spec say "an admin with sudo", which understates it. | Reproduced at the logic level. |

### Important

| # | Finding | Evidence |
|---|---------|----------|
| I1 | **Updating the app never restarts the daemon.** The running `focusguardd` (started Oct 31 15:38) predates the installed binary (Nov 1 02:52). README says updates keep working. | Verified live. |
| I2 | **Never tested across a reboot.** Last boot was Sep 17, before any install. Every rebuild changes the ad-hoc signature; whether launchd starts the daemon and agent after a reboot, or demands re-approval, is unknown. The app reports `agent=enabled` but `launchctl print gui/501` shows no such job. | Verified live (boot time); reboot behaviour unknown. |
| I3 | **Quit and Uninstall ignore upcoming windows.** They gate on windows active this minute only; in the minute before an Impossible window starts, uninstall is ungated. Cmd-Q likely skips the gate entirely (no `applicationShouldTerminate`). | Reproduced (Quit/Uninstall); Cmd-Q by reading. |
| I4 | **Paste guard is bypassable.** It rejects only growth of more than one character: type junk, select all, paste. | Predicate reproduced; UI not exercised. |
| I5 | **Unreadable config → data loss.** A nil read is treated as "missing" and becomes an empty config; the next edit overwrites the real file. | Probe confirmed. |
| I6 | **After Quit there is no button to re-enable the login item** short of a gated Uninstall then Install. Plan Step 7 expected one; the recorded result did not cover it. | By reading. |
| I7 | **`ConfigStore.lastWritten` never invalidated**: app saves A, external edit to B, external restore to A is swallowed; the next app edit silently reverts to B. | By reading; event semantics probed. |

### Minor

- Blocking Finder or System Settings is offered in the picker; Finder would be relaunched and killed in a loop (also the one real battery risk).
- No warning anywhere that blocked apps are force-quit and unsaved work is lost.
- Site blocking lags the app's status by up to 32 s (the app never nudges the daemon).
- "Move to Applications" removes the destination before copying; a failed copy leaves no app.
- DST fall-back: a window ending in the repeated hour shows stale status for up to an hour.
- A gapless 24/7 Impossible schedule can be dismantled 26 h ahead (24 h look-ahead horizon).
- README: `uninstall-daemon.sh` does not clear the hosts region as claimed; `focusguardd check` is not on PATH; `bootout` recovery is temporary for an SMAppService daemon.

### Fixed in this pass

- **Intermittent test.** `LockTests.testWeakensAndLockStateAreFastOnLargeAllDayConfig` timed one
  call with wall-clock `Date()` against a 50 ms budget (the call costs ~18 ms of CPU). Under load
  it failed 16–86 % of runs; idle ~0.3 %. Now measures thread CPU time, best of 5. After the fix:
  0 failures in 800 runs including under 16 and 32 busy loops. Test bug, not a product bug.

## What holds up

- `weakens(from:at:)` is correct for all 19 edit kinds probed, including midnight-crossing
  windows, splits, re-ID tricks and last-minute edits; strictest mode per item wins.
- Every in-app config edit goes through the gate; `commit` is the only writer.
- **Battery:** nothing periodic in the app. One wall-deadline timer per boundary, event-driven
  observers, no polling, no `Timer.publish`/`TimelineView`/`Task.sleep`. Measured over 5+ days:
  app 44 s CPU (0.01 %), daemon 94 s (0.02 %), 3 log lines in 24 h.
- Atomic config save keeps mode `0664`; the file watch survives rename-over and does not leak.
- Bundle layout, plists, signing order and exec bits are correct; the scratch build verified
  with `codesign --verify --deep --strict`.
- Recorded live acceptance (plan Task 15, Oct 31): 7 steps passed; two real bugs found and fixed
  there (notch, polite-quit ignored at launch). Kill latency 200–300 ms.

## Untested

- **Reboot** — daemon and agent start at boot/login; clock anchor across boots; mid-window reboot.
- **Sleep/wake across a window boundary** on real hardware.
- **App update path** — re-approval, stale daemon, signature change.
- **Uninstall from the app**, and what it leaves behind.
- **Firefox**, and Chrome with a custom DoH provider. Chrome's own DNS cache keeps a blocked page
  working until restart (observed).
- **VPN / iCloud Private Relay** (known gap, never measured).
- **All app-target logic by unit test**: `AppModel.apply`/`gate`, `ConfigStore`, `AppKiller`,
  `Installer` status mapping, the paste guard.
- **Real use.** The only window ever configured is a disabled leftover from testing.

## Recommended order

1. C1 — detect an off-screen status item and show a Dock icon; say how to open it in the README.
2. I1 + I2 — restart the daemon on app update; then reboot once and record what happens.
3. C2 + I3 + I4 — take lock decisions from the daemon's guarded clock (or have the daemon refuse
   weakening itself), gate Quit/Uninstall/Cmd-Q with the same look-ahead, harden the paste guard.
4. C3 — decide what the modes are for. Either state plainly "friction inside the app only", or
   move enforcement of weakening into the root daemon with a root-owned config.
5. I5–I7, then unit tests for `ConfigStore`, `AppModel`, `AppKiller`, `Installer`.
6. README corrections.

---

# Fix pass (same day, branch `qa-fixes`)

Everything below was done after the report above. Findings keep their numbers.

## What changed

| Finding | Outcome |
|---------|---------|
| C1 app cannot be found | **Fixed, verified live.** `DockFallback` detects the off-screen status item and shows a Dock icon; Settings opens reliably from the menu, Dock, Spotlight and URL (it used not to come to the front, reported by the user during the pass). |
| C2 clock defeats the lock | **Fixed.** The daemon judges; the app reads the daemon's clock offset and time zone. |
| C3 `config.json` hand edits | **Fixed for Impossible** (daemon-enforced, see below). Friction stays app-only, and the README now says so. |
| I1 stale daemon after update | **Fixed.** The app compares the installed binary with its own and offers Update (one password). |
| I2 reboot | **Still untested.** The install is now a plain root LaunchDaemon, the best-trodden path there is, but nobody has rebooted. |
| I3 Quit/Uninstall look-ahead | **Fixed.** Quit just quits (the app is not the enforcer). Uninstall is judged as "block nothing", with the full week of look-ahead. |
| I4 paste guard | **Fixed.** Single-keystroke rule, with tests. |
| I5 unreadable config → data loss | **Fixed**, with a test; the app can restore the file from the daemon's copy. |
| I6 no way to re-enable login item | **Fixed.** A toggle. |
| I7 `lastWritten` never invalidated | **Fixed**, with a test. |
| Minor: Finder in the picker, no force-quit warning, README errors | **Fixed.** |

## Found during the fix pass

1. **The daemon ran as root out of a user-writable folder.** Demonstrated by accident: replacing
   `focusguardd` inside `/Applications/FocusGuard.app` with `ditto`, no password, had launchd
   running the new file as root 52 s later. Any process running as the user could become root.
   The install is now root-owned files behind one password prompt (spec §11.2).
2. **The self-relaunching login agent was not loaded.** `SMAppService` said enabled; launchd had
   no such job; killing the app did not bring it back. Replaced with a plain login item.
3. **Re-registering the daemon raced its own unregister** and left no daemon running until the
   app repaired it. (Moot now; the mechanism is gone.)

## Second independent review: four bypasses of the new daemon lock

Run against the first version of the daemon-enforced lock, before anything was installed.

| | Bypass (no password) | Fix |
|---|---|---|
| B1 | The Impossible window twice in the file with one id: a copy with no lists, a disabled copy with them. | Windows judged by position; duplicate ids do not decode. |
| B2 | Delete `config.json` during window A; a following Impossible window B was never enforced. | A missing or invalid file is a proposal to block nothing, refused by any Impossible window. |
| B3 | A 1 MB config made each judgement take minutes on the daemon's only thread; apps stopped being killed. | `Config.Limits`; one judgement per proposal per minute. |
| B4 | A lock longer than 24 h could be cut to 24 h. | Look-ahead is one week, the schedule's period. |
| TZ | Daemon kept its start-up time zone; app and daemon disagreed after travel; zone change plus reboot shifted the schedule. | Daemon follows the system zone except during an Impossible window, persists it, publishes it. |

Each has a regression test in `LockBypassTests` / `ReconcilerZoneTests`.

## Verified on the machine during the pass

- Dock icon appears when the status item is hidden (`lsappinfo`: ApplicationType Foreground).
- `open focusguard://settings` leaves the window on screen and FocusGuard frontmost.
- macOS started a rebuilt ad-hoc daemon without re-approval (register, and a self-restart).
- 160 tests; 40 consecutive runs without a failure, 15 of them under CPU load.

## Still open

- **Reboot** has not been tried.
- Sleep/wake across a boundary, Firefox, uninstall: untested on hardware.
- Check by hand on macOS 15: whether System Settings → Login Items → "Allow in the Background"
  can switch a root LaunchDaemon off without a password, and whether Safe Mode loads it.
- `AppModel`, `AppKiller` and the Installer's row mapping have no unit tests.
- The install and update scripts are read from the app bundle, which the user owns. A program
  running as the user could alter them and wait for the next password prompt. Signing would
  close that; without a developer account it is narrowed, not closed.

