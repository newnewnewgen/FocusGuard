#!/bin/bash
# Build FocusGuard.app (menu-bar app + embedded focusguardd + launchd plists), ad-hoc signed.
# Output: build/FocusGuard.app. Run it from /Applications: the app's Status tab offers to move itself.
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
cp launchd/com.focusguard.daemon.plist "$APP/Contents/Library/LaunchDaemons/"
cp launchd/com.focusguard.app.plist    "$APP/Contents/Library/LaunchAgents/"
echo -n "APPL????" > "$APP/Contents/PkgInfo"

# Ad-hoc: no developer account. SMAppService accepts this from /Applications (spike 2026-10-30).
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
echo "built $APP"
