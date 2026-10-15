# Changelog

Project Ink has not published a stable release. This file records changes for
future tagged releases; unreleased development work is tracked in `TODO.md`
and the repository history.

## Unreleased

- Reject new saves inside existing project packages or backups, preventing
  nested artwork from being removed by an enclosing project's atomic save.

- Wrap layer status badges in narrow panels so Active, lock and clipping labels
  do not overflow; add regression coverage and refresh reviewed visual fixtures.

## [0.1.0]

Prepared experimental alpha; not yet published. Candidate verification and
platform distribution decisions are recorded in
[`specifications/alpha-candidate-verification.md`](specifications/alpha-candidate-verification.md).

- Local illustration canvas, built-in brush families, custom brush editing,
  raster layers, selection, undo/redo, named project save/reopen, recovery and
  PNG export.
- Make the active paint target visible; preserve layer locks, alpha lock,
  masks and clipping through engine history and persistence.
- Experimental comic pages, panels, linked dialogue and complete SVG export.
- Prepare macOS universal ZIP and signed Android arm64 APK packaging,
  SHA-256 verification, installation notes and artist feedback templates.

Known limitations and candidate installation status are listed in
[`specifications/alpha-release-notes.md`](specifications/alpha-release-notes.md).

- Keep the editor open when edits arrive during Save while closing; users can
  save again before closing.
- Add a named screen-reader target and drag hint for layer reordering.
- Add release tag preflight and staged-artifact SHA-256 helpers for maintainers.
- Define first-release acceptance scope and parity non-goals.
- Release readiness gates are tracked in
  [`specifications/release-readiness.md`](specifications/release-readiness.md).
