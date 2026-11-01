#!/bin/bash
# Fallback: build focusguardd and install it by hand as a root launchd daemon. Prefer FocusGuard.app → Settings → Status → Install protection, which registers the daemon from inside the app bundle. Do not use both: same label.
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
# The plist in launchd/ is the in-bundle (BundleProgram) form used by the app; the manual
# install needs an absolute program path, so write it here.
sudo tee "$PLIST" >/dev/null <<EOF
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
sudo chmod 644 "$PLIST"
sudo chown root:wheel "$PLIST"
sudo launchctl bootstrap system "$PLIST"
sudo launchctl print system/$LABEL | grep -E "state|pid" | head -2
echo "installed. logs: log stream --predicate 'subsystem == \"com.focusguard\"' --level info"
