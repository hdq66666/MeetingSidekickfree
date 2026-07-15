#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
GIT_VERSION="$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || echo nogit)"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT_DIR/Resources/Info.plist")"
APP_NAME="MeetingSidekickfree-${VERSION}-${GIT_VERSION}"
BUILD_DIR="$ROOT_DIR/Build"
APP_DIR="$ROOT_DIR/Build/${APP_NAME}.app"
DMG_STAGING_DIR="$ROOT_DIR/Build/${APP_NAME}-dmg"
DMG_PATH="$ROOT_DIR/Build/${APP_NAME}-macos-arm64.dmg"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

cd "$ROOT_DIR"
mkdir -p ".build/module-cache"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$ROOT_DIR/.build/module-cache}"

swift build --disable-sandbox -c release

mkdir -p "$BUILD_DIR"
rm -rf "$APP_DIR" "$DMG_STAGING_DIR" "$DMG_PATH"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp ".build/release/MeetingSidekickfree" "$MACOS_DIR/MeetingSidekickfree"
cp "Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "Resources/MeetingSidekick.entitlements" "$RESOURCES_DIR/MeetingSidekick.entitlements"

/usr/libexec/PlistBuddy -c "Set :CFBundleName MeetingSidekickfree" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName MeetingSidekickfree" "$CONTENTS_DIR/Info.plist" >/dev/null 2>&1 \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string MeetingSidekickfree" "$CONTENTS_DIR/Info.plist"
chmod +x "$MACOS_DIR/MeetingSidekickfree"

codesign \
    --force \
    --deep \
    --options runtime \
    --entitlements "Resources/MeetingSidekick.entitlements" \
    --sign - \
    "$APP_DIR" >/dev/null

mkdir -p "$DMG_STAGING_DIR"
ditto "$APP_DIR" "$DMG_STAGING_DIR/${APP_NAME}.app"
ln -s /Applications "$DMG_STAGING_DIR/Applications"

hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$DMG_STAGING_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH" >/dev/null

rm -rf "$DMG_STAGING_DIR"

printf 'app=%s\n' "$APP_DIR"
printf 'dmg=%s\n' "$DMG_PATH"
