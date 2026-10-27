#!/bin/bash
# Build focusguardd in release mode and install it as a root launchd daemon.
# Plan 2 replaces this with SMAppService registration from the app bundle.
set -euo pipefail
cd "$(dirname "$0")/.."

LABEL=com.focusguard.daemon
BIN=/usr/local/libexec/focusguardd
PLIST=/Library/LaunchDaemons/$LABEL.plist

swift build -c release
sudo mkdir -p /usr/local/libexec /Library/Logs/FocusGuard "/Library/Application Support/FocusGuard"
sudo chown root:admin "/Library/Application Support/FocusGuard"
sudo chmod 775 "/Library/Application Support/FocusGuard"
if [ -f "/Library/Application Support/FocusGuard/config.json" ]; then
    sudo chmod 664 "/Library/Application Support/FocusGuard/config.json"
fi

if sudo launchctl print system/$LABEL >/dev/null 2>&1; then
    sudo launchctl bootout system/$LABEL
fi
sudo install -m 755 .build/release/focusguardd "$BIN"
sudo install -m 644 launchd/$LABEL.plist "$PLIST"
sudo chown root:wheel "$PLIST"
sudo launchctl bootstrap system "$PLIST"
sudo launchctl print system/$LABEL | grep -E "state|pid" | head -2
echo "installed. logs: log stream --predicate 'subsystem == \"com.focusguard\"' --level info"
