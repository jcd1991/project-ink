# Comic project model v3

Phase 3 comic structure is Rust-owned and serialized independently from raster
tiles. A `ComicProject` contains a bounded ordered page list, print/webtoon
page metadata, editable panels, balloons/dialogue, nondestructive screentones,
effect lines, and local material attribution records. Flutter receives only
immutable projections through the FRB `ComicProjectHandle` API.

## Safety and compatibility

- `format_version` is `3` and `render_semantics` is `1`; unsupported versions
  or renderer semantics are rejected before mutation.
- A v1 payload is migrated in memory by adding one validated
  page-document reference per existing page and deterministic panel-layer
  bindings for every existing panel. Source bytes are never rewritten during
  load; canonical v3 bytes are published only by a successful save.
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

The v3 metadata is portable and source-preserving. The v2 studio storage
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

## Shared Illustration Panel tool

The Illustration workspace exposes one **Panel divider** tool through the
same tool palette in Simple and Studio layouts. The tool edits the existing
illustration's Rust-owned `ComicProject` panel graph and layer masks. Finishing
a preset, split, divider drag, or style edit applies the outlines to a separate
ordinary raster layer named **Panel Frames**; the shared document keeps them
editable with the normal brush eraser and layer controls. The one-page
illustration project shares the active `DocumentHandle`, so existing artwork
remains in place and normal canvas edits continue against the same document.

On a blank panel map, **2 panels** creates two columns, **3 panels** creates
three stacked rows, and **4 panels** creates a 2×2 grid. A one-finger drag
across a frame creates a split perpendicular to the drag direction. Dragging
the center of an existing gutter moves that divider while keeping the gutter
centered. The Gutter control changes the spacing between aligned rectangular
panels while preserving each divider center and the outside frame bounds; the
Border control changes the outline width. Both controls update masks and panel
metadata in one structural history operation, then refresh the applied Panel
Frames layer. Presets are only offered before panels exist, so applying one
cannot discard an existing layout. Cyan/green editing guides are temporary:
they show only while the Panel divider tool is active. Leaving the tool hides
the preview; applied borders remain as ordinary layer pixels. Clearing the
Panel Frames layer or erasing its pixels does not remove the structural panel
map. Remove a frame from the Comic **Panel** inspector's **Remove panel**
action; this updates the structural map and any applied Panel Frames layer as
one undoable edit. Existing artwork layers remain in the page document, and
dialogue linked to the removed panel becomes page-level dialogue. A later panel
geometry/style edit reapplies the current full outline set.

The interaction supports direct frame editing on touch and desktop: one-finger
frame division, adjustable spacing and border thickness, editable boundaries,
and equal-division presets. Project Ink keeps these controls inside the shared
Illustration tool set rather than introducing a separate phone-only workspace.

Acceptance applies to the shared Simple and Studio canvas on iOS/iPadOS,
macOS, and Android: open an illustration that already has artwork; create a
2-, 3-, or 4-panel layout; draw over it; split and drag a divider; change gutter
and border; undo/redo each committed panel operation; save and reopen; and
confirm both the artwork and editable panels remain. Device-specific stylus
coordinates and touch delivery still require the physical-device acceptance
path; host builds and automated tests establish compile and model behavior only.

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

Opening the Comic workspace does not create or attach example artwork. With no
project open, the workspace stays empty and offers explicit **New print comic**
and **New webtoon** actions. A new print comic starts as a blank page with no
panels or artwork; artists add frames and content deliberately. Startup
recovery inspects the package manifest and routes multi-page Studio packages through
`openStudioProject`; an unreadable recovery is not replaced by a blank document.

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

The SVG frame geometry carries its stable decimal `data-panel-id`; each dialogue
text node carries `data-balloon-id` and, when linked, `data-balloon-panel-id`.
These values match the serialized comic IDs, so exported dialogue remains
associated with its panel without relying on display order. Unified page SVG
exports may embed the page's PNG artwork beneath this editable comic structure.

## Raster print-preview and lettering boundary

`render_page_preview` produces a bounded RGBA PNG for the selected page. It
uses bundled Noto Sans/Serif CJK JP fonts, Parley shaping and Skrifa glyph
outlines without consulting system fonts. Existing v1/v2 projects migrate in
memory without editing the source file. A bounded Rust preflight reports
unsupported font fallbacks, missing glyphs and balloon overflow. Batch PNG/SVG
and webtoon SVG export reject warning-bearing output unless the Flutter export
flow explicitly passes the artist's **Export with warnings** choice.

The active canvas receives a second bounded `render_page_overlay_preview`
result. It has a transparent background, includes comic-owned ink, tones,
effects, balloon fills/tails and lettering, and omits artwork, trim/safety
guides and structural panel borders. Flutter aligns this image with the active
page transform and draws editable panel guides separately. A page change or
document replacement invalidates pending overlay results before they can be
published.

Raster and SVG dialogue are clipped to the one-font-size-inset balloon text
rectangle. The warning list identifies unsupported font families with the
selected deterministic fallback, missing bundled glyphs, and overflow before
the export destination is written.

The preview remains bounded to a 4096-pixel maximum dimension and includes
trim/safety guides. Batch PNG export composites page artwork with comic panels,
ink, tones, effects, balloons and glyph lettering at the page's actual
dimensions; it omits trim/safety guides. SVG embeds only artwork PNG beneath
comic geometry, emits lettering as glyph paths, and retains balloon/panel IDs.
The same comic geometry is composed once in both formats. PDF/PSD output and
full print color management remain unsupported.
