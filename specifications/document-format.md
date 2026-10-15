# `.inkproj` storage format (root v8)

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
Standalone formats 2 through 7 remain readable; saves write v8. Readers reject
newer format versions instead of dropping fields they do not understand.

Root v8 adds `vector_semantics: 1` to the manifest. Its `vectors.json.zst`
records are tagged `ink_model::VectorObject` payloads (`LegacyInk` or
`BezierPath`) with stable object IDs in the existing record-ID field. Record
sequence within each layer is the explicit stacking order and is retained by
checkpoints and history. Formats 2–7 continue to decode vector payloads as
legacy sampled strokes; the v8 writer wraps those strokes as `LegacyInk` when
migrating on save. Unknown semantics, unknown object kinds, invalid geometry,
and malformed source archives are rejected before engine binding. Loading an
older project is read-only; only an explicit save writes the migrated v8
format. Comic metadata and rendering remain on comic format 3.

App startup recovery selects the loader from the root manifest: standalone
documents use the document loader, while Studio packages use the complete
Studio loader and restore the comic controller from the same project handle.
If a recovery package is unsupported or invalid, startup stops with the source
left untouched rather than opening a blank document that could later overwrite
the only recovery copy.

`history.json.zst` may include the optional `history_truncated: true` flag.
Writers set it when they omit older undo/redo snapshots to keep the complete
document within the shared memory budget. Older readers ignore this additive
field; current readers expose the omission in the History palette. The current
artwork checkpoint is retained when history is trimmed.

V6 adds bounded `layer_panel_state` metadata to each page manifest. It stores
the primary layer ID and the IDs of collapsed ordinary groups; this affects
panel presentation only and is excluded from content history and command
journals. Older manifests default to no stored primary target or collapsed
groups. V6 readers validate every ID against the saved layer tree before
opening, and older readers reject V6 rather than silently discarding it.

Root v7 records the comic lettering renderer contract through comic format v3,
including `render_semantics: 1`. Comic text remains editable source data;
shaped glyph outlines are derived at render and export time. The renderer uses
bundled Noto Sans/Serif CJK JP fonts and does not consult system fonts. The
minimum reader version for root v7 is 0.1.0, matching the current alpha package
version. Raise it together with a product-version bump.

Root v7 layer adjustment payloads retain the existing Brightness/Contrast
variant and add Levels, Curves, and Hue/Saturation. Curves store four fixed
16-point channels with a canonical zero representation for unused points.
Unsupported adjustment values are rejected before document mutation. Brush
presets may use format 3 only with evaluator semantics 2001 for pulled-string
stabilization; existing format-2 presets remain on semantics 2000.

`document.sqlite` contains the layer tree, sparse tile index, checkpoint
revision, and append-only v1 command journal. Journal payloads are versioned
binary commands. The engine can decode and replay the journal against a fresh
state to validate command/layer/history compatibility. Replay does not
reconstruct raster pixels: high-frequency pointer packets are intentionally
not journaled, so checkpoint tiles remain the source of pixel truth.
Explicit raster commands such as panel-frame application are journaled and do
replay their bounded pixel edits; this does not change the pointer-packet rule.
Command tag 32 retains subtype 0 for Brightness/Contrast. Subtypes 1, 2, and 3
encode Levels, Curves, and Hue/Saturation respectively, using bounded
little-endian fields and pre-mutation validation.
`history.json.zst` stores bounded reversible layer/tile snapshots so undo and
redo remain available after reopening a project.

In-memory history snapshots share each `TileStore` sparse map and dirty set
through standard-library copy-on-write handles. Tile pixel buffers remain
independently copy-on-write. A write detaches only the touched layer's sparse
containers, and only touched tile pixels; snapshots and the on-disk format are
unchanged. History byte estimates intentionally count shared payloads in every
snapshot as a conservative logical upper bound, and are not a measurement of
unique resident allocations.

