#!/bin/bash
# Decides §3 of docs/superpowers/specs/2026-11-11-chrome-pages-design.md: does Chrome pick up a
# URLBlocklist written to the SYSTEM preference domain (/Library/Preferences, root-only) on its
# own, or only on its periodic refresh / a manual "Reload policies"? Run with sudo. Writes one
# key, asks you what Chrome does, removes the key again. Nothing else is touched.
set -uo pipefail
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 2; }
DOMAIN=/Library/Preferences/com.google.Chrome
PATTERN="chrome-extension://fjcldmjmjhkklehbacihaiopjklihlgg/entrypoints/options-page/index.html"
pgrep -xq "Google Chrome" || { echo "Google Chrome must be running (and stay running) for this"; exit 1; }
if defaults read "$DOMAIN" URLBlocklist >/dev/null 2>&1; then echo "URLBlocklist is already set in $DOMAIN; not touching it"; exit 1; fi
ask() { local a; while :; do read -r -p "$1 [y/n] " a </dev/tty; case "$a" in y|Y) return 0;; n|N) return 1;; esac; done; }

echo "Do NOT click \"Reload policies\" in chrome://policy at any point; the question is whether Chrome notices by itself."
echo
echo "--- 1. writing URLBlocklist to the system domain"
defaults write "$DOMAIN" URLBlocklist -array "$PATTERN" || exit 1
ls -l "$DOMAIN.plist"
echo "    waiting 15 s..."; sleep 15
echo "    now open this in Chrome (a NEW tab):  $PATTERN"
if ask "Is the page blocked (\"blocked by your administrator\" / ERR_BLOCKED_BY_ADMINISTRATOR)?"; then set_live=yes; else
    echo "    waiting another 45 s, then try again (reload the tab)"; sleep 45
    if ask "Blocked now?"; then set_live=slow; else set_live=no; fi
fi

echo "--- 2. removing the key"
defaults delete "$DOMAIN" URLBlocklist
echo "    waiting 15 s..."; sleep 15
echo "    reload that tab"
if ask "Does the page load again?"; then unset_live=yes; else
    echo "    waiting another 45 s, then reload"; sleep 45
    if ask "Loads now?"; then unset_live=slow; else unset_live=no; fi
fi

echo
echo "RESULT: set picked up: $set_live   removal picked up: $unset_live"
case "$set_live$unset_live" in
    yesyes) echo "VERDICT: system domain only (sudo-grade guarantee)";;
    *) echo "VERDICT: write both domains (system for durability, user for live pickup); README states the 30 s re-assert guarantee";;
esac
defaults read "$DOMAIN" URLBlocklist >/dev/null 2>&1 && echo "WARNING: key still present" || echo "cleaned up: key removed"
