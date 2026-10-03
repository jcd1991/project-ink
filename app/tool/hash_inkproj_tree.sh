#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 || ! -d "$1" ]]; then
  printf 'Usage: %s PROJECT.inkproj-directory\n' "$0" >&2
  exit 2
fi

project_dir="$(cd "$1" && pwd)"
while IFS= read -r -d '' file; do
  digest="$(shasum -a 256 "$file" | awk '{ print $1 }')"
  printf '%s  %s\n' "$digest" "${file#"$project_dir"/}"
done < <(find "$project_dir" -type f -print0) | sort
