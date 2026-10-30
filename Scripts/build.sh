#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

if command -v xcodegen >/dev/null 2>&1; then
  xcodegen generate
fi

case "${1:-preview}" in
  preview)
    # Preview build needs no Developer account. It cannot activate the system extension.
    xcodebuild -quiet -project MovemberCam.xcodeproj -scheme MovemberCam \
      -configuration Debug -derivedDataPath build CODE_SIGNING_ALLOWED=NO MOVEMBER_PREVIEW_BUILD=YES build
    # Locally sign executable code so Apple Silicon can launch the preview bundle.
    codesign --force --sign - build/Build/Products/Debug/MovemberCam.app/Contents/Library/SystemExtensions/*.systemextension
    codesign --force --sign - --entitlements Config/Preview.entitlements build/Build/Products/Debug/MovemberCam.app
    printf '\nPreview: %s/build/Build/Products/Debug/MovemberCam.app\n' "$PWD"
    ;;
  signed)
    if [[ ! -f Config/Signing.xcconfig ]]; then
      printf 'Copy Config/Signing.example.xcconfig to Config/Signing.xcconfig and set DEVELOPMENT_TEAM first.\n' >&2
      exit 1
    fi
    signing_args=(-allowProvisioningUpdates)
    if [[ "${REGISTER_DEVELOPMENT_DEVICE:-0}" == "1" ]]; then
      signing_args+=(-allowProvisioningDeviceRegistration)
    fi
    xcodebuild -quiet -project MovemberCam.xcodeproj -scheme MovemberCam \
      -configuration Release -derivedDataPath build "${signing_args[@]}" build
    printf '\nSigned app: %s/build/Build/Products/Release/MovemberCam.app\n' "$PWD"
    ;;
  *) printf 'Usage: %s [preview|signed]\n' "$0" >&2; exit 1 ;;
esac
