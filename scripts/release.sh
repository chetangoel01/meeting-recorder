#!/bin/bash
# Builds, signs (Developer ID), notarizes, staples, and packages Meeting Recorder.
# Prereqs: paid Apple Developer team, notarytool keychain profile "meeting-recorder".
set -euo pipefail

cd "$(dirname "$0")/.."

TEAM_ID="P48VDW72LU"
PROFILE="meeting-recorder"
BUILD_DIR="build/release"
ARCHIVE="$BUILD_DIR/MeetingRecorder.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
APP_NAME="Meeting Recorder"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "==> Archiving"
xcodebuild archive \
  -project MeetingRecorder.xcodeproj \
  -scheme MeetingRecorder \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates \
  -quiet

echo "==> Exporting with Developer ID signing"
cat > "$BUILD_DIR/exportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>$TEAM_ID</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>destination</key>
    <string>export</string>
</dict>
</plist>
PLIST

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$BUILD_DIR/exportOptions.plist" \
  -exportPath "$EXPORT_DIR" \
  -allowProvisioningUpdates

APP="$EXPORT_DIR/MeetingRecorder.app"
STAGED="$BUILD_DIR/$APP_NAME.app"
mv "$APP" "$STAGED"

echo "==> Notarizing"
ZIP="$BUILD_DIR/MeetingRecorder-notarize.zip"
ditto -c -k --keepParent "$STAGED" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait

echo "==> Stapling"
xcrun stapler staple "$STAGED"

echo "==> Verifying"
spctl -a -vv --type execute "$STAGED"

echo "==> Building DMG"
VERSION=$(plutil -extract CFBundleShortVersionString raw "$STAGED/Contents/Info.plist" 2>/dev/null || echo "1.0")
DMG="$BUILD_DIR/MeetingRecorder-$VERSION.dmg"
DMG_ROOT="$BUILD_DIR/dmg-root"
mkdir -p "$DMG_ROOT"
cp -R "$STAGED" "$DMG_ROOT/"

if command -v create-dmg >/dev/null; then
    create-dmg \
        --volname "$APP_NAME" \
        --background scripts/assets/dmg-background.png \
        --window-size 600 360 \
        --icon-size 110 \
        --icon "$APP_NAME.app" 150 165 \
        --app-drop-link 450 165 \
        --hide-extension "$APP_NAME.app" \
        --no-internet-enable \
        "$DMG" "$DMG_ROOT"
else
    echo "create-dmg not installed; falling back to a plain DMG" >&2
    ln -s /Applications "$DMG_ROOT/Applications"
    hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_ROOT" -ov -format UDZO "$DMG" -quiet
fi

echo "==> Done"
echo "App:  $STAGED"
echo "DMG:  $DMG"
