# Canvas diagnostic trace

Project Ink maintains a device-local rolling log for investigating input,
brush rendering, canvas presentation, and native device failures. It starts
when the app starts, runs without a canvas toolbar control, and never uploads
data. Failure to initialize the log does not prevent the editor from opening.

## Captured data

The recorder writes newline-delimited JSON to the app's private
`Documents/Project Ink/Diagnostics` folder. Each row has a monotonically
increasing `seq`, elapsed `tUs`, and event `type`. A `log.start` row identifies
the app process and a `canvas.session_started` row records the active canvas
context. A `log.segment_rotated` row marks segment changes and reports any rows
dropped while the file was being rotated.

- `input.native_packet` captures the exact incoming UIKit Pencil packet, then
  the packet after native queue compaction. `input.engine_packet` captures the
  coordinates and flags actually passed to Rust after viewport transform,
  canvas clipping, and eraser handling. Flutter touch/stylus packets are
  recorded at the engine boundary as well. Packets are base64-encoded and use
  pointer-packet v1: a four-byte little-endian header followed by 48-byte
  samples, as defined in `pointer-packet.md`.
- `canvas.gpu_dab_batch` stores Rust-generated live-dab output packets (format
  v3, 56-byte records, as defined in `live-render.md`). GPU surface setup,
  frame-available notifications, acknowledgements, cancellations, overflow,
  and failure events record the preview handoff.
- `canvas.cpu_composite_tile` records the revision, tile coordinates, byte
  count, and FNV-1a checksum for each accepted committed composite tile. Exact
  tile bytes are included after stroke commit so the persisted CPU output can
  be compared with the live GPU dab stream. Live tile updates use checksums
  only to keep the trace small.
- `canvas.cpu_frame_presented` marks the post-frame Flutter presentation with
  its document revision and dirty-tile count.
- `native.*` records low-rate UIKit Pencil events such as contact, estimated
  force revisions, cancellation, dropped/rejected pointer packets, and Metal
  texture errors. `error` records caught Flutter, Rust-bridge, storage, and
  renderer failures with stack traces when available.

The recorder rotates at 32 MiB and retains at most the current and previous
segment (64 MiB total). It prunes older segments when a new log starts or
rotates. Segments are flushed at rotation and graceful shutdown; an abrupt app
exit may leave the last buffered rows unwritten. The app records document
dimensions and rendering context but omits document names and file paths.
Pointer coordinates, pressure, brush-color dabs, and committed tile pixels can
reveal artwork. Keep the private app-container logs secure. Developers can
retrieve them with the platform device tools; there is no in-app capture or
export UI.

The recorder captures errors visible to Project Ink. It cannot collect
operating-system crash reports or failures hidden inside iPadOS; those require
the platform's separate device diagnostic tools.
