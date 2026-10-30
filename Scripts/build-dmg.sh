#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
project_root="$PWD"
provided_app=""
output_path=""
notary_profile=""
xcode_notarize=0

usage() {
  cat <<'EOF'
Usage: bash Scripts/build-dmg.sh [options]

Builds and exports a Developer ID-signed app, then packages a signed drag-to-Applications DMG.

  --app PATH           Package an already-signed app instead of archiving/exporting.
  --output PATH        Output DMG (default: dist/MovemberCam-VERSION.dmg).
  --notarize PROFILE   Submit to Apple using an existing notarytool keychain profile and staple.
  --notarize-xcode     Notarize the app using Xcode's signed-in account before packaging.
  --help               Show this help.

Requires Config/Signing.xcconfig with DEVELOPMENT_TEAM and a Developer ID Application certificate.
Python packaging dependencies are installed in build/dmg-tools, not into your system Python.
EOF
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --notarize-xcode) xcode_notarize=1; shift ;;
    --app|--output|--notarize)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      case "$1" in
        --app) provided_app="$2" ;;
        --output) output_path="$2" ;;
        --notarize) notary_profile="$2" ;;
      esac
      shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; usage >&2; exit 1 ;;
  esac
done
if [[ "$xcode_notarize" == 1 && ( -n "$provided_app" || -n "$notary_profile" ) ]]; then
  printf 'Use --notarize-xcode without --app or --notarize.\n' >&2; exit 1
fi

[[ "$(uname -s)" == Darwin ]] || { printf 'DMG packaging requires macOS.\n' >&2; exit 1; }
[[ -f Config/Signing.xcconfig ]] || { printf 'Configure Config/Signing.xcconfig first.\n' >&2; exit 1; }
team_id="${MOVEMBER_TEAM_ID:-$(awk -F= '/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=/ {gsub(/[[:space:]]/, "", $2); print $2; exit}' Config/Signing.xcconfig)}"
[[ "$team_id" =~ ^[A-Z0-9]{10}$ ]] || { printf 'A valid DEVELOPMENT_TEAM is required.\n' >&2; exit 1; }
identity="$(security find-identity -v -p codesigning | sed -nE 's/.*"(Developer ID Application: .*\('"$team_id"'\))".*/\1/p' | head -1)"
[[ -n "$identity" ]] || { printf 'No valid Developer ID Application certificate for team %s.\n' "$team_id" >&2; exit 1; }
mkdir -p build/dmg dist

if [[ -n "$provided_app" ]]; then
  app_path="$(cd "$(dirname "$provided_app")" && pwd)/$(basename "$provided_app")"
else
  swift -module-cache-path build/ModuleCache.noindex Scripts/RenderAppIcon.swift \
    "$project_root/Resources/MovemberMo.png" "$project_root/build/icon-artwork"
  iconutil -c icns build/icon-artwork/AppIcon.iconset -o Resources/AppIcon.icns
  if command -v xcodegen >/dev/null 2>&1; then xcodegen generate; fi
  archive_path="$project_root/build/dmg/MovemberCam.xcarchive"
  export_path="$project_root/build/dmg/export"
  export_options="$project_root/build/dmg/ExportOptions.plist"
  python3 - "$export_options" "$team_id" "$xcode_notarize" <<'PY'
import plistlib
import os
import sys
with open(sys.argv[1], "wb") as stream:
    options = {"method": "developer-id", "teamID": sys.argv[2],
                  "signingStyle": os.environ.get("MOVEMBER_SIGNING_STYLE", "automatic"), "signingCertificate": "Developer ID Application",
                  "destination": "upload" if sys.argv[3] == "1" else "export",
                  "manageAppVersionAndBuildNumber": False}
    if options["signingStyle"] == "manual":
        options["provisioningProfiles"] = {"com.grahamgilbert.MovemberCam": os.environ["MOVEMBER_APP_PROFILE"]}
    plistlib.dump(options, stream)
PY
  xcodebuild -quiet -project MovemberCam.xcodeproj -scheme MovemberCam -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath build/dmg-derived \
    -archivePath "$archive_path" -allowProvisioningUpdates archive
  for attempt in 1 2 3; do
    if xcodebuild -quiet -exportArchive -archivePath "$archive_path" -exportPath "$export_path" \
      -exportOptionsPlist "$export_options" -allowProvisioningUpdates; then
      break
    fi
    [[ "$attempt" -lt 3 ]] || exit 1
    printf 'Xcode export failed; retrying (%s/3).\n' "$attempt" >&2
    sleep 2
  done
  app_path="$export_path/MovemberCam.app"
  if [[ "$xcode_notarize" == 1 ]]; then
    app_path="$(python3 - "$archive_path" <<'PY'
import pathlib
import sys
apps = list(pathlib.Path(sys.argv[1]).glob("Submissions/*/MovemberCam.app"))
if not apps:
    sys.exit("Xcode did not save the submitted app.")
