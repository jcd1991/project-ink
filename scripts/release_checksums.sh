#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'release checksums: %s\n' "$1" >&2
  exit 1
}

usage() {
  printf 'usage: scripts/release_checksums.sh create ARTIFACT_DIR FILE...\n'
  printf '       scripts/release_checksums.sh verify ARTIFACT_DIR\n'
}

if [[ $# -lt 2 ]]; then
  usage >&2
  exit 2
fi

mode="$1"
artifact_dir="$2"
shift 2
[[ -d "$artifact_dir" ]] || fail "artifact directory '$artifact_dir' does not exist"
artifact_dir="$(cd "$artifact_dir" && pwd)"

case "$mode" in
  create)
    [[ $# -gt 0 ]] || fail 'create requires at least one artifact filename'
    manifest="$artifact_dir/SHA256SUMS"
    temporary="$artifact_dir/.SHA256SUMS.tmp.$$"
    trap 'unlink "$temporary" 2>/dev/null || true' EXIT
    declare -a seen=()
    seen_count=0
    (
      cd "$artifact_dir"
      for artifact in "$@"; do
        [[ "$artifact" != */* && "$artifact" != '.' && "$artifact" != '..' ]] \
          || fail "use filenames within the artifact directory: '$artifact'"
        [[ "$artifact" != *$'\n'* ]] \
          || fail 'artifact filenames cannot contain newlines'
        [[ "$artifact" != 'SHA256SUMS' ]] \
          || fail 'SHA256SUMS cannot list itself as an artifact'
        for ((index = 0; index < seen_count; index++)); do
          previous="${seen[$index]}"
          [[ "$artifact" != "$previous" ]] \
            || fail "artifact '$artifact' was listed more than once"
        done
        seen[$seen_count]="$artifact"
        seen_count=$((seen_count + 1))
        [[ -f "$artifact" && ! -L "$artifact" ]] \
          || fail "artifact '$artifact' is missing or is not a regular file"
        if command -v shasum >/dev/null 2>&1; then
          shasum -a 256 -- "$artifact"
        elif command -v sha256sum >/dev/null 2>&1; then
          sha256sum -- "$artifact"
        else
          fail 'neither shasum nor sha256sum is available'
        fi
      done
    ) > "$temporary"
    mv -f "$temporary" "$manifest"
    trap - EXIT
    printf 'wrote %s\n' "$manifest"
    ;;
  verify)
    [[ $# -eq 0 ]] || fail 'verify accepts only the artifact directory'
    [[ -f "$artifact_dir/SHA256SUMS" ]] || fail 'SHA256SUMS is missing'
    (
      cd "$artifact_dir"
      if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 -c SHA256SUMS
      elif command -v sha256sum >/dev/null 2>&1; then
        sha256sum -c SHA256SUMS
      else
        fail 'neither shasum nor sha256sum is available'
      fi
    )
    ;;
  *)
    usage >&2
    fail "unknown mode '$mode'"
    ;;
esac
