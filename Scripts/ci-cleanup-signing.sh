#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "${GITHUB_ACTIONS:-}" == true && -n "${RUNNER_TEMP:-}" ]] || exit 0
signing_dir="$RUNNER_TEMP/movember-signing"
security delete-keychain "$signing_dir/signing.keychain-db" 2>/dev/null || true
rm -f Config/Signing.xcconfig
rm -rf "$signing_dir"
