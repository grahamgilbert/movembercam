#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "${GITHUB_ACTIONS:-}" == true && -n "${RUNNER_TEMP:-}" ]] || {
  printf 'Publish updates through GitHub Actions.\n' >&2; exit 1;
}
: "${SPARKLE_PRIVATE_KEY:?Configure the Sparkle signing key}"
mode="${1:-release}"
channel="${RELEASE_CHANNEL:-prerelease}"
[[ "$mode" == release || "$mode" == promote ]] || exit 1
[[ "$channel" == stable || "$channel" == prerelease ]] || exit 1
sign_update="$(find build -type f -path '*/bin/sign_update' ! -path '*old_dsa*' | head -1)"
[[ -x "$sign_update" ]] || { printf 'Sparkle sign_update is missing.\n' >&2; exit 1; }
mkdir -p "$RUNNER_TEMP/movember-signing"
umask 077
key_file="$RUNNER_TEMP/movember-signing/sparkle.key"
printf '%s' "$SPARKLE_PRIVATE_KEY" > "$key_file"
feed_tree="$(mktemp -d "$RUNNER_TEMP/movember-feed.XXXXXX")"
trap 'git worktree remove --force "$feed_tree" >/dev/null 2>&1 || true; rm -f "$key_file"' EXIT
git fetch origin main
git worktree add --detach "$feed_tree" origin/main

if [[ "$mode" == release ]]; then
  tag="${RELEASE_TAG:?Read the release version first}"
  version="${tag#v}"
  archive="$PWD/dist/MovemberCam-$version.dmg"
  build_number="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' build/release/MovemberCam.app/Contents/Info.plist)"
  if gh release view "$tag" --json url >/dev/null 2>&1; then
    existing_commit="$(gh api "repos/$GH_REPO/commits/$tag" --jq .sha)"
    [[ "$existing_commit" == "$GITHUB_SHA" ]] || { printf 'This version was released from another commit. Bump the version.\n' >&2; exit 1; }
    # A retry signs the already-published archive instead of replacing it.
    published="$RUNNER_TEMP/movember-published"
    mkdir -p "$published"
    gh release download "$tag" --pattern "MovemberCam-$version.dmg*" --dir "$published" --clobber
    (cd "$published" && shasum -a 256 -c "MovemberCam-$version.dmg.sha256")
    archive="$published/MovemberCam-$version.dmg"
  else
    release_args=(--target "$GITHUB_SHA" --title "MovemberCam $version" --generate-notes)
    if [[ "$channel" == prerelease ]]; then release_args+=(--prerelease); fi
    gh release create "$tag" "$archive" "$archive.sha256" "${release_args[@]}"
  fi
  signature="$("$sign_update" --ed-key-file "$key_file" "$archive")"
  notes="release-notes-$version.html"
  gh release view "$tag" --json body --jq .body > build/update-notes.md
  python3 Scripts/appcast.py notes --input build/update-notes.md --output "build/$notes" --version "$version"
  notes_signature="$("$sign_update" --ed-key-file "$key_file" --disable-signing-warning -p "build/$notes")"
  notes_length="$(wc -c < "build/$notes" | tr -d '[:space:]')"
  gh release upload "$tag" "build/$notes" --clobber
  feed_args=(--version "$version" --build "$build_number"
    --url "https://github.com/$GH_REPO/releases/download/$tag/MovemberCam-$version.dmg"
    --signature "$signature" --notes-url "https://github.com/$GH_REPO/releases/download/$tag/$notes"
    --notes-signature "$notes_signature" --notes-length "$notes_length")
  python3 Scripts/appcast.py add --feed "$feed_tree/appcast-prerelease.xml" "${feed_args[@]}"
  if [[ "$channel" == stable ]]; then
    python3 Scripts/appcast.py add --feed "$feed_tree/appcast.xml" "${feed_args[@]}"
  fi
else
  version="${2:?Provide the version to promote}"
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || exit 1
  gh release view "v$version" --json url >/dev/null
  python3 Scripts/appcast.py promote --source "$feed_tree/appcast-prerelease.xml" \
    --destination "$feed_tree/appcast.xml" --version "$version"
fi

for feed in appcast.xml appcast-prerelease.xml; do
  "$sign_update" --ed-key-file "$key_file" --disable-signing-warning "$feed_tree/$feed"
  "$sign_update" --verify --ed-key-file "$key_file" "$feed_tree/$feed"
done
git -C "$feed_tree" add appcast.xml appcast-prerelease.xml
if ! git -C "$feed_tree" diff --cached --quiet; then
  git -C "$feed_tree" -c user.name='github-actions[bot]' \
    -c user.email='41898282+github-actions[bot]@users.noreply.github.com' \
    commit -m "Publish signed Sparkle feeds for v$version"
  git -C "$feed_tree" -c credential.helper= -c 'credential.helper=!gh auth git-credential' push origin HEAD:main
fi
if [[ "$mode" == promote ]]; then gh release edit "v$version" --prerelease=false; fi
