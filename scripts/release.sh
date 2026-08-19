#!/bin/bash
# Builds, signs (Developer ID), notarizes, staples, packages, and publishes
# Meeting Recorder as a GitHub release.
# Prereqs: paid Apple Developer team, notarytool keychain profile
# "meeting-recorder", gh CLI authenticated. Bump CFBundleShortVersionString in
# project.yml before releasing; the version tag must not already exist.
# Pass --no-publish to stop after building the DMG.
set -euo pipefail

cd "$(dirname "$0")/.."

PUBLISH=1
[[ "${1:-}" == "--no-publish" ]] && PUBLISH=0

TEAM_ID="P48VDW72LU"
PROFILE="meeting-recorder"
BUILD_DIR="build/release"
ARCHIVE="$BUILD_DIR/MeetingRecorder.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
APP_NAME="Meeting Recorder"

VERSION=$(plutil -extract CFBundleShortVersionString raw MeetingRecorder/Resources/Info.plist)
TAG="v$VERSION"

if [[ $PUBLISH == 1 ]]; then
    echo "==> Pre-flight for $TAG"
    gh auth status >/dev/null
    if git rev-parse "$TAG" >/dev/null 2>&1; then
        echo "error: tag $TAG already exists — bump CFBundleShortVersionString first" >&2
        exit 1
    fi
    if [[ -n "$(git status --porcelain)" ]]; then
        echo "error: working tree is not clean — commit or stash before releasing" >&2
        exit 1
    fi
fi

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

# Notarize and staple the DMG itself, not just the app inside — an unstapled
# DMG spctl-rejects with "no usable signature" even when its app is fine.
echo "==> Notarizing DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"

echo "==> Verifying DMG contents"
# Don't spctl-assess the DMG itself: it is notarized+stapled but unsigned
# (cloud signing can't sign DMGs), so spctl always says "rejected / no usable
# signature" — a false alarm. Gatekeeper only gates the app inside.
DMG_MOUNT="$BUILD_DIR/dmg-verify"
hdiutil attach "$DMG" -nobrowse -readonly -mountpoint "$DMG_MOUNT" -quiet
spctl -a -vv --type execute "$DMG_MOUNT/$APP_NAME.app"
xcrun stapler validate "$DMG_MOUNT/$APP_NAME.app"
hdiutil detach "$DMG_MOUNT" -quiet

if [[ $PUBLISH == 1 ]]; then
    echo "==> Publishing $TAG"
    git tag "$TAG"
    git push origin main "$TAG"
    gh release create "$TAG" \
        "$DMG#Meeting Recorder $VERSION (signed + notarized DMG)" \
        --title "Meeting Recorder $VERSION" \
        --generate-notes
fi

echo "==> Done"
echo "App:  $STAGED"
echo "DMG:  $DMG"
if [[ $PUBLISH == 1 ]]; then
    gh release view "$TAG" --json url -q '.url'
fi
