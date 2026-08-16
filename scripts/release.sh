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
ln -s /Applications "$DMG_ROOT/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_ROOT" -ov -format UDZO "$DMG" -quiet

echo "==> Done"
echo "App:  $STAGED"
echo "DMG:  $DMG"
