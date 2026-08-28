#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCHEME="FSKitExp"
PROJECT="$ROOT/FSKitExp.xcodeproj"
CONFIGURATION="${CONFIGURATION:-Release}"
BUILD_DIR="${BUILD_DIR:-$ROOT/build/release}"
ARCHIVE_PATH="$BUILD_DIR/FSKitExp.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
APP_NAME="FSKitExp.app"
APP_PATH="$EXPORT_DIR/$APP_NAME"
DMG_PATH="$BUILD_DIR/ZipFSKitExp.dmg"
EXPORT_OPTIONS="$ROOT/scripts/ExportOptions.plist"

mkdir -p "$BUILD_DIR"

echo "==> Archive ($CONFIGURATION)"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -archivePath "$ARCHIVE_PATH" \
  archive

echo "==> Export app"
rm -rf "$EXPORT_DIR"
xcodebuild \
  -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_OPTIONS"

echo "==> Register with Launch Services"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f -R "$APP_PATH"

if [[ -f "$ROOT/scripts/notarize.env" ]]; then
  # shellcheck disable=SC1091
  source "$ROOT/scripts/notarize.env"
  : "${NOTARY_APPLE_ID:?Set NOTARY_APPLE_ID in scripts/notarize.env}"
  : "${NOTARY_TEAM_ID:?Set NOTARY_TEAM_ID in scripts/notarize.env}"
  : "${NOTARY_APP_PASSWORD:?Set NOTARY_APP_PASSWORD in scripts/notarize.env}"

  ZIP_PATH="$BUILD_DIR/ZipFSKitExp-notarize.zip"
  echo "==> Notarize"
  ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"
  xcrun notarytool submit "$ZIP_PATH" \
    --apple-id "$NOTARY_APPLE_ID" \
    --team-id "$NOTARY_TEAM_ID" \
    --password "$NOTARY_APP_PASSWORD" \
    --wait
  xcrun stapler staple "$APP_PATH"
  rm -f "$ZIP_PATH"
else
  echo "==> Skipping notarization (copy scripts/notarize.env.example to scripts/notarize.env to enable)"
fi

echo "==> Create DMG"
STAGE="$BUILD_DIR/dmg-stage"
rm -rf "$STAGE" "$DMG_PATH"
mkdir -p "$STAGE"
cp -R "$APP_PATH" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create \
  -volname "ZipFSKitExp" \
  -srcfolder "$STAGE" \
  -ov \
  -format UDZO \
  "$DMG_PATH" >/dev/null
rm -rf "$STAGE"

echo
echo "Built:"
echo "  App: $APP_PATH"
echo "  DMG: $DMG_PATH"
echo
echo "Install: drag FSKitExp.app to Applications, open once, then enable the File System Extension in System Settings."
