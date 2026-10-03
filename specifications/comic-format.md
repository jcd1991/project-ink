# Comic project model v2

Phase 3 comic structure is Rust-owned and serialized independently from raster
tiles. A `ComicProject` contains a bounded ordered page list, print/webtoon
page metadata, editable panels, balloons/dialogue, nondestructive screentones,
effect lines, and local material attribution records. Flutter receives only
immutable projections through the FRB `ComicProjectHandle` API.

## Safety and compatibility

- `format_version` is `2`; unknown versions are rejected before mutation.
- A v1 payload is migrated in memory by adding one validated
  page-document reference per existing page and deterministic panel-layer
  bindings for every existing panel. Source bytes are never rewritten during
  load; canonical v2 bytes are published only by a successful save.
- Maximums are validated before a project becomes live: 512 pages, 256 panels
  per page,
  512 balloons per page, 256 tones, 2,048 effect lines, 4,096 vector-ink
  lines, and 16 KiB dialogue. The sum of `width_px * height_px` across all
  pages is capped at 128 me pixels; the same cap applies when adding pages.
  Import rejects an over-limit comic before loading any referenced page
  documents, and page addition leaves the project unchanged on rejection.
- All geometry, DPI, tone, and effect values must be finite and range checked.
- IDs are stable `u128` values and must be unique across pages and comic
  objects; panel-layer IDs must also be non-zero and unique across bindings.
  Balloon-to-panel references are validated on import.
- JSON imports are capped at 64 MiB and validated before becoming a live
  handle. Export paths reject parent-directory traversal.
- Material records carry license, attribution, and source metadata; they do
  not execute code or resolve network URLs.

Each page has a stable `PageDocumentRef` containing the page ID, document ID,
and exact relative path `pages/<page_id as 32 lowercase hex digits>`. Each
panel has a `PanelLayerBinding` containing generated panel-group, mask, and
Sketch/Ink/Color/Tone/Effects child-layer IDs. These references are validated
against the page/panel graph and are not UI list indexes. Unified project open
and project-boundary panel creation materialize the tree and rasterize the
panel polygon into its sparse mask tiles before the page is presented.
Bindings remain serialized as `u128`; newly generated layer IDs stay within
the positive signed-64-bit range because the current Flutter layer-selection
API transports IDs as Dart `int`. Existing v2 projects retain their stored
binding values on load; migration of projects written with the earlier
out-of-range namespace is a separate compatibility gate.

The v2 metadata is portable and source-preserving. The v2 studio storage
loader materializes each referenced page document below the same `.inkproj`
root, creates any missing panel layer trees atomically, and validates all page
snapshots before publishing the replacement. A failed page save leaves the
previous root and its recovery sibling intact.

## Page and panel semantics

Each page stores pixel dimensions, DPI, bleed, trim, safety insets, and page
number. Rectangular and polygonal panels carry editable geometry, gutter width,
and an optional linked mask-layer ID. Polygon edits preserve the same panel ID
and linked mask, so changing shape or gutter changes only panel structure;
raster/vector contents remain untouched and the operation is safe to undo when
integrated with the document command history. Rectangular panels can be
divided on either axis at a bounded ratio; the first resulting panel retains
the linked mask, the second receives a deterministic linked-mask identity in
the mask metadata namespace, and balloons linked to the original panel are
retargeted before the new structure is published. Derived mask collisions are
rejected before mutation.

In the Flutter canvas, the panel inspector's **Draw inside panel** action
converts selected page-space geometry into the active document space, ensures
the panel tree exists, updates its persistent sparse mask, and installs Rust's
bounded lasso selection mask for the active gesture. Repeating the action
clears the transient selection while the persistent panel mask remains the
document boundary. Guides are presentation-only, scale to the active canvas,
and never render an opaque preview above user strokes.

Pages may also contain bounded vector-ink lines for lightweight comic artwork
and deterministic fixtures. Each line stores finite points, width, and RGBA
color; it is serialized with the page, emitted in SVG, and included in the
Rust raster preview. These lines are not a replacement for the main document
engine's full raster/vector layer stack.

