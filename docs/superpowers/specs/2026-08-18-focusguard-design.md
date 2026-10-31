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
| `FocusGuard.app` | SwiftUI menu-bar app | User, **KeepAlive login item** | Edit config; show status; install the daemon; event-driven app kill (Plan 2). *(Tab watcher §5b deferred.)* |
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
- *(Deferred with §5b)* Automation permission per browser would only be needed
  by the tab watcher; v1 requests none.
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

The daemon runs an idempotent reconciliation loop every **2 seconds while an
app block is active and every 30 seconds otherwise** (battery: `/etc/hosts` is
only *written* on diff and the process table is only enumerated while some
bundle ID is blocked, so an idle tick is one small file read). Timers use
wall-clock deadlines, so a boundary crossed during sleep is honoured within
one tick of waking. Each tick rebuilds desired state from
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
   :: reddit.com
   :: www.reddit.com
   0.0.0.0 dns.google
   …
   # FOCUSGUARD END
   ```
   Desired content = `0.0.0.0` and `::` lines, each also for `www.`, per active
   domain, followed by the public DoH resolver hostnames whenever the domain set
   is non-empty.
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

**Apps (event-driven, Plan 2):** the user-session app subscribes to
`NSWorkspace.didLaunchApplicationNotification` and terminates a blocked bundle
ID the instant it launches. The daemon's 2 s sweep is the backstop and the
only layer that survives the app being quit.

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
  - but the fail-closed state is **bounded**: it persists only while a window
    that was active when the config became unreadable is still active (by
    window ID, per the last-good schedule), and never longer than **24 h**
    (`maxFallback`, covering 24/7 schedules). Then everything is released for
    the rest of the daemon's lifetime; a restart re-arms from `last-good.json`
    (deliberately fail-closed after reboot). No single bug can lock the user
    out for more than 24 h without a restart.
  - Recovery path, documented in the README: `sudo launchctl bootout
    system/<label>` stops the daemon; the daemon's shutdown handler clears its
    hosts region.
- **Clock tamper check (new, revised after review):** schedule matching never
  uses the raw wall clock. The daemon keeps a sticky **anchor**
  `(wallClock, mach_continuous_time)` and always projects "now" from it along
  the monotonic clock, which counts through sleep and cannot be set. The anchor
  moves only on the first sample, in a new boot session (each sample carries
  a `kern.bootsessionuuid` tag; monotonic values from other boots are never
  compared), or
  after the wall clock has disagreed with the projection **continuously for
  24 h** (so a genuine correction eventually wins). A disagreement beyond
  2 minutes in **either** direction is tamper: a forward jump cannot end a
  window early and a backward jump cannot delay one; because the anchor is
  sticky, small repeated steps cannot creep past the tolerance. The anchor is
  persisted root-only in `clock-state.json` so a daemon restart within one boot
  cannot reset it. This closes the open-since-2012 SelfControl bug.
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
  confirm a target site is blocked (hosts layer; with the DoH resolvers
  sinkholed, Chrome's automatic secure DNS and Firefox's default fall back to
  it), a target app is killed on launch, and all are released after the
  window. Done 2026-10-27 via `scripts/verify-launchd.sh` + `verify-teardown.sh`.

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

- *(resolved)* `/Library/Application Support/FocusGuard/` is `root:admin 0775`,
  `config.json` `0664`; `state/` is `root:wheel 0700` holding `last-good.json`
  and `clock-state.json`. Verified on 2026-10-27.
- *(resolved)* No file watcher; the daemon re-reads `config.json` every tick.
- *(resolved 2026-10-30, §10.7)* `SMAppService.daemon` from `/Applications` works ad-hoc signed on
  macOS 15.6 with Xcode 26.3 (the macOS 26 check remains for when this Mac upgrades).
- *(resolved)* Event-driven app kill lives in the Plan 2 app; the daemon
  enumerates with libproc (works without a window server) on a 2 s sweep.
- Exact AppleScript per browser family for "all tabs with URLs", and whether
  `NSAppleScript` or `osascript` subprocess is more robust under TCC.

---

## 10. Plan 2 addendum — `FocusGuard.app` (2026-10-30)

**Status:** Approved for planning. Decided in a brainstorm with the user on
2026-10-30; §3's table and §5a's "event-driven" paragraph are the contract this
section fills in. Nothing here changes the daemon's enforcement semantics.

### 10.1 Scope

- SwiftUI menu-bar app (`LSUIElement`, no Dock icon) that edits `config.json`
  and shows status computed by `FocusGuardCore` from the same file.
- Installs the daemon with `SMAppService.daemon` from inside the bundle and
  registers itself as a `KeepAlive` launch agent. `scripts/install-daemon.sh`
  stays as the documented headless fallback.
- Event-driven app kill in the user session (`NSWorkspace`
  `didLaunchApplicationNotification`); the daemon's 2 s sweep is the backstop.
- One exact wall-clock timer for the next window boundary.
- **Unlock modes** (new, user request): per window, Basic / Friction / Impossible.
- Out of scope, unchanged: tab watcher, stats, notifications, sync, polish.

### 10.2 Shape

Menu-bar dropdown shows status only: the active window(s) and until when, how
many sites and apps are blocked, the next change ("Next: Evening at 19:00"),
then "Open Settings…" and "Quit". Editing lives in a standard Settings window
with three tabs:

- **Status** — a guided-setup checklist on first run that becomes the health
  view once installed: *in /Applications* → *daemon installed* → *start at
  login*, each row with its one button ("Move to Applications", "Install
  protection", "Open Login Items settings"). Afterwards: daemon running (pid),
  current window, counts, and "Uninstall protection".
- **Block Lists** — sidebar of lists; detail shows Sites (domain rows + add
  field) and Apps (icon + name rows + "Add app"). "Add app" opens a sheet
  listing running apps first (with icons), then `/Applications` and
  `~/Applications`, scanned **when the sheet opens**, searchable, plus an
  "Other bundle ID" field.
- **Schedule** — one row per window: name, seven day toggles, start/end time
  pickers, list checkboxes, unlock mode picker, enabled switch, delete.

No countdowns and no per-minute refresh: the menu says "until 12:00".

### 10.3 Data model change

`ScheduleWindow` gains `unlockMode: UnlockMode` (`basic | friction |
impossible`), encoded as a string. Decoding a config without the key yields
`.friction`, so existing files stay valid and the daemon, which ignores the
field, is unaffected. `Config.currentVersion` stays 1.

### 10.4 Unlock modes

A **weakening action** is anything that would unblock something before the
schedule does: removing a site or app from a list attached to an active window,
deleting such a list, disabling or deleting an active window, moving its start
later or its end earlier, removing days or lists from it, lowering its unlock
mode, quitting the app, or uninstalling protection. Adding is never weakening.

Every weakening action is gated by the **strictest mode among the active
windows it touches** (impossible > friction > basic):

| Mode | Behaviour |
|------|-----------|
| Basic | Applies immediately. |
| Friction | A challenge sheet shows a randomly generated sentence of common words that must be typed exactly. The sentence is drawn captcha-style (per-glyph rotation and baseline jitter, strike lines, speckle noise, not selectable) and the input field rejects any change that adds more than one character, so paste and drag-in do not work. |
| Impossible | The control is disabled and labelled "Locked until HH:mm", where the time is when the last active window protecting it ends. |

Mode changes outside active time are free. The daemon enforces the file
regardless; this gate is the app's own friction, consistent with §1 ("strong
friction, not a wall": an admin with `sudo` can still edit the file).

### 10.5 Core additions (pure, test-first)

- `Config.nextBoundary(after: Date, calendar:) -> Date?` — the next instant any
  enabled window starts or ends, searching up to 8 days ahead. Drives the timer.
- `Config.lockState(at: LocalMoment) -> LockState` — for the current moment:
  the strictest mode protecting each list, each window, and the app as a whole,
  plus `lockedUntil: TimeOfDay?` (when the old config's active set becomes empty,
  within 24 h). The UI reads this to disable controls and label them.
- `Config.weakens(from old: Config, at: LocalMoment) -> UnlockMode?` — walks
  minute by minute from now until `old` is idle (max 1440 steps) and returns the
  strictest mode of any `old` window whose blocked items are missing from the
  new config at that minute, or `nil` if nothing weakens. This is the save-time
  guard behind every affordance, so a path the UI forgot to lock is still gated.
- `Challenge` — `sentence(wordCount:using: inout RandomNumberGenerator)` from a
  bundled list of ~250 common words, and `matches(typed:sentence:)` (exact after
  trimming trailing whitespace). Seedable for tests.
- `Config.statusSummary(at:)` — active window names, blocked counts, next
  change, for the menu and Status tab.

### 10.6 App components

| Unit | Responsibility | Depends on |
|------|----------------|------------|
| `ConfigStore` | Load `config.json`; publish `Config`; `apply(edit)` runs the edit on a copy, asks `weakens`, and either saves (temp file + rename in the same directory) or returns `.needsUnlock(mode)`; a vnode `DispatchSource` on the file picks up external edits. | Core |
| `ScheduleClock` | One `DispatchSourceTimer` armed on a wall deadline at `nextBoundary`; re-armed when it fires, when config changes, on `NSWorkspace.didWakeNotification`, and on `NSSystemClockDidChange`. Publishes the current `ActiveSet` and `LockState`. | Core, ConfigStore |
| `AppKiller` | Observes `didLaunchApplicationNotification`; if the bundle ID is in the active set, `terminate()`, then `forceTerminate()` from a one-shot 3 s timer if still running. When a boundary enters a window, one sweep of `runningApplications`. | ScheduleClock |
| `Installer` | `SMAppService.daemon("com.focusguard.daemon.plist")` and `SMAppService.agent("com.focusguard.app.plist")`; status mapping; `openSystemSettingsLoginItems()`; "move to /Applications" (copy bundle, relaunch, quit); detects a legacy `/Library/LaunchDaemons/com.focusguard.daemon.plist` and tells the user to run `scripts/uninstall-daemon.sh` first (same label would collide). | ServiceManagement |
| `DaemonProbe` | On-demand libproc scan for a running `focusguardd` (Status tab appears, after install actions, boundary ticks). Never periodic. | libproc |
| `UnlockGate` | Resolves a `.needsUnlock(mode)`: basic → proceed; friction → present `ChallengeSheet`, proceed on match; impossible → never called (controls are disabled). Quit and Uninstall go through it too. | Core.Challenge |

### 10.7 Install model (verified by spike 2026-10-30)

Bundle layout: `Contents/MacOS/FocusGuard`, `Contents/MacOS/focusguardd`,
`Contents/Library/LaunchDaemons/com.focusguard.daemon.plist`,
`Contents/Library/LaunchAgents/com.focusguard.app.plist`. The daemon plist uses
`BundleProgram` (`Contents/MacOS/focusguardd`) with `ProgramArguments`
`[focusguardd, run]`, `RunAtLoad`, `KeepAlive`, `AssociatedBundleIdentifiers`;
the `StandardOutPath`/`StandardErrorPath` keys are dropped (the daemon logs to
`os.Logger`; launchd cannot create `/Library/Logs/FocusGuard`). The agent plist
mirrors it for the app with `KeepAlive` true so a quit app relaunches; "Quit"
in the menu therefore unregisters the agent first (gated by unlock mode) so it
stays quit.

An ad-hoc-signed bundle in `/Applications` on macOS 15.6 registers with
`register()` throwing "Operation not permitted" while status becomes
`requiresApproval`; after the user enables it under Login Items → Allow in the
Background, the daemon runs as uid 0 with the plist's argv. Build is
`scripts/build-app.sh`: `swift build -c release`, assemble, `codesign -s -`.
No Xcode project (`*.xcodeproj` is gitignored). The daemon creates the support
directory on first start; before that the app cannot write `config.json` and
Status says so.

### 10.8 Battery

Idle cost of the app: one armed timer, one vnode watch, one workspace observer.
All push; nothing polls, nothing refreshes on a cadence.

### 10.9 Errors

- Config unreadable: Status shows the decode error; editing is disabled until
  the file parses (the daemon is in bounded fail-closed meanwhile, §6).
- Config dir missing or not writable: Status explains and points at Install.
- `requiresApproval`: button to the Login Items pane; Status re-probes when the
  window regains focus.
- Not in `/Applications`: Install disabled until moved.
- Legacy manual daemon present: Install disabled with the uninstall instruction.
- App clock vs daemon clock: the app uses the raw wall clock for status and
  locks; the daemon uses the tamper-guarded clock. Under tamper they may
  disagree; enforcement (daemon) wins, status is informational.

### 10.10 Testing

Core: XCTest, test-first — `nextBoundary` (same day, next day, week wrap,
midnight-crossing, disabled windows, empty config, DST day), `lockState` and
`weakens` (remove item, shorten end, extend end is fine, remove day, disable,
delete list, lower mode, strictest-wins across two windows), `Challenge`
(deterministic with seed, exact match, trailing whitespace). App: manual
acceptance on this Mac — build, move, install, approve, daemon running from the
bundle, edit a list and see the daemon's hosts region follow within a tick,
launch Chess during a window and measure kill latency from the launch
notification (~100 ms target), friction challenge blocks paste, impossible
locks controls, boundary timer flips status on the minute. Resolves the
`SMAppService` question in §9.
