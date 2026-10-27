#!/bin/bash
# Stop the daemon (its SIGTERM handler clears the hosts region) and remove installed files.
set -euo pipefail
LABEL=com.focusguard.daemon

if sudo launchctl print system/$LABEL >/dev/null 2>&1; then
    sudo launchctl bootout system/$LABEL
fi
sudo rm -f /Library/LaunchDaemons/$LABEL.plist /usr/local/libexec/focusguardd
if grep -q "FOCUSGUARD START" /etc/hosts; then
    echo "WARNING: hosts region still present; remove the block between the FOCUSGUARD markers in /etc/hosts by hand" >&2
    exit 1
fi
echo "uninstalled. config left in '/Library/Application Support/FocusGuard'"
