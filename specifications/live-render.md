# Live stroke rendering contract (Phase 3.5)

The live path is an ephemeral presentation layer. Rust CPU tiles remain the
authority for saved pixels, undo/redo, export, recovery, and deterministic
replay. A bounded dab stream may be consumed by a future native GPU surface,
but it must never become a second document state.

## Dab queue

`ink-live-render` accepts validated `LiveDab` records containing a stable
stroke ID, monotonic sample sequence, canvas position, radius, opacity,
rotation, and one of `Predicted`, `Coalesced`, or `Confirmed` phases. Nonfinite
values and radii above 131072 logical pixels are rejected. The queue has a
fixed capacity: predicted records are evicted first, predicted overflow is
discarded, and the queue reports confirmed overflow. The document engine
converts that preview-only backpressure into a bounded health counter and
continues CPU rasterization, so confirmed document samples are never lost.

The optional wgpu surface retains accepted dabs until an acknowledgement or
explicit cancellation. Replaying a batch replaces an existing `(stroke,
sample sequence, dab index)` record, which makes retries idempotent without
collapsing multiple dabs emitted from one input packet. Acknowledgement
continues to use the input sample sequence, so all dabs from a confirmed
packet retire together.
If its bounded capacity is reached, the surface evicts predicted records
first and reports backpressure rather than silently dropping confirmed dabs.
Acknowledgement and cancellation repaint the target so old overlay pixels do
not remain visible.

The viewport affine matrix is `[a, b, c, d, tx, ty]`, mapping document-space
dab centers to physical surface pixels as `x' = a*x + c*y + tx` and
`y' = b*x + d*y + ty`. Surface generations are monotonic; a stale generation
is rejected.

## Live-dab packet v3

The control plane carries live dabs in a bounded little-endian binary packet,
not JSON. The 8-byte header is `u16 version = 3`, `u16 flags = 0`, and `u32
record_count`. Each record is exactly 56 bytes: `u128 stroke_id`, `u32 sample
sequence`, `u32 dab index`, five `f32` values (`x`, `y`, `radius`, `opacity`,
`rotation`), one phase byte (`0` predicted, `1` coalesced, `2` confirmed),
straight-alpha sRGB RGBA8 color, and seven zero reserved bytes. The dab index
is stable within a sample sequence and is part of the idempotency key; sample
sequence remains the acknowledgement boundary. Receivers reject unknown
header values, phases, nonzero reserved bytes, invalid floats, and any packet
whose length is not exactly `8 + record_count * 56`.

The bundled wgpu shader expands each dab to an antialiased circular quad and
uses the dab's source color and alpha. The renderer target can be read back
only by local correctness tests and spatial-comparison tooling; readback is
not allowed on the interactive pointer path. This is a geometric preview,
not an authoritative reproduction of textured, watercolor, smudge, or other
multi-pass brush effects. Those settle to the CPU result after confirmation.

The Flutter fallback records preview points synchronously on the pointer path,
then sends the packed packet to Rust. The preview remains visible until the
corresponding CPU tile revision has been decoded and published. Cancellation
removes the preview and restores the CPU pre-stroke state.

## Surface limits

Any native surface must be bounded to the visible viewport, no more than
8192x8192 physical pixels and 256 MiB of GPU-owned color storage. It must use
bundled, audited shaders only; downloaded or user-supplied shader code is not
permitted. Surface loss, allocation failure, unsupported adapters, and shader
failure fall back to the CPU/tile painter without canceling the document
stroke.

## Acceptance telemetry

Local traces report pointer-to-preview, pointer-to-committed-tile, tile decode,
and frame-presentation timings separately. Physical 120 Hz (12 ms preview p95)
and 60 Hz (20 ms preview p95) gates require the Phase 5 device runbook; local
Flutter tests verify ordering, cancellation, stale revisions, queue overflow,
and no confirmed-sample loss.

