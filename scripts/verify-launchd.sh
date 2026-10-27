#!/bin/bash
# Manual acceptance for the installed launchd daemon (plan Task 14). Run AFTER install-daemon.sh.
# Writes a 2-minute window that starts one minute from now, watches the daemon enter and leave
# it, then checks KeepAlive (kill -9 → relaunch) and SIGTERM teardown (bootout → region cleared).
# Takes ~4 minutes. One sudo prompt up front.
set -uo pipefail   # no -e: check() collects failures and the script reports them all
cd "$(dirname "$0")/.."

LABEL=com.focusguard.daemon
CFG="/Library/Application Support/FocusGuard/config.json"
fail=0
check() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1"; fail=1; fi; }

sudo -v
check "daemon is running under launchd" 'sudo launchctl print system/$LABEL 2>/dev/null | grep -q "state = running"'

# Window: start = next full minute + 1, end = start + 2 (local time, today's weekday).
start_epoch=$(( ( $(date +%s) / 60 + 2 ) * 60 ))
end_epoch=$(( start_epoch + 120 ))
start=$(date -r $start_epoch +%H:%M); end=$(date -r $end_epoch +%H:%M)
day=$(date +%a | tr 'A-Z' 'a-z')
echo "--- window $day $start-$end (now $(date +%H:%M:%S))"
cat > "$CFG" <<EOF
{
  "version": 1,
  "blockLists": [{"id": "0B1C2D3E-0000-4000-8000-000000000001", "name": "Distractions",
                  "domains": ["example.com"], "appBundleIDs": ["com.apple.Chess"]}],
  "schedules": [{"id": "0B1C2D3E-0000-4000-8000-000000000002", "name": "Live test",
                 "days": ["$day"], "start": "$start", "end": "$end",
                 "blockListIDs": ["0B1C2D3E-0000-4000-8000-000000000001"], "enabled": true}]
}
EOF
check "config written without sudo (admin-writable)" 'test -s "$CFG"'

echo "--- waiting for window start (+ up to 32 s idle tick)"
sleep $(( start_epoch - $(date +%s) + 35 ))
check "hosts region present after window start" 'grep -q "0.0.0.0 example.com" /etc/hosts'
open -a Chess; sleep 5
check "Chess killed within 5 s of launch (2 s active tick)" '! pgrep -xq Chess'
check "example.com blocked" '! curl -sS -m 5 -o /dev/null https://example.com 2>/dev/null'

echo "--- KeepAlive: kill -9 the daemon"
pid=$(sudo launchctl print system/$LABEL | awk "/pid =/{print \$3}")
sudo kill -9 "$pid"; sleep 4
newpid=$(sudo launchctl print system/$LABEL | awk "/pid =/{print \$3}")
check "relaunched with a new pid ($pid -> $newpid)" 'test -n "$newpid" && test "$newpid" != "$pid"'
check "region still present after relaunch (converged, not reset)" 'grep -q "0.0.0.0 example.com" /etc/hosts'

echo "--- waiting for window end"
sleep $(( end_epoch - $(date +%s) + 35 ))
check "region removed after window end" '! grep -q FOCUSGUARD /etc/hosts'
check "example.com reachable again" 'curl -sS -m 5 -o /dev/null https://example.com'

echo "--- SIGTERM teardown: re-enter a window, then bootout"
start=$(date -r $(( $(date +%s) - 60 )) +%H:%M); end=$(date -r $(( $(date +%s) + 600 )) +%H:%M)
sed -i '' "s/\"start\": \"[0-9:]*\"/\"start\": \"$start\"/; s/\"end\": \"[0-9:]*\"/\"end\": \"$end\"/" "$CFG"
sleep 35   # daemon is on its 30 s idle tick after the window ended
check "region present again" 'grep -q "0.0.0.0 example.com" /etc/hosts'
sudo launchctl bootout system/$LABEL; sleep 2
check "bootout cleared the region" '! grep -q FOCUSGUARD /etc/hosts'
sudo launchctl bootstrap system /Library/LaunchDaemons/$LABEL.plist; sleep 3
check "daemon re-bootstrapped" 'sudo launchctl print system/$LABEL | grep -q "state = running"'

echo "--- disable the test window so nothing stays blocked"
sed -i '' 's/"enabled": true/"enabled": false/' "$CFG"
sleep 5   # a window is active here, so the daemon is on its 2 s tick
check "region cleared after disabling" '! grep -q FOCUSGUARD /etc/hosts'

if [ $fail = 0 ]; then echo "ALL OK"; else echo "SOME CHECKS FAILED"; fi
echo "logs: log show --last 10m --predicate 'subsystem == \"com.focusguard\"' --info"
exit $fail
