#!/usr/bin/env bash
set -euo pipefail
fail() { printf 'iOS acceptance: %s\n' "$1" >&2; exit 2; }
repo_dir="$(cd "$(dirname "$0")/../.." && pwd)"
app_dir="$repo_dir/app"
results_root="$(printenv PROJECT_INK_IOS_ACCEPTANCE_RESULTS_DIR 2>/dev/null || true)"
[[ -n "$results_root" ]] || results_root="$app_dir/build/ios-acceptance"
mode=full
device_id=""
simulator_id=""
device_record=""
resume_dir=""
usage() {
  cat <<'EOF'
Usage: run_ios_acceptance.sh --preflight [UDID] | --simulator | --device UDID | --pencil UDID | --full UDID
       run_ios_acceptance.sh --resume RUN_DIRECTORY [--full|--device|--pencil] [UDID]
Optional: PROJECT_INK_IOS_ACCEPTANCE_RESULTS_DIR, PROJECT_INK_IOS_SIMULATOR_UDID, PROJECT_INK_IPAD_PROFILE=ipad-m1|ipad-m4
EOF
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --preflight) mode=preflight; shift; if [[ $# -gt 0 && "$1" != --* ]]; then device_id="$1"; shift; fi ;;
    --simulator) mode=simulator; shift ;;
    --device) mode=device; shift; [[ $# -gt 0 ]] || { usage >&2; exit 64; }; device_id="$1"; shift ;;
    --pencil) mode=pencil; shift; [[ $# -gt 0 ]] || { usage >&2; exit 64; }; device_id="$1"; shift ;;
    --full) mode=full; shift; [[ $# -gt 0 ]] || { usage >&2; exit 64; }; device_id="$1"; shift ;;
    --resume) [[ $# -ge 2 ]] || { usage >&2; exit 64; }; resume_dir="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 64 ;;
  esac
done
[[ "$(uname -s)" == Darwin ]] || fail 'must run on macOS'
command -v flutter >/dev/null || fail 'Flutter is unavailable'
command -v xcodebuild >/dev/null || fail 'Xcode is unavailable'
command -v xcrun >/dev/null || fail 'xcrun is unavailable'
[[ -d "$app_dir/ios/Runner.xcworkspace" ]] || fail 'run flutter pub get in app/'
[[ -f "$app_dir/.dart_tool/package_config.json" ]] || fail 'Flutter package configuration is missing; run flutter pub get in app/'
available_bytes() { df -Pk "$app_dir" | awk 'NR == 2 { print $4 * 1024 }'; }
available_gib() { awk -v bytes="$(available_bytes)" 'BEGIN { printf "%.1f", bytes / 1073741824 }'; }
required_gib=18
[[ "$mode" != full ]] || required_gib=28
if [[ "$mode" == preflight ]]; then
  printf 'Free disk: %s GiB (recommended before full run: %s GiB)\n' "$(available_gib)" "$required_gib"
else
  free_bytes="$(available_bytes)"
  min_bytes=$((required_gib * 1024 * 1024 * 1024))
  (( free_bytes >= min_bytes )) || fail "only $(available_gib) GiB free; need at least ${required_gib} GiB for this run; free space and retry"
fi
flutter_version="$(flutter --version | sed -n '1p')"
xcode_version="$(xcodebuild -version | tr '\n' ' ')"
[[ "$flutter_version" == Flutter\ 3.47.5* ]] || fail "expected Flutter 3.47.5; got $flutter_version"
revision="$(git -C "$repo_dir" rev-parse HEAD)"
diff_hash="$({
  git -C "$repo_dir" diff --binary HEAD
  while IFS= read -r -d '' extra_file; do
    printf '%s\0' "$extra_file"
    shasum -a 256 "$repo_dir/$extra_file"
  done < <(git -C "$repo_dir" ls-files --others --exclude-standard -z)
} | shasum -a 256 | awk '{print $1}')"
if [[ "$mode" == preflight ]]; then
  printf 'Flutter: %s\nXcode: %s\nRevision: %s\nTracked diff: %s\n' "$flutter_version" "$(xcodebuild -version | tr '\n' ' ')" "$revision" "$diff_hash"
  xcodebuild -list -project "$app_dir/ios/Runner.xcodeproj"
  if [[ -n "$device_id" ]]; then xcrun devicectl list devices | rg -F "$device_id"; fi
  exit 0
fi
if [[ "$mode" == device || "$mode" == pencil || "$mode" == full ]]; then
  [[ -n "$device_id" ]] || fail "--$mode requires a device UDID"
  xcrun devicectl list devices | rg -F "$device_id" >/dev/null || fail "device not found: $device_id"
fi
if [[ -n "$resume_dir" ]]; then
  run_dir="$(cd "$resume_dir" && pwd)"
  [[ -f "$run_dir/state.json" ]] || fail 'resume state is missing'
  rg -F "\"source_revision\": \"$revision\"" "$run_dir/state.json" >/dev/null || fail 'resume rejected: source changed'
  rg -F "\"diff_fingerprint\": \"$diff_hash\"" "$run_dir/state.json" >/dev/null || fail 'resume rejected: tracked diff changed'
  rg -F "\"flutter_version\": \"$flutter_version\"" "$run_dir/state.json" >/dev/null || fail 'resume rejected: Flutter changed'
  rg -F "\"xcode_version\": \"$xcode_version\"" "$run_dir/state.json" >/dev/null || fail 'resume rejected: Xcode changed'
  if [[ -n "$device_id" ]]; then rg -F "\"device_id\": \"$device_id\"" "$run_dir/state.json" >/dev/null || fail 'resume rejected: device changed'; fi
else
  run_dir="$results_root/runs/run-$(date -u +%Y%m%dT%H%M%SZ)-$$"
  mkdir -p "$run_dir"
fi
mkdir -p "$run_dir/.stages" "$run_dir/logs" "$results_root/.device-locks"
# Isolate Flutter's build-dir config to this run; never change the user's global settings.
export XDG_CONFIG_HOME="$run_dir/flutter-config"
mkdir -p "$XDG_CONFIG_HOME"
flutter config --no-enable-swift-package-manager >/dev/null
flutter config --build-dir build/ios-acceptance-output >/dev/null
export SYMROOT="$run_dir/xcode/symroot" OBJROOT="$run_dir/xcode/objroot"
mkdir -p "$SYMROOT" "$OBJROOT"
cd "$app_dir"
flutter pub get --offline
exec > >(tee -a "$run_dir/run.log") 2>&1
printf '%s\n' "$$" > "$run_dir/run.pid"
lock_dir=""
if [[ -n "$device_id" ]]; then
  lock_dir="$results_root/.device-locks/$device_id"
  if ! mkdir "$lock_dir" 2>/dev/null; then
    lock_pid="$(cat "$lock_dir/run.pid" 2>/dev/null || true)"
    if [[ "$lock_pid" =~ ^[0-9]+$ ]] && kill -0 "$lock_pid" 2>/dev/null; then fail "device locked by process $lock_pid"; fi
    rm -f "$lock_dir/run.pid"; rmdir "$lock_dir" 2>/dev/null || fail 'cannot clear stale lock'; mkdir "$lock_dir"
  fi
  printf '%s\n' "$$" > "$lock_dir/run.pid"
fi
write_state() {
  state_simulator_id="$(cat "$run_dir/metadata/simulator-id" 2>/dev/null || true)"
  state_device_record="$(cat "$run_dir/metadata/device-record" 2>/dev/null || true)"
  done_stages=""
  for stage_name in host simulator device pencil; do
    if [[ -f "$run_dir/.stages/$stage_name" ]]; then
      [[ -n "$done_stages" ]] && done_stages="$done_stages, "
      done_stages="$done_stages\"$stage_name\""
    fi
  done
  cat > "$run_dir/state.json.tmp" <<EOF
{"status":"$1","stage":"$2","source_revision":"$revision","diff_fingerprint":"$diff_hash","flutter_version":"$flutter_version","xcode_version":"$xcode_version","device_id":"$device_id","simulator_id":"$state_simulator_id","device_record":"$state_device_record","bundle_id":"org.projectink.studio.acceptance","completed_stages":[$done_stages]}
EOF
  mv "$run_dir/state.json.tmp" "$run_dir/state.json"
}
write_report() {
  state_simulator_id="$(cat "$run_dir/metadata/simulator-id" 2>/dev/null || true)"
  state_device_record="$(cat "$run_dir/metadata/device-record" 2>/dev/null || true)"
  if rg -q 'All tests passed\.' "$run_dir/logs/simulator.log" 2>/dev/null; then flutter_integration_result='passed; see simulator.log'; else flutter_integration_result='not run or failed; inspect stage log'; fi
  if rg -q 'All tests passed\.' "$run_dir/logs/device.log" 2>/dev/null; then flutter_device_result='passed; see device.log'; else flutter_device_result='not run or failed; inspect stage log'; fi
  if [[ -f "$run_dir/.stages/host" ]]; then host_result='passed; see host.log'; else host_result='not run'; fi
  if [[ -f "$run_dir/.stages/simulator" || -f "$run_dir/.stages/device" ]]; then native_result='passed; see xcresult bundles'; else native_result='blocked or not run; inspect xcresult bundles and stage log'; fi
  cat > "$run_dir/report.md" <<EOF
# Project Ink iOS acceptance run

- Status: $1
- Last stage: $2
- Revision: $revision
- Working tree fingerprint: $diff_hash
- Flutter: $flutter_version
- Xcode: $xcode_version
- Device: $device_id
- Simulator: $state_simulator_id
- Device details: $state_device_record
- Bundle: org.projectink.studio.acceptance

## Journey evidence

| Journey | Result |
|---|---|
| Rust and Flutter host suites | $host_result |
| iOS Flutter/Rust integration suites | $flutter_integration_result; $flutter_device_result |
| Native XCTest/XCUITest suite | $native_result |
| Canvas save/reopen and history in a fresh app process | not run; current disk-backed engine checks are separate from process-relaunch UI evidence |
| Layer, custom brush, comic, corrupt-open, and recovery-write bridge workflows | $flutter_integration_result |
| ProjectInkApp recovery and failed-provider UI journey | manual pending; desktop-target widget fixture is excluded on iOS |
| Adjustment workflows and provider write-back | not run |
| Native Files picker and fresh app relaunch | $native_result |
| Physical Pencil interaction and feel | manual pending |
| Physical latency and confirmed-sample delivery | $( [[ -f "$run_dir/trace-report.txt" ]] && printf 'see trace report' || printf 'manual pending' ) |
| Authoritative process RSS ceiling | $( [[ -f "$run_dir/memory-evidence.txt" ]] && printf 'see memory evidence; numeric ceiling still requires project decision' || printf 'manual pending' ) |

Logs, traces, screenshots, and Xcode result bundles in this run directory are local acceptance evidence.
EOF
}
active_stage=preflight
cleanup() {
  exit_status=$?
  trap - EXIT
  set +e
  if [[ "$exit_status" -eq 0 ]]; then write_state complete "$active_stage" && write_report complete "$active_stage"; else write_state failed "$active_stage" && write_report failed "$active_stage"; fi
  if [[ -n "$lock_dir" && -d "$lock_dir" ]]; then rm -f "$lock_dir/run.pid"; rmdir "$lock_dir" 2>/dev/null || true; fi
  if [[ -n "${build_lock_dir:-}" && -d "$build_lock_dir" ]]; then rm -f "$build_lock_dir/run.pid"; rmdir "$build_lock_dir" 2>/dev/null || true; fi
  (cd "$run_dir" && find . -type f ! -name artifacts.sha256 -print0 | sort -z | xargs -0 shasum -a 256) > "$run_dir/artifacts.sha256" 2>/dev/null || true
  exit "$exit_status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# Flutter's Xcode build products share the project Acceptance configuration;
# serialize all runner modes so concurrent runs cannot collide in Xcode.
build_lock_dir="$results_root/.build-lock"
if ! mkdir "$build_lock_dir" 2>/dev/null; then
  build_pid="$(cat "$build_lock_dir/run.pid" 2>/dev/null || true)"
  if [[ "$build_pid" =~ ^[0-9]+$ ]] && kill -0 "$build_pid" 2>/dev/null; then fail "acceptance build locked by process $build_pid"; fi
  rm -f "$build_lock_dir/run.pid"; rmdir "$build_lock_dir" 2>/dev/null || fail 'cannot clear stale build lock'; mkdir "$build_lock_dir"
fi
printf '%s\n' "$$" > "$build_lock_dir/run.pid"
run_stage() {
  active_stage="$1"; shift
  if [[ -f "$run_dir/.stages/$active_stage" ]]; then printf 'Skipping completed stage %s\n' "$active_stage"; return; fi
  write_state running "$active_stage"
  "$@" 2>&1 | tee "$run_dir/logs/$active_stage.log"
  touch "$run_dir/.stages/$active_stage"
  write_state running "$active_stage"
}
host_checks() { cd "$repo_dir"; cargo test --workspace --all-targets --all-features; cd "$app_dir"; flutter analyze; flutter test; }
get_simulator() {
  sim_override="$(printenv PROJECT_INK_IOS_SIMULATOR_UDID 2>/dev/null || true)"
  if [[ -n "$sim_override" ]]; then printf '%s' "$sim_override"; else
    xcrun simctl list devices available | awk '/iPad/ { if (match($0, /[0-9A-F-]{36}/)) { print substr($0, RSTART, RLENGTH); exit } }'
  fi
}
flutter_acceptance() {
  cd "$app_dir"
  for target in integration_test/release_document_round_trip_test.dart integration_test/live_cpu_handoff_test.dart; do
    flutter drive --driver test_driver/ios_acceptance.dart --target "$target" \
      --flavor Acceptance --device-id "$1" --dart-define=PROJECT_INK_TRACE=true --no-pub
  done
}
native_acceptance() {
  result="$run_dir/native-$2.xcresult"
  [[ ! -e "$result" ]] || result="$run_dir/native-$2-$(date -u +%H%M%S).xcresult"
  cd "$app_dir"
  xcodebuild test -workspace ios/Runner.xcworkspace -scheme Acceptance -destination "id=$1" \
    -derivedDataPath "$run_dir/xcode-derived-$2" -resultBundlePath "$result" \
    -only-testing:RunnerUITests CODE_SIGN_STYLE=Automatic BUILD_DIR="$app_dir/build/ios-acceptance-output/ios" \
    FLUTTER_TARGET=lib/main.dart
}
simulator_checks() {
  sim="$(get_simulator)"; [[ -n "$sim" ]] || fail 'no iPad simulator; set PROJECT_INK_IOS_SIMULATOR_UDID'
  simulator_id="$sim"
  mkdir -p "$run_dir/metadata"; printf '%s\n' "$sim" > "$run_dir/metadata/simulator-id"
  if ! xcrun simctl list devices booted | rg -F "$sim" >/dev/null; then xcrun simctl boot "$sim"; fi
  xcrun simctl bootstatus "$sim" -b
  flutter_acceptance "$sim"; native_acceptance "$sim" simulator
}
device_checks() {
  device_record="$(xcrun devicectl list devices | rg -F "$device_id" | head -1)"
  mkdir -p "$run_dir/metadata"
  printf '%s\n' "$device_record" > "$run_dir/metadata/device-record"
  flutter_acceptance "$device_id"
  native_acceptance "$device_id" device
}
get_profile() {
  profile_override="$(printenv PROJECT_INK_IPAD_PROFILE 2>/dev/null || true)"
  if [[ "$profile_override" == ipad-m1 || "$profile_override" == ipad-m4 ]]; then printf '%s' "$profile_override"; return; fi
  listing="$(xcrun devicectl list devices)"
  if printf '%s\n' "$listing" | rg -F "$device_id" | rg -q 'iPad13,4|iPad13,5|iPad Pro \(11-inch\) \(3rd generation\)|iPad Pro \(12\.9-inch\) \(5th generation\)'; then printf ipad-m1
  elif printf '%s\n' "$listing" | rg -F "$device_id" | rg -q 'iPad16,3|iPad16,4|iPad16,5|iPad16,6'; then printf ipad-m4
  else return 1; fi
}
pencil_guide() {
  profile="$(get_profile)" || fail 'set PROJECT_INK_IPAD_PROFILE to ipad-m1 or ipad-m4'
  app_bundle="$app_dir/build/ios-acceptance-output/ios/iphoneos/Runner.app"; trace_dir="$run_dir/device-traces"; mkdir -p "$trace_dir"
  cd "$app_dir"
  flutter build ios --profile --flavor Acceptance --dart-define=PROJECT_INK_TRACE=true
  xcrun devicectl device install app --device "$device_id" "$app_bundle"
  xcrun devicectl device process launch --terminate-existing --device "$device_id" org.projectink.studio.acceptance
  printf 'Use a new disposable canvas in Project Ink Acceptance. Enter p/f/s and an observation for each step.\n'
  printf 'profile=%s\ndevice=%s\n' "$profile" "$device_id" > "$run_dir/pencil-observations.txt"
  for step in 'Pressure range and initial contact' 'Tilt response' 'Slow/fast curves and long stroke beyond autosave debounce' \
    'Brush/color changes, undo/redo, save and fresh reopen' 'Palm contact and touch navigation' \
    'Interruption, cancellation and canvas edges' 'Live preview versus committed pixels' \
    'Pencil double tap and configured eraser action' 'Hover, squeeze, barrel rotation when supported' \
    '4096x4096 document with 20 layers memory evidence' 'One-hour drawing and memory session'; do
    printf '\n%s\n' "$step"; read -r -p 'Result [p/f/s]: ' result
    case "$result" in p|f|s) ;; *) fail 'enter p, f, or s';; esac
    read -r -p 'Observation: ' note
    printf '%s\t%s\t%s\n' "$result" "$step" "$note" >> "$run_dir/pencil-observations.txt"
  done
  xcrun devicectl device copy from --device "$device_id" --source Documents/phase1-traces \
    --destination "$trace_dir" --domain-type appDataContainer --domain-identifier org.projectink.studio.acceptance || true
  trace_file="$(find "$trace_dir" -type f -name '*.jsonl' -print -quit)"
  if [[ -n "$trace_file" ]]; then cd "$repo_dir"; dart tools/phase1_trace_report.dart "$trace_file" "$profile" | tee "$run_dir/trace-report.txt"
  else printf 'Trace missing; latency remains pending.\n' | tee "$run_dir/trace-report.txt"; fi
  read -r -p 'Authoritative Instruments/Xcode RSS evidence path (blank leaves pending): ' memory_path
  if [[ -n "$memory_path" && -f "$memory_path" ]]; then cp "$memory_path" "$run_dir/memory-evidence.txt"
  else printf 'status=pending\nreason=no RSS evidence attached\n' > "$run_dir/memory-evidence.txt"; fi
}
case "$mode" in
  simulator) run_stage simulator simulator_checks ;;
  device) run_stage device device_checks ;;
  pencil) run_stage pencil pencil_guide ;;
  full) run_stage host host_checks; run_stage simulator simulator_checks; run_stage device device_checks; run_stage pencil pencil_guide ;;
  *) usage >&2; exit 64 ;;
esac
