# UI polish — design

**Date:** 2026-11-11 · **Status:** implemented; visual check pending
**Builds on:** `2026-08-18-focusguard-design.md` §11, `2026-11-06-keyword-blocking-design.md` §8

Six changes to the menu-bar app, all app-only: no daemon, config schema or lock change.

## 1. Unlock-mode explainer

Next to the Basic / Friction / Impossible segmented control in each `WindowRow`, a small
`info.circle` button opens a popover (`.popover`, arrow edge bottom, ~560 pt wide). Selecting a
segment stays a one-click act; the popover is only for learning.

The popover has three pages matched to the segments (a `Picker` at the top, preselected to the
window's current mode):

- **Basic** — text only: "Changes apply at once, even while the window is active."
- **Friction** — text: "While the window is active, weakening it (removing a site, ending it
  early, turning it off) first asks you to type a sentence. Paste and autocorrect do not work."
  Below it, the **real `ChallengeSheet`** rendered inline in demo mode with a fixed sample
  sentence and a non-functional Unlock button (`ChallengeSheet(challenge:dismiss:)` gets an
  `isPreview: Bool` that disables the field's effect and the buttons; the captcha canvas draws
  as it would for real).
- **Impossible** — text: "While the window is active nothing can weaken it, not even you. Edits
  that would are held by the daemon until the window ends. Only `sudo` on the command line
  gets around it." Below it, a **live preview of the locked state**: a mock list row
  (`"reddit.com"` with the remove button disabled and the help text "Locked until 20:00") and a
  mock window row with the shield badge, built from the same `ProtectionBadge` and
  `removeButton` views the real tabs use, fed with `mode: .impossible` and
  `until: TimeOfDay("20:00")`.

Live previews, not image assets: they follow the real views when those change and honour the
current appearance.

## 2. Ghost "add window" row

The "Add window" button and the footer `HStack` in `ScheduleTab` go. Under the last
`WindowRow`, the empty area of the list becomes a drop target for the eye: when the pointer is
over it (`.onHover`), a dashed-outline row appears (`RoundedRectangle` stroke, `.secondary`,
dash `[6, 4]`) containing `plus.circle` and "New window · Mon–Fri 09:00–12:00" in
`.secondary`; at 0.35 opacity when the pointer is elsewhere in the tab, 1.0 on hover, animated
over 0.15 s. Clicking it calls the existing `addWindow()`. With no windows at all the ghost row
is shown at full opacity permanently in place of the `ContentUnavailableView` (keep that view's
title text as the ghost row's caption: "Add a window: the days and hours when your lists are
blocked.").

`addWindow()` changes per §6: the new window is attached to the **default list only**.

The unlock-mode sentence that used to sit in the footer moves into the §1 popover (Basic page)
and is deleted from the tab.

## 3. Setup sheet instead of status rows

The Status tab loses the "Protection" section rows "Background daemon running / not installed
/ needs updating / installed but not running", "Open FocusGuard at login" and "Keyword
matching: …", and the paragraph beneath them.

They move to a **Setup** sheet (`SetupSheet.swift`) that the app presents over the settings
window when, on launch or on `didBecomeActive`, any of these is true:
`!inst.daemonInstalled`, `inst.legacyDaemonRunning`, `inst.needsUpdate`,
`inst.daemonInstalled && !inst.daemonRunning`. The sheet is a short checklist:

1. **Protection** — the existing `daemonRow(inst)` content and its Install / Update / Reinstall
   button (password prompt), unchanged in behaviour.
2. **Open at login** — the existing toggle, defaulting on after a fresh install as today.
3. **Keyword matching** — the existing row, shown only while any enabled window's list has
   keyword rules (`model.hasKeywordRules`), reading `watching …` / `waiting for network` /
   `error: …`.

A **Done** button is enabled once step 1 is healthy; the sheet also closes itself 1.5 s after
every shown step turns green. It can be reopened from the Status tab through a single
secondary-style link at the bottom, "Setup…", so the login toggle stays reachable.

What remains on the Status tab when everything is healthy: the `noticeSection` (only when it
has something to say), "Now" (blocking / next change) and nothing else. A problem that the
sheet would show (daemon stopped, needs update, keyword capture error, Dock fallback) appears
as one orange row at the top of Status with a button that opens the Setup sheet, so a broken
state is never silent.

## 4. Uninstall

The "Uninstall protection…" button and its section are removed from the Status tab, along with
`AppModel.requestUninstall` and the `uninstallMode` challenge path if nothing else uses them
(check `ChallengeSheet` / `MenuView`). `Installer.uninstall()` and `scripts/uninstall-daemon.sh`
stay; the README's recovery section already names the script and gets one sentence: "The app
has no uninstall button; use the script."

## 5. "Blocked so far" removed

The caption under each keyword row goes. `AppModel.learnedNames(for:)`, `learned`,
`learnedByRule` and the `learned.json` watcher are removed from the app if nothing else reads
them (the Status tab's keyword row does not). The daemon side is untouched.

## 6. Lists: order, default, per-window choice

- The sidebar `List` in `BlockListsTab` gets `.onMove` (drag to reorder). The move is one
  `model.apply` that reorders `config.blockLists`; it changes no window's `blockListIDs`, so
  `weakens` returns nil and it is never gated. Reordering is disabled only while
  `model.config == nil`.
- The first list is the **default**. Its sidebar row shows a secondary "Default" caption.
  `ScheduleTab.addWindow()` attaches `[blockLists.first!.id]` (and nothing if there is no list;
  the Schedule tab then shows "Create a block list first" in the ghost row's caption and the
  ghost row is disabled).
- Which lists a window uses stays where it is: the per-window checkboxes in `WindowRow`
  (already present, already gated under Impossible).

## 7. Out of scope

Image-based screenshots; renaming lists inline in the sidebar; multiple defaults; anything in
the daemon.

## 8. Testing

App target (`Tests/FocusGuardAppTests`): `addWindow` attaches only the first list; reorder
produces a config whose `weakens(from:)` is nil; Setup-sheet predicate (`SetupNeed.evaluate`
pure function over the installer's flags) covers each trigger and the healthy case. Everything
visual is checked by Newgen in the running app, as with the bulk-add change.
