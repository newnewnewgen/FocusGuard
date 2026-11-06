# FocusGuard

Lightweight macOS website + app blocker on a recurring weekly schedule. Single user, no
Apple Developer account, negligible battery cost. Design:
`docs/superpowers/specs/2026-08-18-focusguard-design.md`. Survey of prior art:
`docs/research/2026-10-27-open-source-blockers.md`. QA record: `docs/qa/`.

## What it is

- **`focusguardd`** — a root launchd daemon. It does the blocking: a marked region in
  `/etc/hosts` for sites, and quitting apps by bundle ID. 2 s tick while an app block is
  active, 30 s otherwise; it never enumerates processes outside a window.
- **`FocusGuard.app`** — a menu-bar app where you edit block lists and the weekly schedule.
  While it is open it also closes blocked apps the moment they launch. Blocking does not
  depend on it: quit it and the daemon carries on.
- **`FocusGuardCore`** — the logic both share, with the tests (`swift test`).

## Install

    scripts/build-app.sh
    ditto build/FocusGuard.app /Applications/FocusGuard.app
    open /Applications/FocusGuard.app

The window opens on the Status tab. Click **Install protection…** and type your password
once: that installs the daemon as root-owned files (`/Library/PrivilegedHelperTools/` and
`/Library/LaunchDaemons/`) and adds FocusGuard to your login items. Ad-hoc signed; requires
macOS 15.

After rebuilding, `ditto` the new bundle over the old one and reopen the app. If the daemon
changed, Status shows **Background daemon needs updating** with an **Update…** button (one
password prompt). Blocking continues with the old daemon until you do.

**Finding the app.** FocusGuard lives in the menu bar (shield icon). macOS silently hides
menu-bar icons that do not fit, which on a notched MacBook with a busy menu bar is common, so
FocusGuard checks whether its icon is actually on screen and shows itself in the **Dock** when
it is not. You can also open the window from Spotlight, or with `open focusguard://settings`.

**Without the app:** `scripts/install-daemon.sh` installs the same daemon from the command
line, and `scripts/uninstall-daemon.sh` removes it. Then edit
`/Library/Application Support/FocusGuard/config.json` by hand (schema:
`Sources/FocusGuardCore/Models.swift`, example: `examples/config.json`).

    /Library/PrivilegedHelperTools/com.focusguard.daemon check    # what would be blocked now
    /usr/bin/log stream --info --predicate 'subsystem == "com.focusguard"'

## Unlock modes

Each schedule window has an unlock mode. It governs anything that would unblock something
while the window is active: removing a site or app, disabling or deleting the window,
shortening it, lowering its mode, uninstalling.

| Mode | What it takes to weaken an active window | Enforced by |
|------|------------------------------------------|-------------|
| **Basic** | Nothing; applies immediately. | — |
| **Friction** (default) | Type a randomly generated sentence, drawn captcha-style, in a field that refuses pasted text. | The app |
| **Impossible** | Cannot be done until the window ends. | The app **and the daemon** |

Adding sites, apps or windows, and extending an end time, are always allowed. The strictest
mode among the windows covering an item wins.

**What Impossible actually guarantees.** `config.json` is writable without a password, so the
daemon treats it as a proposal. It keeps its own accepted copy in `/var/db/FocusGuard`
(root-owned) and refuses any proposal that would unblock something an active Impossible window
protects, judged by its own clock. Editing or deleting the file by hand, changing the Mac's
date, quitting or deleting the app: none of these lift an Impossible block. The refused change
is taken up automatically when the window ends; meanwhile the app shows it as **on hold**. The
daemon's binary, launchd plist and state are root-owned, so replacing them needs your password.

What still gets around it: `sudo` (see Recovery), and the gaps below. **Friction is a speed
bump, not a lock**: it exists only in the app, and editing `config.json` in a text editor
skips it.

## How enforcement works

- **Sites:** a marked region in `/etc/hosts` (`# FOCUSGUARD START` … `END`) with `0.0.0.0`
  and `::` sinks for each domain and its `www.` form. While any block is active the public
  DNS-over-HTTPS resolvers are sinkholed too, so Chrome (automatic secure DNS) and Firefox
  (default) fall back to the system resolver. Written atomically with `fsync`; only the
  marked region is ever touched. A window boundary reaches `/etc/hosts` within 32 s.
- **Apps:** by bundle ID. The app kills a blocked app the moment it launches (~300 ms after
  process start); the daemon's 2 s sweep (SIGTERM, then SIGKILL 3–5 s later) catches anything
  else and works with the app closed. **Blocked apps are force-quit; unsaved work in them is
  lost.** Finder, the Dock and a few other system processes can never be blocked (macOS
  relaunches them instantly, which would be a kill loop).
- **Clock:** the daemon projects schedule time from a persisted anchor along
  `mach_continuous_time`; a wall-clock jump in either direction is ignored for 24 h. The app
  reads the daemon's clock, so its locks agree.
- **Unreadable or missing config** is fail-closed but bounded: the accepted config stays in
  force until the window that was active at the time ends (at most 24 h, unless that window
  is Impossible).

## Recovery

If something goes wrong and you are locked out, this stops the daemon and clears the block
until the next reboot:

    sudo launchctl bootout system/com.focusguard.daemon

To remove it for good, **Settings → Status → Uninstall protection…** (password; gated by the
unlock mode of any active window) or `scripts/uninstall-daemon.sh`. Both stop the daemon,
delete its files and remove the FocusGuard lines from `/etc/hosts`. Your lists and schedule
stay in `config.json`. Nothing else in `/etc/hosts` is ever modified.

## Known gaps

- A browser already running when a window begins may keep loading a site for a while: Chrome
  resolves DNS itself, with its own cache and its own snapshot of `/etc/hosts`, and reuses open
  connections. Quitting and relaunching the browser applies the block at once;
  `chrome://net-internals/#dns` → Clear host cache also works. Sites first visited after the
  window began are blocked immediately.
- VPNs and iCloud Private Relay bypass the hosts layer (only a Network Extension content
  filter covers them, which needs a paid developer account). So does a hand-configured custom
  DoH provider.
- An admin user with `sudo` can always dismantle it. With Impossible windows that is the only
  way; it is strong friction, not a wall.

## Development

    swift test                 # Core and app-target tests
    scripts/build-app.sh       # build/FocusGuard.app, ad-hoc signed

Daemon-only acceptance scripts (need `sudo`): `scripts/verify-once.sh` (single pass, no
launchd), `scripts/verify-launchd.sh` (installed daemon, ~5 minutes), `scripts/verify-teardown.sh`
(SIGTERM cleanup, ~1 minute).
