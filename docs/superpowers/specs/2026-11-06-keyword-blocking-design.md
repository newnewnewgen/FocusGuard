# Keyword blocking — design

**Date:** 2026-11-06 · **Status:** approved in conversation, awaiting spec review
**Builds on:** `2026-08-18-focusguard-design.md` (§11 is the current install and lock model)

## 1. Purpose

Block sites by keyword rather than by name: a rule `manga` blocks mangadex.org,
mangaplus.shueisha.co.jp and read-manga.net without listing them. Rules match the **site name
only** (the host a browser or app looks up); pages, searches and titles are out of scope — with
HTTPS the daemon cannot see them, and watching browser tabs from the app was rejected earlier
on battery grounds.

Decided during design: site names only; four match types plus a global allow list; mechanism A
below (observe DNS lookups and learn) over a local DNS server or a bundled site list.

## 2. Data model

```
BlockList
  domains:      [String]
  appBundleIDs: [String]
  keywords:     [KeywordRule]        // new

KeywordRule
  id:    UUID
  text:  String                      // stored lowercased, trimmed; 2…63 characters, [a-z0-9-]
  match: contains | wholeWord | startsWith | endsWith

Config
  alwaysAllow: [String]              // new, global; site names, normalized like `domains`
```

`Config.Limits`: at most 200 keyword rules across all lists and 500 `alwaysAllow` entries, on
top of the existing limits. Rules with empty or invalid `text` do not decode (same treatment as
duplicate ids: the daemon keeps its accepted copy).

Unknown JSON keys from older files decode as empty arrays, so a 0.4 config loads unchanged.

## 3. Matching

Input: a site name, lowercased, trailing dot removed. Words are the name split on `.` and `-`.

| match | true when |
|---|---|
| contains | `text` is a substring of the name |
| wholeWord | some word equals `text` |
| startsWith | some word has the prefix `text` |
| endsWith | some word has the suffix `text` |

`manga` → contains: mangadex.org, mangalore.in, yamanga.com; wholeWord: manga.example.com,
read-manga.net; startsWith: mangadex.org, mangaplus.shueisha.co.jp; endsWith: yamanga.com,
read-manga.net.

A name is **blocked by keyword** when it matches a rule in a list attached to an active window
and is not under any `alwaysAllow` entry (equal to it or a subdomain of it, via
`DomainNormalizer.host(_:isUnder:)`). Explicit `domains` entries block regardless of
`alwaysAllow`: the allow list beats keyword rules only.

Pure functions in Core: `KeywordRule.matches(name:)`, `Config.keywordBlocks(name:at:)`.

## 4. Learned names

`/var/db/FocusGuard/learned.json` (root:wheel 0644): the set of names the daemon has seen
looked up that matched a rule, each with the time last seen. Only matches are stored, never
general lookup history. Names never expire. Cap 2000; when exceeded, the oldest-seen names are
evicted, and only while no window with keyword rules is active, so eviction never unblocks
something mid-window. The cap is hard: when the set is full, a new match evicts the oldest-seen 5 % first; a genuinely learned name evicted this way is re-learned on its next lookup.

Each tick the blocked domain set is `explicit domains ∪ { n ∈ learned : keywordBlocks(n) }`,
rendered into the hosts region exactly like explicit domains (`0.0.0.0`/`::`, `www.` form).
A name learned under one rule stays blocked under any rule that still matches it; if no active
rule matches, it is simply not rendered.

The app reads the file to show "Blocked so far: …" under each rule. No UI forgets a learned
name in v1; an `alwaysAllow` entry is how a wrongly caught site is released.

## 5. Observing lookups (daemon)

- When any enabled block list has at least one keyword rule, the daemon opens a BPF device
  (`/dev/bpf*`) on every active non-loopback interface: `en*` and `utun*` (VPN tunnels carry
  DNS too). Otherwise it opens nothing.
- Kernel filter: outbound UDP with destination port 53. The daemon is woken for DNS questions
  only, never answers or other traffic. Immediate mode; one `DispatchSource` per device.
- Framing handled: `DLT_EN10MB` (14-byte Ethernet header) and `DLT_NULL` (4-byte family word,
  used by `utun`). IPv4 and IPv6. TCP DNS is ignored (rare; large answers only).
