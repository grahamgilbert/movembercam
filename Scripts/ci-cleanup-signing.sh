#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "${GITHUB_ACTIONS:-}" == true && -n "${RUNNER_TEMP:-}" ]] || exit 0
signing_dir="$RUNNER_TEMP/movember-signing"
security delete-keychain "$signing_dir/signing.keychain-db" 2>/dev/null || true
if [[ -f "$signing_dir/profile-uuid" ]]; then
  profile_uuid="$(cat "$signing_dir/profile-uuid")"
  if [[ "$profile_uuid" =~ ^[A-Fa-f0-9-]{36}$ ]]; then
    rm -f "$HOME/Library/MobileDevice/Provisioning Profiles/$profile_uuid.provisionprofile" \
      "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles/$profile_uuid.provisionprofile"
  fi
fi
rm -f Config/Signing.xcconfig
rm -rf "$signing_dir"