The macOS and iOS runners own bounded IOSurface-backed Flutter texture
registries, connected to the canvas and Rust live-dab lifecycle. On Apple
targets, unique append-only dab batches are rendered into the retained wgpu
surface without rebuilding prior dabs. Android uses a bounded
`SurfaceProducer` texture and hardware-canvas presentation. Dabs are recorded
in cached `RenderNode` groups covering at most eight input sequences and 64 dab
indices each; new packets re-record only affected groups, and the surface
replays cached nodes instead of rebuilding circle draw commands for the whole
stroke on every update. Acknowledgement and cancellation remove or rebuild
affected groups; viewport changes re-record retained groups with the new
transform. The surface buffer estimate remains capped at 256 MiB across the
platform's up-to-three buffers. Flutter submits up to four bounded 2,048-dab
packets in one channel operation; Android records the whole group and publishes
one surface frame so a long-stroke drain does not wait for one display frame
per packet.
CPU acknowledgements are monotonic per stroke. The Flutter controller merges
an acknowledgement burst to its highest committed sequence before asking the
native surface to rebuild, so a CPU commit containing many packet-level
acknowledgements causes one retained-batch rebuild per stroke rather than one
full rebuild per sample. As soon as the matching CPU frame is published, the
Flutter texture is hidden when its retained dabs are fully CPU-covered; native
batch cleanup may finish afterward without delaying the committed canvas.
When no retained dabs remain, the native texture is marked unavailable and
the committed CPU tiles remain the visible result.
Windows and
Linux currently use native pixel-buffer texture registration backed by the
shared `LiveTextureCore` CPU dab rasterizer; this is a presentation/compatibility
path, not proof of GPU dab rendering on those platforms. Both desktop runners
are wired to the bounded v3 channel and Flutter controller, but native
Windows/Linux builds and runtime texture acceptance are still required.

Across connected targets, replacements, viewport changes, acknowledgement, and
cancellation must not leave stale preview pixels. Canvas layout updates the
document-to-physical-pixel matrix; pointer packets schedule bounded dab drains
without waiting in the pointer callback; Flutter switches from its immediate
CPU preview only after a native frame is available. The native overlay retires
confirmed dabs only after the matching CPU composite revision has been decoded
and published. Adapter, packet, queue-overflow, or device failures keep the
Flutter CPU preview active. The Windows/Linux pixel-buffer core preserves the
last published frame when a redraw exceeds its work budget. Physical-device
latency and stylus acceptance remain Phase 5 gates.

The pinned Flutter 3.47.5 macOS Metal embedder does not forward the optional
`onTextureUnregistered` callback. The registry releases its own texture owner
after `unregisterTexture` returns instead of keeping a retirement dictionary
that permanently blocks subsequent surface creation. Flutter's external-texture
wrapper retains the object during pixel-buffer callbacks, and each
`copyPixelBuffer` transfers an independent retained CoreVideo reference to
Flutter. Rust detaches/disposes its surface before native unregistration.
See the upstream [macOS registrar](https://api.flutter.dev/macos-embedder/_flutter_texture_registrar_8mm_source.html)
and [external-texture wrapper](https://api.flutter.dev/macos-embedder/_flutter_external_texture_8mm_source.html).
The debug lifecycle `released` phase describes registry ownership, not receipt
of a raster callback; `requiresUnregisterCallback` is false on macOS.
Once the published CPU frame covers all retained macOS dabs, the texture is
hidden immediately, before the coalesced GPU acknowledgement completes. An
empty cleanup frame must not mark that texture visible again.

Flutter mouse/touch/stylus capture ends at the visible viewport boundary when
the document extends beyond the window. The last accepted input is committed
as one undo transaction, and preview input stops at the same boundary. Re-entry
with the same press does not resume that transaction or interpolate a chord
across the skipped input; a new press starts the next stroke. Page-edge exit
and re-entry within the viewport retain the existing separate-path behavior.
The local trace records `input.viewport_stroke_end` with the source sequence
and pointer kind to distinguish this boundary from page clipping and cancellation.

CPU reference comparison scope, pixel tolerances, adapter skip reporting, and
the required-adapter CI mode are specified in
[engine design guardrails](engine-design-guardrails.md#cpu-reference-and-gpu-preview).
