#!/bin/zsh
# Builds outside the Desktop folder: iCloud/Finder xattrs there break codesign.
#   ./build.sh            build (Debug)
#   ./build.sh test       run unit tests
#   ./build.sh install    build and copy to /Applications/Sidekick.app
set -e
cd "$(dirname "$0")"
DD="$HOME/Library/Developer/Xcode/DerivedData/Sidekick-cli"
# install defaults to an optimized Release build; build/test default to Debug.
if [[ "$1" == "uitest" ]]; then
  # Drives the installed app with synthesized keyboard/mouse input (dry run: no API calls, no typing into other apps).
  pkill -x Sidekick || true; sleep 1
  /Applications/Sidekick.app/Contents/MacOS/Sidekick -uiTest YES 2>/dev/null | grep -E "^UI "
  exit ${pipestatus[1]}
fi
if [[ "$1" == "install" ]]; then CONFIG="${CONFIG:-Release}"; else CONFIG="${CONFIG:-Debug}"; fi
APP="$DD/Build/Products/$CONFIG/Sidekick.app"
./scripts/fetch-vendor.sh
xcodegen generate --quiet
if [[ "$1" == "uitest" ]]; then
  # Drives the installed app with synthesized keyboard/mouse input (dry run: no API calls, no typing into other apps).
  pkill -x Sidekick || true; sleep 1
  /Applications/Sidekick.app/Contents/MacOS/Sidekick -uiTest YES 2>/dev/null | grep -E "^UI "
  exit ${pipestatus[1]}
fi
if [[ "$1" == "install" ]]; then
  xcodebuild -project Sidekick.xcodeproj -scheme Sidekick -configuration "$CONFIG" -derivedDataPath "$DD" build > /tmp/sidekick-build.log 2>&1 \
    || { grep -E "error" /tmp/sidekick-build.log | head -20; echo "** BUILD FAILED ** (not installed; full log: /tmp/sidekick-build.log)"; exit 1; }
  echo "** BUILD SUCCEEDED **"
  pkill -x Sidekick || true
  rm -rf /Applications/Sidekick.app
  ditto "$APP" /Applications/Sidekick.app
  # Re-sign with a stable identity so permission grants survive rebuilds (see scripts/setup-signing.sh).
  if security find-identity -p codesigning | grep -q '"Sidekick Dev"'; then
    # Sign nested code first (dylibs, frameworks, bundles), then the app itself.
    find /Applications/Sidekick.app/Contents \( -name "*.dylib" -o -name "*.framework" -o -name "*.bundle" \) -print0 \
      | xargs -0 -I{} codesign --force --options runtime --timestamp=none --sign "Sidekick Dev" {}
    codesign --force --options runtime --timestamp=none \
      --entitlements Sidekick/Sidekick.entitlements --sign "Sidekick Dev" /Applications/Sidekick.app
    codesign --verify --deep --strict /Applications/Sidekick.app
    echo "signed with 'Sidekick Dev' (stable permissions)"
  else
    echo "note: ad-hoc signed — run scripts/setup-signing.sh once so permissions survive rebuilds"
  fi
  echo "installed: /Applications/Sidekick.app"
else
  xcodebuild -project Sidekick.xcodeproj -scheme Sidekick -configuration "$CONFIG" -derivedDataPath "$DD" "${@:-build}"
  echo "app: $APP"
fi
