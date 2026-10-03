#!/usr/bin/env bash
set -uo pipefail

fail() {
  printf 'macOS alpha checks: %s\n' "$1" >&2
  exit 2
}

[[ "$(uname -s)" == Darwin ]] || fail 'must run on macOS'
command -v flutter >/dev/null 2>&1 || fail 'Flutter is not on PATH'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
app_dir="$(cd "$script_dir/.." && pwd)"
results_dir="${PROJECT_INK_MACOS_ALPHA_RESULTS_DIR:-$app_dir/build/macos-alpha-checks}"
mkdir -p "$results_dir"
cd "$app_dir"

flutter_version="$(flutter --version 2>/dev/null | sed -n '1p')"
if [[ "$flutter_version" != Flutter\ 3.47.5* ]]; then
  fail "expected pinned Flutter 3.47.5; found: $flutter_version"
fi

summary="$results_dir/summary.txt"
: > "$summary"
failed=0

run_check() {
  local name="$1"
  shift
  local log="$results_dir/$name.log"
  printf '\n== %s ==\n' "$name"
  printf 'command:' >> "$log"
  printf ' %q' "$@" >> "$log"
  printf '\n' >> "$log"
  "$@" 2>&1 | tee -a "$log"
  local status=${PIPESTATUS[0]}
  if [[ "$status" -eq 0 ]]; then
    printf 'PASS %s\n' "$name" | tee -a "$summary"
  else
    printf 'FAIL %s (exit %s)\n' "$name" "$status" | tee -a "$summary"
    failed=1
  fi
}

run_check flutter_analyze flutter analyze
run_check flutter_tests flutter test
run_check macos_rust_backed_document_journeys \
  flutter test integration_test/release_document_round_trip_test.dart -d macos
run_check macos_native_live_texture \
  flutter test integration_test/desktop_live_texture_smoke_test.dart -d macos

cat <<'EOF'

Automated macOS checks do not prove the actual AppKit red-button or Cmd-Q
interaction with a dirty named project. Complete those manual checks in a
separate disposable app profile and record Save, Discard, and Cancel outcomes
before claiming native close/quit acceptance.
EOF

if [[ "$failed" -ne 0 ]]; then
  printf '\nOne or more checks failed. Logs: %s\n' "$results_dir" >&2
  exit 1
fi

printf '\nAll automated macOS alpha checks passed. Logs: %s\n' "$results_dir"
