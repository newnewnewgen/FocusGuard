# FocusGuard — Design Spec

**Date:** 2026-08-18 · **Revised:** 2026-10-27
**Status:** Approved for planning
**Working name:** FocusGuard (rename anytime)

> **Revision 2026-10-27.** Incorporates the open-source survey in
> `docs/research/2026-10-27-open-source-blockers.md`. Four changes: a
> browser tab-watcher layer (DoH-proof), a clock-tamper check, bounded
> fail-closed instead of fail-open, and launch-event app killing. Changed
> sections are marked **[rev]**.
>
> **Later the same day:** the tab watcher is **deferred indefinitely** on
> battery grounds (1–3 % CPU per browser during windows). In its place the
> hosts region also sinkholes the public DoH resolvers (`dns.google`,
> `cloudflare-dns.com`, `mozilla.cloudflare-dns.com`, …) whenever a block is
> active, so Chrome's automatic secure-DNS and Firefox's default TRR mode fall
> back to the system resolver. Zero runtime cost. Revisit the watcher only if
> real use shows hosts + DoH sinkhole is insufficient. §5b is kept below as
> the design on file but is not scheduled.

## 1. Purpose

A native macOS app that protects deep-work blocks by hard-blocking distracting
websites and applications on a recurring weekly schedule. Built for a single
user on their own Mac. No cost, no Apple Developer account.

**Strictness:** hard lockout — enforcement survives quitting the config app,
relaunches on login/crash, and is only lifted when the scheduled window ends.
It is "strong friction," not an OS-enforced wall: a determined admin user can
still dismantle it (accepted tradeoff of the free path).

## 2. Non-Goals (v1)

Deferred to v2+, explicitly out of scope for the first working version:

- Manual "start focus now" ad-hoc sessions
- Break-glass / timed override (typing-challenge friction is the settled v2 pattern)
- The browser tab watcher (§5b) — deferred, see revision note
- pf firewall rules (hosts + DoH sinkhole is the v1 stack; pf is a v2 layer)
- Custom/hand-configured DoH providers beyond the sinkholed public list
- Stats, history, or reporting
- Notifications
- iCloud / cross-device sync
- Visual polish and animation

## 3. Architecture **[rev]**

Enforcement cannot live only in a quit-able config app. Two enforcement layers
run in different security contexts, so the system is split into two build
targets plus a shared logic module, in one repository:

- **Network layer** (hosts file, app kill) needs root → lives in a `launchd`
  daemon.
- **Browser layer** (tab watcher) sends Apple Events to the user's browsers,
  which a root daemon cannot do → lives in the user-session app, which is
  therefore itself kept alive by `launchd` as a login item.

### Components

| Component | Kind | Runs as | Responsibility |
|-----------|------|---------|----------------|
| `FocusGuard.app` | SwiftUI menu-bar app | User, **KeepAlive login item** | Edit config; show status; install the daemon; **run the browser tab watcher (§5b)** |
| `focusguardd` | Swift CLI executable | **root** via `launchd` | Read config; enforce hosts + app kills; no UI |
| `FocusGuardCore` | Swift module (library) | — | Pure logic shared by both: config models, schedule matching, active-set computation, hosts-region diffing, URL matching, clock-tamper logic. All unit tests live here. |

### Install & privilege model

- First launch: the app calls `SMAppService.daemon(...)` to register the
  `launchd` daemon shipped inside the app bundle
  (`Contents/Library/LaunchDaemons/`), and `SMAppService.agent(...)` /
  `loginItem` to register **itself** with `KeepAlive` so quitting the app
  relaunches it. macOS shows the approval in System Settings → Login Items.
- The daemon is configured with `RunAtLoad` + `KeepAlive` so it starts at boot
  and relaunches if killed or if it crashes.
- The app requests **Automation** permission for each supported browser the
  first time it needs to script it (standard TCC prompt). Without it the tab
  watcher is inert and the hosts layer alone applies.
- Uninstall: the app calls `SMAppService` unregister for both; the daemon
  cleans its `/etc/hosts` region on shutdown.
- The two layers are independent: killing the app does not weaken the hosts
  layer; the daemon does not depend on the app being alive.

**macOS 26 (Tahoe) note:** system extensions / privileged daemons are sensitive
to app location. The `.app` should live in `/Applications`. (This bit
Network-Extension users on Tahoe; verify the `SMAppService` daemon path is
accepted from `/Applications` during implementation.)

## 4. Data Model

Config is a single JSON file at
`/Library/Application Support/FocusGuard/config.json`. The app writes it; the
daemon reads it. Directory permissions are set at install so the user can write
and root can read.

