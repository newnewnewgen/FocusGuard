#!/bin/bash
# Live acceptance for keyword blocking (keyword spec §10). Needs the installed daemon, no
# password. Uses a rule "example" in a window active now: looks up example.org, expects it in
# /etc/hosts within a few seconds, checks the allow list, and that an Impossible window holds
# when the rule is removed. ~2 minutes. Your config.json is backed up and restored.
set -uo pipefail
CFG="/Library/Application Support/FocusGuard/config.json"
STATUS=/var/db/FocusGuard/status.json
LEARNED=/var/db/FocusGuard/learned.json
fail=0
check() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1"; fail=1; fi; }
wait_for() { for _ in $(seq "$2"); do eval "$1" && return 0; sleep 1; done; return 1; }
field() { /usr/bin/python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$STATUS" "$1" 2>/dev/null; }

[ -f "$STATUS" ] || { echo "the daemon is not installed (no $STATUS)"; exit 1; }
# Every write below is a proposal the daemon may refuse: under an Impossible window of your own
# config it would be held, and nothing here would be exercised.
source=$(field source)
[ "$source" = live ] || { echo "config source is '${source:-unknown}', not live: config.json is not what the daemon enforces (held or unreadable), so this run could not be judged. Fix that first."; exit 1; }
# `live` only says your current config is accepted. A write is judged by weakens(): while any
# window of yours is active, its items are protected until that active stretch ends, and this
# script replaces your whole config, so it must run in a gap. `check` prints that lock state.
cd "$(dirname "$0")/.." || exit 1
swift build --product focusguardd 2>&1 | tail -1
lock=$(.build/debug/focusguardd check | awk '/^lock:/ {sub(/^lock: */, ""); print}')
[ "$lock" = none ] || { echo "your own config has an active window (lock: ${lock:-unknown}): replacing it with the test config would be refused as a weakening. Rerun in a gap of your schedule."; exit 1; }

day=$(LC_ALL=C date +%a | tr 'A-Z' 'a-z'); start=$(LC_ALL=C date -v-1M +%H:%M); end=$(LC_ALL=C date -v+4M +%H:%M)
# A window is start < end on one day; across midnight it would never activate.
[[ "$start" < "$end" ]] || { echo "too close to midnight (window $start-$end would wrap), rerun in 5 minutes"; exit 1; }
if grep -q '"example.org"' "$LEARNED" 2>/dev/null; then
    echo "NOTE: example.org is already in $LEARNED, so the capture path (DNS question -> learned) is not being exercised this run. Delete it from learned.json with sudo to test that."
fi

BACKUP=$(mktemp -t focusguard-config)
cp "$CFG" "$BACKUP" 2>/dev/null || echo '{"version":1,"blockLists":[],"schedules":[]}' > "$BACKUP"
# From here every exit, including an abort, puts your config back.
trap 'cp "$BACKUP" "$CFG" 2>/dev/null; rm -f "$BACKUP"' EXIT
LIST=0B1C2D3E-0000-4000-8000-0000000000B1; WIN=0B1C2D3E-0000-4000-8000-0000000000B2
# The daemon reads config.json only at its tick (30 s + 2 s leeway with no apps to watch), so
# every write carries a sentinel domain named after the step; its line appearing in /etc/hosts
# is the proof that this write is what the daemon now enforces. Without that, a lookup made
# before the tick is matched against the previous config and nothing is learned.
write() {  # $1 keywords json, $2 mode, $3 allow json, $4 step name (sentinel domain)
    printf '{"version":1,"blockLists":[{"id":"%s","name":"kw","domains":["%s.focusguard-test.invalid"],"appBundleIDs":[],"keywords":%s}],"schedules":[{"id":"%s","name":"Keyword test","days":["%s"],"start":"%s","end":"%s","blockListIDs":["%s"],"enabled":true,"unlockMode":"%s"}],"alwaysAllow":%s}\n' \
        "$LIST" "$4" "$1" "$WIN" "$day" "$start" "$end" "$LIST" "$2" "$3" > "$CFG"
}
adopted() { wait_for "grep -q \"^0.0.0.0 $1.focusguard-test.invalid\" /etc/hosts" 35; }
RULE='[{"id":"0B1C2D3E-0000-4000-8000-0000000000B3","text":"example","match":"startsWith"}]'

echo "--- keyword rule 'example' (starts with), window $start-$end"
write "$RULE" basic '[]' rule
check "daemon adopted the test config within a tick" 'adopted rule'
check "daemon is watching lookups" 'wait_for "field dnsWatch | grep -q ^watching" 40'
dig +short example.org >/dev/null 2>&1
check "example.org learned and in /etc/hosts within 5 s" 'wait_for "grep -q \"^0.0.0.0 example.org\" /etc/hosts" 5'
# mDNSResponder picks up the new /etc/hosts and the cache flush asynchronously; allow a few seconds.
check "example.org stops resolving within 10 s" 'wait_for "! curl -sS -m 5 -o /dev/null https://example.org 2>/dev/null" 10'
check "learned.json lists it" 'grep -q example.org "$LEARNED"'

echo "--- allow list"
write "$RULE" basic '["example.org"]' allow
check "daemon adopted the allow list within a tick" 'adopted allow'
check "allowed site is released in the same tick" 'wait_for "! grep -q example.org /etc/hosts" 5'
dig +short example.org >/dev/null 2>&1; sleep 3
check "and not re-learned" '! grep -q "^0.0.0.0 example.org" /etc/hosts'

echo "--- Impossible holds the rule"
write "$RULE" impossible '[]' impossible
check "daemon adopted the Impossible window within a tick" 'adopted impossible'
check "blocked again" 'wait_for "grep -q \"^0.0.0.0 example.org\" /etc/hosts" 5'
write '[]' impossible '[]' removed
# No apps in the test config, so the daemon ticks every 30 s (+2 s leeway).
check "removing the rule is held" 'wait_for "[ \"\$(field source)\" = held ]" 35'
check "still blocked" 'grep -q "^0.0.0.0 example.org" /etc/hosts'

echo "--- restore"
cp "$BACKUP" "$CFG" && rm -f "$BACKUP" && trap - EXIT
if [ "$(field source)" = held ]; then echo "note: test window is Impossible until $end; the restored config is taken up then"; else
check "region clears within a tick" 'wait_for "! grep -q FOCUSGUARD /etc/hosts" 35'; fi
if [ $fail = 0 ]; then echo "ALL OK"; else echo "SOME CHECKS FAILED"; fi
exit $fail
