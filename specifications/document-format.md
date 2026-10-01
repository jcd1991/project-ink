# `.inkproj` storage format (root v2)

The native document is a directory/archive containing `manifest.json`,
`document.sqlite`, compressed raster tiles under `tiles/<layer>/<x>_<y>.tile.zst`,
optional `vectors.json.zst` vector records, resources, and `preview.webp`. Saving writes temporary
files, validates them, and atomically replaces the destination. A newer format
is read-only or rejected; recovery always writes a sibling recovered copy.

Root storage version 2 adds canonical `comic.json` support and the atomic
multi-page writer/loader. A studio project stores each page beneath
`pages/<page_id>/` using the same SQLite, tile, vector, history, and recovery
schema as a standalone document. The bridge exposes one
`StudioProjectHandle`, which owns the comic metadata and all page workers.
Standalone v1/v2 documents remain supported for illustration workflows.

`document.sqlite` contains the layer tree, sparse tile index, checkpoint
revision, and append-only v1 command journal. Journal payloads are versioned
binary commands. The engine can decode and replay the journal against a fresh
state to validate command/layer/history compatibility. Replay does not
reconstruct raster pixels: high-frequency pointer packets are intentionally
not journaled, so checkpoint tiles remain the source of pixel truth.
`history.json.zst` stores bounded reversible layer/tile snapshots so undo and
redo remain available after reopening a project.

Layer stacking is deterministic within each parent: lower `order` values are
behind higher values. The SQLite writer stores siblings in that canonical order
and the loader reconstructs the ranks from row sequence, preserving documents
written before the explicit in-memory order field existed. Moving a layer is an
undoable `MoveLayer` command with a bounded destination index; object IDs are
never used as visual ordering.

Layer kind value `6` is a nondestructive `Adjustment` node. The nullable SQLite
`layers.adjustment` column stores a bounded JSON `LayerAdjustment` payload;
older SQLite projects without this column load each layer with no adjustment.
The first supported payload is `BrightnessContrast { brightness, contrast }`
with each signed percentage limited to `-100..=100`. Adjustment nodes may be
root-level or direct children of an ordinary `Group`; nested adjustments under
other layer kinds (including comic `PanelGroup`) are rejected. Every node must
carry a valid payload; malformed values and settings on a non-adjustment layer
are rejected. Command-journal tag `32` sets these two signed little-endian
16-bit values on an adjustment layer and is undoable. Root adjustments process
the full accumulated document composite. A group adjustment processes only
the alpha coverage contributed by lower paint descendants in that group, after
their sibling/ancestor masks and presentation opacity; pixels outside that
coverage are unchanged. This follows the lower-stack/hierarchy behavior of a
filter layer without changing stored raster/vector source tiles. Group
adjustment evaluation is non-destructive and deterministic per tile; flattened
exports use the same authoritative composite tiles. Spatially editable filter
masks, additional filter kinds, and isolated/pass-through group blend modes
remain unsupported.

Mask layers are raster alpha stencils. A visible mask sibling after a raster
or vector layer in the same parent group multiplies that layer's premultiplied
RGBA during tile reads and export; the mask itself is not painted as a visible
color layer. Group visibility and opacity are presentation ancestors and are
multiplied through the parent chain. Parent cycles and dangling references are
rejected before any content is opened.

Command tag `22` is `AddVectorStroke`: `layer_id:u128`, `stroke_id:u128`,
`closed:u8`, `point_count:u16`, then bounded little-endian point tuples
`(x:f32,y:f32,pressure:f32,tilt:f32)`. `vectors.json.zst` stores the same
validated strokes for the current checkpoint and history states use the same
record shape. Payloads are bounded, finite, canvas-clamped, and never
executed as code.

The v1 journal reserves command tag `17` for `TransformLayer`. Its payload is
`tag:u8`, `layer_id:u128`, followed by six little-endian `f32` values in the
order `a,b,c,d,tx,ty`. The matrix maps `(x,y)` to
`(a*x + c*y + tx, b*x + d*y + ty)`. The engine rejects non-finite values,
near-singular matrices, and transforms outside its bounded numeric limits
before mutating raster tiles.

Command tag `18` is `FillRegion`: `layer_id:u128`, `x:u32`, `y:u32`, RGBA8
color, `tolerance:u16`, and `gap:u32`. The engine bounds the working pixel
buffer, clamps gap closing to four pixels, intersects the result with any
ephemeral selection, and records the operation as an ordinary undoable
transaction.

Command tag `28` is `GradientFill`: `layer_id:u128`, flood origin `x:u32,y:u32`,
four little-endian gradient endpoint floats, two RGBA8 endpoint colors,
`tolerance:u16`, `gap:u32`, `expansion:u32`, and `paint_inside:u8` /
`paint_unfilled:u8` flags. The engine caps expansion at sixteen pixels,
supports reference-layer sampling, selection intersection, Paint Inside
(current-layer alpha), and transparent-only painting. Unsupported flag values
are rejected by the journal decoder.

Command tag `29` is `MergeLayers`: `target_layer_id:u128` followed by
`source_layer_id:u128`. The engine accepts only standalone raster layers in
the same parent group, composites the source with its visibility, opacity, and
blend mode, then removes the source. The command is atomic, undoable, and
replayable; vector, grouped, clipped, mismatched-parent, and child-bearing
layers are rejected without changing the document.

