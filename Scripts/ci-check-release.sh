#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
version="$(awk '/MARKETING_VERSION:/ {gsub(/"/, "", $2); print $2; exit}' project.yml)"
tag="${1:-v$version}"
[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  printf 'Release tags must use vMAJOR.MINOR.PATCH.\n' >&2; exit 1;
}
[[ "$tag" == "v$version" ]] || {
  printf 'Tag %s does not match MARKETING_VERSION %s in project.yml.\n' "$tag" "$version" >&2; exit 1;
}
if git rev-parse --verify "refs/tags/$tag" >/dev/null 2>&1; then
  [[ "$(git rev-parse HEAD)" == "$(git rev-parse "refs/tags/$tag^{commit}")" ]] || {
    printf 'An existing release tag points at a different commit. Bump the version first.\n' >&2; exit 1;
  }
fi
printf '%s\n' "$tag"
