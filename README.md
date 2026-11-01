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
- [x] `FocusGuard.app` — menu-bar editor, `SMAppService` installer, instant app kill, unlock modes.

## Install

    scripts/build-app.sh
    open build/FocusGuard.app

On a fresh install the FocusGuard window opens by itself on the Status tab and walks through
it: **Move to Applications** (macOS only runs background daemons for apps in `/Applications`),
**Install protection** (registers `focusguardd` as a root daemon and FocusGuard as a login
item, both from inside the bundle), then approve FocusGuard in System Settings → General →
Login Items & Extensions → Allow in the Background. The row turns green when the daemon is
running. Ad-hoc signed; no developer account needed. Requires macOS 15.

The menu-bar shield may be hidden behind the notch on a crowded menu bar. Reopen the app
(click it in Finder or Launchpad) or run `open focusguard://settings` to bring the window up.

Config lives at `/Library/Application Support/FocusGuard/config.json`, written by the app,
re-read by the daemon every tick (schema: `Sources/FocusGuardCore/Models.swift`, example:
`examples/config.json`). After rebuilding, copy the new bundle over `/Applications/FocusGuard.app`
(`ditto build/FocusGuard.app /Applications/FocusGuard.app`) and relaunch; the registrations stay.

    focusguardd check        # what would be blocked right now (any user)
    /usr/bin/log stream --info --predicate 'subsystem == "com.focusguard"'

**Fallback without the app:** `scripts/install-daemon.sh` installs the daemon by hand under
the same launchd label (`/usr/local/libexec/focusguardd`). Never use both; the app's Status
tab refuses to install while the manual plist exists and tells you to run
`scripts/uninstall-daemon.sh`.

Acceptance scripts for the daemon alone: `scripts/verify-once.sh` (single pass, no launchd),
`scripts/verify-launchd.sh` (installed daemon, ~5 minutes) and `scripts/verify-teardown.sh`
(SIGTERM cleanup only, ~1 minute).

## Unlock modes

Each schedule window has an unlock mode that governs anything that would unblock something
while it is active (removing a site or app, disabling or deleting the window, shortening it,
lowering its mode, quitting the app, uninstalling):

- **Basic** — applies immediately.
- **Friction** (default) — type a randomly generated sentence, word for word. It is drawn
  captcha-style and the field refuses pasted text.
- **Impossible** — disabled until the window ends ("Locked until 12:00").

Adding sites, apps or windows, and extending an end time, are always allowed. The strictest
mode among the active windows wins. Quitting the app also stops it launching at login until
you reinstall; the daemon keeps enforcing either way.

## How enforcement works

- **Sites:** a marked region in `/etc/hosts` (`# FOCUSGUARD START` … `END`) with `0.0.0.0`
  and `::` sinks for each domain and its `www.` form. While any block is active the public
  DNS-over-HTTPS resolvers are sinkholed too, so Chrome (automatic secure DNS) and Firefox
  (default) fall back to the system resolver. Written atomically with `fsync`; only the
  marked region is ever touched.
- **Apps:** by bundle ID. The app kills a blocked app the moment it launches (NSWorkspace
  launch notification, ~300 ms after process start); the daemon's 2 s sweep (SIGTERM, then
  SIGKILL 3–5 s later) catches anything else and is the only layer that survives the app being
  quit. Helper processes are never targeted by their parent's ID.
- **Clock changes don't help.** Schedule time is projected from a persisted anchor along
  `mach_continuous_time`; a wall-clock jump in either direction is ignored for 24 h.
- **Unreadable config is fail-closed but bounded:** the last good config is enforced until
  the window that was active at the time ends (max 24 h), then released.

## Recovery

If something goes wrong and you are locked out:

    sudo launchctl bootout system/com.focusguard.daemon

Settings → Status → Uninstall protection removes the daemon and login item (gated by the
unlock mode of any active window). The daemon clears its `/etc/hosts` region on the way down. If it didn't, delete the lines
between `# FOCUSGUARD START` and `# FOCUSGUARD END` in `/etc/hosts`. Nothing else in that
file is ever modified. `scripts/uninstall-daemon.sh` does both and removes the binary.

## Known gaps (v1)

A browser that already has the site open keeps working until it re-resolves: browsers cache
DNS and reuse open connections. Quit and relaunch the browser (Chrome: `chrome://net-internals/#dns`
→ Clear host cache) and the block applies.

VPNs and iCloud Private Relay bypass the hosts layer (only a Network Extension content filter
covers them, which needs a paid developer account). A hand-configured custom DoH provider
bypasses it. An admin user with `sudo` can always dismantle it — this is strong friction, not
a wall.
