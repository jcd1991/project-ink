# PhotoCraft reuse — Phase 4: pulled-string stabilization

## Scope and compatibility

Add pulled-string path conditioning at the `ink-brush` path-conditioning
boundary before existing distance resampling. Keep legacy smoothing and
format-2 output unchanged. Format-3 presets use semantics 2001 when pulled
string is selected; brush revision and settings are frozen in each recorded
stroke. Settings are `Legacy | PulledString`, distance 0–100 document pixels,
and `catch_up_on_end`.

## Evaluator rules

- Keep conditioner state constant-sized across packets. For the same confirmed
  samples, output is independent of packet/chunk boundaries.
- Consume confirmed samples in order. Predicted input never changes committed
  conditioner state.
- Condition position only; preserve pressure and other sensor values through
  existing resampling policy. Pulled-string bypasses positional legacy
  smoothing to avoid double filtering. Distance zero is unconditioned.
- `finish` emits bounded endpoint catch-up only when enabled. `cancel` emits no
  catch-up and discards transient state. Endpoint lag is no greater than the
  configured document-pixel distance; catch-up is one bounded terminal sample.
- Freeze settings at stroke start. Use existing drain/cancel barriers for
  brush edits, page switches, and document replacement. Do not add packet
  fields or waits to input callbacks.
- [Time-lapse format 2](time-lapse-format.md) records brush ID, preset revision, evaluator semantics,
  pulled-string selection, document-pixel distance, and end catch-up setting
  beside confirmed samples. Format-1 exports remain readable with legacy
  defaults; new exports identify themselves as format 2.
- Preview committed geometry from the same Rust-conditioned path. A raw cursor
  may remain separate; any raw-path preview is ephemeral and visibly distinct.

## Acceptance

Verify chunk equivalence, tap/short/long strokes, endpoint behavior, cancel,
pressure ramps, rapid brush switching, replay, save/reopen, and unchanged
legacy golden output. Confirm preview/commit geometry parity and test real
stylus endpoints and pressure on target devices. Host simulation is not
physical acceptance.
