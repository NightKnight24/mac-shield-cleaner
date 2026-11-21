#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT_DIR/build"
APP_NAME="Mac Shield & Cleaner.app"
APP_DIR="$BUILD_DIR/$APP_NAME"
INSTALL=0

if [[ "${1:-}" == "--install" ]]; then
    INSTALL=1
fi

rm -rf "$BUILD_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

echo "[1/4] Generating AppIcon.icns..."
swift "$ROOT_DIR/scripts/gen_icon.swift" "$BUILD_DIR/icon_1024.png"
mkdir -p "$BUILD_DIR/AppIcon.iconset"
for sz in 16 32 128 256 512; do
    sips -z $sz $sz "$BUILD_DIR/icon_1024.png" --out "$BUILD_DIR/AppIcon.iconset/icon_${sz}x${sz}.png" >/dev/null
    sz2=$((sz * 2))
    sips -z $sz2 $sz2 "$BUILD_DIR/icon_1024.png" --out "$BUILD_DIR/AppIcon.iconset/icon_${sz}x${sz}@2x.png" >/dev/null
done
iconutil -c icns "$BUILD_DIR/AppIcon.iconset" -o "$APP_DIR/Contents/Resources/AppIcon.icns"
rm -rf "$BUILD_DIR/icon_1024.png" "$BUILD_DIR/AppIcon.iconset"

echo "[2/4] Compiling Universal Binary (arm64 + x86_64)..."
swiftc -O -parse-as-library -target arm64-apple-macosx13.0 \
    "$ROOT_DIR/src/MacShieldCleanerApp.swift" \
    -o "$BUILD_DIR/MacShieldCleaner-arm64" \
    -framework SwiftUI -framework AppKit

swiftc -O -parse-as-library -target x86_64-apple-macosx13.0 \
    "$ROOT_DIR/src/MacShieldCleanerApp.swift" \
    -o "$BUILD_DIR/MacShieldCleaner-x86_64" \
    -framework SwiftUI -framework AppKit

lipo -create -output "$APP_DIR/Contents/MacOS/MacShieldCleaner" \
    "$BUILD_DIR/MacShieldCleaner-arm64" "$BUILD_DIR/MacShieldCleaner-x86_64"
rm -f "$BUILD_DIR/MacShieldCleaner-arm64" "$BUILD_DIR/MacShieldCleaner-x86_64"

echo "[3/4] Bundling engines & Info.plist..."
cp "$ROOT_DIR/src/shield_engine.sh" "$APP_DIR/Contents/Resources/"
cp "$ROOT_DIR/src/cleaner_engine.sh" "$APP_DIR/Contents/Resources/"
chmod +x "$APP_DIR/Contents/Resources/"*.sh

cat << 'PLIST' > "$APP_DIR/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>MacShieldCleaner</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>io.github.macshieldcleaner</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Mac Shield &amp; Cleaner</string>
    <key>CFBundleDisplayName</key>
    <string>Mac Shield &amp; Cleaner</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.1</string>
    <key>CFBundleVersion</key>
    <string>2</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>Mac Shield &amp; Cleaner needs Automation permission to elevate active games/browsers and inspect frontmost window titles during Shield monitoring.</string>
    <key>NSRemovableVolumesUsageDescription</key>
    <string>Mac Shield &amp; Cleaner needs removable volume access to scan and clean clutter on connected external drives.</string>
</dict>
</plist>
PLIST

echo "[4/4] Code signing bundle..."
codesign --force --deep --sign - "$APP_DIR"

echo "Built: $APP_DIR"
if [[ $INSTALL -eq 1 ]]; then
    rm -rf "/Applications/$APP_NAME"
    cp -R "$APP_DIR" "/Applications/$APP_NAME"
    echo "Installed to: /Applications/$APP_NAME"
fi
