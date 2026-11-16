#!/bin/zsh
# Package a built MarkText.app into a DMG. Optionally sign with Developer ID and notarize.
#
# usage:
#   Scripts/release.sh <path/to/MarkText.app> [version]
#
# Environment:
#   SIGN_IDENTITY   e.g. "Developer ID Application: Jane Doe (ABCDE12345)". Unset = keep the app's current
#                   (ad-hoc) signature and skip notarization.
#   NOTARY_PROFILE  keychain profile created once with `xcrun notarytool store-credentials <name> ...`.
#                   Required to notarize; ignored without SIGN_IDENTITY.
#
# Output: dist/MarkText-<version>-arm64.dmg (+ .sha256)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_APP="${1:?usage: release.sh <MarkText.app> [version]}"
VERSION="${2:-$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$SRC_APP/Contents/Info.plist")}"
DIST="$ROOT/../dist"; STAGE="$DIST/stage"; DMG="$DIST/MarkText-$VERSION-arm64.dmg"
rm -rf "$STAGE"; mkdir -p "$STAGE"
ditto "$SRC_APP" "$STAGE/MarkText.app"
APP="$STAGE/MarkText.app"

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  echo "==> Signing with $SIGN_IDENTITY"
  # Inside-out: extension first, then the app. Hardened runtime + secure timestamp are required for notarization.
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" \
    --entitlements "$ROOT/Config/MarkTextQuickLook.entitlements" "$APP/Contents/PlugIns/MarkTextQuickLook.appex"
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" \
    --entitlements "$ROOT/Config/MarkText.entitlements" "$APP"
  codesign --verify --deep --strict --verbose=2 "$APP"
  if codesign -d --entitlements - "$APP" 2>/dev/null | grep -q get-task-allow; then
    echo "error: get-task-allow present; notarization would reject it" >&2; exit 1
  fi
fi

echo "==> Building $DMG"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "MarkText 2" -srcfolder "$STAGE" -fs APFS -format ULMO -ov "$DMG" >/dev/null 2>&1

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
  if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    echo "==> Notarizing (usually a few minutes)"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
    spctl --assess --type open --context context:primary-signature -vv "$DMG" || true
  else
    echo "note: NOTARY_PROFILE not set, DMG is signed but not notarized"
  fi
fi

rm -rf "$STAGE"
( cd "$DIST" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256" )
echo "==> Done: $DMG"; cat "$DMG.sha256"
