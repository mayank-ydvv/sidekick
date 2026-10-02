#!/bin/zsh
# Builds a Release Sidekick.dmg.
#   ./scripts/make-dmg.sh                       → locally signed ("Sidekick Dev" or ad-hoc) DMG for your own Mac
#   DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=sidekick ./scripts/make-dmg.sh
#                                               → signed with Developer ID, notarized, stapled (shareable)
# One-time notary setup:  xcrun notarytool store-credentials sidekick --apple-id you@example.com --team-id TEAMID
set -e
cd "$(dirname "$0")/.."
DD="$HOME/Library/Developer/Xcode/DerivedData/Sidekick-cli"
OUT="build/dist"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Sidekick/Info.plist 2>/dev/null || echo 0.0.0)
./scripts/fetch-vendor.sh
xcodegen generate --quiet
xcodebuild -project Sidekick.xcodeproj -scheme Sidekick -configuration Release -derivedDataPath "$DD" build | grep -E "error|BUILD" || true

# Stage outside ~/Desktop: iCloud/Finder xattrs there break codesign.
STAGE=$(mktemp -d)/stage
mkdir -p "$STAGE" "$OUT"
ditto --noextattr "$DD/Build/Products/Release/Sidekick.app" "$STAGE/Sidekick.app"
APP="$STAGE/Sidekick.app"

IDENTITY="${DEVELOPER_ID:-}"
if [[ -z "$IDENTITY" ]]; then
  if security find-identity -p codesigning | grep -q '"Sidekick Dev"'; then IDENTITY="Sidekick Dev"; else IDENTITY="-"; fi
fi
TS="--timestamp"; [[ "$IDENTITY" == "-" || "$IDENTITY" == "Sidekick Dev" ]] && TS="--timestamp=none"
find "$APP/Contents" \( -name "*.dylib" -o -name "*.framework" -o -name "*.bundle" \) -print0 \
  | xargs -0 -I{} codesign --force --options runtime $TS --sign "$IDENTITY" {}
codesign --force --options runtime $TS --entitlements Sidekick/Sidekick.entitlements --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"
echo "signed with: $IDENTITY"

ln -s /Applications "$STAGE/Applications"
DMG="$OUT/Sidekick-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "Sidekick" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
[[ "$IDENTITY" != "-" ]] && codesign --force $TS --sign "$IDENTITY" "$DMG"

if [[ -n "${DEVELOPER_ID:-}" && -n "${NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  spctl -a -t open --context context:primary-signature -v "$DMG"
  echo "notarized ✓"
else
  echo "note: not notarized (set DEVELOPER_ID and NOTARY_PROFILE to notarize for sharing)"
fi
echo "dmg: $DMG ($(du -h "$DMG" | cut -f1))"
