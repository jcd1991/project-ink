# PhotoCraft reuse — Phase 2A: editable layered PSD

## Scope

The first editable subset is PSD v1, RGB, 8-bit: raster layers, names, order,
offsets, visibility, opacity, full/alpha locks, ordinary isolated and
pass-through groups, Normal/Multiply/Screen, simple raster masks, and clipping
chains whose results match Ink. PSB, non-sRGB profiles, higher bit depths,
adjustment/text layers, gradient and pattern fills, smart objects, effects,
vector masks, unsupported blend modes, and arbitrary metadata preservation are
excluded. A single RGB solid-color `SoCo` fill on a raster layer is accepted
only when its versioned descriptor contains finite 0–255 RGB components. Ink
converts it to a paint layer: the fill color is baked into RGBA pixels, fill
opacity is baked into pixel alpha, and ordinary layer opacity, locks, clipping,
visibility, offsets, and supported raster masks remain separate. The user must
be told that the imported fill color is no longer editable as a fill.

`ink-export` owns bounded format inspection/serialization. `ink-engine` turns a
validated decode into a detached candidate and owns conversion/publication.
Flutter presents compatibility details and obtains an explicit choice.

## Inspection and import

- Inspect dimensions, supported features, incompatibilities, merged composite
  availability, and estimated working set before choosing import mode.
- Report the number of logical layer and group nodes in preflight; exclude PSD
  bounding section-divider records from that count. Keep raw file-record
  projections internal to decoding and diagnostics.
- Accept only the bounded solid-color conversion above. Leave gradient fills,
  pattern fills, unsupported color descriptors, multiple `SoCo` records, and
  malformed fill descriptors as editable-import incompatibilities. This does
  not change the import memory limit or ICC-profile policy.
- Choose editable import only when the complete structure is supported. Offer
  flattened import only by explicit user choice and only with a valid merged
  composite. Never silently use cached layer pixels for unsupported live
  effects.
- Preserve source bytes; create a new unsaved Ink document with fresh IDs.
  Validate parent-first hierarchy, sibling order, offsets, masks, and clipping
  references before binding. Convert straight RGBA to premultiplied BGRA once.
- Enforce dimensions, 1,024-layer, depth-32, parser allocation, existing
  document limits, 768 MiB import working-set policy, and remaining global
  memory budget before decode/decompression where possible. Report any parser
  limit that cannot be enforced before its allocation.
- Cancellation or any parse/decode/validation/replacement failure leaves the
  active document untouched. A mid-decode cancellation hook is required if
  decoding is moved off the current synchronous boundary.

## Export

- Export a coherent Rust snapshot and calculate/write the real merged composite;
  a PSD layer builder alone does not provide it.
- Crop raster pixels to their nontransparent bounds and preserve the resulting
  document-space layer offsets. Preserve a mask's own bounds separately from
  its owner layer; use a one-pixel default mask for masks with no nondefault
  samples.
- Reject editable export when unsupported content is present and return a
  feature report. Offer flattened PSD only as a separate explicit action.
- Preserve safe export staging, sync, no-overwrite, and failure cleanup. Do not
  claim arbitrary Photoshop metadata survives editing in Ink.

## Acceptance

Use independent external fixtures, not only Ink→PSD→Ink. Verify hierarchy,
offsets, visibility, opacity, locks, masks (enabled/disabled and default
coverage), clipping, group behavior, and composite pixels against independent
expected images. Include malformed/truncated data, allocation caps, unsupported
content, missing merged composite, cancellation, destination failure, and
save/reopen. Record which cases are fixture-only versus installed macOS and
Android acceptance.

For the solid-color conversion, verify RGB descriptor decoding, fill-opacity
alpha, layer opacity and masks, the visible conversion notice, group-node
counting, unsupported gradient/pattern/malformed fill rejection, and save/reopen
pixel durability. These tests do not establish ICC conversion, blend-mode
support beyond the current subset, or a larger import-memory budget.

For a third-party render check of exported files, run the Photoshop fixture
bridge tests with `PROJECT_INK_PSD_ORACLE_DIR` set, then pass each copied PSD
and its independent PNG to `tools/verify_external_psd_composite.py`. The script
requires `psd-tools==1.11.0` and Pillow 10.4.0, compares the third-party
composite pixelwise, and prints the parsed layer bounds, group structure,
clipping, and mask bounds.
