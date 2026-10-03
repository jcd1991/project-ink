#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'release preflight: %s\n' "$1" >&2
  exit 1
}

if [[ $# -ne 1 ]]; then
  fail 'usage: scripts/release_preflight.sh vMAJOR.MINOR.PATCH'
fi

tag="$1"
if [[ ! "$tag" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
  fail "tag '$tag' must use vMAJOR.MINOR.PATCH"
fi
release_version="${tag#v}"

repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || fail 'run inside the Git repository'
cd "$repo_root"

tag_commit="$(git rev-parse --verify "refs/tags/$tag^{commit}" 2>/dev/null)" \
  || fail "tag '$tag' does not resolve to a commit"
head_commit="$(git rev-parse HEAD)"
[[ "$tag_commit" == "$head_commit" ]] \
  || fail "tag '$tag' does not point to checked-out HEAD"

app_version="$(sed -nE 's/^version:[[:space:]]*([0-9]+\.[0-9]+\.[0-9]+)\+[0-9]+[[:space:]]*$/\1/p' app/pubspec.yaml)"
[[ -n "$app_version" ]] \
  || fail 'app/pubspec.yaml must use version MAJOR.MINOR.PATCH+BUILD'
[[ "$app_version" == "$release_version" ]] \
  || fail "tag version $release_version does not match app version $app_version"

grep -Eq "^## \[$release_version\]([[:space:]]|$)" CHANGELOG.md \
  || fail "CHANGELOG.md must contain a ## [$release_version] release heading"

git diff --quiet && git diff --cached --quiet \
  || fail 'working tree has tracked changes'
[[ -z "$(git ls-files --others --exclude-standard)" ]] \
  || fail 'working tree has untracked files'

printf 'release preflight passed for %s at %s\n' "$tag" "$head_commit"
