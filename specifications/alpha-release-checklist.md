# Immediate experimental alpha checklist

Reviewed 2026-10-08 against Storytold's PhotoCraft and VectorCraft first public
releases and Project Ink's recorded acceptance evidence. The recommendation is
to freeze feature scope now and finish candidate verification and distribution.
No additional art feature is required for this experimental illustration alpha.

## Launch goal

Publish an experimental GitHub prerelease for artist feedback. The minimum
product is a useful illustration workflow: create, draw, edit layers, undo/redo,
save, close, reopen, and export. Basic comics can be included as experimental
functionality, with their export limitations stated explicitly.

Aim for macOS and Android downloads, where preliminary testing already exists.
Ship one usable platform artifact first. Add macOS, Android, and iOS/iPadOS
artifacts independently as their installation and smoke checks pass. Source
build instructions may cover additional development targets. A platform missing
an installable artifact must be described as a development target rather than
included in the tested-download list.

This checklist governs the experimental alpha decision. The broader supported
release requirements remain in [release-readiness.md](release-readiness.md)
and [first-release-scope.md](first-release-scope.md). No format, persistence,
input, or platform support contract is changed by this document.

## What the comparison supports

The closest references are PhotoCraft (raster/layer editing) and VectorCraft
(vector illustration). Their earliest currently published releases are both
`v0.1.0`, dated 2026-10-02 UTC. Sources below are pinned to that tag rather than
today's expanded feature set.

