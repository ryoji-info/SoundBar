#!/bin/bash
# SoundBar installer.
#
# Dragging SoundBar.app to Applications is enough to *run* it, but not enough to have it
# start at login: the login agent is a LaunchAgent plist that has to name your own home
# directory, so it cannot be shipped pre-made. This script writes it for you.
#
# Everything it does is reversible — see "Uninstall SoundBar.command".

set -uo pipefail

APP_NAME="SoundBar"
BUNDLE_ID="com.ryoji.SoundBar"
INSTALL_DIR="/Applications"
AGENT_PLIST="$HOME/Library/LaunchAgents/$BUNDLE_ID.plist"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$APP_NAME.app"

say()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!! \033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m!! \033[0m %s\n' "$*"; echo; echo "Press return to close."; read -r _; exit 1; }

echo
say "Installing $APP_NAME"
echo

# --- Requirements ------------------------------------------------------------------------

if [[ ! -d "$SRC" ]]; then
  die "Can't find $APP_NAME.app next to this script. Run it from the mounted SoundBar disk image."
fi

os_major=$(sw_vers -productVersion | cut -d. -f1)
os_minor=$(sw_vers -productVersion | cut -d. -f2)
if (( os_major < 14 || (os_major == 14 && os_minor < 4) )); then
  die "macOS 14.4 or later is required (you have $(sw_vers -productVersion)).
     SoundBar depends on per-process CoreAudio properties that do not exist before 14.4."
fi

if [[ "$(uname -m)" != "arm64" ]]; then
  die "This build is Apple Silicon only (this Mac reports $(uname -m)).
     Rebuild from source with a different -target to run on Intel."
fi

# Not fatal: someone may be installing ahead of plugging in / for a different machine.
if ! ioreg -c AppleMultitouchDevice -r 2>/dev/null | grep -qi 'DFR\|TouchBar' \
   && ! pgrep -xq TouchBarServer; then
  warn "No Touch Bar detected. SoundBar will install and run, but it has nothing to draw on."
  echo
fi

# --- Stop anything already running -------------------------------------------------------

if [[ -f "$AGENT_PLIST" ]] || pgrep -xq "$APP_NAME"; then
  say "Stopping the existing copy"
  launchctl bootout "gui/$(id -u)/$BUNDLE_ID" 2>/dev/null || true
  pkill -x "$APP_NAME" 2>/dev/null || true

  # Wait for it to actually go rather than assuming a fixed delay is enough: replacing the
  # bundle underneath a live process is how you get a half-written binary and a relaunch loop.
  for _ in $(seq 1 50); do
    pgrep -xq "$APP_NAME" || break
    sleep 0.1
  done
  if pgrep -xq "$APP_NAME"; then
    warn "It did not exit after 5s; forcing."
    pkill -9 -x "$APP_NAME" 2>/dev/null || true
    sleep 1
  fi
fi

# --- Copy --------------------------------------------------------------------------------

say "Copying to $INSTALL_DIR"
if [[ -e "$INSTALL_DIR/$APP_NAME.app" ]]; then
  rm -rf "$INSTALL_DIR/$APP_NAME.app" || die "Could not replace $INSTALL_DIR/$APP_NAME.app — is it running?"
fi
# ditto rather than cp: it preserves the code signature byte-for-byte, which matters because the
# app is ad-hoc signed and macOS keys its privacy permissions to the exact code hash. cp -R can
# perturb the seal and would cost you the Microphone / Audio Recording grants on every install.
ditto "$SRC" "$INSTALL_DIR/$APP_NAME.app" || die "Copy failed. Do you have permission to write to $INSTALL_DIR?"

# A disk image that travelled through a browser, AirDrop or email carries a quarantine flag, and a
# quarantined ad-hoc-signed app is refused outright ("damaged and can't be opened").
xattr -dr com.apple.quarantine "$INSTALL_DIR/$APP_NAME.app" 2>/dev/null || true

if command -v codesign >/dev/null 2>&1; then
  if codesign --verify --strict "$INSTALL_DIR/$APP_NAME.app" 2>/dev/null; then
    say "Signature intact"
  else
    warn "Signature did not verify after copying; re-signing ad-hoc."
    codesign --force --sign - --identifier "$BUNDLE_ID" --timestamp=none \
      "$INSTALL_DIR/$APP_NAME.app" >/dev/null 2>&1 \
      || warn "Re-signing failed. SoundBar will still run, but you may be re-prompted for permissions."
  fi
fi

# --- Login agent -------------------------------------------------------------------------

say "Writing the login agent"
mkdir -p "$(dirname "$AGENT_PLIST")" "$HOME/Library/Logs/SoundBar"
cat > "$AGENT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$BUNDLE_ID</string>
  <key>ProgramArguments</key>
  <array>
    <string>$INSTALL_DIR/$APP_NAME.app/Contents/MacOS/$APP_NAME</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key>
  <dict><key>SuccessfulExit</key><false/></dict>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/SoundBar/launchd.err.log</string>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/SoundBar/launchd.out.log</string>
</dict>
</plist>
PLIST

say "Starting SoundBar"
launchctl bootstrap "gui/$(id -u)" "$AGENT_PLIST" 2>/dev/null || \
  launchctl kickstart -k "gui/$(id -u)/$BUNDLE_ID" 2>/dev/null || \
  warn "Could not start the agent automatically. Log out and back in, or open $INSTALL_DIR/$APP_NAME.app by hand."

sleep 2
if pgrep -xq "$APP_NAME"; then
  echo
  say "Installed and running."
else
  echo
  warn "Installed, but the app is not running yet. Check ~/Library/Logs/SoundBar/launchd.err.log"
fi

cat <<'NEXT'

  SoundBar has no Dock icon and no window — look for it in the menu bar.

  Two permissions are needed, both asked for the first time audio is captured:

    • Screen & System Audio Recording — REQUIRED. macOS files system-audio capture
      under Screen Recording even though SoundBar never reads the screen. Deny it and
      the Touch Bar draws a flat line: the tap is created and calls back at full rate,
      but every sample arrives as 0.0. It fails silently, with no error.

    • Microphone — REQUIRED. Not just for the input meter; macOS checks it when the
      system-audio tap is created too.

  Accessibility and Input Monitoring are NOT needed. Play something to test.

NEXT
echo "Press return to close."
read -r _
