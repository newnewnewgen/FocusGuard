#!/bin/bash
# Install (or update) the FocusGuard daemon. MUST RUN AS ROOT.
#   usage: install-daemon-root.sh /path/to/built/focusguardd
#
# Called two ways: by FocusGuard.app behind one macOS password prompt, and by
# scripts/install-daemon.sh via sudo. Everything it writes is root-owned and sits in directories
# only root can modify, so the code that runs as root cannot be swapped without a password.
set -euo pipefail

SRC="${1:?usage: install-daemon-root.sh /path/to/focusguardd}"
LABEL=com.focusguard.daemon
BIN=/Library/PrivilegedHelperTools/$LABEL
PLIST=/Library/LaunchDaemons/$LABEL.plist
SUPPORT="/Library/Application Support/FocusGuard"

[ "$(id -u)" = 0 ] || { echo "install-daemon-root.sh must run as root" >&2; exit 1; }
[ -f "$SRC" ] && [ -x "$SRC" ] || { echo "no daemon binary at $SRC" >&2; exit 1; }

# Stop whatever holds the label now: an older copy of this install, the pre-0.4 one registered
# from inside the app bundle, or the first manual install. bootout is asynchronous.
if launchctl print "system/$LABEL" >/dev/null 2>&1; then
    launchctl bootout "system/$LABEL" 2>/dev/null || true
    for _ in $(seq 40); do
        launchctl print "system/$LABEL" >/dev/null 2>&1 || break
        sleep 0.25
    done
fi
rm -f /usr/local/libexec/focusguardd   # first manual install location

mkdir -p /Library/PrivilegedHelperTools /Library/Logs/FocusGuard "$SUPPORT"
chown root:admin "$SUPPORT"
chmod 775 "$SUPPORT"   # the app saves config.json here as the logged-in admin user

# Copy to a temp name, then rename: never a half-written binary at the path launchd runs.
install -o root -g wheel -m 755 "$SRC" "$BIN.new"
mv -f "$BIN.new" "$BIN"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key><array><string>$BIN</string><string>run</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardOutPath</key><string>/Library/Logs/FocusGuard/daemon.log</string>
    <key>StandardErrorPath</key><string>/Library/Logs/FocusGuard/daemon.log</string>
</dict>
</plist>
EOF
chown root:wheel "$PLIST"
chmod 644 "$PLIST"

launchctl enable "system/$LABEL" 2>/dev/null || true
launchctl bootstrap system "$PLIST"
echo "installed $BIN"
