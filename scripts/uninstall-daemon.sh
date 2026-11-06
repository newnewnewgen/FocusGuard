#!/bin/bash
# Command-line uninstall. FocusGuard.app → Status → Uninstall protection does the same thing.
set -euo pipefail
cd "$(dirname "$0")"
sudo ./uninstall-daemon-root.sh
echo "config left in '/Library/Application Support/FocusGuard/config.json'"
