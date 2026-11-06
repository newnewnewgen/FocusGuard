#!/bin/bash
# Command-line install of the daemon alone (no app). FocusGuard.app → Status → Install protection
# does the same thing behind a password prompt; both run scripts/install-daemon-root.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product focusguardd
sudo scripts/install-daemon-root.sh "$PWD/.build/release/focusguardd"
sudo launchctl print system/com.focusguard.daemon | grep -E "state =|pid =" | head -2
echo "logs: /usr/bin/log stream --info --predicate 'subsystem == \"com.focusguard\"'"
