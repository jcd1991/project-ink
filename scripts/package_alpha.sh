#!/usr/bin/env bash
set -euo pipefail

fail() { printf 'alpha packaging: %s\n' "$1" >&2; exit 1; }
[[ $# -ge 4 ]] || fail 'usage: scripts/package_alpha.sh VERSION OUTPUT_DIR --macos APP [--android SIGNED_APK] (either platform may be supplied)'
version="$1"
destination="$2"
shift 2
[[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || fail 'use MAJOR.MINOR.PATCH'
root="$(git rev-parse --show-toplevel)"
cd "$root"
app_version="$(sed -nE 's/^version:[[:space:]]*([0-9]+\.[0-9]+\.[0-9]+)\+[0-9]+[[:space:]]*$/\1/p' app/pubspec.yaml)"
[[ "$app_version" == "$version" ]] || fail 'version differs from app/pubspec.yaml'
macos_app=''
android_apk=''
while [[ $# -gt 0 ]]; do
  [[ $# -ge 2 ]] || fail 'platform option needs a path'
  case "$1" in
    --macos) [[ -z "$macos_app" ]] || fail 'duplicate macOS option'; macos_app="$2" ;;
    --android) [[ -z "$android_apk" ]] || fail 'duplicate Android option'; android_apk="$2" ;;
    *) fail "unknown option: $1" ;;
  esac
  shift 2
done
[[ ! -e "$destination" ]] || fail 'destination already exists; use a new directory'
mkdir -p "$destination"
destination="$(cd "$destination" && pwd)"
declare -a artifacts=()
{
  printf 'Project Ink %s experimental alpha candidate\n' "$version"
  printf 'Source commit: %s\n' "$(git rev-parse HEAD)"
  printf 'Built/package record UTC: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'Tracked application/Rust patch SHA-256: %s\n' "$(git diff HEAD --binary -- app rust Cargo.toml Cargo.lock | shasum -a 256 | cut -d ' ' -f 1)"
  printf 'Source checkout state:\n'
  git status --short
  printf '\nThis records packaging, not interactive acceptance or a published release.\n'
} > "$destination/BUILD-INFO.txt"
if [[ -n "$macos_app" ]]; then
  [[ -d "$macos_app/Contents" ]] || fail 'macOS bundle is missing'
  plist="$macos_app/Contents/Info.plist"
  bundle_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")"
  [[ "$bundle_version" == "$version" ]] || fail 'macOS bundle version differs'
  executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist")"
  codesign --verify --deep --strict "$macos_app"
  architectures="$(lipo -archs "$macos_app/Contents/MacOS/$executable" | tr ' ' '-')"
  filename="project-ink-${version}-macos-${architectures}.zip"
  ditto -c -k --sequesterRsrc --keepParent "$macos_app" "$destination/$filename"
  artifacts+=("$filename")
  {
    printf '\nmacOS architectures: %s\n' "$architectures"
    codesign -dv --verbose=2 "$macos_app" 2>&1
    printf '\nNotarization: not established by this helper; record stapler/spctl evidence separately.\n'
  } >> "$destination/BUILD-INFO.txt"
fi
if [[ -n "$android_apk" ]]; then
  [[ -f "$android_apk" ]] || fail 'Android APK is missing'
  [[ -n "${APKSIGNER:-}" && -x "$APKSIGNER" ]] || fail 'set APKSIGNER to verify Android signing'
  [[ -n "${AAPT:-}" && -x "$AAPT" ]] || fail 'set AAPT to verify APK version and ABI'
  badging="$("$AAPT" dump badging "$android_apk")"
  package_id="$(printf '%s\n' "$badging" | sed -n "s/^package: name='\([^']*\)'.*/\1/p")"
  apk_version="$(printf '%s\n' "$badging" | sed -n "s/^package: .*versionName='\([^']*\)'.*/\1/p")"
  [[ "$package_id" == org.projectink.studio && "$apk_version" == "$version" ]] || fail 'APK identity/version differs'
  if printf '%s\n' "$badging" | rg -q '^application-debuggable'; then
    fail 'debuggable APKs are not release candidates'
  fi
  libraries="$(unzip -Z -1 "$android_apk" | sed -n '/^lib\/.*\.so$/p')"
  app_libraries="$(printf '%s\n' "$libraries" | sed -n '/\/libapp\.so$/p')"
  [[ "$app_libraries" == 'lib/arm64-v8a/libapp.so' ]] || fail 'this helper expects only an arm64 Flutter application'
  for library in libflutter.so libink_bridge.so; do
    printf '%s\n' "$libraries" | rg -Fqx "lib/arm64-v8a/$library" || fail "missing arm64 $library"
    other_targets="$(printf '%s\n' "$libraries" | rg "/$library$" | sed '/^lib\/arm64-v8a\//d')"
    [[ -z "$other_targets" ]] || fail "unexpected non-arm64 $library"
  done
  printf '\nAndroid native library inventory (extra plugin ABIs do not establish app support):\n%s\n' "$libraries" >> "$destination/BUILD-INFO.txt"
  "$APKSIGNER" verify --verbose --print-certs "$android_apk" > "$destination/ANDROID-SIGNING.txt"
  filename="project-ink-${version}-android-arm64.apk"
  cp "$android_apk" "$destination/$filename"
  artifacts+=("$filename" 'ANDROID-SIGNING.txt')
fi
artifacts+=('BUILD-INFO.txt')
scripts/release_checksums.sh create "$destination" "${artifacts[@]}"
scripts/release_checksums.sh verify "$destination"
printf 'Candidate packages: %s\n' "$destination"
