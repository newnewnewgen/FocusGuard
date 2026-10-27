#!/bin/bash
# Just the SIGTERM-teardown check from verify-launchd.sh (~50 s): enter a window, wait for the
# idle tick to pick it up, bootout the daemon, confirm it cleared its hosts region on the way
# down, re-bootstrap it, disable the window.
set -uo pipefail   # no -e: check() collects failures and the script reports them all
cd "$(dirname "$0")/.."
LABEL=com.focusguard.daemon
CFG="/Library/Application Support/FocusGuard/config.json"
fail=0
check() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1"; fail=1; fi; }

sudo -v
check "daemon is running" 'sudo launchctl print system/$LABEL 2>/dev/null | grep -q "state = running"'
day=$(date +%a | tr 'A-Z' 'a-z')
start=$(date -r $(( $(date +%s) - 60 )) +%H:%M); end=$(date -r $(( $(date +%s) + 600 )) +%H:%M)
cat > "$CFG" <<EOF
{
  "version": 1,
  "blockLists": [{"id": "0B1C2D3E-0000-4000-8000-000000000001", "name": "Distractions",
                  "domains": ["example.com"], "appBundleIDs": ["com.apple.Chess"]}],
  "schedules": [{"id": "0B1C2D3E-0000-4000-8000-000000000002", "name": "Teardown test",
                 "days": ["$day"], "start": "$start", "end": "$end",
                 "blockListIDs": ["0B1C2D3E-0000-4000-8000-000000000001"], "enabled": true}]
}
EOF
echo "--- waiting up to 35 s for the idle tick"
for _ in $(seq 35); do grep -q "0.0.0.0 example.com" /etc/hosts && break; sleep 1; done
check "region present" 'grep -q "0.0.0.0 example.com" /etc/hosts'
sudo launchctl bootout system/$LABEL; sleep 2
check "bootout (SIGTERM) cleared the region" '! grep -q FOCUSGUARD /etc/hosts'
sudo launchctl bootstrap system /Library/LaunchDaemons/$LABEL.plist; sleep 3
check "daemon re-bootstrapped" 'sudo launchctl print system/$LABEL | grep -q "state = running"'
check "region re-applied on restart (window still active)" 'grep -q "0.0.0.0 example.com" /etc/hosts'
sed -i '' 's/"enabled": true/"enabled": false/' "$CFG"; sleep 5
check "region cleared after disabling" '! grep -q FOCUSGUARD /etc/hosts'
if [ $fail = 0 ]; then echo "ALL OK"; else echo "SOME CHECKS FAILED"; fi
exit $fail