- The DNS question name is parsed from the packet by a pure Core function
  (`DNSQuestion.parse(frame:linkType:) -> [String]`), tested against byte fixtures. Compressed
  labels and malformed packets are rejected, never trusted.
- On a match: record in `learned`, rewrite the hosts region now (not at the next tick) and flush
  the DNS cache, so the gap is one lookup, not up to 30 s.
- Interface changes (Wi-Fi join, VPN up/down) arrive through `NWPathMonitor` (event-driven, same semantics as
  `SCDynamicStore` notifications for `State:/Network/Interface`); captures are reopened then. No polling.
- Watching is independent of windows so that a site seen on Tuesday is already known when
  Wednesday's window opens; this is what closes the first-visit gap in practice.

**Gaps, documented in the README:** the very first lookup of a never-seen matching name
succeeds (the answer is already on its way); the page may load once, and a browser's own DNS
cache may keep it working for up to about a minute. Encrypted DNS configured system-wide
(profiles, the 1.1.1.1 app) and iCloud Private Relay are invisible, as they already are to the
hosts layer. Browser DoH is already handled: public DoH resolvers are sinkholed during windows.

## 6. Locking

For `weakens(from:at:)` a keyword rule is an item `k:<match>:<text>`, protected by the windows
whose lists contain it, like a domain. Editing a rule's text or match, or removing it, is a cut
of that item. Adding a rule never weakens.

`alwaysAllow`: adding an entry is a weakening at the strictest mode among the active windows
whose lists have keyword rules (it may uncover a learned name). Removing an entry never
weakens. This is deliberately coarser than checking the learned set, which the app may not have
the latest copy of; the daemon applies the same rule, so both agree.

The daemon's held/accepted logic needs no change: the new items flow through `weakens`.

## 7. Status

`DaemonStatus` gains `dnsWatch: String` — `"off"` (no keyword rules), `"watching en0, utun4"`,
or `"error: <reason>"`. The Status tab shows it as "Keyword matching: …". When capture fails,
explicit domains and apps keep working; only keyword rules are inert, and the app says so.

## 8. App

- Block Lists → each list gets a **Keywords** section: rows of *text* and a *match* popup
  (Contains, Whole word, Starts with, Ends with); add/remove buttons; under each row a
  secondary line "Blocked so far: a.com, b.org" (from `learned.json`, up to ~10 names then
  "+N more").
- **Always allow** list at the bottom of the Block Lists tab: site names, add/remove.
- All edits go through the existing gate (`AppModel.apply`), so Friction and Impossible apply
  as §6 says. Validation in the editor: lowercase, strip spaces, reject `text` outside
  `[a-z0-9-]{2,63}` with an inline message.

## 9. Battery

One kernel-filtered wake per outbound DNS question while keyword rules exist (~50 µs; a busy
day of 20,000 lookups ≈ 1 s CPU). Nothing periodic. Hosts rewrites happen only on a new match.
With no keyword rules, no device is opened.

## 10. Testing

- Core (XCTest): the matcher table in §3 plus allow-list, `www.`, hyphen and case cases; DNS
  parser fixtures for Ethernet/IPv4, Ethernet/IPv6, `DLT_NULL`/IPv4, a compressed-name answer
  (rejected), a truncated packet; learned-set merge, cap and eviction rule; `weakens` with
  keyword items and allow entries (add/remove/edit, Impossible held); hosts rendering with
  learned names; config decode of old files and of over-limit/invalid rules.
- Daemon (live script, needs the installed daemon, no password): keyword `example` in a window
  active now → `dig example.org` → name in `/etc/hosts` within 3 s and `curl` fails; add
  `example.org` to `alwaysAllow` → cleared within a tick; make the window Impossible and remove
  the keyword → daemon reports `held`, name stays blocked; window ends → released.
- Battery: `ps -o time` on the daemon after a day with rules configured, compared with today's
  baseline (94 s over 5.7 days with none).

## 11. Out of scope

Page paths, titles and searches; regular expressions; multi-keyword rules; forgetting learned
names from the UI; blocking the first-ever lookup (would need the daemon to be the resolver).
