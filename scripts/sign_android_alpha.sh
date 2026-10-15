#!/usr/bin/env bash
set -euo pipefail

fail() { printf 'Android alpha signing: %s\n' "$1" >&2; exit 1; }
[[ $# -eq 2 ]] || fail 'usage: scripts/sign_android_alpha.sh INPUT_APK OUTPUT_APK'
input="$1"
output="$2"
[[ -f "$input" ]] || fail 'input APK is missing'
[[ ! -e "$output" ]] || fail 'output already exists; choose a new filename'
[[ -n "${INK_ANDROID_KEYSTORE_PATH:-}" && -f "$INK_ANDROID_KEYSTORE_PATH" ]] \
  || fail 'set INK_ANDROID_KEYSTORE_PATH to a private keystore outside the repository'
root="$(git rev-parse --show-toplevel)"
keystore="$(cd "$(dirname "$INK_ANDROID_KEYSTORE_PATH")" && pwd -P)/$(basename "$INK_ANDROID_KEYSTORE_PATH")"
[[ "$keystore" != "$root"/* && ! -L "$INK_ANDROID_KEYSTORE_PATH" ]] \
  || fail 'keystore must be outside the repository and not a symlink'
[[ -n "${INK_ANDROID_KEY_ALIAS:-}" && -n "${INK_ANDROID_STORE_PASSWORD:-}" && -n "${INK_ANDROID_KEY_PASSWORD:-}" ]] \
  || fail 'set INK_ANDROID_KEY_ALIAS, INK_ANDROID_STORE_PASSWORD, and INK_ANDROID_KEY_PASSWORD'
[[ -n "${APKSIGNER:-}" && -x "$APKSIGNER" ]] || fail 'set APKSIGNER to the SDK apksigner executable'
[[ -n "${ZIPALIGN:-}" && -x "$ZIPALIGN" ]] || fail 'set ZIPALIGN to the SDK zipalign executable'
mkdir -p "$(dirname "$output")"
aligned="${output}.aligned.$$"
signed="${output}.signed.$$"
trap 'unlink "$aligned" 2>/dev/null || true; unlink "$signed" 2>/dev/null || true; unlink "${signed}.idsig" 2>/dev/null || true' EXIT
"$ZIPALIGN" -P 16 -f 4 "$input" "$aligned"
"$APKSIGNER" sign --ks "$INK_ANDROID_KEYSTORE_PATH" \
  --ks-key-alias "$INK_ANDROID_KEY_ALIAS" \
  --ks-pass env:INK_ANDROID_STORE_PASSWORD --key-pass env:INK_ANDROID_KEY_PASSWORD \
  --out "$signed" "$aligned"
"$APKSIGNER" verify --verbose --print-certs "$signed"
"$ZIPALIGN" -c -P 16 4 "$signed"
mv "$signed" "$output"
printf 'Signed APK: %s\n' "$output"
