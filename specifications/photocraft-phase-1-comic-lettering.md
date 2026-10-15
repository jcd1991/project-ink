# PhotoCraft reuse — Phase 1: comic lettering and export

## Goal and ownership

The canvas preview, PNG export, and SVG export must render the same committed
comic content. `ink-text` owns deterministic shaping, glyph outlines, and
coverage. `ink-comic` owns the comic render plan; `ink-engine` supplies a
coherent page snapshot; `ink-export` composes output; Flutter displays Rust
projections and editor-only guides. Flutter must not independently shape
committed dialogue.

Transport-neutral minimum values are a layout request (UTF-8 text, resolved
family, size, orientation, bounded content rectangle), a layout result
(positioned glyph outlines, UTF-8 cluster ranges, content bounds, typed
warnings), and an ordered page render plan with editor guides represented
separately. Warnings identify unsupported family fallback, missing glyph, or
overflow and the affected balloon.

## Font and layout behavior

- Bundle unmodified regular Noto Sans CJK JP and Noto Serif CJK JP from the
  pinned commit in the shared contract. Preserve OFL notices and asset hashes.
- Resolve `sans-serif` and `serif` deterministically. Preserve unknown stored
  family strings, select the corresponding bundled fallback, and report it.
- Support Japanese horizontal and vertical dialogue. Use bundled glyph
  coverage for other CJK characters; visibly represent and report missing
  glyphs. Do not consult platform fonts.
- Horizontal dialogue is centered and wraps at Unicode cluster boundaries.
  Vertical dialogue flows top-to-bottom with columns right-to-left; apply
  vertical metrics and punctuation substitutions. Rotate Latin runs clockwise.
  Ruby and tate-chu-yoko are deferred.
- Inset the balloon content rectangle by one font size. Line/column advance is
  `1.2 * font_size_px`. Preserve explicit newlines and stored text. Never
  truncate or auto-shrink. Clip visual overflow and report it.
- Export with missing glyphs or overflow only after explicit “Export with
  warnings” confirmation. Show the full bounded preflight report in a
  scrollable dialog, identify affected pages/balloons, and recheck that report
  before publishing if the project may have changed while the dialog was open.

## Render and export contract

- Generate balloon shapes, tails, outlines, and glyphs from the same Rust plan.
  Selection handles, trim/safety guides, and editor highlights are excluded.
- PNG uses page pixel dimensions and the established page background policy.
  It includes artwork, comic-owned ink, tones, effects, panels where structural
  output requires them, balloons, and dialogue exactly once.
- SVG embeds artwork-only raster content and adds comic geometry once. Emit
  text as glyph paths and retain escaped source text plus stable balloon/panel
  IDs as metadata. Never embed a final comic PNG beneath a second comic overlay.
- Paint-layer panel borders remain artwork. Structural panel lines remain
  guides unless the export format explicitly includes comic structure; do not
  duplicate or bake them as an incidental side effect.
- Preflight and export use a coherent page/comic revision after accepted edits
  drain. Keep no-overwrite and all-or-nothing batch publication guarantees.
- Cache layout by text, style, bounds, font bundle, and rendering semantics;
  bound glyph/layout caches to 64 MiB. Rasterize bounded tiles. Drop stale
  results after page/document generation changes or disposal.

## Acceptance and evidence

Use a two-page stick-figure comic with Latin and Japanese dialogue, including
vertical punctuation. Verify edit, undo/redo, save, quit, reopen, PNG and SVG.
Both exports must preserve lettering and tails once, retain IDs/metadata, and
omit guides. Inspect dimensions, transparency/background, and representative
pixels/paths. Include warnings and destination-failure cases.

Separate Rust fixtures, Flutter projection tests, installed macOS results,
real Android interaction, and iOS compile/device results. Passing a renderer
unit test does not establish an installed artist journey.
