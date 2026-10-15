# Alpha candidate verification — 2026-10-08

Source: `1d09f7f` on `main` plus the staged preparation changes, app `0.1.0+1`,
Flutter 3.47.5. No commit, tag, remote or publication was created. Candidates
remain local; final physical/provider and distribution gates are still open.

## Current rebuilt candidate

Packages: ignored `artifacts/alpha-0.1.0/review-candidate/`. Signing metadata,
checkout state and the tracked application/Rust patch fingerprint are included.
This is review provenance, not a clean tagged release.

| Check | Current result |
|---|---|
| Rust | 340 tests passed across the workspace/all targets/all features. Format and Clippy with warnings denied passed. Existing dependency `block 0.1.6` emits a future-incompatibility notice. |
| Flutter | All 677 tests passed; analyze reports no issues. Includes New canvas releasing the previous provider destination, fresh Save As, rejected/canceled Open bookkeeping, explicit provider PNG path, nested-save rejection and layer layout regressions. |
| macOS | Release build passed. Built, tested and ZIP-extracted app match all 51 file hashes. A transparent 512×512 drawing with crossing mouse strokes plus a new horizontal mark was saved with Save As as `macos-bound-final.inkproj`, quit with process absence verified, reopened in a fresh process and exported. PNG RGBA bytes exactly match reconstructed saved BGRA tiles; alpha 0–255, 7,710 painted pixels. |
| Mac distribution | Ad hoc signature verifies, but `spctl --assess --type execute` rejects it. Simulated quarantine launch timed out and no app appeared in inventory; a user-approved exception workflow is not verified. Developer ID/notarization and Intel interaction remain open. |
| Android | Rebuilt release APK, dedicated-key signature and 16 KiB alignment verified. Updated S23 Ultra with `adb install -r` successfully, preserving app data. User saved `android-final.inkproj` into Download/ProjectInkAlphaValidation outside old packages. Private copy verifies 720×1544, transparent, revision 806, Active layer 1, 8,295 painted pixels. Force-stop/relaunch shows the distinctive strokes in recovery (process 7416 → 9443); explicit named reopen/export and pressure/workspace/provider error-path confirmations remain pending. Final bound-only export refinement is packaged and installed successfully as another data-preserving update; package flags are non-debuggable. Canvas screenshot region (0,159,720,1290) is pixel-identical before/after the final update and recovery. This does not substitute for explicit named reopen/export. |
| iOS | Provider changes pass Swift parsing and `flutter build ios --debug --no-codesign`. Compile-only; no signed install, physical test or distributable candidate. |
| Publication audit | Selected high-confidence secret-pattern scan covered 1,724 reachable history blobs with no matches or size skips. This does not establish absence of every secret/private asset. Rust metadata covered 244 packages; the sole missing license field has an Apache-2.0 LICENSE file. This is a scoped dependency review, not complete binary notice certification. |

Current package SHA-256:

- macOS ZIP: `62e8fd73edbf11210902e5de177e02da92c12d51a2bf5b107f3bebb8c3ac095a`
- Android APK: `1b29b50afc5b50993c26bd94c0d75fafea5a0f1d22e6d66ccf9ec805c61350f8`

An untouched blank startup canvas produced an unsaved-change prompt during
explicit Open. Discarding that disposable blank canvas allowed named reopen;
this is recorded as a remaining UX issue, not evidence of lost saved marks.

## Earlier candidate evidence (before the fixes)

