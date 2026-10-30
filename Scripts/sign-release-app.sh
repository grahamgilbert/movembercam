#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app_path="${1:?Usage: sign-release-app.sh APP PROFILE TEAM_ID}"
profile_path="${2:?Provide a Developer ID provisioning profile}"
team_id="${3:?Provide the Apple developer team ID}"
[[ "$team_id" =~ ^[A-Z0-9]{10}$ ]] || { printf 'Invalid developer team ID.\n' >&2; exit 1; }
extension_path="$app_path/Contents/Library/SystemExtensions/com.grahamgilbert.MovemberCam.CameraExtension.systemextension"
[[ -d "$extension_path" ]] || { printf 'Camera extension is missing from the app.\n' >&2; exit 1; }
mkdir -p build/release-entitlements
security cms -D -i "$profile_path" > build/release-entitlements/profile.plist
python3 Scripts/release_signing.py "$app_path" "$team_id" build/release-entitlements/profile.plist
cp "$profile_path" "$app_path/Contents/embedded.provisionprofile"
# Build outputs must not carry Finder/resource-fork metadata into their code signatures.
xattr -cr "$app_path"
identity="$(cat build/release-entitlements/identity)"
sign_bundle() {
  local entitlements="$1" bundle="$2" attempt
  for attempt in 1 2 3; do
    if codesign --force --options runtime --timestamp --entitlements "$entitlements" --sign "$identity" "$bundle"; then
      return
    fi
    [[ "$attempt" -lt 3 ]] || return 1
    printf 'Signing failed; retrying (%s/3).\n' "$attempt" >&2
    sleep 2
  done
}
sign_bundle build/release-entitlements/Extension.entitlements "$extension_path"
sign_bundle build/release-entitlements/App.entitlements "$app_path"
codesign --verify --deep --strict "$app_path"
printf 'Signed app and camera extension: %s\n' "$app_path"
