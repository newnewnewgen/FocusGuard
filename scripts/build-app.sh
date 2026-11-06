#!/bin/bash
# Build FocusGuard.app (menu-bar app + embedded focusguardd + launchd plists), ad-hoc signed.
# Output: build/FocusGuard.app. Copy it to /Applications and open it; Status → Install protection.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=${1:-release}
# One invocation per product: SwiftPM honours only the last --product flag.
swift build -c "$CONFIG" --product focusguardd
swift build -c "$CONFIG" --product FocusGuard
BIN=".build/$CONFIG"
APP=build/FocusGuard.app

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" \
         "$APP/Contents/Library/LaunchDaemons" "$APP/Contents/Library/LaunchAgents"
cp "$BIN/FocusGuard"  "$APP/Contents/MacOS/FocusGuard"
cp "$BIN/focusguardd" "$APP/Contents/MacOS/focusguardd"
cp Sources/FocusGuard/Info.plist "$APP/Contents/Info.plist"
# Inert since 0.4: kept only so an install made by ≤ 0.3 (SMAppService) can be found and
# unregistered during migration. The daemon is installed by install-daemon-root.sh.
cp launchd/com.focusguard.daemon.plist "$APP/Contents/Library/LaunchDaemons/"
cp launchd/com.focusguard.app.plist    "$APP/Contents/Library/LaunchAgents/"
cp scripts/install-daemon-root.sh scripts/uninstall-daemon-root.sh "$APP/Contents/Resources/"
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"   # regenerate: swift scripts/make-icon.swift
echo -n "APPL????" > "$APP/Contents/PkgInfo"

# Ad-hoc: no developer account. SMAppService accepts this from /Applications (spike 2026-10-30).
# Inside-out, with a fixed identifier on the daemon: `--deep` would give the bare Mach-O an
# identifier derived from its hash, different on every build.
codesign --force --sign - --identifier com.focusguard.daemon "$APP/Contents/MacOS/focusguardd"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
echo "built $APP"