Page layout metadata is editable through validated Rust commands. DPI, bleed,
trim, and safety values are checked before mutation; an invalid safety inset
cannot consume the page, and a rejected edit leaves panels, balloons, and ink
lines unchanged. Rectangular panel bounds can likewise be moved or resized
without repainting content, but they and polygon vertices must remain inside
the page canvas. Out-of-canvas edits are rejected before mutation. Polygon
panels remain on the explicit polygon editing path so a rectangle edit can
never silently discard polygon vertices.

The unified bridge exposes project-boundary resize, polygon, and split
operations. Each validates comic metadata first, then materializes or reuses
the linked page-document layer tree and rewrites the generated sparse mask.
The Flutter comic controller now uses `StudioProjectHandle` for metadata,
validated page activation, project-manager structural undo/redo, and complete
project saves. The canvas receives an Arc-backed capability to the active page
document, so drawing, layers, tiles, and persistence share the same Rust state.
A bounded host callback remains only for compatibility panel-mask geometry
updates; it is not a second document authority.

## Dialogue and effects

Balloons support oval, thought, narration, and burst shapes with editable tails,
panel links, horizontal/vertical text, font fallback name, fill/outline style,
and bounded text. Preview/export must preserve shape identity: thought balloons
render as an oval with two detached bubble nodes, burst balloons render as a
bounded star polygon, narration uses a rounded rectangle, and all stored tails
remain visible. Dialogue search is case-insensitive and returns page, balloon,
and UTF-8 byte offsets. Tone layers store frequency, angle, density, shape, and
bounded coverage. Effect lines store a named kind, polyline, width, and opacity.
Materials are local project records only: each carries a bounded name, kind,
license, optional attribution, and optional source string. The authoring UI
collects those fields before persistence, while Rust validates the bounds and
stores the values in the project. They are displayed as attribution metadata
and are never resolved, downloaded, or executed by the engine.

## Webtoon and acceptance fixture

`webtoon_segments` deterministically divides a page into bounded export slices
without repainting source content. Batch export can emit bounded JSON manifests,
full self-contained SVG pages, or cropped SVG segments whose viewBox preserves
the original page coordinates. SVG output is structural and
offline: it includes panels, linked mask IDs, balloons/text, tone patterns,
and effect-line polylines, while escaping all user text and font metadata and
emitting no scripts, external URLs, or embedded executable content. The
portable render digest is SHA-256 over canonical project JSON, each page's
deterministic SVG bytes, and its bounded 1024-pixel raster preview; it gives a
transfer check that is independent of platform filesystem order or font caches.
`xkcd_stick_figure_comic()` creates an eight-page, four-panel-per-page
stick-figure fixture for create/close/recover, page reorder, gutter,
dialogue-search, JSON/SVG export, JSON round-trip, and segmentation tests.

## Raster print-preview boundary

`render_page_preview` produces a bounded RGBA PNG for the selected page. The
Rust renderer scales the page to a caller-provided dimension (64–4096 pixels,
16 million pixels maximum) and deterministically draws trim/safety guides,
panel outlines, screentone marks, effect-line polylines, balloon tails and
outlines, and an offline text-length stub. It does not load fonts, external
resources, or network content, so it is safe for print-layout inspection and
stable in tests. Final production export remains responsible for font shaping
and real text rasterization; the preview must not be presented as a proof of
final typography or color management. The unified Studio project batch PNG
action exports the actual flattened composite of each page drawing document
(including its white page background) as `page-####.png`. This is an
artwork-only export: it does not yet composite comic-owned panels, balloons,
dialogue, tones, effect lines, or trim/safety guides into those PNGs. The
separate structural SVG export remains available on the compatibility
comic-project API; do not mistake either path for print-ready PDF/PSD or a
fully lettered comic-page export.
The main Flutter canvas may draw the stored balloon text, font fallback, text
orientation, and outline as a local UI overlay above this deterministic PNG;
that overlay is presentation-only and does not change Rust preview hashes or
the saved comic structure.
