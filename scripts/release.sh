#!/usr/bin/env bash
# release — build, sign, notarize, package ContextBuddy as a DMG.
#
# Per SPEC.md §12. Requires:
#   - DEVELOPER_ID="Developer ID Application: <Name> (TEAMID)"
#   - APPLE_ID, APPLE_TEAM_ID, APPLE_APP_PASSWORD env vars (or a stored
#     notarytool keychain profile named "contextbuddy-notarize")
#   - create-dmg installed (`brew install create-dmg`)
#
# Distribution-only flow — local `swift run` does not need any of this.

set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="ContextBuddy"
BUNDLE_ID="com.donthype.contextbuddy"
BUILD_DIR=".build/release"
STAGE_DIR=".build/stage"
APP_DIR="${STAGE_DIR}/${APP_NAME}.app"
DMG_PATH=".build/${APP_NAME}.dmg"

require_env() {
  local var="$1"
  if [ -z "${!var:-}" ]; then
    printf 'release: missing env var %s\n' "$var" >&2
    exit 1
  fi
}

require_env DEVELOPER_ID

# 1. Build release binary.
swift build -c release --arch arm64 --arch x86_64 || swift build -c release

# 2. Stage .app bundle layout.
rm -rf "$STAGE_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BUILD_DIR/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key>
  <string>${BUNDLE_ID}</string>
  <key>CFBundleName</key>
  <string>${APP_NAME}</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHumanReadableCopyright</key>
  <string>MIT License</string>
</dict>
</plist>
PLIST

# 3. Sign with hardened runtime.
codesign --force --deep --options runtime \
  --sign "$DEVELOPER_ID" \
  --timestamp \
  "$APP_DIR"

codesign --verify --verbose=2 "$APP_DIR"

# 4. Submit to notary.
ZIP_PATH=".build/${APP_NAME}-notary.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ZIP_PATH"

if xcrun notarytool store-credentials --help >/dev/null 2>&1; then
  if [ -n "${APPLE_ID:-}" ] && [ -n "${APPLE_TEAM_ID:-}" ] && [ -n "${APPLE_APP_PASSWORD:-}" ]; then
    xcrun notarytool submit "$ZIP_PATH" \
      --apple-id "$APPLE_ID" \
      --team-id "$APPLE_TEAM_ID" \
      --password "$APPLE_APP_PASSWORD" \
      --wait
  else
    xcrun notarytool submit "$ZIP_PATH" \
      --keychain-profile "contextbuddy-notarize" \
      --wait
  fi
else
  printf 'release: notarytool not available; skipping notarization\n' >&2
fi

xcrun stapler staple "$APP_DIR" || true

# 5. Build DMG.
if command -v create-dmg >/dev/null 2>&1; then
  rm -f "$DMG_PATH"
  create-dmg \
    --volname "$APP_NAME" \
    --window-size 540 360 \
    --icon-size 100 \
    --app-drop-link 380 180 \
    --icon "${APP_NAME}.app" 160 180 \
    "$DMG_PATH" \
    "$STAGE_DIR"
else
  printf 'release: create-dmg not installed; staged app at %s\n' "$APP_DIR" >&2
fi

printf 'release: done. App at %s, DMG at %s\n' "$APP_DIR" "$DMG_PATH"
