#!/bin/bash
# Install (or update) the FocusGuard daemon. MUST RUN AS ROOT.
#   usage: install-daemon-root.sh /path/to/built/focusguardd
#
# Called two ways: by FocusGuard.app behind one macOS password prompt, and by
# scripts/install-daemon.sh via sudo. Everything it writes is root-owned and sits in directories
# only root can modify, so the code that runs as root cannot be swapped without a password.
set -uo pipefail

SRC="${1:?usage: install-daemon-root.sh /path/to/focusguardd}"
LABEL=com.focusguard.daemon
BIN=/Library/PrivilegedHelperTools/$LABEL
PLIST=/Library/LaunchDaemons/$LABEL.plist
SUPPORT="/Library/Application Support/FocusGuard"
STATE=/var/db/FocusGuard

fail() { echo "install-daemon-root.sh: $*" >&2; exit 1; }
loaded() { launchctl print "system/$LABEL" >/dev/null 2>&1; }

[ "$(id -u)" = 0 ] || fail "must run as root"
[ -f "$SRC" ] && [ -x "$SRC" ] || fail "no daemon binary at $SRC"

# From here on a failure must not leave the Mac with no daemon: if a plist is in place and
# nothing is loaded, load it. Set before the bootout, which is the first thing that can do that.
recover() {
    if [ -f "$PLIST" ] && ! loaded; then launchctl bootstrap system "$PLIST" 2>/dev/null || true; fi
}
trap recover EXIT

# Stop whatever holds the label now: an older copy of this install, the pre-0.4 one registered
# from inside the app bundle, or the first manual install. bootout is asynchronous, and launchd
# waits up to 20 s for the old process to exit before killing it, so wait longer than that.
if loaded; then
    launchctl bootout "system/$LABEL" 2>/dev/null || true
    for _ in $(seq 120); do
        loaded || break
        sleep 0.25
    done
    loaded && fail "the running daemon did not stop within 30 s; it has been left as it was"
fi

rm -f /usr/local/libexec/focusguardd   # first manual install location

mkdir -p /Library/PrivilegedHelperTools /Library/Logs/FocusGuard "$SUPPORT" "$STATE" || fail "cannot create directories"
chown root:admin "$SUPPORT" && chmod 775 "$SUPPORT" || fail "cannot set up $SUPPORT"   # the app saves config.json here
chown root:wheel "$STATE" && chmod 755 "$STATE" || fail "cannot set up $STATE"

# State written by ≤ 0.3 sat inside the user-writable support directory. Carry the accepted
# config over once, only as a plain file and only if there is none yet, then drop the old copy.
LEGACY="$SUPPORT/state"
# The directory sits where the user can rename things, so trust it only if root owns it (as the
# old daemon made it): a planted one is ignored.
if [ -d "$LEGACY" ] && [ ! -L "$LEGACY" ] && [ "$(stat -f %u "$LEGACY")" = 0 ]; then
    if [ ! -e "$STATE/last-good.json" ] && [ -f "$LEGACY/last-good.json" ] && [ ! -L "$LEGACY/last-good.json" ] \
        && [ "$(stat -f %u "$LEGACY/last-good.json")" = 0 ]; then
        install -o root -g wheel -m 644 "$LEGACY/last-good.json" "$STATE/last-good.json" || true
    fi
fi
rm -rf "$LEGACY"

# Copy to a temp name, then rename: never a half-written binary at the path launchd runs.
install -o root -g wheel -m 755 "$SRC" "$BIN.new" || fail "cannot copy the daemon"
mv -f "$BIN.new" "$BIN" || fail "cannot install the daemon"

cat > "$PLIST.new" <<EOF || fail "cannot write $PLIST"
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
chown root:wheel "$PLIST.new" && chmod 644 "$PLIST.new" && mv -f "$PLIST.new" "$PLIST" || fail "cannot install $PLIST"

launchctl enable "system/$LABEL" 2>/dev/null || true
# bootstrap can fail transiently while launchd finishes tearing the old job down.
for attempt in 1 2 3 4 5; do
    loaded && break
    launchctl bootstrap system "$PLIST" 2>/dev/null && break
    sleep 1
done
loaded || fail "launchd would not load $PLIST"

# The label must now belong to the root-owned plist, not to a leftover registration that points
# into an app bundle.
case "$(launchctl print "system/$LABEL" 2>/dev/null)" in
    *"path = $PLIST"*) ;;
    *) fail "the label is loaded from somewhere other than $PLIST" ;;
esac
trap - EXIT
echo "installed $BIN"