Layer stacking is deterministic within each parent: lower `order` values are
behind higher values. The SQLite writer stores siblings in that canonical order
and the loader reconstructs the ranks from row sequence, preserving documents
written before the explicit in-memory order field existed. Moving a layer is an
undoable `MoveLayer` command with a bounded destination index; object IDs are
never used as visual ordering.
Command-journal tag `36` groups two or more same-parent layer IDs in one
undoable pass-through group. Member order is taken from the existing sibling
stack; the group is inserted at the highest selected sibling position. Older
readers reject this unknown tag instead of discarding the grouping operation.
Command-journal tag `37` deletes one or more selected structural roots and
their descendants atomically in one undoable edit. When a selected group and
one of its descendants both appear in the request, the descendant is
normalized away. An edit that would remove every layer or touch comic-owned
content is rejected before mutation.
Command-journal tag `38` ungroups one ordinary pass-through group, replacing
it in its parent stack with its children in their existing order. It is
rejected unless the group is Normal at 100% opacity and the operation can
preserve mask/clipping relationships; comic-owned groups remain routed through
the comic workspace. The operation is undoable as one layer snapshot.
Command-journal tag `39` duplicates a paint leaf and its attached masks as one
undoable operation. The payload carries the source owner, duplicate owner, and
ordered source-mask/duplicate-mask ID pairs; the copies retain their relative
mask ownership after undo, redo, save, and reopen. Earlier readers reject the
unknown tag rather than dropping the masks.
Command-journal tag `40` sets visibility for a non-empty list of distinct
layer IDs with one history entry. The engine validates the complete list
before mutation, so missing or repeated IDs cannot partially change the stack.
Earlier readers reject the unknown tag rather than replaying only part of the
bulk operation.
Command-journal tag `41` sets the explicit full-lock flag on one layer. The
flag is separate from alpha lock, survives undo/redo and save/reopen, and a
locked ordinary group protects its descendants. Visibility and unlocking
remain available. Earlier readers reject this unknown command.
Command-journal tag `42` sets full-lock state for a non-empty list of distinct
layer IDs in one history entry. The engine validates every target before
changing any lock; a locked ancestor prevents bulk changes to descendants.
Earlier readers reject the unknown command rather than applying a partial
selection.
Command-journal tag `43` reorders a non-empty set of distinct structural roots
within one sibling stack as a stable block. Attached masks move with their
owners, selected descendants normalize under selected ancestors, and undo
restores the prior stack order in one history step. Earlier readers reject
the unknown command.
Command-journal tag `44` sets or clears a color label on a non-empty list of
distinct layer IDs in one history entry. The engine validates every target
before mutation, and undo restores all labels together. Earlier readers reject
the unknown command rather than applying only part of the selection.
Command-journal tag `45` duplicates at least two sibling structural roots and
their ordinary group descendants or owner-attached masks in one history entry.
The command stores deterministic source-to-new-ID mappings, requires each new
ID to be the next available ID, and rejects locked, comic-owned, malformed, or
cross-stack selections before mutation. Selected descendants normalize under
their selected ancestor, attached masks remain linked to the copied owner, and
undo removes the complete duplicate block atomically. Earlier readers reject
the unknown command rather than duplicating only part of the selection.
Command-journal tag `46` merges at least two contiguous visible standalone
raster siblings into the lowest selected layer in one undoable transaction.
All selected layers must use Normal blending; clipping, masks, invalid tile
payloads, and a lowest target below 100% opacity reject the operation before
mutation. Source opacity is baked into the retained target. Earlier readers
reject the unknown command rather than applying a partial merge.
Command-journal tags `47` and `48` enable/disable and invert an attached mask.
Both operations alter only mask properties, leave sparse pixels untouched,
and create one undo entry. The engine rejects non-mask or locked targets.
Command-journal tag `49` applies an attached mask to its raster owner, baking
effective coverage into the owner's pixels and removing the mask in one undoable
transaction. Unsupported owners and locked targets are rejected without change.
Command-journal tag `50` replaces a raster layer with up to 256 applied panel
frame outlines. Each frame stores a bounded document-space polygon with 3–64
vertices and the requested border width; raster work is capped before mutation.
The operation is one undo entry, so the panel geometry remains independent from
the editable border pixels.
Command-journal tag `51` clears all raster or vector paint from one layer as a
single undoable operation. It keeps the layer and any comic panel metadata in
place, allowing standard brush erasing or Clear layer to remove applied panel
borders without deleting the editable panel layout.
Command-journal tag `52` applies one atomic mixed-vector patch to one vector
layer. It contains the layer ID, a non-empty bounded edit count, and ordered
insert/replace/remove edits. Insert records carry an explicit object ID and
position; insert/replace carry a tagged little-endian vector object; remove
carries the object ID. The tag is followed by `vector_semantics: 1`. Legacy
objects encode closed state and up to 8,192 sampled `(x, y, pressure, tilt)`
records. Bézier objects encode optional fill/stroke RGBA8 values, stroke
settings, fill rule, bounded subpath/anchor records, and an optional archived
legacy stroke. Unknown semantics or tags, non-finite values, invalid style
enums, malformed archives, and invalid path structure are rejected while
decoding. The complete payload is capped at 256 KiB and 4,096 edits; encoding
checks size and structure before engine mutation or journal allocation. The
engine validates edits against a candidate layer, rasterizes its complete
resulting path set, and publishes geometry, tiles, revision and one history
entry only after every edit succeeds. Journal replay stores resolved object
geometry; it never reruns recognition or fitting.

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

