#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Lookout"
APP_BUNDLE="$SCRIPT_DIR/$APP_NAME.app"
ICONSET_DIR="$(mktemp -d)/AppIcon.iconset"

echo "==> Generating icon..."
mkdir -p "$ICONSET_DIR"
swift "$SCRIPT_DIR/generate_icon.swift" "$ICONSET_DIR"
iconutil -c icns "$ICONSET_DIR" -o "$SCRIPT_DIR/AppIcon.icns"
rm -rf "$(dirname "$ICONSET_DIR")"

echo "==> Building $APP_NAME..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

swiftc -O -o "$APP_BUNDLE/Contents/MacOS/$APP_NAME" \
    "$SCRIPT_DIR/main.swift" \
    "$SCRIPT_DIR/LookoutKeychain.swift" \
    "$SCRIPT_DIR/LookoutGitHub.swift" \
    "$SCRIPT_DIR/LookoutCore.swift" \
    "$SCRIPT_DIR/LookoutPanel.swift" \
    "$SCRIPT_DIR/LookoutSetup.swift" \
    "$SCRIPT_DIR"/JorvikKit/*.swift \
    -framework Cocoa \
    -framework SwiftUI \
    -framework ServiceManagement \
    -framework Security

cp "$SCRIPT_DIR/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$SCRIPT_DIR/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

codesign --force --sign "Developer ID Application: Jonthan Hollin (EG86BCGUE7)" \
    --options runtime \
    --timestamp \
    "$APP_BUNDLE"

echo "==> Built: $APP_BUNDLE"
