# macOS alpha acceptance

This procedure records the full acceptance evidence for native document safety.
It is for a disposable debug run only. Do not point it at a personal project
or delete the test profile after the run; retain its result record until the
alpha decision is made.

The `Acceptance` Xcode scheme drives the actual macOS app and covers all six
red-close/Cmd-Q Save, Discard, and Cancel choices. `run_macos_alpha_checks.sh
--full` runs that suite after the Rust-backed document workflows. Use
`--workflows-only` to repeat Flutter analysis/tests, disk-backed document
journeys, and the macOS app build when Xcode UI automation is unavailable; this
mode does not claim native close/quit acceptance. Use `--appkit-only` to rerun
the real-app close/quit matrix after changing the UI tests or granting Xcode UI
automation, without rerunning the Rust-backed workflows. It still needs 6 GiB
free for Xcode build products and refuses to run while Project Ink is open.
Use `--appkit-test <test-name>` to run one of the six named
`NativeDocumentSafetyTests` cases while diagnosing a focused failure; the
runner validates the test name and retains a separate `.xcresult` bundle.
For example: `app/tool/run_macos_alpha_checks.sh --appkit-test
testRedCloseCancelKeepsDirtyNamedProjectOpen`.
`--unit-only` runs analysis and Flutter unit/widget tests without the build
space threshold. The UI tests
launch with a unique documents path inside the app sandbox and compare the
named project's package files before and after the exit choice. Xcode must be
allowed to use macOS UI automation; if the test runner cannot enable
automation, record the Xcode result bundle and complete the manual matrix below
instead. A compiled test bundle or a runner timeout is not a pass.

The manual matrix remains useful for visual confirmation and for checking
behaviors outside the six automated cases, including failed saves and picker
cancellation.

## Before launch

1. Run `app/tool/run_macos_alpha_checks.sh --preflight-only` from the repository
   root. Full mode requires at least 6 GiB free and refuses to rebuild while a
   `project_ink` process is running. Do not close an existing app that has a
   document or recovery state you need.
2. Create a unique validation directory inside the app sandbox container:

   ```sh
   run_id="$(date +%Y%m%d-%H%M%S)-$$"
   validation_root="$HOME/Library/Containers/org.projectink.studio/Data/Documents/ProjectInkAlphaValidation/$run_id"
   mkdir -p "$validation_root/documents" "$validation_root/projects" "$validation_root/records"
   ```

3. From `app/`, launch a debug build with the isolated recovery directory:

   ```sh
   flutter run -d macos \
     --dart-define="PROJECT_INK_TEST_DOCUMENTS_PATH=$validation_root/documents"
   ```

   If Flutter reports a disk-space error, stop. Do not remove build caches or
   artifacts to make the run fit. Use another machine or free space through the
   owner's normal process, then rerun the preflight.

4. Create a canvas, draw a recognizable mark, and use **Save project as** to
   save `baseline.inkproj` under `$validation_root/projects`. Wait for the save
   to finish. Record its exact contents:

   ```sh
   app/tool/hash_inkproj_tree.sh "$validation_root/projects/baseline.inkproj" \
     > "$validation_root/records/baseline.sha256"
   ```

## Native close and quit matrix

Run each row from a fresh launch with the same isolated validation directory.
For every run, draw a different additional mark after opening the baseline so
the named project is dirty relative to its last explicit save.

| Exit path | Choice | Expected result |
| --- | --- | --- |
| Red window close button | Cancel | Window and same document remain open; the new mark is still visible and can be saved. |
| Red window close button | Save | Save completes before the window closes; relaunch and open the project to confirm the new mark. |
| Red window close button | Discard | Window closes; the named project hash remains identical to its pre-dirty hash; the recovery copy is removed; relaunch has no recovery prompt for the discarded mark. |
| Cmd-Q | Cancel | App stays open with the same dirty document and mark. |
| Cmd-Q | Save | App quits only after saving; relaunch and reopen to confirm the mark. |
| Cmd-Q | Discard | App quits; the named project hash is unchanged; the recovery copy is removed; relaunch has no recovery prompt for the discarded mark. |

Use `app/tool/hash_inkproj_tree.sh` before and after each Discard. The output
must be byte-for-byte identical. Record the run ID, macOS version, app revision,
exit path, choice, outcome, and any recovery path in a text file under
`$validation_root/records`. If AppKit does not present all three choices, or
the result differs from the table, record the failure and stop the alpha gate.

## Disk-backed failure cases

The integration suite exercises these through the production Rust bridge with
temporary on-disk fixtures. Repeat the visible app flows where possible and
record any difference:

- Open a damaged `.inkproj`. Record the source tree hash before and after. The
  open project, its pixels, path, dirty state, and recovery copy must remain
  available; the damaged source must remain byte-identical.
- Save to an invalid destination such as a child path beneath a regular file.
  The failed save must not change the active path, clear the dirty marker, or
  alter the blocker or existing project.
- Import a damaged `.inkbrush`. The import must report failure, leave the
  source hash unchanged, and install no partial brush.
- Cancel Open, Save As, and import pickers. Cancellation must leave the open
  document and its dirty/recovery state unchanged.

The automated failure suite is run by `app/tool/run_macos_alpha_checks.sh
--full`; it also covers failed writes to a disk-backed recovery destination,
the document/layer/brush/comic round trips, and the AppKit close/quit choices.
The separate
`--native-live-texture` mode exercises the Rust/Metal/Flutter surface handoff
and needs a foreground macOS session with a working Metal adapter. A green
automated suite does not replace the AppKit matrix above.

## Result record

Keep one record per run. Mark only evidence actually observed:

```text
Run ID:
Source revision:
macOS version/build:
Flutter version:
Device and input:
Validation documents directory:
Automated command and result:
Red close: Cancel / Save / Discard, result:
Cmd-Q: Cancel / Save / Discard, result:
Baseline hash before/after Discard:
Recovery present/removed after each choice:
Open/Save/import failure results:
Offline drawing/save/reopen/export result:
Failures, logs, and retained artifact paths:
```

Do not claim native close/quit, provider, offline, or physical stylus
acceptance from widget tests or a successful debug build alone.