print(max(apps, key=lambda app: app.stat().st_mtime))
PY
)"
    # Stapling checks Apple's ticket service directly, without another developer account login.
    for attempt in {1..30}; do
      if xcrun stapler staple "$app_path"; then break; fi
      [[ "$attempt" -lt 30 ]] || { printf 'Notarization ticket is not available yet.\n' >&2; exit 1; }
      printf 'Waiting for Apple notarization (%s/30).\n' "$attempt"
      sleep 10
    done
    xcrun stapler validate "$app_path"
    spctl --assess --type execute --verbose=2 "$app_path"
  fi
fi

[[ -d "$app_path" ]] || { printf 'App not found: %s\n' "$app_path" >&2; exit 1; }
codesign --verify --deep --strict "$app_path"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_path/Contents/Info.plist")"
app_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_path/Contents/Info.plist")"
[[ -n "$output_path" ]] || output_path="$project_root/dist/MovemberCam-$version.dmg"
mkdir -p "$(dirname "$output_path")"
output_path="$(cd "$(dirname "$output_path")" && pwd)/$(basename "$output_path")"

if [[ ! -x build/dmg-tools/bin/python ]]; then python3 -m venv build/dmg-tools; fi
build/dmg-tools/bin/python -m pip --disable-pip-version-check --cache-dir build/pip-cache \
  install --quiet -r Scripts/dmg-requirements.txt
swift -module-cache-path build/ModuleCache.noindex Scripts/RenderDMGBackground.swift \
  "$project_root/Resources/MovemberMo.png" "$project_root/build/dmg/artwork"
build/dmg-tools/bin/dmgbuild -s Scripts/DMGSettings.py \
  -D "app=$app_path" -D "background=$project_root/build/dmg/artwork/background.png" \
  'MovemberCam' "$output_path"
for attempt in 1 2 3; do
  if codesign --force --sign "$identity" --identifier "$app_identifier.dmg" --timestamp "$output_path"; then
    break
  fi
  [[ "$attempt" -lt 3 ]] || exit 1
  printf 'DMG signing failed; retrying (%s/3).\n' "$attempt" >&2
  sleep 2
done
codesign --verify --strict "$output_path"
hdiutil verify "$output_path"

# Check the packaged payload too: Finder attributes can invalidate an otherwise valid app signature.
verify_mount="$(mktemp -d /private/tmp/MovemberCam-DMG-verify.XXXXXX)"
trap 'hdiutil detach "$verify_mount" >/dev/null 2>&1 || true; rmdir "$verify_mount" 2>/dev/null || true' EXIT
hdiutil attach -readonly -nobrowse -mountpoint "$verify_mount" "$output_path" >/dev/null
codesign --verify --deep --strict "$verify_mount/MovemberCam.app"
if [[ "$xcode_notarize" == 1 ]]; then xcrun stapler validate "$verify_mount/MovemberCam.app"; fi
[[ "$(readlink "$verify_mount/Applications")" == /Applications ]] || {
  printf 'The DMG Applications shortcut is invalid.\n' >&2; exit 1;
}
hdiutil detach "$verify_mount" >/dev/null
rmdir "$verify_mount"
trap - EXIT

if [[ -n "$notary_profile" ]]; then
  notary_args=(--keychain-profile "$notary_profile")
  if [[ -n "${MOVEMBER_NOTARY_KEYCHAIN:-}" ]]; then notary_args+=(--keychain "$MOVEMBER_NOTARY_KEYCHAIN"); fi
  submission_result="$project_root/build/dmg/notary-submission.json"
  for attempt in 1 2 3; do
    if xcrun notarytool submit "$output_path" "${notary_args[@]}" --wait --output-format json > "$submission_result"; then break; fi
    [[ "$attempt" -lt 3 ]] || exit 1
    printf 'Notary service request failed; retrying (%s/3).\n' "$attempt" >&2
    sleep 2
  done
  notary_status="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["status"])' "$submission_result")"
  if [[ "$notary_status" != Accepted ]]; then
    submission_id="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "$submission_result")"
    xcrun notarytool log "$submission_id" "${notary_args[@]}" > "$project_root/build/dmg/notary-log.json" || true
    printf 'Apple notarization status: %s. See build/dmg/notary-log.json.\n' "$notary_status" >&2
    exit 1
  fi
  for attempt in 1 2 3 4 5; do
    if xcrun stapler staple "$output_path"; then break; fi
    [[ "$attempt" -lt 5 ]] || exit 1
    sleep 3
  done
  xcrun stapler validate "$output_path"
fi
(cd "$(dirname "$output_path")" && shasum -a 256 "$(basename "$output_path")") > "$output_path.sha256"
printf '\nCreated: %s\nChecksum: %s.sha256\n' "$output_path" "$output_path"
if [[ "$xcode_notarize" == 1 ]]; then
  printf 'Signed DMG containing a notarized app with its stapled ticket.\n'
elif [[ -z "$notary_profile" ]]; then
  printf 'Signed; not notarized. To notarize, rerun with --notarize YOUR_KEYCHAIN_PROFILE.\n'
fi
