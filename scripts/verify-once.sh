#!/bin/bash
# Manual acceptance for the daemon's single-pass mode (plan Task 13), no launchd involved.
# Installs examples/config.json (an all-day window blocking example.com, reddit.com and Chess),
# runs one reconcile pass as root, checks the effects, then disables the window and confirms
# everything is released. Backs up /etc/hosts first.
set -euo pipefail
cd "$(dirname "$0")/.."

CFG="/Library/Application Support/FocusGuard/config.json"
BIN=.build/debug/focusguardd

swift build 2>&1 | tail -1
sudo -v   # one password prompt up front

echo "--- backup /etc/hosts"
sudo cp /etc/hosts /tmp/hosts.before

echo "--- install example config"
sudo mkdir -p "/Library/Application Support/FocusGuard"
sudo cp examples/config.json "$CFG"
$BIN check

echo "--- open Chess, then one enforcement pass"
open -a Chess; sleep 2
sudo $BIN once
sleep 1
if pgrep -xq Chess; then echo "FAIL: Chess still running"; else echo "ok: Chess was quit"; fi
if grep -q "0.0.0.0 example.com" /etc/hosts; then echo "ok: hosts region present"; else echo "FAIL: no hosts region"; fi
if curl -sS -m 5 -o /dev/null https://example.com 2>/dev/null; then echo "FAIL: example.com still reachable"; else echo "ok: example.com blocked"; fi
ls -la "/Library/Application Support/FocusGuard" "/Library/Application Support/FocusGuard/state"

echo "--- disable the window, one more pass"
sudo sed -i '' 's/"enabled": true/"enabled": false/' "$CFG"
sudo $BIN once
if grep -q FOCUSGUARD /etc/hosts; then echo "FAIL: region not removed"; else echo "ok: region removed"; fi
if diff -q /tmp/hosts.before /etc/hosts >/dev/null; then echo "ok: hosts byte-identical to backup"; else echo "FAIL: hosts differs from backup"; diff /tmp/hosts.before /etc/hosts || true; fi
if curl -sS -m 5 -o /dev/null https://example.com; then echo "ok: example.com reachable again"; else echo "FAIL: example.com still blocked"; fi

echo "--- re-enable the window in the installed config (so install-daemon.sh has something to enforce)"
sudo sed -i '' 's/"enabled": false/"enabled": true/' "$CFG"
echo "done"
