#!/bin/bash
# Live acceptance for Chrome pages (chrome pages spec §8). Needs the installed 0.6.1 daemon, no
# password, Google Chrome running, and you at the keyboard: the script can read the policy
# preference but cannot see what Chrome shows, so it asks. Puts the two News Feed Eradicator
# patterns in a window active now and checks the preference follows the window in both domains
# (set; the user copy re-asserted after you delete it; removed when the window is over; held
# under Impossible), asking whether Chrome blocks chrome://extensions. ~4 minutes. Your
# config.json is backed up and restored.
set -uo pipefail
CFG="/Library/Application Support/FocusGuard/config.json"
STATUS=/var/db/FocusGuard/status.json
RECORD=/var/db/FocusGuard/chrome-policy.json
SYS=/Library/Preferences/com.google.Chrome
EXT=fjcldmjmjhkklehbacihaiopjklihlgg
fail=0
check() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1"; fail=1; fi; }
wait_for() { for _ in $(seq "$2"); do eval "$1" && return 0; sleep 1; done; return 1; }
field() { /usr/bin/python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$STATUS" "$1" 2>/dev/null; }
record_field() { /usr/bin/python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get(sys.argv[2],""))' "$RECORD" "$1" 2>/dev/null; }
ask() { local a; while :; do read -r -p "$1 [y/n] " a </dev/tty; case "$a" in y|Y) return 0;; n|N) return 1;; esac; done; }
# The system-domain plist is world-readable; `defaults read` by path needs no root. The user
# domain is your own: `defaults read com.google.Chrome` is the copy Chrome watches live.
sys_has() { defaults read "$SYS" URLBlocklist 2>/dev/null | grep -qF -- "$1"; }
sys_absent() { ! defaults read "$SYS" URLBlocklist >/dev/null 2>&1; }
user_has() { defaults read com.google.Chrome URLBlocklist 2>/dev/null | grep -qF -- "$1"; }
user_absent() { ! defaults read com.google.Chrome URLBlocklist >/dev/null 2>&1; }
user_domain() { defaults read com.google.Chrome URLBlocklist 2>/dev/null | tr -d '\n ' || echo absent; }

[ -f "$STATUS" ] || { echo "the daemon is not installed (no $STATUS)"; exit 1; }
[ "$(field version)" = 0.6.1 ] || { echo "installed daemon is $(field version), not 0.6.1: update it from the app's Status tab first"; exit 1; }
# Every write below is a proposal the daemon may refuse: under an Impossible window of your own
# config it would be held, and nothing here would be exercised.
source=$(field source)
[ "$source" = live ] || { echo "config source is '${source:-unknown}', not live: config.json is not what the daemon enforces (held or unreadable), so this run could not be judged. Fix that first."; exit 1; }
# `live` only says your current config is accepted. A write is judged by weakens(): while any
# window of yours is active, its items are protected until that active stretch ends, and this
# script replaces your whole config, so it must run in a gap. `check` prints that lock state.
cd "$(dirname "$0")/.." || exit 1
swift build --product focusguardd >/dev/null 2>&1 || { echo "build failed (swift build --product focusguardd)"; exit 1; }
lock=$(.build/debug/focusguardd check | awk '/^lock:/ {sub(/^lock: */, ""); print}')
[ -n "$lock" ] || { echo "could not read lock state from focusguardd check"; exit 1; }
[ "$lock" = none ] || { echo "your own config has an active window (lock: $lock): replacing it with the test config would be refused as a weakening. Rerun in a gap of your schedule."; exit 1; }
pgrep -xq "Google Chrome" || { echo "start Google Chrome first (and keep it running); the Chrome-visible checks need it"; exit 1; }
[ -f "$RECORD" ] && { echo "$RECORD exists: the daemon believes it holds URLBlocklist right now, so no window of yours with Chrome patterns may be active. Rerun in a gap."; exit 1; }
# The daemon refuses a system key it did not write (spec §3), so the whole run would read
# `not applied`. A user copy is not a reason for the daemon to refuse, but the test deletes
# the key from your domain on window end, so a copy of your own would be lost: stop here.
sys_absent || { echo "URLBlocklist is already set in $SYS by something else; the daemon will refuse to touch it. Remove it (sudo defaults delete $SYS URLBlocklist) and rerun."; exit 1; }
user_absent || { echo "URLBlocklist is already set in your own Chrome preferences (defaults read com.google.Chrome URLBlocklist); the test would remove it. Remove it yourself (defaults delete com.google.Chrome URLBlocklist) and rerun."; exit 1; }

