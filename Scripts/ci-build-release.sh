#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${MOVEMBER_PROFILE_PATH:?Configure release signing first}"
: "${MOVEMBER_TEAM_ID:?Configure the developer team first}"
: "${MOVEMBER_NOTARY_PROFILE:?Configure notarization first}"
swift -module-cache-path build/ModuleCache.noindex Scripts/RenderAppIcon.swift \
  "$PWD/Resources/MovemberMo.png" "$PWD/build/icon-artwork"
iconutil -c icns build/icon-artwork/AppIcon.iconset -o Resources/AppIcon.icns
xcodegen generate
xcodebuild -quiet -project MovemberCam.xcodeproj -scheme MovemberCam -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath build/release-derived \
  -archivePath build/release.xcarchive CODE_SIGNING_ALLOWED=NO archive
signed_app="$PWD/build/release/MovemberCam.app"
ditto build/release.xcarchive/Products/Applications/MovemberCam.app "$signed_app"
bash Scripts/sign-release-app.sh "$signed_app" "$MOVEMBER_PROFILE_PATH" "$MOVEMBER_TEAM_ID"
bash Scripts/build-dmg.sh --app "$signed_app" --notarize "$MOVEMBER_NOTARY_PROFILE"
