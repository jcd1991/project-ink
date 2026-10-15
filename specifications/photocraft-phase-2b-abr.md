# PhotoCraft reuse — Phase 2B: ABR brush import

## Scope and ownership

Extend `ink-brush` parsing/conversion and the existing `BrushImportReport`
workflow. Keep parsing budgets in the parser boundary, Rust brush/library state
authoritative, and Flutter limited to report, preview, selection, and explicit
confirmation. Do not create a parallel brush library or promise Photoshop
renderer parity.

Support computed and sampled tips from ABR v1/v2 and bounded supported
sectioned v6+ descriptors. Map diameter, hardness, roundness, angle, spacing,
and supported dynamics to existing Ink brush presets. The supported dynamics
subset includes zero-jitter Pen Pressure controls for size and opacity, mapped
as linear normalized pressure curves from the configured minimum to 100%.
Jittered, tilt, fade, wheel, rotation, scatter, flow, color, dual-brush, and
texture controls remain explicit omissions until their semantics have
independent fixtures and a faithful Ink target. Preserve tip identity and
source attribution. Confirm sample coverage polarity with fixtures.
Unsupported settings, patterns, and preset descriptors are reported
individually.

Adobe documents pressure as controlling brush size between the initial and
minimum diameter and opacity up to the configured maximum. The converter
interprets sectioned `bVTy` control IDs using the `ag-psd` descriptor mapping
(`0=off`, `1=fade`, `2=pen pressure`) and labels Ink's linear response
Approximate. See [Adobe
brush dynamics](https://helpx.adobe.com/photoshop/using/adding-dynamic-elements-brushes.html)
and the [`ag-psd` ABR descriptor mapping](https://github.com/Agamnentzar/ag-psd/blob/master/src/abr.ts).

## Transaction and resource contract

- Every conversion is Approximate, Tier C. Successful parsing does not increase
  fidelity automatically.
- Reuse archive, resource, dimensions, and cumulative import budgets; enforce
  them while parsing, before large allocations.
- Show an isolated deterministic preview and complete report before
  registration. Cancel registers nothing.
- Save selected valid brushes and resources atomically. Deduplicate resources
  by content hash. A malformed member may be omitted only when the complete
  report identifies the omission before confirmation.
- Keep conversion bounded to 256 imported presets/tips. Report the exact count
  of sectioned presets or standalone sampled tips beyond that limit. List each
  unsupported setting while the combined per-brush report, including
  file-level omissions, fits the 128-entry omission bound. If malformed/skipped
  members exceed the bounded complete report, reject the file before
  confirmation rather than silently truncating diagnostics or importing a
  partial result.
- Rejection, cancellation, and failed registration leave the existing library
  unchanged.

## Acceptance

Fixtures cover computed and sampled tips, supported ABR version descriptors,
zero-jitter pressure size/opacity mapping, unsupported dynamics, duplicates,
unsupported settings, corrupt/truncated records, polarity, and
cumulative-budget rejection. Verify cancel/no mutation, multi-brush atomic
registration, deduplication, deterministic preview, save/reopen, and painting
with the imported settings. Test imported pressure mapping separately from
native S Pen pressure normalization. Report host and installed device evidence
separately. A successful mapping remains Approximate, Tier C.