```
Config
  version: Int
  blockLists: [BlockList]
  schedules:  [ScheduleWindow]

BlockList
  id:           UUID
  name:         String
  domains:      [String]     // e.g. "reddit.com"
  appBundleIDs: [String]     // e.g. "com.tinyspeck.slackmacgap"

ScheduleWindow
  id:           UUID
  name:         String
  days:         [Weekday]    // Mon…Sun
  start:        "HH:mm"      // local time
  end:          "HH:mm"      // local time
  blockListIDs: [UUID]
  enabled:      Bool
```

Apps are identified by **bundle ID**, not display name — stable and not easily
spoofed.

## 5. Enforcement Flow **[rev]**

### 5a. Daemon (root): hosts + apps

The daemon runs an idempotent reconciliation loop every ~20 seconds, on
config-file change, and on **system wake** (so a window boundary that passed
during sleep is applied immediately). Each tick rebuilds desired state from
scratch and converges to it, so a crash + relaunch mid-window simply
re-converges with no stuck state to repair.

Each tick:

1. **Compute active set** — the union of all block lists belonging to a
   `ScheduleWindow` that is `enabled` and whose `days` + `start`/`end` match the
   current local time **as adjusted by the clock-tamper check (§6)**. Yields a
   set of blocked domains and a set of blocked bundle IDs.
2. **Sites** — maintain a marked region in `/etc/hosts`:
   ```
   # FOCUSGUARD START
   0.0.0.0 reddit.com
   0.0.0.0 www.reddit.com
   # FOCUSGUARD END
   ```
   Desired content = one `0.0.0.0` line (plus a `www.` line) per active domain.
   Write the file only if the region's desired content differs from current.
   After writing, flush DNS (`dscacheutil -flushcache; killall -HUP
   mDNSResponder`). The daemon owns **only** the marked region; all other
   `/etc/hosts` content is preserved.
3. **Apps (sweep)** — enumerate running applications; any whose bundle ID is in
   the active set is terminated (SIGTERM, escalating to SIGKILL after ~3s if it
   does not exit). Browser *helper* processes (`…Helper`, `…Renderer`) are never
   targeted directly — only the parent app.
4. **Outside all windows** — the marked region is emptied and no apps are
   killed.

**Apps (event-driven, in addition to the sweep):** the daemon subscribes to
`NSWorkspace.shared.notificationCenter` `didLaunchApplicationNotification`.
When a blocked bundle ID launches during an active window it is terminated
immediately, so the user sees at most a flash rather than up to 20 s of the
app. The 20 s sweep remains the safety net for apps already running when a
window opens, and for any missed notification.

### 5b. App (user session): browser tab watcher — **DEFERRED, not scheduled**

Runs only while at least one window is active (the app computes the same
active set from the same config via `FocusGuardCore`). Design copied from
dh-blocker, not appjail — every tab, every second, redirect rather than close:

1. Every **1 s**, for each supported running browser (Safari, Chrome, Brave,
   Edge, Arc — all Chromium-family share one script), run one AppleScript that
   returns `(window, tab, url)` for **every open tab**, not just the active one.
2. Match each URL's host against the active domain set: exact host, or any
   subdomain (`*.reddit.com`). Matching is a pure function in
   `FocusGuardCore`.
3. For each match, set that tab's URL to a bundled local block page
   (`file:///…/blocked.html?from=<host>`), preserving the tab so the user's
   session isn't destroyed.
4. **All Apple Events go through a single serial queue.** Concurrent
   `osascript`/NSAppleScript calls deadlock the Apple Event manager.
