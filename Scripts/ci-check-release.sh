#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
tag="${1:-}"
[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  printf 'Release tags must use vMAJOR.MINOR.PATCH.\n' >&2; exit 1;
}
version="$(awk '/MARKETING_VERSION:/ {gsub(/"/, "", $2); print $2; exit}' project.yml)"
[[ "$tag" == "v$version" ]] || {
  printf 'Tag %s does not match MARKETING_VERSION %s in project.yml.\n' "$tag" "$version" >&2; exit 1;
}
git rev-parse --verify "refs/tags/$tag" >/dev/null
[[ "$(git rev-parse HEAD)" == "$(git rev-parse "refs/tags/$tag^{commit}")" ]] || {
  printf 'The checked-out commit does not match the release tag.\n' >&2; exit 1;
}
