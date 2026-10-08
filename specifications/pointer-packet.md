# Pointer packet v1

Packets are little-endian and versioned. The header is two `u16` values:
`version=1`, then `sample_count`. Each sample is 48 bytes:

```text
u32 pointer_id
u16 flags
u8  device_kind
u8  phase
f32 canvas_x
f32 canvas_y
f32 pressure
f32 tilt_x
f32 tilt_y
f32 azimuth
f32 twist
u64 timestamp_ns
u32 sequence
```

Sensor units are explicit at the wire boundary: `pressure` is normalized to
`[0, 1]`, `tilt_x`/`tilt_y` use signed normalized components, `azimuth` is
radians, and `twist` is a normalized turn in `[0, 1)`. Native adapters convert
platform-specific degrees/radians before encoding. Rust clamps normalized
values again during brush evaluation because packets can arrive from an
untrusted FFI caller.

`canvas_x` and `canvas_y` are logical Flutter screen coordinates in logical
pixels, before the active Flutter viewport transform. Android adapters convert
`MotionEvent` physical pixels by the display density; UIKit adapters already
receive coordinates in points, which map to Flutter logical pixels.

The Rust decoder rejects truncated, trailing, unknown-version, or over-limit
packets, and rejects samples with an unknown lifecycle phase. It does not
silently reinterpret malformed phases as cancellation.
The Dart/native transport seam applies the same 256-sample maximum before
transforming or accounting for a packet.
Native encoders also enforce this maximum. When a platform event contains too
many samples, confirmed samples are retained before coalesced samples, and
predicted samples are retained last; retained samples stay in their original
wire order. This bounds allocation before the packet reaches Dart.
The largest accepted wire packet is 12,292 bytes (`4 + 256 * 48`). The Rust
bridge rejects larger byte buffers before copying them into the render queue.
Predicted samples are disposable. If the bounded worker queue is full of
confirmed input, the producer waits for capacity and then enqueues the original
packet; it must not reject the packet or cancel the active stroke. Confirmed
samples and begin/end phases are never dropped.

The `ERASER` flag makes confirmed dabs clear alpha in the target raster layer
instead of blending color. Erasing an untouched sparse tile does not allocate
that tile. Eraser dabs are part of the same undoable stroke transaction.

Predicted samples are rendered into an ephemeral preview tile overlay. The
overlay is never included in snapshots, undo states, journals, or saved
projects. Confirmed samples rebuild the committed tiles and replace the
overlay; ending or canceling a stroke also clears it and emits dirty-tile
notifications so the Flutter cache cannot retain stale prediction pixels.

All brush engines resample confirmed input incrementally from persistent
conditioning and spacing anchors. Compiled brushes carry their sensor, speed,
global dab-progress, and dual-brush state between packets, so packetization
does not change the generated dabs. Dual-brush companion dabs are deferred
until stroke completion to preserve the established primary-then-secondary
compositing order. The bounded raw-sample allowance is 2,000,000 per stroke,
matching the time-lapse sample limit; emitted dabs remain subject to each
preset's existing work limits. If a stroke exceeds its sample or dab work
limit, Rust stops accepting further samples for that stroke but preserves and
commits the already-rasterized prefix at pointer-up. Hitting a work limit is
not a worker error and must not cancel the stroke or affect subsequent strokes.
The UI should expose a non-blocking warning if a limit is reached. Each new
stroke receives a fresh bounded work budget.

Canvas input keeps finite, bounded raw document coordinates through the bridge.
The Rust worker clips each confirmed pointer segment to the document rectangle;
it must not clamp every outside sample to the edge, which would turn captured
off-page motion into a long border stroke. If a stroke exits the page after
entering it, the accepted portion ends at the page boundary. Captured motion
outside the page is ignored; the first confirmed sample on re-entry resumes
the same stroke as a separate path segment. Brush interpolation must reset at
that boundary so no line or dab chain bridges the off-page gap. Pointer-up or
cancel still closes the single stroke transaction, preserving one undo step.

The Rust bridge validates and enqueues packets for the dedicated render worker;
the enqueue call does not rasterize synchronously. Commands, tile reads, event
drains, snapshots, and saves flush the worker before observing document state.
Revision reads are intentionally non-flushing so the high-frequency Dart path
does not turn each packet into a synchronous render request; the next tile/event
drain observes the committed worker revision.

The opt-in Flutter acceptance trace counts total, confirmed, and predicted
samples from received wire packets. It also records native sequence gaps and
packets rejected by the Rust queue, including rejected confirmed samples. A
physical run cannot claim confirmed-sample delivery when either sequence gaps
or rejected confirmed samples are non-zero.