5. Error handling: `-600` (browser not running) → skip silently. `-1743`
   (Automation permission denied) during an active window → the app
   **terminates that browser** and shows a menu-bar notice explaining why
   (same enforcement as dh-blocker's `enforcer`). Revoking consent must not be
   a free bypass.

Why this layer exists: `/etc/hosts` is the single most-reported bypass in
SelfControl's issue tracker — any browser with DNS-over-HTTPS on never consults
it. The tab watcher reads the URL the browser is actually showing, so DNS
doesn't matter. Firefox is the one gap (no scriptable tab dictionary) and is
deferred.

## 6. Error Handling & Key Decisions **[rev]**

- **Bounded fail-closed on unreadable config (revised, was fail-open):**
  SelfControl removes its block the moment its state file disappears; this is a
  documented bypass. FocusGuard instead:
  - keeps the **last-known-good config in memory** and keeps enforcing it;
  - on daemon start with no readable config, reads a root-owned
    `last-good.json` snapshot the daemon writes beside the config after every
    successful parse, and enforces that;
  - but the fail-closed state is **bounded**: it persists only until the end of
    the window that was active when the config became unreadable (per the
    last-good schedule). Once no window is active, everything is released.
    There is no way for a bug to produce an indefinite lockout.
  - Recovery path, documented in the README: `sudo launchctl bootout
    system/<label>` stops the daemon; the daemon's shutdown handler clears its
    hosts region.
- **Clock tamper check (new):** every ScheduleWindow evaluation uses wall-clock
  time, but the daemon also records `(wallClock, mach_continuous_time)` at each
  tick in memory and in `last-good.json`. If wall clock moved **backwards**
  relative to the monotonic delta by more than 2 minutes, the daemon treats the
  current time as `lastWall + monotonicDelta` (i.e. the time it *should* be)
  for schedule matching until the two agree again. Forward jumps are trusted
  (sleep, NTP corrections are forward or tiny). Changing the clock cannot end a
  window early — the open-since-2012 SelfControl bug.
- **Malformed config on an otherwise-readable file:** same as unreadable —
  last-known-good, log the error, do not crash.
- **Manual `/etc/hosts` edits:** preserved. The daemon reconciles only its
  marked region.
- **DST / timezone:** schedule windows are matched against the machine's current
  local calendar time.
- **DoH:** bypasses `/etc/hosts`. Mitigated by sinkholing the public DoH
  resolver hostnames in the same hosts region while any block is active;
  Chrome (automatic mode) and Firefox (default mode) then fall back to the
  system resolver. A hand-configured custom DoH provider is an accepted gap.
- **VPN / iCloud Private Relay:** not addressed by any layer (SelfControl calls
  it "not technically feasible"; only a Network Extension content filter, which
  needs a paid developer account, covers it). Accepted.
- **App-block flicker:** a blocked app may be visible for a fraction of a
  second (launch notification) or, if already running when a window opens, up
  to one sweep interval. Accepted.
- **Tab flicker:** a blocked page may render for up to ~1 s before redirect.
  Accepted.
- **License:** SelfControl is GPL-3. Nothing is copied from it; all mechanisms
  are reimplemented from the survey's description.

## 7. Testing Strategy

- **Unit (TDD core, in `FocusGuardCore`):** schedule matching, active-set
  computation, hosts-region diffing, **URL-host matching, clock-tamper
  adjustment, and the fail-closed bound** are pure functions with no root
  requirement. This is the bulk of the logic and the primary defense against
  bugs. Written test-first.
- **Integration:** exercise the daemon's reconciliation against an injectable
  temp hosts-file path, a fake clock (wall + monotonic), and a fake process
  list; assert convergence across window-enter / window-exit /
  crash-relaunch / clock-rewind / config-vanishes scenarios. Tab watcher:
  inject a fake "browser" that returns scripted tab lists and records
  redirects.
- **Manual acceptance:** install for real, define a 2-minute block window,
  confirm a target site is blocked in Safari with DoH off (hosts layer) and in
  Chrome with DoH on (tab watcher), a target app is killed on launch, and all
  are released after the window.

## 8. Design Principles (isolation & testability)

- Enforcement logic is pure and injectable (clock, hosts-file path, running-app
  list, process-killer, browser-tab source are all interfaces) so the core is
  unit-testable without root and without touching the real system.
- The daemon is "dumb": it polls config and enforces. All schedule intelligence
  lives in `FocusGuardCore`. The app is a thin editor over the config file plus
  the tab watcher, which is itself a thin loop over a Core matching function.
- Separate *process alive* from *policy alive* (abstand's ADR): `KeepAlive`
  handles the first; root-owned config + `last-good.json` handle the second.
- Idempotent convergence over stateful transitions — every tick is safe to run
  from any starting state.

## 9. Open Implementation Questions (resolve during planning)

- Exact directory/file permission scheme for the shared config path so a
  user-level app can write a file a root daemon reads.
- Whether to watch the config file (FSEvents) in addition to the 20s poll, or
  rely on the poll alone for v1 simplicity.
- Confirm `SMAppService.daemon` registration succeeds from `/Applications` on
  macOS 26.3.
- Whether the daemon (a non-GUI process running as root) receives
  `NSWorkspace` launch notifications reliably, or whether the event-driven app
  kill should be delegated to the user-session app (with the daemon's sweep as
  backstop). Decide by spike.
- Exact AppleScript per browser family for "all tabs with URLs", and whether
  `NSAppleScript` or `osascript` subprocess is more robust under TCC.