day=$(LC_ALL=C date +%a | tr 'A-Z' 'a-z')
# The live window: active now. The over window: already ended, for the "window end" step.
start=$(LC_ALL=C date -v-1M +%H:%M); end=$(LC_ALL=C date -v+6M +%H:%M)
ostart=$(LC_ALL=C date -v-2M +%H:%M); oend=$start
# A window is start < end on one day; across midnight it would never activate (or never end).
[[ "$ostart" < "$oend" && "$start" < "$end" ]] || { echo "too close to midnight (windows $ostart-$oend / $start-$end would wrap), rerun in 7 minutes"; exit 1; }

BACKUP=$(mktemp -t focusguard-config)
cp "$CFG" "$BACKUP" 2>/dev/null || echo '{"version":1,"blockLists":[],"schedules":[]}' > "$BACKUP"
# From here every exit, including an abort, puts your config back. An abort during the
# Impossible step restores a config the daemon holds until the test window ends: say so.
impossible_step=0
restore() {
    cp "$BACKUP" "$CFG" 2>/dev/null; rm -f "$BACKUP"
    [ "$impossible_step" = 1 ] && echo "note: test window is Impossible until $end; the restored config is held until then, and the key is removed from both domains when it is taken up"
}
trap restore EXIT
LIST=0C1C2D3E-0000-4000-8000-0000000000C1; WIN=0C1C2D3E-0000-4000-8000-0000000000C2
# The daemon reads config.json only at its tick (30 s + 2 s leeway with no apps to watch), so
# every write carries a sentinel domain named after the step; its line appearing in /etc/hosts
# is the proof that this write is what the daemon now enforces. A write whose window is over
# has no hosts line; its proof is the previous step's line disappearing.
write() {  # $1 chromeURLs json, $2 mode, $3 step name (sentinel domain), $4 start, $5 end
    printf '{"version":1,"blockLists":[{"id":"%s","name":"chrome","domains":["%s.focusguard-test.invalid"],"appBundleIDs":[],"keywords":[],"chromeURLs":%s}],"schedules":[{"id":"%s","name":"Chrome test","days":["%s"],"start":"%s","end":"%s","blockListIDs":["%s"],"enabled":true,"unlockMode":"%s"}],"alwaysAllow":[]}\n' \
        "$LIST" "$3" "$1" "$WIN" "$day" "$4" "$5" "$LIST" "$2" > "$CFG"
}
adopted() { wait_for "grep -q \"^0.0.0.0 $1.focusguard-test.invalid\" /etc/hosts" 35; }
released() { wait_for "! grep -q \"$1.focusguard-test.invalid\" /etc/hosts" 35; }
BOTH='["chrome-extension://'"$EXT"'","chrome://extensions"]'
ONE='["chrome-extension://'"$EXT"'"]'

