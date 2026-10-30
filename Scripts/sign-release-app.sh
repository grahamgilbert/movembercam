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
python3 - "$app_path" "$team_id" <<'PY'
import datetime
import hashlib
import pathlib
import plistlib
import re
import subprocess
import sys
app, team = pathlib.Path(sys.argv[1]), sys.argv[2]
output = pathlib.Path("build/release-entitlements")
with (output / "profile.plist").open("rb") as stream:
    profile = plistlib.load(stream)
with (app / "Contents/Info.plist").open("rb") as stream:
    bundle = plistlib.load(stream)["CFBundleIdentifier"]
entitlements = profile.get("Entitlements", {})
if profile.get("TeamIdentifier") != [team] or entitlements.get("com.apple.application-identifier") != team + "." + bundle:
    sys.exit("Provisioning profile does not match the app and developer team.")
if not entitlements.get("com.apple.developer.system-extension.install"):
    sys.exit("Provisioning profile must allow system extension installation.")
if entitlements.get("get-task-allow") or entitlements.get("com.apple.security.get-task-allow"):
    sys.exit("Use a Developer ID distribution profile, not a development profile.")
if profile["ExpirationDate"] <= datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None):
    sys.exit("Provisioning profile has expired.")
allowed = {hashlib.sha1(certificate).hexdigest().upper() for certificate in profile["DeveloperCertificates"]}
identities = subprocess.check_output(["security", "find-identity", "-v", "-p", "codesigning"], text=True)
identity = next((fingerprint for fingerprint, name in re.findall(r'\d+\) ([A-F0-9]{40}) "([^"]+)"', identities)
                 if fingerprint in allowed and name.startswith("Developer ID Application:") and name.endswith("(" + team + ")")), None)
if not identity:
    sys.exit("Import the Developer ID Application certificate and private key selected in this profile.")
(output / "identity").write_text(identity)
with open("Config/App.entitlements", "rb") as stream:
    host = plistlib.load(stream)
host["com.apple.application-identifier"] = team + "." + bundle
host["com.apple.developer.team-identifier"] = team
with (output / "App.entitlements").open("wb") as stream:
    plistlib.dump(host, stream)
extension = pathlib.Path("Config/Extension.entitlements").read_text().replace("$(TeamIdentifierPrefix)", team + ".")
(output / "Extension.entitlements").write_text(extension)
PY
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
