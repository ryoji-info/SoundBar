#!/bin/bash
# Builds SoundBar.app with the Command Line Tools only (no Xcode required).
#
#   ./scripts/build.sh            build into ./build/SoundBar.app
#   ./scripts/build.sh --install  also copy to /Applications and (re)start the login agent
#
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
APP_NAME="SoundBar"
BUNDLE_ID="com.ryoji.SoundBar"
APP="$BUILD_DIR/$APP_NAME.app"
INSTALL_DIR="/Applications"
AGENT_LABEL="$BUNDLE_ID"
AGENT_PLIST="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"

INSTALL=0
[[ "${1:-}" == "--install" ]] && INSTALL=1

SDK="$(xcrun --show-sdk-path)"
# macOS 14.4 is the floor: the per-process CoreAudio properties SoundBar relies on
# (kAudioProcessPropertyIsRunningOutput / …Input) do not exist before it.
TARGET="arm64-apple-macos14.4"

echo "==> Cleaning"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> Copying app icon"
cp "$PROJECT_DIR/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$PROJECT_DIR/Resources/MenuBarNote.svg" "$APP/Contents/Resources/MenuBarNote.svg"

echo "==> Compiling"
# shellcheck disable=SC2046
swiftc \
  -sdk "$SDK" \
  -target "$TARGET" \
  -O \
  -swift-version 5 \
  -framework AppKit \
  -framework CoreAudio \
  -framework AudioToolbox \
  -framework Accelerate \
  -framework ApplicationServices \
  -framework IOKit \
  -F /System/Library/PrivateFrameworks -framework DFRFoundation \
  -import-objc-header "$PROJECT_DIR/Sources/SoundBar/Private.h" \
  -o "$APP/Contents/MacOS/$APP_NAME" \
  $(find "$PROJECT_DIR/Sources/SoundBar" -name '*.swift' | sort)

echo "==> Writing Info.plist"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIconFile</key><string>AppIcon.icns</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.2</string>
  <key>CFBundleVersion</key><string>4</string>
  <key>LSMinimumSystemVersion</key><string>14.4</string>
  <!-- Background agent: no Dock icon, no menu bar of its own. -->
  <key>LSUIElement</key><true/>
  <!-- MANDATORY for the CoreAudio process tap. Without this key tccd refuses the tap silently:
       every call returns noErr, the IOProc fires at full rate, and every sample is 0.0. -->
  <key>NSAudioCaptureUsageDescription</key>
  <string>SoundBar reads the audio you are playing so it can draw it on the Touch Bar. Nothing is recorded or sent anywhere.</string>
  <!-- Only for visualising microphone input, which is optional. -->
  <key>NSMicrophoneUsageDescription</key>
  <string>SoundBar shows your microphone's level on the Touch Bar while a microphone is in use. Nothing is recorded or sent anywhere.</string>
  <!-- Only to ask BetterTouchTool which Touch Bar group is showing. -->
  <key>NSAppleEventsUsageDescription</key>
  <string>SoundBar asks BetterTouchTool whether it has the Touch Bar after the visualiser stops.</string>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Signing (ad-hoc)"
# Ad-hoc is the only option without a Developer ID, but note what it costs. With no team identity
# to pin to, codesign can only write a cdhash-only designated requirement — `codesign -d -r- "$APP"`
# reports `designated => cdhash H"..."` — so TCC keys its grants to the exact code hash, not to
# (path, identity). Any build whose binary or Info.plist changed produces a new cdhash and the
# Screen & System Audio Recording and Microphone grants have to be re-added by hand; a rebuild from
# unchanged sources is reproducible and keeps them. See README, "Permissions".
#
# Deliberately NOT passing --options runtime: an ad-hoc signature can never be notarised, so the
# hardened runtime buys nothing here and only adds ways for dlopen of MultitouchSupport to break.
# Deliberately NOT passing --deep: it is deprecated and there is no nested code in a single binary.
codesign --force --sign - \
  --identifier "$BUNDLE_ID" \
  --timestamp=none \
  "$APP" >/dev/null

codesign --verify --strict "$APP" && echo "    signature OK"

echo "==> Built $APP"

if [[ $INSTALL -eq 1 ]]; then
  echo "==> Installing to $INSTALL_DIR"
  # Stop the running copy first so the binary is not replaced underneath it.
  if [[ -f "$AGENT_PLIST" ]]; then
    launchctl bootout "gui/$(id -u)/$AGENT_LABEL" 2>/dev/null || true
  fi
  pkill -x "$APP_NAME" 2>/dev/null || true
  sleep 1

  rm -rf "$INSTALL_DIR/$APP_NAME.app"
  cp -R "$APP" "$INSTALL_DIR/"
  # Copying can perturb the seal, and TCC evaluates the designated requirement of the file it
  # actually launches, so re-sign in place. Ad-hoc signing is deterministic, so re-signing identical
  # bytes under the same identifier reproduces the same cdhash — this step alone does not void grants.
  codesign --force --sign - --identifier "$BUNDLE_ID" --timestamp=none "$INSTALL_DIR/$APP_NAME.app" >/dev/null
  codesign --verify --strict "$INSTALL_DIR/$APP_NAME.app" && echo "    installed signature OK"

  echo "==> Writing login agent $AGENT_PLIST"
  mkdir -p "$(dirname "$AGENT_PLIST")"
  cat > "$AGENT_PLIST" <<AGENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$AGENT_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$INSTALL_DIR/$APP_NAME.app/Contents/MacOS/$APP_NAME</string>
  </array>
  <key>RunAtLoad</key><true/>
  <!-- Stay running: relaunch if it ever exits unexpectedly. -->
  <key>KeepAlive</key>
  <dict><key>SuccessfulExit</key><false/></dict>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/SoundBar/launchd.err.log</string>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/SoundBar/launchd.out.log</string>
</dict>
</plist>
AGENT

  mkdir -p "$HOME/Library/Logs/SoundBar"
  launchctl bootstrap "gui/$(id -u)" "$AGENT_PLIST"
  echo "==> Installed and started. Log: ~/Library/Logs/SoundBar/SoundBar.log"
fi
