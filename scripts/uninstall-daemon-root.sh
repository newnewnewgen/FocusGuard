#!/bin/bash
# Remove the FocusGuard daemon and everything it wrote. MUST RUN AS ROOT.
# Called by FocusGuard.app behind one macOS password prompt, and by scripts/uninstall-daemon.sh.
# Leaves /Library/Application Support/FocusGuard/config.json (your lists and schedule) in place.
set -euo pipefail

LABEL=com.focusguard.daemon
[ "$(id -u)" = 0 ] || { echo "uninstall-daemon-root.sh must run as root" >&2; exit 1; }

# The daemon clears its /etc/hosts region when it receives SIGTERM; wait for it to go.
if launchctl print "system/$LABEL" >/dev/null 2>&1; then
    launchctl bootout "system/$LABEL" 2>/dev/null || true
    for _ in $(seq 40); do
        launchctl print "system/$LABEL" >/dev/null 2>&1 || break
        sleep 0.25
    done
fi

rm -f "/Library/LaunchDaemons/$LABEL.plist" "/Library/PrivilegedHelperTools/$LABEL" /usr/local/libexec/focusguardd
rm -rf /var/db/FocusGuard "/Library/Application Support/FocusGuard/state"

# Belt and braces: if the daemon was already dead, its region is still in /etc/hosts.
if grep -q "^# FOCUSGUARD START" /etc/hosts; then
    sed -i '' '/^# FOCUSGUARD START/,/^# FOCUSGUARD END/d' /etc/hosts
    dscacheutil -flushcache
    killall -HUP mDNSResponder 2>/dev/null || true
fi
echo "uninstalled"
