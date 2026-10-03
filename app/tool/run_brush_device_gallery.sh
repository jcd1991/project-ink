#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 DEVICE_UDID brush-file [brush-file ...]" >&2
  exit 64
fi

device_id=$1
shift
repo_root=$(cd "$(dirname "$0")/../.." && pwd)
app_dir="$repo_root/app"
profile_app="$app_dir/build/ios/iphoneos/Runner.app"
fixture_root="$app_dir/build/brush-device-gallery-fixtures"
run_id="run-$(date -u +%Y%m%dT%H%M%SZ)-$$"
local_run_dir="$fixture_root/$run_id"
local_fixture_dir="$local_run_dir/device-gallery"
remote_relative_dir="BrushQA/device-gallery"
ready_relative_dir="BrushQA/device-gallery-control"
output_dir="$app_dir/build/brush-device-gallery/$run_id"
drive_log="$output_dir/flutter-drive.log"
restore_app="$output_dir/restore/Runner.app"
drive_pid=""

if [[ ! -d "$profile_app" ]]; then
  echo "Build the iOS Profile app first; it is used to restore the app after the gallery run." >&2
  exit 69
fi

mkdir -p "$local_fixture_dir" "$output_dir"

# `flutter drive --profile` builds the integration-test entrypoint into the
# same Profile-iphoneos output directory used by a normal profile build. Keep
# an immutable copy of the user's launchable app before starting the test; the
# bundle at $profile_app may be replaced while flutter drive is running.
app_snapshot="$profile_app/Frameworks/App.framework/App"
if [[ ! -f "$app_snapshot" ]]; then
  echo "The normal Profile app is incomplete; build it before running the gallery." >&2
  exit 69
fi
if strings "$app_snapshot" | rg -q 'PROJECT_INK_BRUSH_GALLERY_WAIT|imports brushes and captures a touch-stroke gallery'; then
  echo "The Profile app already contains the gallery test runner. Rebuild the normal Profile app before running the gallery." >&2
  exit 69
fi
mkdir -p "$(dirname "$restore_app")"
ditto "$profile_app" "$restore_app"
for source in "$@"; do
  if [[ ! -f "$source" ]]; then
    echo "Brush fixture does not exist: $source" >&2
    exit 66
  fi
  extension=$(printf '%s' "${source##*.}" | tr '[:upper:]' '[:lower:]')
  case "$extension" in
    brush|sut) ;;
    *) echo "Expected a .brush or .sut file: $source" >&2; exit 65 ;;
  esac
  fixture_name=$(basename "$source")
  if [[ -e "$local_fixture_dir/$fixture_name" ]]; then
    echo "Fixture basenames must be unique: $fixture_name" >&2
    exit 65
  fi
  cp "$source" "$local_fixture_dir/"
done

restore_profile_app() {
  if [[ -d "$restore_app" ]]; then
    echo "Restoring the installed Profile app on $device_id"
    xcrun devicectl device install app \
      --device "$device_id" "$restore_app" >/dev/null
    if ! xcrun devicectl device process launch \
      --device "$device_id" org.projectink.studio >/dev/null; then
      echo "iPadOS requires the developer to be trusted in Settings before Project Ink can open." >&2
    fi
  fi
}
trap restore_profile_app EXIT

stop_drive() {
  [[ -n "$drive_pid" ]] || return 0
  if kill -0 "$drive_pid" 2>/dev/null; then
    kill -TERM "$drive_pid" 2>/dev/null || true
    for _ in $(seq 1 50); do
      if ! kill -0 "$drive_pid" 2>/dev/null; then break; fi
      sleep 0.1
    done
    if kill -0 "$drive_pid" 2>/dev/null; then
      kill -KILL "$drive_pid" 2>/dev/null || true
    fi
  fi
  wait "$drive_pid" 2>/dev/null || true
  drive_pid=""
}

handle_signal() {
  local exit_code=$1
  stop_drive
  exit "$exit_code"
}
trap 'handle_signal 130' INT
trap 'handle_signal 143' TERM

echo "Running the touch-stroke brush gallery on $device_id"
cd "$app_dir"
PROJECT_INK_BRUSH_GALLERY_OUTPUT="$output_dir" \
  flutter drive \
    --profile \
    --device-id "$device_id" \
    --driver test_driver/brush_device_gallery.dart \
    --target integration_test/brush_device_gallery_test.dart \
    --dart-define="INK_BRUSH_GALLERY_FIXTURE_DIR=$remote_relative_dir" \
    --dart-define="INK_BRUSH_GALLERY_FIXTURE_COUNT=$#" \
    >"$drive_log" 2>&1 &
drive_pid=$!

echo "Waiting for the integration app before transferring fixtures"
ready=0
for attempt in $(seq 1 240); do
  if xcrun devicectl device copy from \
    --device "$device_id" \
    --source "Documents/$ready_relative_dir/READY" \
    --destination "$output_dir/READY" \
    --domain-type appDataContainer \
    --domain-identifier org.projectink.studio \
    >/dev/null 2>&1; then
    ready=1
    break
  fi
  if ! kill -0 "$drive_pid" 2>/dev/null; then break; fi
  if rg -q "The Dart VM Service was not discovered" "$drive_log"; then
    echo "The iPad integration app did not expose its VM service; stopping the runner." >&2
    stop_drive
    break
  fi
  sleep 1
done

if [[ "$ready" != 1 ]]; then
  cat "$drive_log"
  stop_drive
  echo "The integration app did not create its fixture-ready marker." >&2
  exit 70
fi

echo "Copying brush fixtures into the running test app"
for source in "$@"; do
  fixture_name=$(basename "$source")
  if ! xcrun devicectl device copy to \
    --device "$device_id" \
    --source "$source" \
    --destination "Documents/$remote_relative_dir/$fixture_name" \
    --domain-type appDataContainer \
    --domain-identifier org.projectink.studio; then
    echo "CoreDevice reported a copy error for $fixture_name; verifying the file on the iPad."
    if ! xcrun devicectl device copy from \
      --device "$device_id" \
      --source "Documents/$remote_relative_dir/$fixture_name" \
      --destination "$output_dir/$fixture_name" \
      --domain-type appDataContainer \
      --domain-identifier org.projectink.studio \
      >/dev/null 2>&1 || ! cmp -s "$source" "$output_dir/$fixture_name"; then
      cat "$drive_log"
      echo "Fixture transfer could not be verified: $fixture_name" >&2
      exit 71
    fi
    echo "Verified $fixture_name on the iPad despite the copy command status."
  fi
done

printf 'complete' > "$output_dir/COMPLETE"
xcrun devicectl device copy to \
  --device "$device_id" \
  --source "$output_dir/COMPLETE" \
  --destination "Documents/$ready_relative_dir/COMPLETE" \
  --domain-type appDataContainer \
  --domain-identifier org.projectink.studio

echo "Waiting for the brush gallery and screenshot"
if wait "$drive_pid"; then
  cat "$drive_log"
else
  result=$?
  cat "$drive_log"
  exit "$result"
fi

echo "Gallery output: $output_dir/brush-device-gallery.png"
