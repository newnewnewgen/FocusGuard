# FocusGuard — Design Spec

**Date:** 2026-08-18
**Status:** Approved for planning
**Working name:** FocusGuard (rename anytime)

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
- Break-glass / timed override
- Blocking DNS-over-HTTPS (DoH) endpoints
- Stats, history, or reporting
- Notifications
- iCloud / cross-device sync
- Visual polish and animation

## 3. Architecture

Enforcement cannot live in the config app, because a quit process enforces
nothing. The system is therefore split into two build targets plus a shared
logic module, in one repository.

### Components

| Component | Kind | Runs as | Responsibility |
|-----------|------|---------|----------------|
| `FocusGuard.app` | SwiftUI menu-bar app | User | Edit config; show status; install/remove the daemon |
| `focusguardd` | Swift CLI executable | **root** via `launchd` | Read config; enforce on a timer; no UI |
| `FocusGuardCore` | Swift module (library) | — | Pure logic shared by both: config models, schedule matching, hosts-region diffing. All unit tests live here. |

### Install & privilege model

- First launch: the app calls `SMAppService.daemon(...)` to register the
  `launchd` daemon shipped inside the app bundle
  (`Contents/Library/LaunchDaemons/`). macOS shows one approval prompt in
  System Settings → Login Items.
- The daemon is configured with `RunAtLoad` + `KeepAlive` so it starts at boot
  and relaunches if killed or if it crashes.
- Uninstall: the app calls `SMAppService` unregister; the daemon cleans its
  `/etc/hosts` region on shutdown.

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

## 5. Enforcement Flow

The daemon runs an idempotent reconciliation loop every ~20 seconds, and also
on config-file change. Each tick rebuilds desired state from scratch and
converges to it, so a crash + relaunch mid-window simply re-converges with no
stuck state to repair.

Each tick:

1. **Compute active set** — the union of all block lists belonging to a
   `ScheduleWindow` that is `enabled` and whose `days` + `start`/`end` match the
   current local time. Yields a set of blocked domains and a set of blocked
   bundle IDs.
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
3. **Apps** — enumerate running applications; any whose bundle ID is in the
   active set is terminated (SIGTERM, escalating to SIGKILL if it does not
   exit).
4. **Outside all windows** — the marked region is emptied and no apps are
   killed.

## 6. Error Handling & Key Decisions

- **Fail-open on bad config (decided):** if the daemon cannot read or parse the
  config at all, it *removes* blocks rather than locking the user out of
  everything on a bug. Deliberate weakening of strictness in favor of not
  trapping the user.
- **Malformed config on an otherwise-readable file:** keep the last-known-good
  config in memory, log the error, do not crash.
- **Manual `/etc/hosts` edits:** preserved. The daemon reconciles only its
  marked region.
- **DST / timezone:** schedule windows are matched against the machine's current
  local calendar time.
- **DoH caveat:** browsers with DNS-over-HTTPS enabled resolve over HTTPS and
  bypass `/etc/hosts`. v1 accepts this limitation; v2 may block common DoH
  endpoints.
- **App-block flicker:** a blocked app may be visible for up to one poll
  interval before being quit. Accepted; tightening the interval reduces it.

## 7. Testing Strategy

- **Unit (TDD core, in `FocusGuardCore`):** schedule matching, active-set
  computation, and hosts-region diffing are pure functions with no root
  requirement. This is the bulk of the logic and the primary defense against
  bugs. Written test-first.
- **Integration:** exercise the daemon's reconciliation against an injectable
  temp hosts-file path and a fake clock; assert convergence across
  window-enter / window-exit / crash-relaunch scenarios.
- **Manual acceptance:** install for real, define a 2-minute block window,
  confirm a target site and a target app are blocked during the window and
  released after it.

## 8. Design Principles (isolation & testability)

- Enforcement logic is pure and injectable (clock, hosts-file path, running-app
  list, process-killer are all interfaces) so the core is unit-testable without
  root and without touching the real system.
- The daemon is "dumb": it polls config and enforces. All schedule intelligence
  lives in `FocusGuardCore`. The app is a thin editor over the config file.
- Idempotent convergence over stateful transitions — every tick is safe to run
  from any starting state.

## 9. Open Implementation Questions (resolve during planning)

- Exact directory/file permission scheme for the shared config path so a
  user-level app can write a file a root daemon reads.
- Whether to watch the config file (FSEvents) in addition to the 20s poll, or
  rely on the poll alone for v1 simplicity.
- Confirm `SMAppService.daemon` registration succeeds from `/Applications` on
  macOS 26.3.
