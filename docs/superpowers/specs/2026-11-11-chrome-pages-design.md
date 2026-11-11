# Chrome pages — design

**Date:** 2026-11-11 · **Status:** approved; §3 settled by the probe on 2026-11-11 — **write both domains** (variant B)
**Builds on:** `2026-08-18-focusguard-design.md` §11 (install and lock model), `2026-11-06-keyword-blocking-design.md` (list item types, Add many…)

## 1. Purpose

Block pages inside Chrome that no site rule can reach because they never cause a DNS lookup:
extension pages (`chrome-extension://<id>/…`) and internal pages (`chrome://extensions`,
`chrome://settings`). The case that prompted it: the user runs the News Feed Eradicator
extension (`fjcldmjmjhkklehbacihaiopjklihlgg`) and wants its options page — and the page where
the extension could be disabled — unreachable during windows.

Chrome's own `URLBlocklist` policy does this. Verified on this Mac on 2026-11-09: a plain
preference written with `defaults write com.google.Chrome URLBlocklist -array <pattern>` shows in
`chrome://policy` at level **Mandatory**, and the pattern
`chrome-extension://fjcldmjmjhkklehbacihaiopjklihlgg/entrypoints/options-page/index.html`
blocks that page. No MDM, no configuration profile.

## 2. Data model

```
BlockList
  chromeURLs: [String]        // new; Chrome URLBlocklist patterns, as typed, trimmed
```

A pattern is valid when it is non-empty, has no whitespace or control characters, is at most
2048 characters, and either starts with a scheme (`chrome://`, `chrome-extension://`,
`chrome-untrusted://`, `devtools://`, `file://`, `http://`, `https://`) or is a bare
host-pattern Chrome accepts (`example.com`, `.exact.host.com`, `*`). `Config.Limits.maxChromeURLs = 200`
across all lists. Older config files decode with an empty array.

Patterns are kept as typed after the scheme (Chrome does its own matching); the app trims,
lowercases the scheme part (everything before `://`, so `CHROME://flags` is stored as
`chrome://flags`) and rejects whitespace. A bare host pattern may carry a `:port` tail only
if it is 1–5 digits (`example.com:8080/path`; `example.com:abc` and `example.com:123456`
are rejected). Dedup is exact-string on the normalized form.

## 3. Enforcement

Each tick the daemon computes `active.chromeURLs` = union of `chromeURLs` over lists attached to
active windows, in sorted order, and makes Chrome's policy preference match it:

- non-empty → `URLBlocklist` = that array
- empty → the key is removed

The write happens when the set differs from what was last written (same change-detection as
the hosts region), and again whenever the user-domain copy has gone missing (see the second
decision rule below). Chrome is told nothing else: no `URLAllowlist`, no extension blocklist.

**Probe result (2026-11-11, `scripts/probe-chrome-policy.sh`):** a key added to the system domain was picked up by Chrome within 15 s without a reload; the same key *removed* was not noticed within 60 s. So the system domain alone would start windows on time and never end them. Decision: **write both domains** (second rule below).

**Where the preference is written was decided by the probe, not assumed.** `CFPreferences` has
two candidate domains, and they differ in what matters:

| Domain | File | Who can change it without a password | Picked up live by Chrome? |
|---|---|---|---|
| system (`kCFPreferencesAnyUser`) | `/Library/Preferences/com.google.Chrome.plist` | nobody (`root:wheel 0755` dir) | **unknown — the probe answers this** |
| user | `~/Library/Preferences/com.google.Chrome.plist` | the user (`defaults delete`) | yes, within seconds (observed) |

Decision rule:

- **Probe says the system file is picked up within ~15 s** (both when set and when removed):
  the daemon writes the system domain only. Chrome pages then carry the same guarantee as the
  hosts region: changing them under an Impossible window needs `sudo`.
- **Otherwise:** the daemon writes **both** — the system domain as the durable copy, the user
  domain as the one Chrome watches. The user-domain write is done as the console user (the
  daemon runs `launchctl asuser <uid> sudo -n -u <name> /usr/bin/defaults …`), because cfprefsd
  keys the user domain by uid. Deleting the user copy makes Chrome reload policy, which still
  finds the system copy. **Every tick while patterns are active** the daemon checks that the
  console user's `~/Library/Preferences/com.google.Chrome.plist` still holds the key
  (`ChromePolicyWriter.userCopyPresent()`: the file is parsed once per distinct mtime+size, so
  an unchanged file is one `stat`); if it does not, the daemon calls `apply` again with the
  unchanged set and logs `chrome: user copy was removed; re-asserted` once per episode (a
  loop deleting it every tick is one episode; the line repeats only after a tick has found the
  copy in place again). The tick is 2 s while an app block is active and 30 s otherwise, so
  the copy is back within 2 s or within 30 s respectively. With no console user there is
  nothing to re-assert; the next tick after someone logs in sees their file. README states
  this under *How enforcement works* and *Known gaps*: a determined loop can keep deleting
  the preference, which the hosts region cannot suffer.

