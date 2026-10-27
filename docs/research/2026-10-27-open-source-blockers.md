# Open-source macOS blockers — engineering survey

**Date:** 2026-10-27
**Purpose:** Before building FocusGuard, learn how existing open-source
app/website blockers work on macOS, and what breaks them. Findings come from
reading each repo's source (file names cited), plus SelfControl's issue tracker.

## 1. The landscape in one table

| Repo | ★ | Websites | Apps | Privilege | Schedules | Anti-tamper | Stack |
|---|---|---|---|---|---|---|---|
| [SelfControlApp/selfcontrol](https://github.com/SelfControlApp/selfcontrol) | 4.4k | `/etc/hosts` + pf anchor (`HostFileBlocker.m`, `PacketFilter.m`) | **none** | SMJobBless root helper `selfcontrold` + NSXPC, caller checked by team ID (`SCDaemon.m`) | **none** (open issues #53/#297/#594) | 1s checkup timer re-installs rules every 15s; `/etc/hosts` file watcher | Obj-C, GPL-3 |
| [builder-group/abstand](https://github.com/builder-group/abstand) | 43 | Reads browser URL via Accessibility, draws overlay over content (`BrowserURLExtractor.swift`, `WindowOverlay.swift`) | Overlay via NSWorkspace + AXObserver, re-stacked every 200ms | user-level; LaunchAgent watchdog relaunches app | weekday mask + time-of-day in SQLite; monotonic sleep, catches up after wake (`scheduler.rs`) | strict mode blocks quit/SIGTERM; DB deletion declared out of scope | Tauri + React + Swift FFI, ~150 files |
| [aadeshrao123/Focuser](https://github.com/aadeshrao123/Focuser) | 64 | Browser extension ↔ local API `127.0.0.1:17549`; hosts fallback (dead on macOS w/o root) | sysinfo poll + kill every 3s, skips browser helpers | user-level | weekly `TimeSlot{day,start,end}`, merged across midnight, DST-aware (`schedule.rs`) | Argon2 password / retype random string; **kills browsers whose extension hasn't checked in** | Tauri + React, ~40k LOC |
| [devsemih/appjail](https://github.com/devsemih/appjail) | 7 | AppleScript reads active tab on browser *activation*, closes it | `didActivateApplication` → `terminate()` | apple-events entitlement only | weekday + start/end, 30s tick, crosses midnight | none — quit ends block | Swift |
| [digitalhabits/dh-blocker](https://github.com/digitalhabits/dh-blocker) | 14 | AppleScript polls **every tab** in Safari/Chrome/Brave/Edge every 1s, sets `location` to a block page (`web_automation.rs`); Firefox needs extension + native-messaging host | process poll 1–2s + NSWorkspace wake-up, `terminate` after 30s warning | user-level | yes | force-quits browsers that revoked Automation permission; 300-word typing challenge to end early | Tauri/Rust; Screen Time only on iOS target |
| [Negenii/BusyBlock](https://github.com/Negenii/BusyBlock) | 6 | Browser extension using `declarativeNetRequest`, polls loopback server 1s | `app.hide()` with retries (never kills) | user-level | external hardware device | none | Swift + JS |
| [erikberglund/AppBlocker](https://github.com/erikberglund/AppBlocker) | 56 | — | `NSWorkspaceWillLaunchApplication` → SIGKILL | launchd `KeepAlive` | — | relaunch only | PyObjC, 1 file |
| [doug-leith/appFirewall](https://github.com/doug-leith/appFirewall) | 167 | libpcap sniff + DNS-reply sniffing, injects TCP RSTs (`sniffer_blocker.c`) | — | root helper | — | — | C/Obj-C; leaks packets, blind to DoH |
| [bdcdo/open-turkey](https://github.com/bdcdo/open-turkey) (Linux) | 13 | 4 layers re-applied every 5s: hosts, iptables + DoH block, managed browser policies | `/proc` scan + SIGKILL | root systemd daemon | **none** | 300-char typing challenge | Go, 4.3k LOC |
| [irbis-sh/zen-desktop](https://github.com/irbis-sh/zen-desktop) | 4.3k | Full MITM proxy with own CA + PAC via `networksetup` | — | admin prompt per toggle | — | — | Wails/Go, heavy |
| SelfControl schedulers ([auto-selfcontrol](https://github.com/andreasgrill/auto-selfcontrol), [-rs](https://github.com/AlexanderDickie/auto-selfcontrol-rs), [selfcontrol-scheduler](https://github.com/Hxagow/selfcontrol-scheduler)) | 324/34/0 | launchd `StartCalendarInterval` or 30s timer → `selfcontrol-cli start`. The Rust one stores your password in Keychain and **types it into the auth dialog with simulated keystrokes** | — | wrapper, not daemon | weekly | none; gaps on sleep/logout | Py2 (dead) / Rust / Swift |

## 2. The four ways to block a website on macOS

| Technique | Needs | Beats DoH? | Beats VPN/Private Relay? | Can user bypass without admin? | Used by |
|---|---|---|---|---|---|
| `/etc/hosts` | root | **no** | no | no (root-owned) | SelfControl, open-turkey, Focuser |
| pf anchor + table | root | yes (IP-level) | no | no | SelfControl |
| AppleScript / Accessibility tab watching | Automation or AX consent | **yes** (reads URL, not DNS) | yes | yes — revoke permission in System Settings | dh-blocker, abstand, appjail |
| Browser extension + loopback server | extension per browser | yes | yes | yes — disable extension (Focuser mitigates by killing browsers that don't check in) | Focuser, BusyBlock |
| NE content filter (`NEFilterDataProvider`, SNI parsing) | **paid Apple dev account**, system-extension approval, notarization | yes | partial | no | Foqos (mac target), Gertrude |
| MITM proxy + CA | admin, PAC | yes | no | yes — switch proxy off | zen-desktop |

**Verdicts from the research:**
- **Network Extension content filter** is the strongest option but is off the table without $99/yr: `networking.networkextension` + `system-extension.install` are restricted entitlements. (Workaround = SIP off + `systemextensionsctl developer on`, tinkering only.)
- **Screen Time APIs** (FamilyControls/ManagedSettings/DeviceActivity): no repo uses them on macOS; dh-blocker's desktop stub literally returns "Screen Time is only available on iOS". Treat as not viable on Mac. *(Partly from memory of Apple docs — not re-verified this session.)*
- **AppleScript tab watching** is the best DoH-proof technique available for free. Copy dh-blocker, not appjail: poll every tab ~1s, redirect rather than close, serialize all Apple Events through one lock (concurrent osascript calls deadlock the Apple Event manager), handle errors -1743 (permission denied) and -600 (browser not running). Firefox can't be scripted.

## 3. What breaks SelfControl (the 4.4k★ incumbent)

From code and issues:
- **Clock change ends the block** (#28, open since 2012) — expiry is a wall-clock compare.
- **pf comes back disabled after reboot** (#815, #770); only hosts persists.
- **DoH, VPNs, iCloud Private Relay all bypass it** (#906, #249, #639); FAQ calls VPNs "not technically feasible". Installing it breaks Private Relay (#852).
- Domains resolved **once** at block start via `CFHost` — CDN IP rotation defeats pf rules. No wildcard subdomains, just `www.` + bare + hard-coded Facebook ranges. Literal IPv6 skipped.
- Settings file vanishes → block removed (deliberate fail-open).
- Freezes on macOS 26 Tahoe for some users (#911). Latest release 4.0.2 is old; still SMJobBless, not SMAppService.
- **GPL-3**: borrowing `PacketFilter.m`/`HostFileBlocker.m` makes FocusGuard GPL. Reimplement the ideas.

## 4. Lessons for FocusGuard's design

What the existing spec (`docs/superpowers/specs/2026-08-18-focusguard-design.md`) already gets right: root daemon via SMAppService, idempotent reconcile loop, hosts marked region, bundle-ID app kill, pure testable core. What the survey changes or adds:

1. **Schedule lives in the root daemon, not a wrapper.** Every SelfControl scheduler leaves gaps (sleep, logout, app not running). Spec already does this — keep it. Add `NSWorkspace.didWakeNotification`/power-event handling so missed boundaries fire after sleep (abstand's pattern).
2. **Clock tampering is universal weakness.** None of the eleven repos defends against it. Compare wall clock against `mach_continuous_time`; a backwards jump → treat as still-in-window. Also consider blocking System Settings during a window.
3. **Fail-open vs fail-closed.** Spec says fail-open on unreadable config. SelfControl's fail-open is a known hole. Compromise: fail-*closed* for a bounded time (e.g. keep last-known-good for up to the window's remaining length) with a documented recovery path (`sudo launchctl unload`).
4. **Layer a DoH-proof fallback.** hosts alone is defeated by Chrome/Firefox DoH. Cheapest layered stack, all free: hosts (root daemon) **+** AppleScript tab watcher in the menu-bar app (dh-blocker design) **+** kill browsers if Automation consent is revoked (dh-blocker `enforcer.rs`, Focuser `enforce_browser_extension`). pf is optional — if added, use a table + anchor, re-resolve domains periodically, and re-enable pf at daemon start (#815).
5. **App blocking: events + sweep, not just polling.** Subscribe to `NSWorkspace.didLaunchApplicationNotification` for near-instant kills, plus the 20s sweep as safety net. Skip browser helper processes. `terminate()` first, SIGKILL on timeout.
6. **Separate "process alive" from "policy alive"** (abstand ADR). KeepAlive handles the first; root-owned state handles the second. Accept that an admin can always dismantle it — every repo concedes this.
7. **Friction for early exit** is cheap and effective: typing challenge (open-turkey/dh-blocker) or delay-then-quit (abstand "balanced"). Out of scope for v1 per spec, but the pattern is settled.
8. **Don't copy:** sudoers NOPASSWD for all users (open-turkey), unauthenticated control endpoints (procrastiproxy), keystroke-injecting your own password (auto-selfcontrol-rs), per-block password prompts (the root cause of that hack).

## 5. Decision pending

Spec v1 = root daemon + hosts + app kill. The survey argues for adding the AppleScript tab watcher as a v1 or v1.5 layer, since hosts-only is the single most-reported bypass in the incumbent. Open question: whether `SMAppService.daemon` registration works cleanly from `/Applications` on macOS 26 (spec §9) — still unverified.