Mask layers are raster alpha stencils. V3 persists a nullable `mask_owner`
layer ID. A mask attached to raster/vector content must share the owner's
parent; a group mask is a child of its owner group. Rendering and export
resolve masks by stable owner ID, so sibling reorder does not retarget them.
On v1/v2 load, legacy adjacency is converted in memory to this relation.
Opening a legacy source never rewrites it. V5 adds `mask_enabled`,
`mask_stencil`, and `mask_inverted`. Ordinary masks store sparse hidden
coverage: zero alpha reveals the owner, so a new empty mask starts reveal-all
without allocating canvas-sized tiles. `mask_stencil` preserves direct reveal
coverage for comic geometry masks and migrated v1-v4 masks. `mask_inverted`
switches effective coverage without rewriting pixels, and disabled masks are
bypassed by preview and export. The mask itself is not painted as a visible
color layer. Group visibility and opacity remain presentation ancestors and
are multiplied through the parent chain. Parent
cycles, dangling references, invalid mask owners, and mismatched mask/owner
hierarchies are rejected before content is opened.

V4 adds `layers.locked`, a validated zero-or-one integer that defaults to
zero when reading v1/v2/v3 packages. V5 retains this field and adds mask
semantics. V6 adds layer-panel presentation metadata. Older readers reject
v4/v5/v6 rather than dropping newer layer state.

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
`source_layer_id:u128`. The engine accepts only adjacent, visible standalone
raster siblings in the same parent group, with the target directly below the
source, Normal blending, no clipping, and no sibling or ancestor mask. The
lower target must be at 100% opacity, and every source mark must sit over a
fully opaque target pixel. The engine preflights this coverage before mutation,
then bakes the source opacity into the target pixels and removes the source in
one atomic, undoable, replayable operation. These conservative conditions
preserve composited pixels exactly for any backdrop. Vector, grouped, clipped,
masked, non-adjacent, mismatched-parent, child-bearing, and unsafe-coverage
layers are rejected without changing the document. Safe merge remains
unavailable for masks and dependent effects; command tag 29 retains its
existing wire layout.

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

## Reader memory budget

Standalone `.inkproj` readers and the pages of a studio project use one
aggregate budget. Accounted project data is capped at 768 MiB across decoded
tiles, parsed sidecars, journal payloads, resources, and comic metadata. Zstd
sidecars are decoded only up to the remaining budget, reserving space for the
encoded member, parsed structures, and temporary buffer growth; the projected
load working set is capped at 900 MiB. Studio pages share one budget with their
outer comic structure, rather than receiving an independent allowance per page.
The writer applies the same accounted-data cap so it does not publish a project
that the reader would reject. If reversible history alone prevents a save from
fitting, the writer reduces the saved history window while retaining the newest
undo/redo states that fit; it returns the original memory-limit error if the
artwork and other required data still exceed the cap. These are conservative
estimates, not substitutes for minimum-device peak-memory measurements.

## Client autosave contract

Flutter may attach an autosave coordinator to an open document path. The
coordinator stores no document state: it only coalesces mutation notifications
and calls the Rust save boundary. Pointer packets during a long stroke may
keep the interval alive without postponing the first checkpoint. Rust flushes
the render worker before snapshotting, and the storage layer publishes the
checkpoint atomically. A failed checkpoint leaves the coordinator dirty and
retryable; it must never clear the dirty state or replace the last valid
project on error.
