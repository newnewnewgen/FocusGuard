#!/bin/bash
# Live acceptance for the daemon-enforced Impossible lock. Needs NO password: every attack here is
# something the logged-in user can do. Sets up a 5-minute Impossible window blocking example.com
# and Chess, tries to get out of it, then checks it releases by itself. ~6 minutes.
# Your config.json is backed up first and restored at the end.
set -uo pipefail   # no -e: check() collects failures and the script reports them all

CFG="/Library/Application Support/FocusGuard/config.json"
STATUS=/var/db/FocusGuard/status.json
BACKUP=$(mktemp -t focusguard-config)
fail=0
check() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1"; fail=1; fi; }
source_is() { [ "$(/usr/bin/python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["source"])' "$STATUS" 2>/dev/null)" = "$1" ]; }
blocked() { grep -q "^0.0.0.0 example.com" /etc/hosts; }
wait_for() { for _ in $(seq "$2"); do eval "$1" && return 0; sleep 1; done; return 1; }

[ -f "$STATUS" ] || { echo "the daemon is not installed (no $STATUS)"; exit 1; }
cp "$CFG" "$BACKUP" 2>/dev/null || echo '{"version":1,"blockLists":[],"schedules":[]}' > "$BACKUP"

day=$(date +%a | tr 'A-Z' 'a-z')
start=$(date -v-1M +%H:%M)
end_epoch=$(( ( $(date +%s) / 60 + 5 ) * 60 ))
end=$(date -r "$end_epoch" +%H:%M)
LIST=0B1C2D3E-0000-4000-8000-0000000000A1
WIN=0B1C2D3E-0000-4000-8000-0000000000A2
window() {  # $1 enabled, $2 lists json
    printf '{"id":"%s","name":"Impossible test","days":["%s"],"start":"%s","end":"%s","blockListIDs":%s,"enabled":%s,"unlockMode":"impossible"}' "$WIN" "$day" "$start" "$end" "$2" "$1"
}
lists='[{"id":"'$LIST'","name":"Test","domains":["example.com"],"appBundleIDs":["com.apple.Chess"]}]'
write() { printf '{"version":1,"blockLists":%s,"schedules":[%s]}\n' "$1" "$2" > "$CFG"; }

echo "--- Impossible window $day $start-$end (now $(date +%H:%M:%S))"
write "$lists" "$(window true "[\"$LIST\"]")"
check "daemon took the window up (within its 32 s idle tick)" 'wait_for blocked 40'
check "daemon reports source=live" 'source_is live'
open -a Chess; sleep 5
check "Chess is killed" '! pgrep -xq Chess'
check "example.com does not resolve" '! curl -sS -m 5 -o /dev/null https://example.com 2>/dev/null'

echo "--- attack 1: disable the window in config.json"
write "$lists" "$(window false "[\"$LIST\"]")"; sleep 6
check "still blocked" 'blocked'
check "daemon reports the change as held" 'source_is held'

echo "--- attack 2: delete config.json"
rm -f "$CFG"; sleep 6
check "still blocked" 'blocked'
check "daemon is on its accepted copy" 'source_is lastGood'

echo "--- attack 3: twin windows sharing one id (the bypass found in review)"
write "$lists" "$(window true "[]"),$(window false "[\"$LIST\"]")"; sleep 6
check "still blocked" 'blocked'

echo "--- attack 4: a valid config that blocks nothing"
echo '{"version":1,"blockLists":[],"schedules":[]}' > "$CFG"; sleep 6
check "still blocked" 'blocked'
check "daemon reports the change as held" 'source_is held'

echo "--- attack 5: garbage in config.json"
echo 'not json {{{' > "$CFG"; sleep 6
check "still blocked" 'blocked'

echo "--- attack 6: touch the daemon's own files and job (all must be refused)"
check "cannot write the accepted config" '! ( echo x > /var/db/FocusGuard/last-good.json ) 2>/dev/null'
check "cannot create files in the state dir" '! touch /var/db/FocusGuard/x 2>/dev/null'
check "cannot rename the state dir" '! mv /var/db/FocusGuard /var/db/FocusGuard.aside 2>/dev/null'
check "cannot replace the daemon binary" '! cp /usr/bin/true /Library/PrivilegedHelperTools/com.focusguard.daemon 2>/dev/null'
check "cannot stop the daemon" '! launchctl bootout system/com.focusguard.daemon 2>/dev/null'
check "cannot kill the daemon" '! kill $(pgrep -f "PrivilegedHelperTools/com.focusguard.daemon") 2>/dev/null'
check "cannot edit /etc/hosts" '! ( echo "# x" >> /etc/hosts ) 2>/dev/null'
sleep 3
check "still blocked after all of that" 'blocked'
open -a Chess; sleep 5
check "Chess is still being killed" '! pgrep -xq Chess'

echo "--- leave a 'disable it' proposal in place and wait for the window to end at $end"
write "$lists" "$(window false "[\"$LIST\"]")"
sleep $(( end_epoch - $(date +%s) - 20 ))
check "still blocked 20 s before the end" 'blocked'
check "released by itself after the end (within 45 s)" 'sleep 22; wait_for "! blocked" 45'
check "the held proposal was taken up (source=live)" 'wait_for "source_is live" 10'
check "example.com resolves again" 'curl -sS -m 8 -o /dev/null https://example.com'

echo "--- restore your config"
cp "$BACKUP" "$CFG"; rm -f "$BACKUP"; sleep 3
check "nothing left in /etc/hosts" '! grep -q FOCUSGUARD /etc/hosts'

if [ $fail = 0 ]; then echo "ALL OK"; else echo "SOME CHECKS FAILED"; fi
exit $fail
