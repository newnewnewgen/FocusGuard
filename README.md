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
protects, judged by its own clock and time zone, looking a full week ahead. None of these lift
an Impossible block: editing the file by hand, deleting or corrupting it (that counts as a
proposal to block nothing), changing the Mac's date, time or time zone, quitting or deleting
the app. A refused change is taken up automatically when the window ends; meanwhile the app
shows it as **on hold**. The daemon's binary, launchd plist and state are root-owned, so
replacing them needs your password.

Two consequences worth knowing before you choose it:

- To change or remove an Impossible schedule, do it **while none of its windows is active**.
- A schedule with **no gap all week** can never be weakened without `sudo`. That is what you
  asked for; leave a gap if you want a way out.

What still gets around it: `sudo` (see Recovery), and the gaps below. **Friction is a speed
bump, not a lock**: it exists only in the app, and editing `config.json` in a text editor
skips it.

## Keywords

A block list can hold keyword rules as well as site names: `manga` with **starts with** blocks
mangadex.org and mangaplus.shueisha.co.jp; **whole word** blocks manga.example.com and
read-manga.net but not mangalore.in; **contains** and **ends with** do what they say. Rules
match the **site name only** — never a page path, a search or a title, which HTTPS hides.
Whole word, starts with and ends with look at the parts of the name between dots and hyphens.

While any list has keyword rules, the daemon watches the Mac's outgoing DNS questions (a
kernel filter wakes it for those alone; a busy day costs about a second of CPU). A name that
matches is learned, stored in `/var/db/FocusGuard/learned.json` and blocked from then on in
every browser and app, during any window whose list has a matching rule. Only matches are
stored, never your lookup history. The **Always allow** list stops keyword rules (not names
you listed yourself) from blocking a site and its subdomains.

The first ever lookup of a never-seen matching site succeeds — the answer is already on its
way back — so that one page may load, and a browser's own cache may keep it working for up to
about a minute. Sites you have visited before, inside or outside a window, are known already.
Encrypted DNS configured system-wide and iCloud Private Relay hide lookups from the daemon,
as they already hide them from the hosts layer. VPNs that use `ipsec*` or `ppp*` interfaces rather than `utun*` are not watched.

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
- **Unreadable or missing config** is fail-closed: the accepted config stays in force until
  the window that was active at the time ends (at most 24 h), and through every Impossible
  window after that. A config with duplicate ids, or larger than the limits in
  `Config.Limits` (512 KB, 48 windows, 32 lists, 2000 sites, 300 apps), counts as unreadable.

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
- Apps are matched by bundle ID. A copy of an app with its bundle ID edited is a different app
  as far as FocusGuard can tell.
- Keyword rules see site names only; a page about manga on a site whose name does not match is not caught.
- An admin user with `sudo` can always dismantle it. With Impossible windows that is the only
  way; it is strong friction, not a wall.

## Development

    swift test                 # Core and app-target tests
    scripts/build-app.sh       # build/FocusGuard.app, ad-hoc signed

`scripts/verify-impossible.sh` attacks a real 5-minute Impossible window the ways a user could
without a password and checks it holds, then releases by itself (~6 minutes, no `sudo`).

`scripts/verify-keywords.sh` checks keyword rules, learning, the allow list and the Impossible hold (~2 minutes, no `sudo`).

Daemon-only acceptance scripts (need `sudo`): `scripts/verify-once.sh` (single pass, no
launchd), `scripts/verify-launchd.sh` (installed daemon, ~5 minutes), `scripts/verify-teardown.sh`
(SIGTERM cleanup, ~1 minute).