In both cases the daemon uses `CFPreferencesSetValue` + `CFPreferencesSynchronize` from Core
Foundation for the system domain (no shelling out), and records what it wrote in
`/var/db/FocusGuard/chrome-policy.json` so a restart can tell its own key from a user's. The
record is saved **before** either domain is touched: it is the intent, and a record with no
key behind it is harmless (clearing an absent key is a no-op), whereas a key with no record
would read as someone else's forever.

**The daemon never writes the key when it has nothing to block and never wrote it before**, so
a user who sets `URLBlocklist` themselves for other reasons is not clobbered: on first run, if
the key already exists **in the system domain** and `chrome-policy.json` is absent, the daemon
logs once, leaves the key alone, and reports `chrome: not applied (URLBlocklist already set by
someone else)`. Only the system domain counts for this rule — it is the one nobody can set
without a password. A user-domain copy alone is never a reason to refuse. The rule is also
skipped once this daemon process has called `apply` and not since cleared: a key left by a
write of ours that failed part-way is retried, not refused. The foreign-key log line repeats
for a new episode after a write of ours has succeeded in between.

Chrome absent (no `/Applications/Google Chrome.app` and no `~/Applications/Google Chrome.app`):
the daemon still writes the preference (harmless, and Chrome installed later picks it up) and
status says `chrome: applied (N patterns; Chrome not found)`.

## 4. Locking

A Chrome pattern is item `c:<pattern>` in `weakens(from:at:)`, protected by the windows whose
lists contain it. Removing or editing one is a cut; adding never weakens. No allow-list
interaction (nothing learns, nothing is uncovered).

## 5. Status

`DaemonStatus` gains `chrome: String` — `"off"` (no patterns in any enabled window's list),
`"applied (N patterns)"`, `"applied (N patterns; Chrome not found)"`, `"not applied (…)"`, or
`"error: <reason>"`. The Status tab shows it as "Chrome pages: …". Decoding a status without the
key yields `"off"`.

## 6. App

- Block Lists → each list gets a **Chrome pages** section: rows showing the pattern
  (monospaced), remove button gated like domains; an `AddRow` with placeholder
  "chrome-extension://… or chrome://extensions/*", validation message on a bad pattern; **Add
  many…** reusing `BulkAddSheet` with a new `.chromeURLs` kind (one pattern per line, comma or
  space separated; no hosts-file handling).
- **Add extension…** button: a sheet listing installed Chrome extensions by name, from
  `~/Library/Application Support/Google/Chrome/*/Extensions/<id>/<version>/manifest.json`
  (name from `manifest.json`, or `__MSG_…__` resolved from `_locales/en/messages.json`, else the
  id). Choosing one adds two patterns: `chrome-extension://<id>/*` and `chrome://extensions/*`.
  The second is explained in the sheet: "also blocks the page where the extension could be
  disabled". Each is skipped if already present.
- Footer text: "Blocks pages inside Chrome itself. Chrome shows them as blocked by an
  administrator. Other browsers are not affected."

## 7. Battery

Outside a window nothing is added: no check, no write. While patterns are active each tick
costs one `stat` of the console user's `com.google.Chrome.plist` (the parse is cached by
mtime+size, so it is repeated only when the file changes) plus one `SCDynamicStoreCopyConsoleUser`
call. The plist write happens when the active pattern set changes (window start/end, edit) or
the user copy was deleted; `CFPreferencesSynchronize` is a cfprefsd round trip, microseconds,
and the user-domain mirror is one short-lived `defaults` process per write.

## 8. Testing

- Core: pattern validation table; union per tick in sorted order; `c:` lock items (remove →
  held under Impossible, add → never weakens); status decode without the key; config decode of
  a 0.5 file.
- Daemon: a `ChromePolicyWriter` protocol in Core with a recording fake for Reconciler tests;
  the real one in `focusguardd` is tested live only.
- Live script `scripts/verify-chrome.sh` (no password; runs in a schedule gap like
  `verify-keywords.sh`): a window with the two News Feed Eradicator patterns, Basic → within a
  tick `defaults read` shows them; the user confirms `chrome://extensions` is blocked (the
  script cannot see Chrome) → window ends → key removed within a tick → Impossible → removing a
  pattern is held.

## 9. Out of scope

Other Chromium browsers (Brave, Edge, Arc, Vivaldi — same mechanism, different preference
domain; a follow-up); Safari and Firefox (no equivalent local policy without a profile);
`ExtensionInstallBlocklist` (disabling an extension outright); allow-list exceptions.
