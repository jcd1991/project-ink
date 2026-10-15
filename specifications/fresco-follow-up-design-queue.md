# Fresco-informed follow-up design queue

This queue turns the follow-up ideas in
[`fresco-workflow-baseline.md`](fresco-workflow-baseline.md) into independent,
reviewable specification assignments. These are design tasks, not permission to
implement the features. Assign one item at a time after reviewing the relevant
current implementation. A design is complete when it names owners, contracts,
risks, acceptance tests, and a staged delivery plan without inventing support
that the repository does not have.

## Shared instructions for each assignment

> Work only on the assigned design item. Read `AGENTS.md`, inspect the current
> branch and working-tree diff, and preserve all existing changes. Read the
> nearest current specifications and inspect the code that owns the workflow
> before proposing new behavior. Cite repository paths and observed APIs in the
> design so reviewers can distinguish evidence from assumptions.
>
> Write or update only the named specification. Do not implement features,
> change code, formats, dependencies, or generated files. Rust remains the
> authority for document/project state, pixels, layers, history, persistence,
> and export. Keep local-first behavior and the existing provider and recovery
> guarantees. If an existing contract blocks the idea, describe the smallest
> versioned contract proposal and migration questions; do not work around it.
>
> The design must include: user problem and evidence; current capability audit;
> platform scope; ownership and data flow; proposed UX; persistence/export
> effects; accessibility and resource bounds; failure/recovery behavior;
> non-goals; acceptance scenarios; validation by host test and physical device
> where applicable; rollout sequence; and unresolved product decisions. Report
> changed docs, observed evidence, assumptions, and tests not run.

## D1 — Reference surface and extracted image palettes

**Output:** `specifications/reference-surface-and-image-palettes.md`

Audit the current reference-layer flag, image import path, color sampler,
workspace persistence, and export paths. Design a reference surface that stays
outside paint layers and artwork compositing. Specify bounded image decoding,
maximum dimensions/bytes and failure behavior, local asset ownership, placement
and transform controls, color sampling coordinates/color space, and palette
extraction with duplicate handling and editable swatches. State whether
references belong to a project package or a device-local sidecar and how
missing assets recover. References must not appear in rendered exports unless
the user explicitly opts into a separately designed operation.

**Acceptance scenarios:** large or malformed files fail without destabilizing
the canvas; changing reference visibility never changes artwork or undo state;
sampling returns the expected color after zoom/rotation; reopen and export
behavior is explicit; accessibility labels cover reference controls.

## D2 — Project gallery, presets, and safe duplication

**Output:** `specifications/project-gallery.md`

Audit the recent-project service, document picker, project creation dialog,
thumbnail/render APIs, and local/provider document capabilities. Design a
gallery that builds on recents with creation presets, project thumbnails, and
safe duplication. Define thumbnail freshness and memory/disk bounds, missing or
corrupt project presentation, and duplication semantics for project sidecars,
comic assets, recovery data, and name collisions. Keep unavailable entries
visible and preserve the active project if a destination or copy fails.

Do not include cloud sync or provider-backed projects until durable provider
identity and reopen/write-back semantics are demonstrated. A staged provider
copy path is not a durable identity.

**Acceptance scenarios:** recents remain correct across restart; a duplicate is
independent and opens successfully; cancellation or partial failure leaves the
source intact; thumbnails never become the authoritative project state.

## D3 — Multipage comic PDF export

**Output:** `specifications/comic-pdf-export.md`

Audit the Rust comic project model, authoritative page render plans, existing
PDF/export code, lettering/font behavior, and current raster/vector output.
Define page order, page boxes, print size and DPI, bleed/trim policy, color
handling, font embedding or outlining, transparent content, and how vectors,
balloons, and screentones are represented. Identify exactly when rasterization
occurs and require a user-visible warning before lossy export. Specify
page-level and whole-document failures, cancellation, and output atomicity.

**Acceptance scenarios:** mixed page dimensions are represented intentionally;
fonts missing on the host produce a clear result; vector preservation claims
are tested in the actual PDF; failed export does not leave a file that appears
complete.

## D4 — Faithful playable time-lapse

**Output:** update `specifications/time-lapse-format.md` or add
`specifications/playable-timelapse.md` after auditing the existing format.

Audit current recording events, replay behavior, brush serialization/resources,
layer and mask mutations, image imports, undo grouping, and the existing
time-lapse version contract. Separate a faithful replay from a simplified
stroke-only recording. Enumerate which edits are captured, which cannot be
reproduced, and what resource snapshot or stable references are required.
Define bounded event/resource sizes, deterministic ordering, forward-version
rejection, privacy/local-storage behavior, and recovery after truncated data.

Do not call a recording faithful unless replay reproduces the saved result for
the supported operation set. Do not change the existing JSON format in this
design task.

**Acceptance scenarios:** paint, erase, mask, layer changes, imported content,
undo/redo, and brush-resource availability each have an explicit supported or
rejected outcome; truncated and oversized recordings fail safely; replay is
compared to the original rendered result.

## D5 — Read-only browser viewer package

**Output:** `specifications/browser-viewer-package.md`

Audit project/comic export formats, local asset loading, and security boundaries.
Design an offline package exported by the native app for viewing, page
navigation, zoom, and optional presentation mode. Keep browser state read-only;
do not treat `.inkproj` as a browser-editing contract. Specify package version,
asset paths, integrity checks, size bounds, compatibility behavior, and defenses
against path traversal, executable embedded content, and untrusted text or
fonts. Explain what is flattened and what remains navigable.

**Acceptance scenarios:** package opens without an account or network; pages
and navigation work with local assets; malformed packages cannot escape their
root or execute imported content; no viewer action can mutate the source
project.

## D6 — Timeline animation

**Output:** `specifications/timeline-animation-design.md`

Audit Rust document state, layer identity, command history, rendering, comic
timeline concepts, and available export paths. Propose Rust-owned animation
tracks/frames and playback state without duplicating document authority in
Dart. Specify frame/layer ownership, keyframe semantics, onion-skin composition,
playback timing, undo grouping, autosave interaction, persistence versioning,
and bounded export. Treat motion paths as a later extension and keep them out of
the first animation milestone.

**Acceptance scenarios:** editing a frame is undoable and survives save/reopen;
onion skin affects only presentation; playback does not mutate the document;
large timelines have documented memory and render budgets; exports declare
their raster/vector fidelity.

## Ordering and review gates

Run D1 and D2 after reviewing the recent-project implementation. Run D3 and D4
as separate export/persistence designs. Run D5 after choosing a supported comic
or project package boundary. Run D6 only after the current Rust persistence and
history contracts are mapped. These items may be researched independently, but
do not combine their implementation proposals into one feature branch.

Before accepting any design, reviewers should verify that it:

- cites inspected repository behavior and marks unknown behavior as unknown;
- preserves the single Rust document authority and local-first operation;
- identifies versioned-format/API changes instead of assuming compatibility;
- includes an undo, save/reopen, failure, and accessibility acceptance path;
- separates unit/host evidence from installed-device acceptance; and
- gives an initial small milestone with explicit non-goals.

Vector intersection trimming, multicolor brush sampling, arbitrary off-canvas
artwork, and richer wet-paint simulation remain deferred to separate engine
contracts and performance budgets.
