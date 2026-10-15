# PhotoCraft reuse — Phase 3: non-destructive adjustments

## Scope

Add Levels, Curves, and Hue/Saturation through existing adjustment-layer,
compositor, history, persistence, and export ownership. Existing adjustment
placement rules remain unchanged. Rust validates and evaluates committed
parameters; Flutter holds only a temporary draft and displays Rust preview.

## Parameters and evaluation

- Levels: input/output endpoints are integers 0–255; gamma is hundredths
  10–1000; input black is strictly below input white and output black is at
  most output white.
- Curves: master, red, green, and blue channels; 2–16 ordered points per
  channel; endpoint x coordinates are 0 and 255, x strictly increases, and
  every x/y is an 8-bit value. Fixed-capacity storage uses a
  canonical zero encoding for unused points.
- Hue/Saturation: hue −180…180; saturation and lightness −100…100. Colorize
  and targeted ranges are excluded.
- Compile Levels and Curves to 256-entry LUTs in `ink-compositor`. Apply master
  curve before channel curves. Levels normalize, apply `x^(1/gamma)`, then map
  output endpoints. Curves interpolate piecewise linearly. Hue/Saturation uses
  HSL on existing sRGB channels: saturation is scaled by `1 + percent/100`
  and clamped to 0–1; lightness is offset by `percent/100` and clamped to 0–1.
- Round final 8-bit channel values to nearest with ties away from zero, then
  clamp to 0–255. Keep the existing specified `f32` curve/HSL and `f64` Levels
  evaluation paths stable within a renderer semantic version; changing numeric
  evaluation requires a semantics/version change and golden updates.
- Safely unpremultiply, adjust, and re-premultiply. Preserve alpha exactly;
  zero-alpha remains zero. Identity parameters return original bytes exactly.
- Reuse established scope, opacity, clipping, and mask semantics. Canvas,
  recovery, PNG, and PSD merged composite use the same evaluator.

## Persistence and edit transaction

Coordinate root-format changes against the shared contract and current v8
vector payload. Extend command tag 32 with subtype 1 Levels, 2 Curves, 3
Hue/Saturation; subtype 0 Brightness/Contrast stays byte-compatible. Define
bounded little-endian payloads and reject invalid/unknown data before
mutation. Update layer storage, journal codecs, history snapshots, fixtures,
and `document-format.md` together.

Flutter draft preview calls Rust without dirtying the document or adding
history. Apply is one undoable command; Cancel restores committed projection.
Disable conflicting document/history actions while a preview transaction is
active. Stale preview responses must not overwrite a newer draft/document.

## Acceptance

Cover identity byte equality, alpha edges, zero alpha, group scope, masks,
invalid parameters, unknown subtypes, cancel, one-step undo/redo, recovery,
save/reopen, and identical canvas/export evaluation. Add independent expected
pixel fixtures and confirm merged export. Report installed macOS and Android
workflows separately from deterministic host tests.
