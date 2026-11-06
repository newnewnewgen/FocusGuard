#!/bin/bash
# Remove the FocusGuard daemon and everything it wrote. MUST RUN AS ROOT.
# Called by FocusGuard.app behind one macOS password prompt, and by scripts/uninstall-daemon.sh.
# Leaves /Library/Application Support/FocusGuard/config.json (your lists and schedule) in place.
set -uo pipefail

LABEL=com.focusguard.daemon
loaded() { launchctl print "system/$LABEL" >/dev/null 2>&1; }

[ "$(id -u)" = 0 ] || { echo "uninstall-daemon-root.sh: must run as root" >&2; exit 1; }

# The daemon clears its /etc/hosts region when it receives SIGTERM. launchd gives it up to 20 s
# before killing it, so wait longer than that.
if loaded; then
    launchctl bootout "system/$LABEL" 2>/dev/null || true
    for _ in $(seq 120); do
        loaded || break
        sleep 0.25
    done
fi

rm -f "/Library/LaunchDaemons/$LABEL.plist" "/Library/PrivilegedHelperTools/$LABEL" /usr/local/libexec/focusguardd
rm -rf /var/db/FocusGuard "/Library/Application Support/FocusGuard/state"

# Belt and braces: if the daemon was killed rather than stopped, its region is still in
# /etc/hosts. Only a complete START…END block is removed; nothing else is touched.
if grep -q "^# FOCUSGUARD START" /etc/hosts && grep -q "^# FOCUSGUARD END" /etc/hosts; then
    sed -i '' '/^# FOCUSGUARD START/,/^# FOCUSGUARD END/d' /etc/hosts
    dscacheutil -flushcache
    killall -HUP mDNSResponder 2>/dev/null || true
elif grep -q "^# FOCUSGUARD START" /etc/hosts; then
    echo "uninstall-daemon-root.sh: /etc/hosts has a FOCUSGUARD START line with no END; remove the FocusGuard lines by hand" >&2
fi
echo "uninstalled"
