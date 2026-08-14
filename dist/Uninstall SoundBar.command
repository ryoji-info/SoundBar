#!/bin/bash
# Removes SoundBar completely: the login agent, the app, and optionally its settings and logs.

set -uo pipefail

APP_NAME="SoundBar"
BUNDLE_ID="com.ryoji.SoundBar"
AGENT_PLIST="$HOME/Library/LaunchAgents/$BUNDLE_ID.plist"

say() { printf '\033[1m==>\033[0m %s\n' "$*"; }

echo
say "Removing $APP_NAME"
echo

launchctl bootout "gui/$(id -u)/$BUNDLE_ID" 2>/dev/null || true
pkill -x "$APP_NAME" 2>/dev/null || true
sleep 1

[[ -f "$AGENT_PLIST" ]] && rm -f "$AGENT_PLIST" && say "Removed the login agent"
[[ -d "/Applications/$APP_NAME.app" ]] && rm -rf "/Applications/$APP_NAME.app" && say "Removed the app"

echo
read -r -p "Also delete settings and logs? [y/N] " answer
if [[ "$answer" == [Yy]* ]]; then
  defaults delete "$BUNDLE_ID" 2>/dev/null || true
  rm -rf "$HOME/Library/Logs/SoundBar"
  say "Removed settings and logs"
else
  say "Kept your settings — reinstalling will pick up where you left off."
fi

cat <<'NEXT'

  One thing this script cannot do for you: macOS keeps the privacy permissions you granted.
  To clear them, remove SoundBar from System Settings ▸ Privacy & Security under
  Microphone, Screen & System Audio Recording.

NEXT
echo "Press return to close."
read -r _
