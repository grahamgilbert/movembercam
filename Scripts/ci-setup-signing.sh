#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "${GITHUB_ACTIONS:-}" == true && -n "${RUNNER_TEMP:-}" && -n "${GITHUB_ENV:-}" ]] || {
  printf 'This script is for an isolated GitHub Actions macOS runner.\n' >&2; exit 1;
}
required=(APPLE_TEAM_ID BUILD_CERTIFICATE_BASE64 P12_PASSWORD
  BUILD_PROVISION_PROFILE_BASE64 APPLE_ID APPLE_ID_PASSWORD)
for name in "${required[@]}"; do
  [[ -n "${!name:-}" ]] || { printf 'Missing release configuration: %s\nSee docs/RELEASING.md.\n' "$name" >&2; exit 1; }
done
[[ "$APPLE_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || { printf 'Invalid APPLE_TEAM_ID.\n' >&2; exit 1; }

umask 077
signing_dir="$RUNNER_TEMP/movember-signing"
mkdir -p "$signing_dir"
export MOVEMBER_SIGNING_DIRECTORY="$signing_dir"
python3 <<'PY'
import base64
import os
import pathlib
directory = pathlib.Path(os.environ["MOVEMBER_SIGNING_DIRECTORY"])
for variable, filename in [("BUILD_CERTIFICATE_BASE64", "certificate.p12"),
                           ("BUILD_PROVISION_PROFILE_BASE64", "app.provisionprofile")]:
    encoded = "".join(os.environ[variable].split())
    (directory / filename).write_bytes(base64.b64decode(encoded, validate=True))
PY
security cms -D -i "$signing_dir/app.provisionprofile" > "$signing_dir/profile.plist"
python3 - "$signing_dir/profile.plist" <<'PY'
import datetime
import os
import plistlib
import sys
import uuid
with open(sys.argv[1], "rb") as stream:
    profile = plistlib.load(stream)
team = os.environ["APPLE_TEAM_ID"]
entitlements = profile.get("Entitlements", {})
if profile.get("TeamIdentifier") != [team]:
    sys.exit("Provisioning profile does not belong to APPLE_TEAM_ID.")
if entitlements.get("com.apple.application-identifier") != team + ".com.grahamgilbert.MovemberCam":
    sys.exit("Provisioning profile is not for the MovemberCam app identifier.")
if not entitlements.get("com.apple.developer.system-extension.install"):
    sys.exit("Provisioning profile must include the System Extension capability.")
if entitlements.get("get-task-allow") or entitlements.get("com.apple.security.get-task-allow"):
    sys.exit("Use a Developer ID distribution profile, not a development profile.")
if profile["ExpirationDate"] <= datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None):
    sys.exit("Provisioning profile has expired.")
uuid.UUID(profile["UUID"])
print("Validated the MovemberCam Developer ID provisioning profile.")
PY

keychain_path="$signing_dir/signing.keychain-db"
keychain_password="$(openssl rand -base64 32)"
printf '::add-mask::%s\n' "$keychain_password"
security create-keychain -p "$keychain_password" "$keychain_path"
security set-keychain-settings -lut 21600 "$keychain_path"
security unlock-keychain -p "$keychain_password" "$keychain_path"
security import "$signing_dir/certificate.p12" -P "$P12_PASSWORD" \
  -t cert -f pkcs12 -k "$keychain_path" -T /usr/bin/codesign -T /usr/bin/security
security set-key-partition-list -S apple-tool:,apple:,codesign: -k "$keychain_password" "$keychain_path" >/dev/null
security list-keychains -d user -s "$keychain_path"

cat > Config/Signing.xcconfig <<EOF
DEVELOPMENT_TEAM = $APPLE_TEAM_ID
CODE_SIGN_STYLE = Manual
CODE_SIGN_IDENTITY = Developer ID Application
EOF
xcrun notarytool store-credentials movember-release --keychain "$keychain_path" \
  --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_ID_PASSWORD"
{
  printf 'MOVEMBER_TEAM_ID=%s\n' "$APPLE_TEAM_ID"
  printf 'MOVEMBER_PROFILE_PATH=%s/app.provisionprofile\n' "$signing_dir"
  printf 'MOVEMBER_NOTARY_PROFILE=movember-release\n'
  printf 'MOVEMBER_NOTARY_KEYCHAIN=%s\n' "$keychain_path"
} >> "$GITHUB_ENV"
