#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
expected_version='flutter_rust_bridge_codegen 2.13.0'

if ! command -v flutter_rust_bridge_codegen >/dev/null 2>&1; then
  echo "Install the pinned generator with: cargo install flutter_rust_bridge_codegen --version 2.13.0 --locked" >&2
  exit 1
fi

actual_version="$(flutter_rust_bridge_codegen --version)"
if [[ "$actual_version" != "$expected_version" ]]; then
  echo "Expected $expected_version, found $actual_version" >&2
  exit 1
fi

cd "$repo_root"
exec flutter_rust_bridge_codegen generate \
  --rust-input crate::api \
  --dart-output app/lib/bridge/generated \
  --c-output rust/crates/ink-bridge/src/frb_generated.h \
  --rust-root rust/crates/ink-bridge \
  --rust-output rust/crates/ink-bridge/src/frb_generated.rs \
  --dart-root app \
  --no-add-mod-to-lib