Command tag `30` is `CreatePanelLayerTree`: eight little-endian `u128` values
(`panel_id`, `panel_group_id`, `mask_id`, `sketch_id`, `ink_id`, `color_id`,
`tone_id`, `effects_id`). It atomically creates a top-level `PanelGroup` with
ordered `Sketch`, `Ink`, `Color`, `Tone`, `Effects`, and `Mask` children. IDs
must be non-zero and unique; a complete matching tree is an idempotent retry,
while a partial or incompatible tree is rejected without mutation. The panel
geometry is written to an authoritative sparse mask by the unified project
boundary and Draw-inside-panel path; the bounded Rust selection clip remains
for immediate input safety while the gesture is active.

Command tag `31` is `SetPanelMaskGeometry`: `mask_id:u128`,
`point_count:u16`, then 3–64 finite little-endian `(f32 x, f32 y)` vertices in
document space. The engine rasterizes only the bounded polygon bounds into the
mask's sparse tiles, publishes layer and composite invalidations, and records
the operation as an ordinary undoable transaction. A mask with allocated
geometry on a `Group`/`PanelGroup` ancestor clips every paint child in that
group; an empty generated mask is inactive until geometry is set.

Command tag `19` is `PerspectiveLayer`: `layer_id:u128` followed by four
little-endian `(f32 x, f32 y)` target points ordered clockwise from the
top-left. The engine rejects non-finite, out-of-range, or near-zero-area
quadrilaterals before changing tiles.

Command tag `20` is `MeshLayer`: `layer_id:u128`, `columns:u16`, `rows:u16`,
`point_count:u16`, then bounded little-endian `(f32 x, f32 y)` control points
in row-major order. The engine requires a 2–32 grid and exactly
`columns*rows` points.

Command tag `21` is `LiquifyLayer`: `layer_id:u128`, six little-endian `f32`
values (`center_x`, `center_y`, `radius`, `strength`, `direction_x`,
`direction_y`), and a mode byte (`0` push, `1` expand, `2` contract, `3`
twirl). Non-finite, negative-radius, out-of-range, and unknown modes are
rejected before raster mutation.

Tags `23`–`27` are the undoable vector-edit commands (tag `22`
`AddVectorStroke` is defined above):

- `23 TransformVectorStroke`: `layer_id:u128`, `stroke_id:u128`, and six
  little-endian `f32` values `a,b,c,d,tx,ty`.
- `24 SimplifyVectorStroke`: `layer_id:u128`, `stroke_id:u128`, and a finite
  positive `tolerance:f32` capped at 256.
- `25 ConnectVectorStrokes`: `layer_id:u128`, `first_id:u128`, `second_id:u128`,
  and a finite positive connection tolerance capped at 256.
- `26 EraseVectorSegment`: `layer_id:u128`, `stroke_id:u128`, and finite
  `center_x`, `center_y`, and positive `radius` values.
- `27 SetVectorPoint`: `layer_id:u128`, `stroke_id:u128`, `index:u32`, and
  finite `x`, `y`, `pressure`, and `tilt` values. Pressure is clamped to
  `0..1` and coordinates must remain inside the document.

All five commands validate IDs, finite values, canvas bounds, and layer kind
before mutation. Their effects rebuild the deterministic raster visibility
cache; vector centerlines remain authoritative in `vectors.json.zst`, and
undo/redo snapshots retain the pre-edit records. `EraseVectorSegment` is
intersection-aware: it solves segment/circle crossings, emits interpolated
centerline cut points (including pressure and tilt), and stores each surviving
piece as an open editable stroke. A miss leaves the original stroke, including
its closed flag, unchanged.

The bridge's external-brush workflow is staged and expiring: `stage_brush_import`
returns an opaque operation ID and source hash, `convert_staged_brush_import`
re-reads and verifies that source, `commit_staged_brush_import` installs only
after a second hash check, and `discard_staged_brush_import` cancels it. IDs
expire after ten minutes and at most sixteen operations are retained per
document handle. Paths, archives, and reports are never persisted in the
document format.
`brushes.json.zst` optionally stores bounded, validated JSON brush-preset
payloads for user-owned brush overrides. It contains no executable code or
external paths; old projects without the file load with the built-in library.
Layer IDs are never recycled while a document is open, duplicate IDs and
parent references are rejected, and the reopened layer graph must be acyclic
with no dangling parents. Deleting a layer with children is rejected rather
than silently orphaning their content.

Save publication is tested against hard process termination after each
manifest, SQLite, tile, history, backup-rename, and publish-rename stage. A
termination before publication leaves the previous destination readable; a
termination after the old destination is moved leaves the `.bak` sibling
recoverable into a new project; a termination after publication leaves the new
validated project readable. Temporary siblings are never treated as the user’s
source document.

## Client autosave contract

Flutter may attach an autosave coordinator to an open document path. The
coordinator stores no document state: it only coalesces mutation notifications
and calls the Rust save boundary. Pointer packets during a long stroke may
keep the interval alive without postponing the first checkpoint. Rust flushes
the render worker before snapshotting, and the storage layer publishes the
checkpoint atomically. A failed checkpoint leaves the coordinator dirty and
retryable; it must never clear the dirty state or replace the last valid
project on error.