| Reference | Observed first-release evidence | Lesson for Ink |
|---|---|---|
| [PhotoCraft v0.1.0](https://github.com/storytold/photocraft/releases/tag/v0.1.0) | Its [tagged README](https://github.com/storytold/photocraft/blob/v0.1.0/README.md) explicitly calls it early alpha, describes core editing and file workflows, warns about rough edges, and invites issues. Assets include desktop installers, a web archive, and checksums. | A useful editing loop and accessible downloads can precede full competitor parity. |
| [VectorCraft v0.1.0](https://github.com/storytold/vectorcraft/releases/tag/v0.1.0) | Its [tagged README](https://github.com/storytold/vectorcraft/blob/v0.1.0/README.md) says active development. Release notes include a save prompt on close; assets include desktop installers, a web archive, and checksums. Its [tagged roadmap](https://github.com/storytold/vectorcraft/blob/v0.1.0/ROADMAP.md) leaves interaction fidelity, advanced type/effects, and hardening work open. | Label unfinished areas and continue refinement after a usable release. |

Neither release is marked as a GitHub prerelease in the API, and VectorCraft's
tag does not explicitly use the word alpha. We will mark Ink as a prerelease
to make its experimental status clear. Asset listings were checked through the
[PhotoCraft release API](https://api.github.com/repos/storytold/photocraft/releases/tags/v0.1.0)
and [VectorCraft release API](https://api.github.com/repos/storytold/vectorcraft/releases/tags/v0.1.0).
These are publication precedents, not independent tests of those applications.
Their downloads do not establish mobile/stylus readiness for Ink. Roadmap gaps
do not prove they skipped safety checks, and their parity estimates are not an
appropriate measure of Ink's readiness.

## Existing evidence to carry forward

Baseline: clean `main` at `c486a06` before this checklist was added. These checks
have passed at the recorded evidence level; they are not all final-artifact
install tests.

- [x] Code license: the repository contains MPL-2.0 and declares it in the
  README and Rust workspace. This does not establish redistribution rights for
  every external asset or imported test brush.
- [x] Illustration journey: macOS Flutter/Rust integration covers two brush
  families, UI size/color changes, intended-layer painting, layer
  create/select/rename/reorder/visibility/opacity/delete/undo, native save/reopen,
  and a dimension/transparency-checked PNG export (2026-10-08).
- [x] Custom brush edit: preview, cancel, save, rendered-setting changes, and
  persistence pass in the macOS integration. Package interoperability remains
  a documented testing gap.
- [x] Active paint target is labeled **Active** in the layer UI (`a6d54cb`).
  Engine regressions cover group lock inheritance, alpha lock, attached masks,
  clipping, undo/redo, and save/reopen. Physical combined acceptance is pending.
- [x] Android three-finger Redo was confirmed by the user; recovery marks
  reopened after force-stop (2026-10-08). This evidence does not include a named
  project save or Redo after reopen.
- [x] Basic comic journey: macOS controller/Rust integration creates two pages
  with panels, linked dialogue and editable ink, saves/reopens, and checks both
  page exports. UI preset and linked-balloon controls have widget coverage.
  The test generates ink through the bridge rather than canvas pointer input.
- [x] Real macOS AppKit Save/Discard/Cancel and fresh-process drawing/reopen/
  Undo/Redo were recorded on 2026-10-03. Reuse this scoped manual evidence;
  native XCUITest automation remains incomplete. See
  [release-readiness.md](release-readiness.md) and
  [macos-alpha-acceptance.md](macos-alpha-acceptance.md).

## Required before publishing the alpha

1. [ ] **Prepare the actual repository.** Configure the intended GitHub
   repository/remote and its chosen visibility. Review the source, history and
   attached files intended for publication for secrets, personal artwork,
   diagnostic traces and non-redistributable bundled assets. Preserve private
   local evidence; do not attach it to a public release by default. No Git
   remote was configured at the baseline revision.
2. [ ] **Pass one artist smoke journey on every attached binary.** Install the
   actual candidate, record its hash/device/OS/input, then create a canvas;
   draw with two brush families and different size/color settings; erase a mark;
   pan/zoom; create and
   select a second layer; hide/show it; undo/redo; save a named project; fully
   quit and relaunch; reopen; and export an image at the expected dimensions.
   Confirm strokes stay on the layer marked Active. Use a disposable project.
   Mouse testing is sufficient for a declared mouse-only Mac alpha; a claimed
   S Pen or Pencil alpha needs a real pen run. Record light/firm pressure
   behavior and any limitations. If comics are advertised in the release,
   also create a page, panel and dialogue through the UI; save/reopen; and
   inspect its complete SVG export for readable dialogue and matching artwork.
3. [ ] **Resolve the reported Android lost-work case before attaching an
   Android binary.** Reconcile the 2026-10-07 missing sketch/empty History
   report with the later recovery success. On the candidate, check a long
   S Pen stroke, named save/fresh-process reopen, and recovery after force-stop.
   Fix a reproducible silent-loss or wrong-layer failure. If Android cannot
   pass, publish the other passing artifact(s) and keep Android as a development
   target for this alpha.
4. [ ] **Confirm basic safe exit and replacement on the candidate.** Cancel a
   dirty-document close and an Open/Save As picker; verify the same work remains.
   Reopen a saved disposable project after quitting. Reject one corrupt copy
   without altering the current project or the corrupt source. Existing
   integration and manual evidence may be referenced, with its revision and
   scope recorded; any known regression needs a focused rerun.
5. [ ] **Record candidate regression checks once.** Run the existing Flutter
   analyzer/unit suite and Rust format/test/Clippy checks on the selected code
   revision, plus the relevant document journey for code changed since the
   recorded pass. Record results and baseline failures. Documentation-only
   changes do not require repeating application builds or every device suite.
6. [ ] **Prepare version and release notes.** The app is currently `0.1.0+1`.
   Add a matching `## [0.1.0]` changelog entry, choose the candidate commit/tag,
   and mark the GitHub release as a prerelease. Existing preflight accepts
   `v0.1.0` with the matching app version, changelog heading and clean tagged
   checkout. An `alpha.N` tag suffix would require an intentional preflight
   update; it is optional for the immediate release.
7. [ ] **Package the passing artifacts.** Record the source tag, toolchain,
   architecture, signing status and SHA-256 hashes. A manual package from
   tagged source is acceptable for the first alpha; an automated signed
   publishing workflow can follow. An Android APK needs a valid install
   signature. An Apple test build must meet the signing requirements of its
   selected distribution channel. State macOS notarization status and verify
   the documented install procedure. Never describe a no-codesign compile as
   an installable iOS download.
8. [ ] **Write a short tester README/release note.** Include installation or
   source-build steps, tested OS/device/input combinations, the draw/save/reopen
   workflow, where projects/recovery live, and known limitations. Explain that
   alpha testers should use copies of valuable artwork. State that comic SVG
   is the complete composite while batch comic PNG currently contains artwork
   only. List untested pen behavior, brush interoperability, file providers,
   performance and format compatibility honestly.
9. [ ] **Provide feedback and private security reporting.** Link a working
   issue tracker for ordinary bugs and a verified private route for security
   reports. Request version, device/OS, reproduction steps and expected/actual
   behavior; do not require private artwork or raw troubleshooting traces.
10. [ ] **Verify the published download.** Check the release is marked as a
    prerelease, download each attached artifact, verify its checksum, and use
    the documented install/start procedure. Link the source tag and license.

An alpha is ready when these applicable launch checks pass. A reproducible
loss/corruption of ordinary saved work, silent painting on a different layer,
or failure to launch/install blocks the affected artifact. Incomplete features
and untested development platforms can be disclosed or omitted.

## Follow-up work that does not hold this alpha

- Full Clip Studio Paint, Procreate or ibisPaint feature parity; additional
  brushes, filters, animation, cloud features and collaboration.
- Six-platform support, a broad desktop tablet brand matrix, and Apple store
  distribution. An Apple artifact still needs a valid chosen test channel.
- A fully automated packaging/notarization/publishing pipeline when the first
  manual release is reproducible and verified.
- Every advanced layer, adjustment and brush interchange combination; expose
  their current experimental status and prioritize observed tester failures.
- Production comic typography/color management, flattened lettered PNG/PDF,
  print workflows, and cross-device comic production acceptance.
- Maximum-valid import fixtures, cancellation/deadline support for every
  expensive importer, and complete minimum-spec performance certification.
  Existing size bounds remain in force; a known crash in the ordinary alpha
  journey must still be addressed.
- Comprehensive localization and accessibility audits. Core controls in the
  offered alpha still need readable text, usable targets and a working primary
  interaction path.

## Candidate evidence record

Fill one row for each offered artifact; leave a platform out of the release's
download list if its row is incomplete. An existing pass can be reused when
its code/input path has not changed, but the final package still needs an
installation/start and basic save/reopen smoke check.

| Platform | Source commit / artifact SHA-256 | OS / device / input | Install + artist journey | Exit / recovery evidence | Distribution channel / signing | Decision |
|---|---|---|---|---|---|---|
| macOS | Pending | Pending | Pending final package | Prior manual matrix; candidate scope pending | Pending | Candidate |
| Android | Pending | Galaxy S23 Ultra / S Pen; candidate OS pending | Named save/fresh-process reopen pending | Redo/recovery observed; earlier missing-work report unresolved | Signed APK pending | Candidate |
| iOS/iPadOS | Pending | Pending | Physical acceptance pending | Pending | Provisioning/install pending | Add when ready |

Record the date, result, evidence path and any reproduced failure beside each
completed launch check. Keep private artwork and traces outside public release
attachments. After launch, prioritize issues by saved-work safety, blocked
artist workflows, drawing/input behavior, and then feature expansion.
