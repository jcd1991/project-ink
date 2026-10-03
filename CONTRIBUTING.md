# Contributing to Project Ink

Thanks for considering a contribution. Project Ink is a local-first Rust and
Flutter drawing application. Rust owns document state, pixels, layers, history,
storage, and export; Flutter owns presentation, input arbitration, and visible
composition. Please keep changes within those boundaries.

## Before opening a pull request

1. Read `AGENTS.md` and the README for the affected package. Read the relevant
   `specifications/` document before changing a public API, file format, input
   protocol, or persistence behavior.
2. Keep the change focused and preserve existing work in the checkout. Do not
   use broad reset, clean, or revert commands to make a test run easier.
3. Add or update deterministic tests for changed behavior, including failure,
   cancellation, recovery, and persistence cases where they apply.
4. Report the exact checks run and distinguish automated tests, builds,
   simulator/emulator runs, hosted platforms, and physical-device results.
5. Update the closest specification or runbook when behavior or compatibility
   changes.

## Local checks

From the repository root:

```sh
cargo fmt --all -- --check
cargo test --workspace --all-targets --all-features
cargo clippy --workspace --all-targets --all-features -- -D warnings
```

From `app/`:

```sh
flutter analyze
flutter test
```

Use Flutter 3.47.5 and `flutter_rust_bridge` 2.13.0 as pinned by the project.
For generated bridge changes, edit the exported Rust API and run
`../scripts/generate_frb.sh` from `app/`; review the Rust and Dart generated
diffs together.

## Pull requests

- Explain the user-visible behavior and any format or platform implications.
- Include focused test evidence and screenshots for visible UI changes.
- Do not include artwork, local traces, build output, credentials, or unrelated
  generated files.
- Do not claim a platform or physical-device gate passed from a host test or
  successful compile alone.

The project currently has no published support policy or release branch. Check
the README and `specifications/release-readiness.md` for current status before
relying on a feature or platform as release-supported.

## Maintainer release preparation

There is not yet a signed package publisher. The tag workflow only validates
release metadata; it does not build or publish artifacts. Before preparing a
release, complete the platform acceptance gates and select each distribution
channel in `specifications/release-readiness.md`.

For a release commit:

1. Set `app/pubspec.yaml` to `MAJOR.MINOR.PATCH+BUILD` and add a matching
   `## [MAJOR.MINOR.PATCH]` heading to `CHANGELOG.md`.
2. Commit the release metadata, create the `vMAJOR.MINOR.PATCH` tag on that
   commit, then check out the tag in a clean worktree.
3. Run `scripts/release_preflight.sh vMAJOR.MINOR.PATCH`. The tag must resolve
   to `HEAD`, the app version and changelog heading must match, and the
   checkout must be clean. `.github/workflows/release-preflight.yml` runs this
   check for pushed `v*` tags.
4. After signed packages are built, place each package in one staging
   directory and generate the manifest by listing the package filenames:

   ```sh
   scripts/release_checksums.sh create dist/release \
     Project-Ink-macOS.dmg Project-Ink-iPadOS.ipa
   scripts/release_checksums.sh verify dist/release
   ```

The checksum command rejects missing, duplicate, nested, and symlinked inputs.
The manifest is useful only when distributed beside the exact packages it
checks. Do not describe the current metadata preflight as a signed release
workflow.
