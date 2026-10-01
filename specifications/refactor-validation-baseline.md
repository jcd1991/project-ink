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

## Post-refactor validation status

Captured after the ownership and bridge changes on the same Apple Silicon host.

| Check | Result |
| --- | --- |
| `cargo fmt --all -- --check` | Passed after refactor. |
| `cargo clippy --workspace --all-targets --all-features -- -D warnings` | Passed. Bridge-wide `clippy::all` suppression is removed; remaining complexity allowances are local to command/transaction or long scenario tests. |
| `cargo test --workspace --all-targets --all-features --no-fail-fast` | One failure: the same engine golden hash mismatch (`1395959408535220756` vs `12475419944979558790`). All other workspace test targets passed, including 35 bridge tests and 15 comic tests. |
| `cargo clippy --workspace --all-targets --all-features -- -D warnings` | Passed. |
| `flutter analyze` | Passed with no issues after extracting bridge adapters and comic/canvas presentation widgets. |
| `flutter test` | 226 passed, 113 failed. Failures remain editor-layout goldens on this macOS host, matching the captured baseline. Pointer-failure, persistence, tile, and live-render tests passed. |
| FRB generated API | The 2.13.0-generated Rust and Dart bindings compile against the current Rust API. Regeneration corrected stale checked-in composite-tile bindings to the existing capture/compose API; all other existing exported API names/types remain unchanged. |

Release benchmarks were not rerun: less than 1 GiB remained free and the
Phase 1/Phase 2 release benchmark executables were not already built. Apple-host
Clippy compiles the platform-gated Metal path, but no physical tablet acceptance
was run because no tablet is attached to this task.