| Check | Evidence and result |
|---|---|
| macOS release build | Passed; universal arm64/x86_64 app, 102.2 MB. `codesign --verify --deep --strict` passed; ad hoc, no TeamIdentifier, not notarized. |
| Mac install/start | ZIP extracted and launched on ARM macOS 27.0 (26A428). Local launch only; quarantine/Gatekeeper and Intel not tested. |
| Mac drawing/layers/history | Mouse drew Technical Pen and HB Sketch Pencil crossing strokes on two separate Active layers. Undo removed the second stroke; Redo restored it. |
| Mac named save/reopen | Saved transparent 512×512 `macos-final-smoke.inkproj`, revision 11, active layer 2. Separate extracted-package process reopened it; both marks visible. |
| Mac export/quit | Reopened project exported PNG, 512×512 RGBA, alpha range 0–255, 5,042 pixels with nonzero alpha. Native Quit ended the process; process absence checked. Full final smoke matrix remains incomplete. |
| Mac fresh quit/reopen | Relaunched after confirmed exit and explicitly reopened the same named project; both marks visible and project file hashes unchanged. Recovery prompt appeared before opening; this was a disposable saved test. Two test instances had shared recovery earlier, so isolated recovery behavior needs another pass. |
| Android release build | Passed after refreshing plugin metadata. Initial `--no-pub` build failed because generated registrant referenced development integration_test. No generated source was edited. |
| Android signing | arm64 APK signed with dedicated alpha RSA 3072 certificate; apksigner verification and 16 KiB zip alignment passed. Certificate SHA-256: `5a9f87d61e48bd92e5b3a61e3be69431f3f1856cfdc6236a4ea1256b14d8c661`. |
| Android installed test state | S23 Ultra SM-S918U1, Android 16/API 36. Existing debug install backed up privately before any replacement. Recovery manifest revision 368 with committed tiles; this is evidence of that checkpoint, not a root cause for the earlier loss report. |
| Android release install | Owner authorized replacing the testing install on October 8. Took a fresh private app-data backup, uninstalled the debug build, installed the dedicated-key APK successfully and launched it. Package flags confirm it is not debuggable. |
| Android final journey | Real S Pen long strokes, named save, user-confirmed named reopen, observed force-stop recovery and a decoded PNG export have evidence on the installed APK. Pressure feel and the combined workspace/History/Active-layer matrix remain unconfirmed. Installed APK predates the layout and save-location fixes; rebuilt-package retest required. |
| Android release recovery | User drew several distinctive long strokes in the installed release candidate. On October 8, captured the visible drawing, force-stopped process 18752, relaunched as process 21130 and captured the same marks. This observed unsaved recovery check passed; pressure feel, workspace/History checks and named-save/export acceptance remain unconfirmed. Private before/after screenshots and process logs are retained. |
| Android named save | Located `android-alpha-smoke.inkproj` in the Android picker’s remembered public-storage location. Pulled a private copy: format 6, 2048×2048, transparent background, revision 1051, Active layer 1, tiles and history present. The location was nested inside an older `.inkproj` package. Original files were preserved. User confirmed named reopen worked after restart. |
| Android reopen follow-up | A later landscape screenshot was blank, then new looping marks appeared. User clarified “yes its a new one”: the changed drawing was intentional. Do not classify this sequence as reproduced loss of the saved long strokes. The preserved saved package still contains painted tile data. User-confirmed reopen is distinct from the separate observed recovery comparison. |
| Android PNG | Exported `untitled.png` into the remembered folder inside the saved package. Pulled/decoded it: 2048×2048 RGBA, alpha 0–255, 10,462 pixels with nonzero alpha. Looping marks match the current phone screenshot; user confirmed this is a new drawing. Encoding/dimensions/transparency passed for the current drawing. This is not a pixel comparison of the original named-save test against its export. |
| iOS/iPadOS | Not installed/tested or packaged in this preparation. |

## Android missing-work gate

The October 7 sketch disappeared and History showed no edits; no named Save
was reported. October 8 Redo and recovery succeeded in later testing. Those
results do not explain or close the earlier report. No speculative code fix was
made. Android remains withheld until the final release candidate passes:

- Real S Pen long stroke, light/firm pressure and intended Active-layer drawing.
- Switching the earlier Simple/Studio/color/layers/History path preserves marks
  and shows committed edits.
- Named save, force-stop/relaunch, explicit named reopen, dimension-checked PNG.
- Unsaved disposable drawing survives a recovery checkpoint and force-stop.

If silent loss is reproduced, capture private evidence and fix the owning path
before distributing the APK. If not reproduced, record the exact scope and
leave the historical cause unproven; do not call it a diagnosed fix.

## Local evidence and remaining gates

Build logs, Android pre-install backup, Mac test project/PNG and signing records
are ignored under `artifacts/alpha-0.1.0/records/`. Public-safe candidate packages
and checksum/signing metadata are in `artifacts/alpha-0.1.0/verified-candidate/`.
The backup and artwork/logs must not be uploaded by default.

