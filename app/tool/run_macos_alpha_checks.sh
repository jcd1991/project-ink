#!/usr/bin/env bash
set -uo pipefail

fail() {
  printf 'macOS alpha checks: %s\n' "$1" >&2
  exit 2
}

usage() {
  cat <<'EOF'
Usage: run_macos_alpha_checks.sh [--unit-only | --full | --native-live-texture | --preflight-only]

  --unit-only      Run Flutter analysis and the complete unit/widget suite.
  --full           Also build and run Rust-backed document workflow suites.
  --native-live-texture Run the foreground macOS Rust/Metal/Flutter texture smoke test.
  --preflight-only Report toolchain, disk, and app-process state without tests.

The default is --full. Full mode requires at least 6 GiB free and refuses to
rebuild while any Project Ink macOS process is running. It never deletes build
outputs, caches, or app data. See specifications/macos-alpha-acceptance.md for
the separate interactive AppKit close/quit procedure.
EOF
}

[[ "$(uname -s)" == Darwin ]] || fail 'must run on macOS'
command -v flutter >/dev/null 2>&1 || fail 'Flutter is not on PATH'

mode=full
case "${1:-}" in
  '') ;;
  --unit-only) mode=unit ;;
  --full) mode=full ;;
  --native-live-texture) mode=native ;;
  --preflight-only) mode=preflight ;;
  --help|-h) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac
