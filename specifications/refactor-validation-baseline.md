# Refactor validation baseline

Captured before the Rust and Dart/Flutter refactor on 2026-10-01.

## Environment

- Host: Apple Silicon (`arm64`, `aarch64-apple-darwin`)
- Rust: 1.98.1
- Flutter: 3.47.5
- Dart: 3.13.4
- Refactor branch: `refactor/rust-flutter-boundaries`

## Checks

| Check | Baseline |
| --- | --- |
| `cargo fmt --all -- --check` | Passed |
| `cargo test --workspace --all-targets --all-features` | 1 failure: `recorded_stroke_has_cross_architecture_golden_tile_hash` produced `1395959408535220756`, expected `12475419944979558790`; other engine tests passed. This known mismatch is already documented in `specifications/phase3.85-be-illustration-comic-parity.md`; keep the golden unchanged until independently resolved. |
| `cargo clippy --workspace --all-targets --all-features -- -D warnings` | Blocked by `clippy::redundant_locals` at `ink-model/src/lib.rs:194` (`let kind = kind;`). |
| `flutter analyze` | Exited nonzero with two infos: string interpolation in `canvas_screen.dart:10568` and missing braces in `canvas_pointer_failure_test.dart:463`. |
| `flutter test` | 226 passed, 113 failed. Failures include many editor layout golden image diffs on this macOS host; diagnostics were written under ignored `app/test/failures/`. Do not regenerate goldens as part of a structural refactor. |

## Not measured

Release benchmark binaries were not built because the host had 2.7 GiB free while existing Rust and Flutter build caches occupied several GiB. Preserve those caches and user files; establish benchmark measurements when adequate space is available. No physical tablet acceptance was run during this baseline capture.