Open: remaining artist smoke actions and physical provider/safe-exit/corrupt-copy
matrix on the exact packages; downloaded Mac installation; Android lost-work
acceptance; complete asset/binary notice audit; chosen
tagged source and rebuilt provenance; GitHub feedback/private security setup;
published-download verification. Existing earlier integration/manual evidence
is described in [the checklist](alpha-release-checklist.md), not reclassified
as a final-package pass.

## Regression results and fix

- Flutter analyze passed on the original candidate source.
- Initial full Flutter suite: 616 passed, 47 failed. Narrow layer subtitle Rows
  overflowed and visual fixtures predated the Active label/status presentation.
- Replaced the layer subtitle Row with Wrap; Rust state, layer selection and
  save formats are unchanged. Layer/gesture focused suite: 36 passed; dedicated
  layer badge/gesture suite: 61 passed. Added a narrow Active/alpha-lock/clipping
  regression. Reviewed desktop and high-contrast 200% text images; refreshed
  intentional layer presentation snapshots. Visual suite: 120 passed.
- Full Flutter rerun after the badge fix: 663 passed, one stale New-document
  dialog assertion failed. Updated it to the existing New canvas/Create canvas
  UI labels; current analyzer passed. Final full rerun: **664 passed**, zero
  failures. The focused app lifecycle suite also passed all 16 tests.
- Initial Rust compilation was stopped when disk fell below 1 GB. The lean
  retry subsequently passed all 340 tests, format and Clippy; see current results.
- Shell syntax and diff checks passed. Actual signing/alignment and combined
  packaging/checksum verification passed; both helpers refused existing output
  paths. App bridge/Flutter/ink libraries are arm64 only; additional plugin ABI
  files are inventoried without claiming those platforms are supported.
- Mac installed bundle file hashes match the packaged build's file hashes.
  ZIP archive hashes differ between packaging runs; use the matching manifest.

Current package hashes (before the layout fix):

| Artifact | SHA-256 |
|---|---|
| macOS ZIP | `44088059b5541d2fe0ec19aafb22b4c096c538b061a0f06f0af05ac55cf5ed61` |
| Android APK | `d9e9fee6d4d3b351a4f411a39bfb14cbaf84c93254bffc6d57bd350d09f3ac35` |

Suggested commit groups: layer badge layout + regression + reviewed goldens;
packaging/signing helpers + generated Kotlin ignore; release documents +
changelog + README + issue templates. Nothing has been committed or pushed.

## Save-location correction discovered on device

The remembered native save folder was inside an older `.inkproj` directory.
This can put a new project at risk when its enclosing package is atomically
replaced or a backup rotates. Added a picker guard rejecting new local-save
folders inside `.inkproj` and `.inkproj.bak` ancestors, with an actionable
document-action error and no silent fallback. Existing project open and save
formats remain unchanged. Android/macOS picker regressions cover direct,
descendant, uppercase and backup selections. Include this source/test/README
change in its own save-safety commit. The installed APK also predates this fix.
Focused picker/document-action tests: 51 passed. Flutter analyzer passed after
the guard. Full Flutter suite rerun after this correction: **672 passed**, zero
failures (71 seconds). Rust tests/Clippy and rebuilt-package acceptance remain
open as recorded above.

## Provider binding correction

A widget reproduction demonstrated that Open provider → New canvas retained
the old save destination. The optional picker-session binding now changes only
after successful document transitions. Ordinary Save uses the bound path;
Save As chooses a new path and New canvas releases the previous provider.
Native Android/iOS source metadata is keyed by staged path so another rejected
Open cannot redirect current-project write-back. Provider PNG requests identify
the bound project; new/local canvases choose their own export destination.
Rust authority, project format and existing transactional write-back remain
unchanged. Mocked channel/widget tests and native builds passed; physical
provider cancellation/rejected-open/write-back acceptance is still required.

Suggested commit groups now include: layer layout/fixtures; document picker
safety and lifecycle regressions/specification; packaging/signing helpers;
release/feedback documentation. All changes are prepared locally for review.
