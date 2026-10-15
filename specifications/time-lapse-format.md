# Time-lapse JSON format

Time-lapse JSON is a separate export format; it does not change `.inkproj`
root versions. The engine emits format version 2. Readers must reject unknown
future format versions rather than reinterpret them.

## Version 2

The recording contains the format version and a bounded ordered list of
strokes. Limits are 100,000 strokes and 2,000,000 samples per recording. Each
stroke stores the document revision, target layer ID, brush ID, brush preset
revision, brush evaluator semantics, pulled-string flag, stabilization
distance in document pixels, endpoint catch-up flag, and confirmed input
samples (position, 16-bit pressure, tilt, azimuth, twist, and timestamp).

Brush metadata uses the preset's captured values at stroke start:

- `brush_revision` identifies the preset revision; zero is reserved for the
  legacy brush path with no versioned preset.
- `brush_semantics` is 0 for the legacy brush path, 2000 for the format-2
  brush evaluator, or 2001 for pulled-string semantics.
- Semantics 2001 requires a nonzero revision and `pulled_string: true`.
  Distances must be finite and in `0..=100` document pixels. Semantics 0/2000
  require `pulled_string: false`, zero distance, and no catch-up.
- A recording identifies the brush but does not embed its complete preset or
  external brush resources. Replay must resolve the matching brush ID and
  revision from the source project; if unavailable, report that limitation
  instead of silently substituting a different revision.

## Compatibility

Format-1 files remain readable. Their new brush metadata defaults to zero/false,
which identifies the legacy path. Format-1 recordings are read-only; appending
new strokes requires creating a version-2 recording. The JSON reader must
validate metadata and resource bounds before replay or allocation.