echo "--- two patterns, Basic, window $start-$end"
write "$BOTH" basic both "$start" "$end"
check "daemon adopted the test config within a tick" 'adopted both'
# Both domains are written in the same tick as the hosts region (spec §3); the user-domain
# mirror is one short-lived `defaults import`, so allow a few seconds.
check "user domain (the copy Chrome watches) lists chrome://extensions within 5 s" 'wait_for "user_has chrome://extensions" 5'
check "and the extension pattern" 'user_has "chrome-extension://$EXT/"'
check "system domain (the durable copy) lists both" 'sys_has "chrome://extensions" && sys_has "chrome-extension://$EXT/"'
check "status says applied (2 patterns" 'field chrome | grep -q "^applied (2 patterns"'
check "ownership record written and names you" '[ -f "$RECORD" ] && [ "$(record_field name)" = "$(id -un)" ] && [ "$(record_field uid)" = "$(id -u)" ]'
echo "    status chrome: $(field chrome)"
echo "    user domain now: $(user_domain)"
echo "    In Chrome, open a NEW tab at chrome://extensions  (do not click Reload policies anywhere)."
check "Chrome blocks chrome://extensions" 'ask "Does Chrome show it as blocked by your administrator (ERR_BLOCKED_BY_ADMINISTRATOR)?"'
echo "    Now open chrome-extension://$EXT/entrypoints/options-page/index.html in a new tab."
check "Chrome blocks the extension's options page" 'ask "Blocked too?"'

echo "--- deleting the user copy: re-asserted next tick"
# Your own domain needs no password. The daemon notices the copy is gone (userCopyPresent) and
# calls apply again with the unchanged set: within 30 s + 2 s leeway with no apps to watch.
# No check that the copy is gone right after: the daemon may re-assert it within milliseconds
# if its tick lands just then, and either outcome is correct. The re-assert is what is judged.
defaults delete com.google.Chrome URLBlocklist 2>/dev/null
check "system copy untouched by that" 'sys_has "chrome://extensions"'
check "user copy re-asserted within 35 s" 'wait_for "user_has chrome://extensions/\\*" 35'
check "with both patterns" 'user_has "chrome-extension://$EXT/"'
check "status still applied (2 patterns" 'field chrome | grep -q "^applied (2 patterns"'

echo "--- window end: a window already over ($ostart-$oend) removes the key"
write "$BOTH" basic over "$ostart" "$oend"
check "daemon adopted the over window within a tick (hosts region released)" 'released both'
check "URLBlocklist removed from the user domain in the same tick" 'wait_for user_absent 5'
check "and from the system domain" 'sys_absent'
# status.json is written after the tick's writes land: allow a few seconds for both.
check "status is off" 'wait_for "[ \"\$(field chrome)\" = off ]" 5'
check "ownership record gone" 'wait_for "[ ! -f \"$RECORD\" ]" 5'
echo "    status chrome: $(field chrome)"
echo "    user domain now: $(user_domain)"
echo "    Reload the chrome://extensions tab."
check "chrome://extensions loads again" 'ask "Does the page load now?"'

echo "--- Impossible holds a pattern"
impossible_step=1
write "$BOTH" impossible impossible "$start" "$end"
check "daemon adopted the Impossible window within a tick" 'adopted impossible'
check "both patterns back in the user domain within 5 s" 'wait_for "user_has chrome://extensions/\\*" 5 && user_has "chrome-extension://$EXT/"'
check "and in the system domain" 'sys_has "chrome://extensions"'
write "$ONE" impossible removed "$start" "$end"
# No apps in the test config, so the daemon ticks every 30 s (+2 s leeway).
check "removing a pattern is held" 'wait_for "[ \"\$(field source)\" = held ]" 35'
check "chrome://extensions still in the user domain" 'user_has "chrome://extensions"'
check "and in the system domain" 'sys_has "chrome://extensions"'
check "status still applied (2 patterns" 'field chrome | grep -q "^applied (2 patterns"'

echo "--- restore"
trap - EXIT; impossible_step=0
cp "$BACKUP" "$CFG" && rm -f "$BACKUP"
if [ "$(field source)" = held ]; then echo "note: test window is Impossible until $end; the key is removed from both domains when the restored config is taken up then"; else
check "key removed from both domains within a tick" 'wait_for "user_absent && sys_absent" 35'; fi
if [ $fail = 0 ]; then echo "ALL OK"; else echo "SOME CHECKS FAILED"; fi
exit $fail
