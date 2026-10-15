# PhotoCraft reuse integration contract

Status: implementation contract for the PhotoCraft-derived work in Project
Ink. This document is subordinate to `AGENTS.md`, existing format specs, and
the implementation. It records integration constraints and handoff rules.

## Ownership and provenance

- Rust remains authoritative for document content, pixels, brush evaluation,
  text shaping, history, persistence, and export. Flutter submits commands and
  presents immutable projections.
- Keep the text engine leaf-level: `ink-text` may depend on font/shaping
  libraries and `ink-model`, but not on `ink-comic`, `ink-engine`, Flutter, or
  platform font services. Comic rendering consumes its value results.
- Keep import parsers below engine conversion. Parsers inspect bounded source
  data; `ink-engine` validates a detached candidate and publishes only after
  the document replacement barrier succeeds.
- Keep bridge exports thin and handwritten. FRB runtime, generator, and Dart
  runtime stay pinned to 2.13.0. Regenerate bindings with `scripts/generate_frb.sh`
  and review Rust and Dart output together.
- PhotoCraft-derived code is pinned to
  `5ecc860ac1abf8fa7e3f218c0474cdcce49fa6c7`. Vendor only required parser,
  layout, adjustment, and conditioning components. Preserve upstream notices,
  mark local modifications, and do not import its application/document or
  painting-engine ownership. Use the compatible MIT route for copied code.
- Bundled Noto Sans CJK JP and Noto Serif CJK JP assets are pinned to Noto CJK
  commit `f8d157532fbfaeda587e826d4cd5b21a49186f7c`; record hashes and OFL
  notices next to the assets. Font size and package impact belong in release
  notes.

## Compatibility and version domains

- The checkout already writes root `.inkproj` format 8 with
  `vector_semantics: 1`; do not apply the earlier proposal to reset it to 7.
  Any new persistent root capability must either fit the documented v8
  payload with strict unknown-value rejection or introduce the next explicit
  root format version. Update `document-format.md`, storage fixtures, journal
  codecs, and history snapshots together. Legacy reads remain source-preserving
  until an explicit successful save.
- Comic metadata is format 3 with `render_semantics: 1`. Brush presets use
  format 3 only for pulled-string semantics 2001; format-2 presets retain the
  semantics-2000 evaluator. These versions are independent of the root format.
- Reject unsupported versions, semantics, malformed parameters, and unknown
  tagged variants before mutation. Never silently drop data on open, import,
  replay, or save.
- Retain sparse premultiplied BGRA tiles, copy-on-write snapshots, bounded
  memory, serialized stroke work, atomic save/export, no-overwrite behavior,
  and the document replacement barrier.

## Failure, async, and resource rules

- Preflight limits before allocation or decompression wherever the parser
  permits; checking only after materialization is insufficient. Include source,
  decoded channels, masks, candidate state, composites, and parser working set
  in memory estimates.
- Import into detached state. Cancellation, malformed input, allocation
  rejection, conversion failure, or replacement failure leaves the active
  document and source bytes untouched.
- Export from one coherent revision after accepted edits drain. Stage and
  sync outputs before publication; batch failure publishes no partial batch.
- Async render/import results carry a document/page generation and must be
  discarded after page switch, document replacement, or owner disposal.
- Keep shaped glyphs and export caches derived. Bound caches and render tiles;
  never allocate an unbounded full-page overlay for interactive display.
- Do not copy user artwork, private diagnostics, generated build products, or
  unrelated alpha preparation files into these feature commits.

## Phase delivery and verification

Each phase has its own spec and reviewable diff. Implementation assignments
should state the phase/task ID, owner modules, allowed format/API changes,
fixtures, acceptance gates, exclusions, and baseline files to preserve.
Implementation reports list behavior changed, commands actually run, results,
and remaining device gates. Do not merge phases into a single feature commit.

Run focused deterministic tests first, then the Rust workspace and Flutter
gates appropriate to changed code. Regenerate FRB when exported interfaces
change. Validate macOS installed interaction first, connected Android with
real S Pen second, and iOS compile separately from installed iOS interaction.
Host builds and synthetic pointer tests never count as physical-device
acceptance. Report test/build/install/device evidence separately.

ICC conversion, CMYK, higher bit depths, custom font import, full Photoshop
compatibility, and broader PhotoCraft parity are explicitly deferred.