[[ $# -le 1 ]] || { usage >&2; exit 2; }

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
app_dir="$(cd "$script_dir/.." && pwd)"
repo_dir="$(cd "$app_dir/.." && pwd)"
results_dir="${PROJECT_INK_MACOS_ALPHA_RESULTS_DIR:-$app_dir/build/macos-alpha-checks}"
flutter_version="$(flutter --version 2>/dev/null | sed -n '1p')"
[[ "$flutter_version" == Flutter\ 3.47.5* ]] || \
  fail "expected pinned Flutter 3.47.5; found: $flutter_version"

free_mib="$(df -Pm "$repo_dir" | awk 'NR == 2 { print $4 }')"
[[ "$free_mib" =~ ^[0-9]+$ ]] || fail 'could not read available disk space'
printf 'Flutter: %s\nAvailable disk: %s MiB\n' "$flutter_version" "$free_mib"

running_apps="$(pgrep -x project_ink 2>/dev/null || true)"
if [[ -n "$running_apps" ]]; then
  printf 'Running Project Ink process IDs: %s\n' "$(tr '\n' ' ' <<<"$running_apps")"
else
  printf 'Running Project Ink process IDs: none\n'
fi

if [[ "$mode" == preflight ]]; then
  printf 'Results directory: %s\n' "$results_dir"
  exit 0
fi

if [[ "$mode" == full || "$mode" == native ]]; then
  min_free_mib="${PROJECT_INK_MACOS_BUILD_MIN_FREE_MIB:-6144}"
  [[ "$min_free_mib" =~ ^[0-9]+$ ]] || fail 'minimum free-space setting must be an integer MiB value'
  (( free_mib >= min_free_mib )) || \
    fail "${mode} mode needs ${min_free_mib} MiB free for macOS rebuilds; found ${free_mib} MiB. No build or test was started."
  [[ -z "$running_apps" ]] || \
    fail "${mode} mode stops because the existing app may hold files in the build bundle. Close the app safely, then rerun."
fi

mkdir -p "$results_dir"
cd "$app_dir"
summary="$results_dir/summary.txt"
: > "$summary"
failed=0

run_check() {
  local name="$1"
  shift
  local log="$results_dir/$name.log"
  printf '\n== %s ==\n' "$name"
  printf 'command:' > "$log"
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
  if [[ "$name" == macos_* ]] && pgrep -x project_ink >/dev/null 2>&1; then
    fail "$name left Project Ink running; refusing to rebuild its app bundle"
  fi
}

if [[ "$mode" != native ]]; then
  run_check flutter_analyze flutter analyze
  run_check flutter_unit_and_widget_tests flutter test
fi

if [[ "$mode" == full ]]; then
  # Keep test recovery data in a unique child of the sandboxed app container.
  # Tests own this new directory; nothing in the runner removes existing app data.
  default_container="${HOME}/Library/Containers/org.projectink.studio/Data/Documents/ProjectInkAlphaValidation"
  validation_docs="${PROJECT_INK_MACOS_ALPHA_DOCUMENTS_DIR:-$default_container/$(date +%Y%m%d-%H%M%S)-$$}"
  case "$validation_docs" in
    "$default_container"/*) ;;
    *) fail 'validation documents path must be under the app container Documents/ProjectInkAlphaValidation directory' ;;
  esac
  mkdir -p "$validation_docs"
  printf 'Isolated test documents: %s\n' "$validation_docs" | tee -a "$summary"

  run_check macos_layer_round_trip \
    flutter test integration_test/release_document_round_trip_test.dart \
    --plain-name 'Rust bridge persists a representative layer workflow on disk' \
    -d macos --dart-define="PROJECT_INK_TEST_DOCUMENTS_PATH=$validation_docs"
  run_check macos_brush_edit_import_round_trip \
    flutter test integration_test/release_document_round_trip_test.dart \
    --plain-name 'Rust bridge persists edited and re-imported custom brush settings' \
    -d macos --dart-define="PROJECT_INK_TEST_DOCUMENTS_PATH=$validation_docs"
  run_check macos_failed_brush_import_preserves_source \
    flutter test integration_test/release_document_round_trip_test.dart \
    --plain-name 'failed disk-backed brush import preserves source and document' \
    -d macos --dart-define="PROJECT_INK_TEST_DOCUMENTS_PATH=$validation_docs"
  run_check macos_comic_round_trip_and_export \
    flutter test integration_test/release_document_round_trip_test.dart \
    --plain-name 'Rust comic workflow saves, reopens, and exports multiple pages' \
    -d macos --dart-define="PROJECT_INK_TEST_DOCUMENTS_PATH=$validation_docs"
  run_check macos_draw_save_reopen_undo_redo \
    flutter test integration_test/release_document_round_trip_test.dart \
    --plain-name 'Rust bridge round-trip preserves pixels and recovery on corrupt Open' \
    -d macos --dart-define="PROJECT_INK_TEST_DOCUMENTS_PATH=$validation_docs"
  run_check macos_failed_save_and_corrupt_open \
    flutter test integration_test/release_document_round_trip_test.dart \
    --plain-name 'ProjectInkApp keeps Rust recovery and active engine after corrupt Open' \
    -d macos --dart-define="PROJECT_INK_TEST_DOCUMENTS_PATH=$validation_docs"
  run_check macos_failed_recovery_write_preserves_dirty_engine \
    flutter test integration_test/release_document_round_trip_test.dart \
    --plain-name 'failed disk-backed recovery write keeps dirty Rust document' \
    -d macos --dart-define="PROJECT_INK_TEST_DOCUMENTS_PATH=$validation_docs"

fi

if [[ "$mode" == native ]]; then
  run_check macos_native_live_texture \
    perl -e 'alarm 90; exec @ARGV' \
    flutter test integration_test/desktop_live_texture_smoke_test.dart \
    -d macos --timeout 60s
fi

if [[ "$mode" == full || "$mode" == native ]]; then
  cat <<'EOF'

Automated suites do not drive AppKit's red close button or Cmd-Q. Complete
specifications/macos-alpha-acceptance.md in a disposable app session and save
the outcome record before claiming native close/quit acceptance.
EOF
fi

if [[ "$failed" -ne 0 ]]; then
  printf '\nOne or more checks failed. Logs: %s\n' "$results_dir" >&2
  exit 1
fi

printf '\nAll selected macOS alpha checks passed. Logs: %s\n' "$results_dir"
