# First public release scope

This document defines the acceptance scope for the first public release. It is
not a statement that Project Ink is currently release-ready or that either
candidate platform is already supported. See
[`release-readiness.md`](release-readiness.md) for the evidence gates.

## Candidate platforms

The first candidates are macOS and iPadOS. Each platform must independently
pass its signed-install, input, file, offline, recovery, export, and workflow
acceptance before being called supported. iOS, Android, Windows, and Linux
remain development targets for later releases.

## Product promise after acceptance

The first release is a local-first illustration and comic studio. Its required
user journeys are:

- Create a canvas; draw with multiple brush families; save; close; reopen in a
  fresh process; and verify undo and redo.
- Manage a useful layer stack: explicit paint targeting, visibility, safe
  reorder, groups, attached masks, locks, undo/redo, and persistence after
  reopen.
- Edit a custom brush, preview it, cancel or commit the edit, save it, export
  and re-import it, select it, and verify its settings affect a stroke.
- Create a multi-page comic with panels and dialogue, save and reopen it, and
  inspect a useful export with its references intact.
- Recover safely from failed or interrupted saves, reject corrupt replacements
  without losing the current document, and complete file workflows offline.

These are release acceptance requirements, not current support claims. Their
status is tracked individually in `release-readiness.md`; host tests, desktop
mouse runs, and physical pen acceptance are separate evidence.

## Explicit non-goals

- Full feature parity with Clip Studio Paint, Procreate, or ibisPaint.
- Claiming support for platforms that have not passed their own install and
  real-use acceptance gates.
- Promising final print color management, typography parity, or a broad suite
  of adjustment effects before those areas have separate acceptance evidence.
- Cloud sync, accounts, collaboration services, or required network access.

The app-specific interface copy is English only. No translated catalogs are
part of this release scope.
