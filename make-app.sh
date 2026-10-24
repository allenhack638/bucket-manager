#!/bin/bash
# Packages the built SwiftPM executable into a double-clickable macOS .app bundle.
# Usage: ./make-app.sh [release|debug]   (default: release)
set -euo pipefail

CONFIG="${1:-release}"
APP_NAME="BucketManager"
APP_BUNDLE_NAME="Bucket Manager"
BUNDLE_ID="com.bucketmanager.app"
VERSION="${VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"

echo "Building ($CONFIG)…"
swift build -c "$CONFIG" -Xswiftc -Xfrontend -Xswiftc -disable-round-trip-debug-types

BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)/$APP_NAME"
APP_DIR="build/$APP_BUNDLE_NAME.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"
cp "$BIN_PATH" "$MACOS_DIR/$APP_NAME"
mkdir -p "$APP_DIR/Contents/Resources"
cp assets/AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_BUNDLE_NAME</string>
  <key>CFBundleDisplayName</key><string>Bucket Manager</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Copyright © 2026 Allen Benny. MIT License.</string>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
</dict>
</plist>
PLIST

# Hardened Runtime is enabled for every build, including ad-hoc development
# builds. Set CODESIGN_IDENTITY to a Developer ID Application certificate for a
# distributable, notarizable build.
if [ "$CODESIGN_IDENTITY" = "-" ]; then
  codesign --force --options runtime --sign - "$APP_DIR"
else
  codesign --force --options runtime --timestamp --sign "$CODESIGN_IDENTITY" "$APP_DIR"
fi
codesign --verify --strict --verbose=2 "$APP_DIR"

echo "Created $APP_DIR (version $VERSION, build $BUILD_NUMBER)"
echo "Run with: open \"$APP_DIR\"   (or: $MACOS_DIR/$APP_NAME for console logs)"
