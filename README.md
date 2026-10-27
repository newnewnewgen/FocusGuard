# FocusGuard

Lightweight macOS website + app blocker on a recurring weekly schedule. Single user, no
Apple Developer account, negligible battery cost. Design:
`docs/superpowers/specs/2026-08-18-focusguard-design.md`. Survey of prior art:
`docs/research/2026-10-27-open-source-blockers.md`.

## Status

- [x] `FocusGuardCore` — schedule matching, active set, hosts region (incl. DoH-resolver
      sinkhole), sticky-anchor clock-tamper guard, bounded fail-closed, reconciler. `swift test`.
- [x] `focusguardd` — root launchd daemon: `/etc/hosts` + app kill. 2 s tick while an app
      block is active, 30 s otherwise; never enumerates processes outside a window.
- [ ] `FocusGuard.app` — menu-bar config editor and `SMAppService` installer (Plan 2).

## Install the daemon (manual, until the app exists)

    scripts/install-daemon.sh

Config lives at `/Library/Application Support/FocusGuard/config.json` and is writable by
admin users (see `examples/config.json`). The daemon re-reads it on every tick; no restart.

    focusguardd check        # what would be blocked right now (any user)
    log stream --predicate 'subsystem == "com.focusguard"' --level info

Acceptance scripts: `scripts/verify-once.sh` (single pass, no launchd) and
`scripts/verify-launchd.sh` (installed daemon, ~5 minutes) and `scripts/verify-teardown.sh`
(SIGTERM cleanup only, ~1 minute).

## How enforcement works

- **Sites:** a marked region in `/etc/hosts` (`# FOCUSGUARD START` … `END`) with `0.0.0.0`
  and `::` sinks for each domain and its `www.` form. While any block is active the public
  DNS-over-HTTPS resolvers are sinkholed too, so Chrome (automatic secure DNS) and Firefox
  (default) fall back to the system resolver. Written atomically with `fsync`; only the
  marked region is ever touched.
- **Apps:** by bundle ID. SIGTERM, then SIGKILL 3–5 s later. Helper processes are never
  targeted by their parent's ID.
- **Clock changes don't help.** Schedule time is projected from a persisted anchor along
  `mach_continuous_time`; a wall-clock jump in either direction is ignored for 24 h.
- **Unreadable config is fail-closed but bounded:** the last good config is enforced until
  the window that was active at the time ends (max 24 h), then released.

## Recovery

If something goes wrong and you are locked out:

    sudo launchctl bootout system/com.focusguard.daemon

The daemon clears its `/etc/hosts` region on the way down. If it didn't, delete the lines
between `# FOCUSGUARD START` and `# FOCUSGUARD END` in `/etc/hosts`. Nothing else in that
file is ever modified. `scripts/uninstall-daemon.sh` does both and removes the binary.

## Known gaps (v1)

VPNs and iCloud Private Relay bypass the hosts layer (only a Network Extension content filter
covers them, which needs a paid developer account). A hand-configured custom DoH provider
bypasses it. An admin user with `sudo` can always dismantle it — this is strong friction, not
a wall.
