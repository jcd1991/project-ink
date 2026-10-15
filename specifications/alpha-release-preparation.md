# Local alpha preparation

The owner requested local preparation only. The reviewed source snapshot is
organized into feature-sized commits on local branch
`codex/project-ink-feature-commits-2026-10-15`; this work does not create or
configure a remote, tag, or GitHub release. Keep binary candidates and private
test records under ignored `artifacts/alpha-0.1.0/`.

## Reproducible packages

Requirements: pinned Flutter 3.47.5, Rust/toolchains from the repository,
Xcode for macOS, Android SDK build tools, Bash, Git, `rg`, `ditto`, `codesign`,
`lipo` and `shasum`/`sha256sum`. Run from the repository root.

The current rebuilt packages are in `artifacts/alpha-0.1.0/review-candidate/`.
They include the layer and picker safety fixes. Current host regression and Mac
journey results are in the candidate verification document; remaining physical
and distribution checks still prevent treating them as cleared downloads.

Build macOS with `flutter build macos --release` from `app/`. Build Android with
`flutter build apk --release --target-platform android-arm64` from `app/`.
If the Android release build reports that `integration_test` is missing from
the release compile classpath, regenerate the release-mode registrant with
`flutter build apk --release --target-platform android-arm64 --config-only`.
Confirm the generated `GeneratedPluginRegistrant.java` excludes
`integration_test`, then run the full release build with `--no-pub` so the
release-mode registrant is retained. Verify the resulting APK contains no
`integration_test` package. Do not edit generated registrants. Preserve caches;
check free disk before rebuilding.

Android signing uses `scripts/sign_android_alpha.sh INPUT_APK OUTPUT_APK`.
Set `APKSIGNER` and `ZIPALIGN` to SDK executable paths and provide
`INK_ANDROID_KEYSTORE_PATH`, `INK_ANDROID_KEY_ALIAS`,
`INK_ANDROID_STORE_PASSWORD` and `INK_ANDROID_KEY_PASSWORD` through the
environment. Keep the keystore/password outside the repository, back them up
privately, and never put them in logs, release attachments or shell arguments.
The helper verifies the signature/alignment before promoting its output file.

```sh
scripts/package_alpha.sh 0.1.0 artifacts/alpha-0.1.0/new-candidate \
  --macos app/build/macos/Build/Products/Release/project_ink.app \
  --android /absolute/path/to/signed.apk
```

For Android also set `APKSIGNER` and `AAPT` executable paths. Either platform
can be omitted. The helper checks version/identity/signature, records source
commit and signing/architecture metadata, then creates and verifies SHA256SUMS.
It records checkout state and the tracked application/Rust patch SHA-256;
packaging a dirty checkout is not final release
provenance. If it fails, retain the partial directory for diagnosis and use a
new output directory for the next attempt. Only verified completed candidates
are eligible for review. Copies of private test records are never attachments.

## Before GitHub publication

1. Finish [candidate verification](alpha-candidate-verification.md). Remove
   any platform that cannot pass its installation and artist journey.
2. Review source/history/assets for secrets, private artwork and licensing.
   Keep commit groups focused: packaging helpers; release/feedback documents.
3. Once separately authorized, create/configure the exact GitHub repository and
   visibility. Verify the configured remote before any push.
4. Enable/test Issues and private vulnerability reporting; add real feedback
   links to release notes and SECURITY.md. Do not invent a contact address.
5. Commit the reviewed changes. Choose numeric tag `v0.1.0`, matching
   `app/pubspec.yaml` and CHANGELOG. Run `scripts/release_preflight.sh` using
   its documented arguments from a clean checkout with that tag at HEAD.
6. Rebuild/package from the tagged source, record toolchain and hashes, and
   repeat the final package smoke journey. Do not rename an old build's source
   commit to the new tag.
7. Prepare a **draft prerelease**, attach only cleared binaries, signing/build
   metadata, checksums and tester notes. Review it before publication.
8. Download published assets and verify checksums, installation/start and the
   source tag/license. Publication acceptance cannot be done locally.

Ad hoc macOS signing is not Developer ID distribution or notarization. Only an
Apple Development identity was available during this preparation; a public Mac
installation channel still needs a deliberate choice and verified procedure.
iOS has no distributable candidate here.

## Local source snapshot

The source, tests, specifications, and branding are organized into focused
local commits on `codex/project-ink-feature-commits-2026-10-15`. No remote is
configured and nothing has been pushed or tagged. Ignored build products,
signing keys, private artwork, and local validation records remain outside Git.

The candidate packages and device results above predate this source snapshot.
Before publication, choose a clean source tag, rebuild each offered platform,
record hashes, and repeat its installation and artist smoke journey. Do not
attribute the earlier package evidence to these commits.
