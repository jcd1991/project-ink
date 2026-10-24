# Project Ink brush engine and preset format v2

Status: Phase 2 implementation specification. Phase 1 `BrushPreset` values are
legacy built-ins and must migrate into this schema without changing their
recorded-stroke output.

This specification defines a configurable, deterministic CPU brush engine for
sketching, inking, painting, digital watercolor, smudging, decoration, and
effects. It also defines the native `.inkbrush` and `.inkbrushpack` formats.
External-format conversion policy is specified in
[`brush-import-compatibility.md`](brush-import-compatibility.md).

Format-3 pulled-string compatibility is specified below. Format-2 presets and
evaluator semantics remain unchanged.

`CPU_BRUSH_V4` synchronizes pressure with the smoothed sample position. V2 and
V3 strokes retain their historical pressure sampling during replay. Brush edits
that pass through the current draft editor store V4 semantics so subsequent
strokes use the aligned sensor path; existing strokes keep their captured
semantics.

## Product goals

The Phase 2 brush system must:

- Feel responsive on iPad, Android tablets and phones, and desktop tablets.
- Cover a broad range of illustration workflows without copying another
  application's interface or proprietary data.
- Let artists duplicate, edit, preview, tag, favorite, import, and export
  brushes without an account or network connection.
- Keep every preset declarative. A brush or brush pack may never contain
  executable code, shaders, scripts, native libraries, or network references.
- Produce identical committed pixels for the same document, preset, stroke,
  engine-semantics version, and resources on arm64 and x64.
- Bound CPU, memory, archive expansion, resource dimensions, dab count, and
  history growth before allocating or rendering.
- Preserve authorship, license, attribution, source-format, and conversion
  metadata without treating imported resources as Project Ink-owned content.

Exact rendering parity with another application's brush engine is not a goal.
The importer reports which properties were mapped, approximated, or omitted.

Brush tuning improvements may use public references such as Photocraft's
response-curve editor and dynamic-parameter model as design input. Ink keeps its
own evaluator, serialized preset format, and precision: normalized curve points
are validated as finite values in `[0, 1]` with strictly increasing X, and must
not be rounded to two decimal places. Upstream code, presets, and bitmap assets
are separate reuse decisions; record source revision and required attribution
for any code or resource actually adapted.

The starter library includes four explicitly labeled, editable-by-duplication
experimental references: Inking Pen, Tilt Pencil, Flow Marker, and Calligraphic
Raster. They copy Ink's own procedural presets and exercise existing pressure,
tilt, flow, and elliptical-tip controls. They are tuning references, not
promoted defaults or claims of Apple Pencil/S Pen acceptance.

The editor exposes independent pressure responses for diameter (Size),
opacity, and flow using the existing `ParameterBinding` evaluator. Ordinary
brush draft commits preserve each response curve. The legacy shared-curve
settings command retains its historical behavior of applying one curve to all
pressure bindings. A response with multiple pressure bindings for the same
parameter is projected read-only until the editor can represent each binding
without flattening it. Disabling a response sets its amount to zero and keeps
its curve; enabling a response with no prior amount starts at amount `1.0`.

Photocraft review reference: `storytold/photocraft` main tree
`b07b7fab559ce2f7c3ba7ef80b7fb50c3aad170e`. Its response editor and dynamic
parameter concepts informed the controls; no upstream code or brush resources
are copied by this change.

## Phase boundary

Phase 2 includes visually convincing digital media:

- textured pencils, charcoal, chalk, pastel, and colored pencil;
- technical pens, pressure pens, brush pens, dry ink, calligraphy, and pixel
  brushes;
- opaque, glazing, marker, gouache, acrylic, airbrush, bristle, rake, and
  palette-knife-style brushes;
- canvas color pickup, RGB mixing, smudge, blur, and textured blenders;
- digital watercolor washes, paper grain, granulation, edge pooling, glazing,
  and controlled bleed-style softening;
- spray, spatter, foliage, hair, cloud, ribbon, pattern, hatch, halftone,
  noise, glow, and dual brushes.

Phase 5 retains physically based features:

- time-evolving wet-canvas diffusion after the stylus stops;
- spectral/Kubelka-Munk pigment mixing;
- fluid flow, backruns, blooms, salt chemistry, impasto height, and lighting;
- GPU-compute-only brush execution;
- 16-bit, HDR, Display P3, and CMYK brush pipelines.

Phase 2 watercolor therefore means a deterministic digital approximation made
from deposits, pickup, texture, edge accumulation, and bounded blur. It must be
artistically useful, but must not be described as physical pigment simulation.

## Runtime pipeline

Every brush compiles into the same bounded pipeline. Optional stages are
disabled at compile time for a preset rather than branched per pixel.

```text
pointer samples
  -> input validation and quantization
  -> stabilization and taper
  -> distance/time resampling
  -> derived sensors and parameter curves
  -> dab or particle generation
  -> tip/ribbon/bristle coverage
  -> grain and paper modulation
  -> source color, canvas pickup, and color dynamics
  -> deposit/smudge/erase composite
  -> optional stroke-finalization effects
  -> dirty tiles and undo snapshot
```

The preset compiler validates and normalizes a `BrushPresetV2` into a compact
`CompiledBrush`. Rendering code consumes only `CompiledBrush`; it does not
interpret JSON, strings, file paths, or unbounded collections on the hot path.

## Core Rust model

The following types describe the stable intent. Exact field layout may change
before the v2 format is released, but serialized field names and semantics
must be covered by compatibility tests.

```rust
pub struct BrushPresetV2 {
    pub format_version: u32,
    pub engine_semantics: EngineSemantics,
    pub id: BrushId,
    pub revision: u32,
    pub metadata: BrushMetadata,
    pub tool: ToolBehavior,
    pub stroke: StrokeBehavior,
    pub tip: TipBehavior,
    pub grain: Option<GrainBehavior>,
    pub paint: PaintBehavior,
    pub dynamics: Vec<ParameterBinding>,
    pub dual: Option<DualBrush>,
    pub post_effects: Vec<PostEffect>,
    pub limits: BrushLimits,
}

pub enum ToolBehavior {
    Deposit,
    Erase,
    Smudge,
    Blur,
    Clone, // Reserved until a bounded Phase 2 clone source is implemented.
}

pub enum TipBehavior {
    Stamp(StampTip),
    Spray(SprayTip),
    Ribbon(RibbonTip),
    Bristle(BristleTip),
}

pub enum PaintBehavior {
    Solid(SolidPaint),
    Glaze(GlazePaint),
    Marker(MarkerPaint),
    ColorPickup(ColorPickupPaint),
    DigitalWatercolor(DigitalWatercolorPaint),
}

pub struct CompiledBrush {
    pub source_hash: [u8; 32],
    pub semantics: EngineSemantics,
    pub fixed: CompiledFixedParameters,
    pub bindings: Box<[CompiledBinding]>,
    pub tips: Box<[DecodedTip]>,
    pub grain: Option<DecodedGrain>,
    pub dual: Option<Box<CompiledDualBrush>>,
}
```

`EngineSemantics` is not the app version. It identifies rendering behavior that
can affect pixels, for example `CpuBrushV2_0`. Bug fixes that change output
require a new semantics value. Existing documents replay with the semantics
recorded at stroke creation.

`Clone` reserves a compatible schema value, but is not a required Phase 2
built-in. The compiler rejects it until the clone source, sampling boundary,
and replay semantics have their own tests. External clone brushes are reported
as omitted or approximate until that gate is met.

The render hash covers every pixel-affecting normalized setting, engine
semantics value, and referenced resource hash. It excludes mutable library
metadata such as display name, tags, favorite state, and timestamps. A preset
edit that can affect pixels always produces a new render hash and revision.

## Input and derived sensors

All sensor values are normalized to `[0, 1]` unless otherwise stated. Missing
hardware channels use explicit fallback values; they are never random.

Direct sensors:

- `pressure`
- `tilt_x`, `tilt_y`, and derived `tilt_magnitude`
- `azimuth`
- `barrel_rotation` from Apple Pencil Pro or compatible hardware
- `pointer_kind`
- `eraser_tip`

Derived sensors:

- `speed_fine` and `speed_gross`, computed from quantized distance/time;
- `direction` and `direction_change`;
- `distance` and normalized `stroke_progress`;
- `elapsed_time` and `dab_index`;
- `initial_direction`;
- deterministic `random_per_stroke`, `random_per_dab`, and `random_per_particle`;
- `fade`, `taper_start`, and `taper_end`;
- `canvas_zoom` only for explicitly screen-space effects. Ordinary brushes are
  canvas-space and must not change appearance with zoom.

Fallbacks:

- no pressure: `0.5` while drawing;
- no tilt: upright stylus, `tilt_magnitude = 0`;
- no azimuth: stroke direction;
- no barrel rotation: azimuth, then stroke direction;
- zero or invalid timestamp delta: reuse the previous valid speed;
- touch input: configurable synthetic pressure curve, default `0.5`.

The iPad UIKit adapter holds the initial zero-force Pencil contact until the
first confirmed move, then gives the start sample the pressure from the
earliest confirmed measured move. A contact that ends without moving preserves
its initial pressure and remains a tap.

Every built-in brush now has a stylus-pressure binding and defers its first dab
until movement or a stationary tap is confirmed, then ramps dab radius and
opacity by confirmed travel distance over one base brush diameter. Motion is
detected before spacing resampling, so a short first segment cannot jump to a
full-size, fully opaque dab; stationary taps keep their normal mark. Technical Pen
revision 4 maps pressure directly to its preset diameter, with a visible 12%
minimum and a full-size response at maximum force. The response is tuned
across the S23 Ultra's measured light-to-firm normalized pressure range.
Revision 5 sets the built-in Technical Pen's default diameter to 12 document
pixels, matching the editor's initial brush-size projection. Existing
serialized presets retain their captured brush data; the brush evaluator
semantics remain 2000. Opaque Round and Marker advance to preset revision 2;
Ink Spatter and Ribbon Chain advance to revision 3 for their pressure and
visible-mark updates. Existing saved overrides keep their captured settings.

## Parameter bindings

Size, opacity, flow, density, spacing, rotation, scatter, grain strength,
pickup, smudge, color shift, and other configurable values share one mapping
system.

Starter pressure bindings span more of the ordinary Apple Pencil force range:
their response rises from roughly 0.45 at normalized pressure `0.02` to 0.78
at `0.08`, where samples reached in physical-device diagnostics. The curve
continues rising through firmer pressure instead of reaching its maximum at
light force. Binding strength remains brush-specific, and the brush editor's
pressure size and response-curve controls tune each brush independently.

The same low-force-friendly pressure curve is used by built-in bindings; the
binding amount and target vary by brush. `+N%` means the parameter reaches up to
`1 + N%` of its unpressured value at maximum curve output. Each built-in
changes at least one visible output property under stylus pressure. User-created
and imported brushes retain their own saved dynamics and can be tuned in the
brush editor.

| Built-in brush | Default size (canvas px) | Pressure response |
| --- | ---: | --- |
| Technical Pen | 12 | Diameter +100%; wider light-force range; extended firm ramp |
| HB Sketch Pencil | 6 | Diameter +55%; opacity +35% |
| Opaque Round | 24 | Diameter +80% |
| Soft Airbrush | 80 | Opacity +85% |
| Marker | 14 | Diameter +55%; opacity +30% |
| G-Pen | 10 | Diameter +85% |
| Dry Gouache | 28 | Diameter +25%; opacity +35% |
| Digital Watercolor Wash | 42 | Opacity +45% |
| Watercolor Blender | 38 | Diameter +20%; opacity +40% |
| Ink Spatter | 30 | Diameter +45%; opacity +80%; darker, larger particles |
| Ribbon Chain | 16 | Width +65%; alternating repeated links |
| Acrylic Rake | 30 | Diameter +45% |
| Soft Graphite | 8 | Diameter +62%; opacity +35% |
| Charcoal | 18 | Diameter +62%; opacity +40% |
| Brush Pen | 18 | Diameter +62%; end taper |
| Dry Ink | 7 | Diameter +62%; end taper |
| Flat Paint | 32 | Diameter +25% |
| Soft Blender | 36 | Diameter +25%; opacity +30% |
| Hard Eraser | 24 | Diameter +65% |
| Soft Eraser | 36 | Diameter +55%; opacity +30% |

All factory brushes, including the original IDs 1–5, render through their V2
preset so the documented pressure bindings control committed strokes and live
previews. The legacy dab renderer remains a compatibility path for commands
that do not resolve to a factory or imported V2 preset.

```rust
pub struct ParameterBinding {
    pub target: ParameterId,
    pub base: NormalizedValue,
    pub modulators: Vec<Modulator>,
    pub clamp: ValueRange,
}

pub struct Modulator {
    pub sensor: SensorId,
    pub curve: ResponseCurve,
    pub amount: SignedNormalizedValue,
    pub combine: CombineOp,
}

pub enum CombineOp {
    Add,
    Multiply,
    Replace,
    Minimum,
    Maximum,
}
```

The v2 evaluator seeds each target with `base` once, then composes matching
modulators in declaration order. Sensor values are normalized before curve
evaluation; angular direction is wrapped, while normalized pressure, tilt,
speed, progress, random, and barrel rotation are clamped. A curve always has
2–16 points. The final value is clamped to the target's declared safe range so
malformed or hostile presets cannot create non-finite dimensions or unbounded
work.

Rules:

- A target has at most eight modulators.
- A response curve has 2–16 ordered control points.
- Points use fixed-point serialized coordinates; duplicate or decreasing input
  positions are invalid.
- Interpolation is piecewise monotone cubic when safe and linear otherwise.
- Evaluation must never produce NaN, infinity, negative dimensions, or values
  outside the target's declared range.
- Random inputs use PCG seeded from document ID, stroke ID, preset hash, and
  the appropriate dab/particle index. Preview and committed rendering use the
  same seed stream.
- Imported curves are resampled into this representation and retained in the
  import report; arbitrary formulas or scripts are not accepted.

The editor exposes common mappings as simple toggles and sliders, with the
curve editor behind an Advanced control. Pressure, tilt, speed, direction,
barrel rotation, stroke progress, and random may be attached independently.
The Done action commits one validated library mutation through the shared
Undo/Redo command path; invalid drafts are discarded transactionally.

## Stroke path, smoothing, and taper

`StrokeBehavior` contains:

- spacing as a fraction of current diameter, default `0.10`;
- minimum canvas-space spacing, default `0.25 px`;
- optional time-based stationary deposition for airbrushes;
- spacing jitter, lateral jitter, and longitudinal jitter;
- velocity-aware low-pass smoothing;
- streamline/pull amount;
- motion-filter amount and expression restoration;
- start/end pressure and touch taper curves;
- synthetic start/end fade by distance or time;
- corner preservation and pointed-corner strength;
- ruler/symmetry snapping capability flags;
- post-stroke correction capability for vector ink only.

Smoothing is evaluated before resampling. Dynamics and end taper are evaluated
at resampled positions. A configured start taper uses confirmed travel distance
from the initial contact, normalized by the base brush diameter; it does not
advance by packet or dab count. It scales dab radius and opacity together, so
short initial samples cannot jump straight to a full-size, fully opaque dab.
Stationary taps keep their normal mark. Confirmed samples are the source of
truth. Predicted samples render into the existing ephemeral preview tiles and
never enter undo, journal, time-lapse, or saved brush state.

Stationary deposition is generated at a bounded frequency from monotonic input
time. It stops immediately on pointer up/cancel and may never run from a wall
clock after the stroke has ended.

### Format-3 pulled-string stabilizer

Pulled-string is an optional position conditioner selected per brush preset.
Its serialized contract is `format_version: 3`, `engine_semantics: 2001`,
`stabilizer: PulledString`, `distance_px: 0..=100`, and
`catch_up_on_end: bool`. It runs before the existing distance resampler and
keeps constant-size state per active stroke. Confirmed input order determines
the result independent of packet chunk boundaries. It changes only position;
pressure, tilt, azimuth, twist, timestamps, and sequence remain the input
values used by the existing evaluator. Predicted samples are preview-only.

With pulled-string selected, legacy positional smoothing/streamline filtering
is bypassed. Zero distance follows the unconditioned position path. On
pointer-up, `catch_up_on_end` emits the final confirmed endpoint; pointer-cancel
emits no catch-up. Brush settings and semantics are captured by the compiled
brush at stroke start. Format-2 brushes retain semantics 2000 and their legacy
output exactly.

## Tip engines

### Stamp

The stamp engine covers round, image-tip, pencil, pen, marker, chalk, texture,
and most paint brushes.

Configurable properties:

- one round/elliptical procedural tip or 1–32 grayscale tip images;
- tip selection: repeat, reverse, ping-pong, random, shuffle-once, or once;
- hardness and antialiasing mode;
- base angle, follow-stroke amount, azimuth amount, barrel-roll amount, and
  random rotation;
- horizontal/vertical scale, roundness, aspect, squeeze, and flip jitter;
- 1–16 impressions per dab with bounded count jitter;
- individual-dab density separate from whole-stroke opacity;
- density compensation when spacing changes;
- the editor's normalized scatter value is retained separately from derived
  stamp density so Rust projections can round-trip the control exactly;
- per-dab blend mode.

Tip images are single-channel coverage masks. Color tip images are allowed only
for explicit stamp/decorative brushes and must declare `ColorTipMode`.

### Spray

The spray engine emits bounded particles inside an ellipse around each
resampled point.

Configurable properties:

- particles per dab or particles per second;
- particle size, aspect, rotation, opacity, and color variation;
- radial distribution: uniform area, center-biased, Gaussian, ring, or curve;
- angular distribution and rotation toward/away from center;
- source-tip selection and deterministic scatter;
- continuous stationary spraying.

Particle generation is capped before allocating. High-density spray presets
degrade by deterministic thinning, never by allocating an unbounded list.
The built-in Ink Spatter uses 12 larger particles per dab and stronger base and
pressure opacity so marks remain dark enough to read as ink.

### Ribbon

The ribbon engine follows the path with a continuous or repeated image strip.
It covers chains, lace, stitching, foliage trails, calligraphic ribbons, and
decorative object brushes.

Configurable properties:

- stretch or repeat along path;
- preserve-aspect or fit-width;
- tangent/normal orientation;
- sequence and mirroring modes;
- corner join and end-cap behavior;
- optional colorization of grayscale source art.

Ribbon Chain revision 3 emits alternating slanted elliptical links at its
configured repeat spacing and does not add a continuous pen stroke beneath
them. Older revision-2 ribbon presets retain their continuous-dab evaluator.

### Bristle

The Phase 2 bristle engine is a deterministic bundle of 1–128 virtual bristles,
not a fluid simulation.

Configurable properties:

- bristle count, length, thickness, stiffness, and spread;
- elliptical or custom bundle profile;
- pressure/tilt squash and barrel-roll orientation;
- per-bristle opacity and color jitter;
- reconnect/lag amount and bounded canvas pickup;
- anti-aliasing and composite-per-bristle versus composite-per-dab.

Bristle state is stored only for the active stroke. Replay derives it from the
stroke seed and pointer samples.

## Grain and paper texture

Grain is independent of the tip mask.

```rust
pub enum GrainSpace {
    Canvas,
    Stroke,
    Dab,
}

pub struct GrainBehavior {
    pub resource: ResourceHash,
    pub space: GrainSpace,
    pub scale: FixedScale,
    pub rotation: FixedAngle,
    pub depth: NormalizedValue,
    pub contrast: SignedNormalizedValue,
    pub brightness: SignedNormalizedValue,
    pub invert: bool,
    pub offset_jitter: NormalizedValue,
    pub blend: GrainBlendMode,
    pub filtering: TextureFiltering,
}
```

Required grain blend modes: normal, multiply, subtract, overlay, height,
outline, and hard-mix. Unsupported imported modes map to the closest declared
mode and produce a warning.

Canvas-space grain uses document coordinates so adjacent tiles and separate
strokes align without seams. Grain resources must either be seamless or carry
an explicit edge mode: repeat, mirror, clamp, or transparent.

## Opacity, flow, density, and accumulation

These controls remain distinct:

- `opacity`: upper alpha contribution of the entire stroke;
- `flow`: paint deposited by each pass while moving or holding;
- `density`: coverage of an individual tip mask;
- `spacing_compensation`: normalizes density when dab spacing changes;
- `accumulation`: whether repeated dabs build opacity during one stroke;
- `wash`: whether transparent deposits replace, glaze, or accumulate.

Required accumulation modes:

- `BuildUp`: conventional repeated source-over deposits;
- `UniformStroke`: prevent a stroke from darkening itself past its computed
  stroke opacity;
- `Glaze`: low-flow transparent buildup;
- `Marker`: controlled overlap behavior with optional same-stroke uniformity;
- `DarkenTips`: retain the darker overlapping tip value;
- `Erase`: remove alpha with flow/density dynamics.

All color compositing uses the existing deterministic linear-light integer
pipeline. Presets cannot select platform-native floating-point blending.

## Color dynamics and mixing

Color dynamics can vary foreground/background mix, hue, saturation, value,
lightness, temperature approximation, and per-stroke/per-dab jitter from any
supported sensor.

Phase 2 paint mixing uses deterministic RGB canvas pickup:

- `charge`: amount of selected color initially carried by the brush;
- `pickup`: rate at which canvas color enters the brush reservoir;
- `deposit`: rate at which reservoir color is applied;
- `smudge`: rate at which existing pixels are displaced along the path;
- `dilution`: transparency added to the carried color;
- `persistence`: how long carried color remains in the reservoir;
- `radius`: pickup sampling radius;
- `blur`: bounded local softening for blender brushes;
- `sample_all_visible`: off by default and explicitly enabled by the user.

The reservoir is a small fixed-point color/state structure, not a pixel buffer.
It is recreated from stroke start during replay. It may sample committed tiles
but never predicted preview tiles.

`Smudge` and `Blur` tools use the same tip, grain, spacing, and dynamics system
as deposit brushes. They differ only in the paint stage. Sampling beyond the
canvas returns transparent/background according to document policy.

## Digital watercolor

`DigitalWatercolorPaint` combines low-flow glazing, bounded pickup, paper grain,
granulation, and an optional final edge effect.

Configurable properties:

- wash opacity, flow, dilution, charge, pickup, and color stretch;
- granulation strength and scale;
- paper-resist strength;
- wet-look local softening radius;
- edge accumulation width, strength, blur, darkness, saturation, and hue shift;
- edge style: `Standard` or `Vivid`;
- edge timing: live or on stroke finalization.

The watercolor edge is computed only over the bounded dirty region plus its
declared halo. Stroke-finalization work is cancellable and produces one undo
transaction with the stroke. It must not scan the entire document.

The preset editor labels this section “Digital Watercolor” and explains that
the effect does not continue diffusing after the stroke ends.

## Dual brushes

A dual brush contains exactly two non-dual component brushes. Recursive dual
brushes are invalid.

Supported combine modes:

- normal/source-over;
- multiply coverage;
- minimum/maximum coverage;
- add/subtract coverage;
- primary masked by secondary;
- secondary masked by primary;
- darken/lighten color.

Components share the same conditioned pointer path and stroke seed but have
independent resampling, tips, grains, dynamics, and deterministic random
streams. A hard combined dab/particle budget applies across both components.

## Post effects

Phase 2 post effects are limited to bounded dirty regions:

- digital watercolor edge;
- edge soften/sharpen;
- stamp outline;
- bounded trailing fade;
- optional stroke-level texture pass.

Post effects cannot inspect unrelated layers unless the preset declares
`sample_all_visible` and the user grants that capability. They cannot modify
outside the active layer or selection.

## Built-in brush library

Phase 2 ships a deliberately small, high-quality library rather than hundreds
of near-duplicates. Factory brush identity is independent of document-local
custom IDs: the original 12 brush IDs remain stable, and additional starter
brushes use the reserved ID range beginning at `4_000_000_000_000_001` so
projects created by earlier versions cannot mistake a saved custom brush for
a new factory preset. The list currently contains 20 tuned originals:

- Technical Pen, HB Sketch Pencil, Opaque Round, Soft Airbrush, Marker, G-Pen,
  Dry Gouache, Digital Watercolor Wash, Watercolor Blender, Ink Spatter,
  Ribbon Chain, and Acrylic Rake;
- Soft Graphite, Charcoal, Brush Pen, Dry Ink, Flat Paint, Soft Blender,
  Hard Eraser, and Soft Eraser.

Every built-in has a clear use and remains subject to golden-stroke and device
review as its settings evolve.

### Sketch

- 2H drafting pencil
- HB pencil
- 6B soft pencil
- side-shading graphite pencil
- charcoal pencil
- vine charcoal
- chalk/pastel
- colored pencil

### Ink

- technical pen
- pressure ink pen
- G-pen
- mapping pen
- brush pen
- dry ink
- flat calligraphy pen
- pixel pen

### Paint and blend

- opaque round
- opaque flat
- soft airbrush
- hard airbrush
- marker
- glazing brush
- gouache
- dry gouache
- acrylic bristle
- rake brush
- palette-knife-style smear
- smooth blender
- textured blender
- soft smudge

### Digital watercolor

- clean wash
- textured wash
- wet-on-dry round
- granulating wash
- watery blender
- watercolor edge liner

### Effects and decoration

- spray paint
- ink spatter
- noise/speckle
- foliage scatter
- cloud texture
- hair/fur rake
- hatch
- halftone dots
- glow particles
- chain/ribbon demonstration brush using redistributable original assets

Built-in texture and tip assets must be original, public domain, or under a
license compatible with redistribution in MPL-2.0 binaries. Attribution files
ship beside the assets and are included in the app's license screen.

## Native preset format

### `.inkbrush`

An `.inkbrush` is a ZIP archive with this fixed layout:

```text
manifest.json
preset.cbor
preview.webp
tips/<sha256>.png
grains/<sha256>.png
licenses/<name>.txt
source/import-report.json        # optional
```

### `.inkbrushpack`

An `.inkbrushpack` is a ZIP archive containing:

```text
manifest.json
brushes/<brush_uuid>/preset.cbor
brushes/<brush_uuid>/preview.webp
resources/tips/<sha256>.png
resources/grains/<sha256>.png
licenses/<name>.txt
```

Resources are content-addressed and deduplicated. Presets refer to hashes, not
paths. Manifests contain:

- format and minimum-reader versions;
- pack/brush UUID, name, author, description, tags, locale-neutral category;
- creation/modification timestamps;
- license identifier, attribution, homepage, and redistribution flag;
- resource hashes, byte sizes, pixel dimensions, and MIME types;
- source application/format and conversion metadata when applicable;
- an optional Ed25519 signature over the canonical manifest and resource hash
  list. A signature proves continuity only after the user trusts its public
  key; it is not an automatic safety or authorship endorsement. Unsigned local
  packs remain supported.

CBOR is canonical and rejects duplicate keys, indefinite lengths, unknown
required fields, non-finite floats, and integers outside declared ranges.
Unknown optional fields are retained when a preset is edited and re-exported.

## Import security limits

Limits apply before decompression or image decode:

- maximum archive entries: 256 for `.inkbrush`, 10,000 for `.inkbrushpack`;
- maximum nesting depth: 8;
- maximum archive size: 256 MiB;
- maximum expanded size: 512 MiB;
- maximum compression ratio: 100:1 per entry and for the archive total;
- maximum preset/manifest document: 1 MiB;
- maximum tip or grain image: 4096×4096 and 32 MiB decoded;
- maximum preview: 1024×1024 and 8 MiB decoded;
- maximum 32 tip resources and 8 grain resources per brush;
- ZIP64, encryption, symlinks, hard links, device files, absolute paths,
  parent traversal, NULs, duplicate names, and case-folding collisions are
  rejected;
- no external URLs are fetched while importing or rendering.

Import parses into an immutable staging area, validates every hash and preset,
generates previews in a bounded worker, then atomically installs resources.
Failure leaves the library unchanged. Imported source files are never modified.

Image decoders run with dimension and byte limits. ICC profiles, EXIF, comments,
and ancillary chunks are discarded unless explicitly required. SVG tips are not
accepted in v2; rasterize trusted SVG externally or through a future sandboxed
import path.

## Brush library and editor behavior

The UI has compact and advanced views.

Compact view:

- size, opacity, flow, color, stabilization, and favorite;
- recent brushes, category/tag search, and device-local user brush sets;
- duplicate, reset, export, and delete-user-copy actions;
- live pressure-aware scratch pad.

User brush sets are local library metadata, separate from artwork state. They
support create, rename, delete, membership changes, and filtering. Their
membership key must identify the same brush definition across document
libraries; a document-local numeric ID alone is not a durable cross-artwork
identity. Deleting a set never deletes its brushes.

Advanced view groups settings as:

- Stroke Path
- Stabilization and Taper
- Shape/Tip
- Grain/Paper
- Rendering and Accumulation
- Color Dynamics
- Paint Mixing or Digital Watercolor
- Input Dynamics
- Dual Brush
- Brush Properties and Attribution

Every setting has Reset and Disable actions. Invalid combinations are disabled
with an explanation. The editor works on a draft preset and commits one
undoable library edit only when the user selects Done. Cancel leaves the saved
preset unchanged.

Imported presets are duplicated before editing by default. Built-ins are
immutable; editing creates a user copy linked to its source version.

## Engine integration

Rust remains authoritative for:

- preset validation, compilation, hashing, migration, and storage;
- brush resource decoding and bounded caches;
- all dynamic evaluation, dab/particle generation, paint state, pixels, and
  deterministic previews;
- import conversion and compatibility reports.

Brush thumbnails and editor scratchpad strokes use the bounded Rust preview
renderer. The scratchpad sends normalized stylus points to a disposable render
request; it must not advance the document revision, write document tiles, or
add history. Preview requests are limited to 256×256 pixels and 1,024 points.
The document-backed preview path uses the production brush-dab rasterizer and
exports straight-alpha RGBA pixels; deterministic tests compare its output to
the committed raster path for identical preset and pointer samples.
The UI may debounce requests while the pointer is moving, but must never await
preview work from the pointer callback.

Flutter owns:

- library/editor UI, categories, search, favorites, and dialogs;
- scratch-pad viewport and presentation;
- file selection and platform share sheets;
- immutable preset projections tagged with library revision.

Dart must not interpret brush behavior or maintain a second mutable preset.
Editor changes are commands applied to a Rust draft handle.

Proposed bridge surface:

```rust
list_brushes(library, query) -> BrushPage
get_brush_snapshot(library, brush_id) -> BrushSnapshot
create_brush_draft(library, source: Option<BrushId>) -> BrushDraftHandle
update_brush_parameter(draft, change) -> Result<PreviewRevision, BrushError>
render_brush_preview(draft, preview_spec) -> OperationId
commit_brush_draft(draft) -> Result<BrushId, BrushError>
discard_brush_draft(draft)
import_brushes(library, staged_path, policy) -> OperationId
get_import_report(operation) -> BrushImportReport
commit_import(operation, selected_brushes) -> Result<Vec<BrushId>, BrushError>
export_brush(library, brush_id, destination) -> OperationId
export_brush_pack(library, brush_ids, destination) -> OperationId
```

Large images, previews, and archives never cross FRB as JSON. Control DTOs are
bounded; image data uses byte buffers or the existing tile/image path.

## Caches and memory

- Compiled presets are cached by `(preset_hash, engine_semantics)`.
- Decoded tips/grains are cached by resource hash with an explicit byte budget.
- Project Ink's CPU engine uses a 64 MiB per-document decoded-resource LRU in
  v1 of the Phase 2 implementation. Durable decoded resources remain bounded
  by the separate 256 MiB `.inkproj` resource limit; a future platform profile
  may raise the hot-cache budget only with recorded memory evidence.
- Full layer-map undo/redo snapshots use a separate 256 MiB aggregate payload
  budget. The newest snapshot is retained for undo even when one document
  state alone exceeds the budget; older snapshots are evicted oldest-first.
  The same bound is applied while opening a project, so a hostile history
  cannot expand memory without limit.
- Least-recently-used decoded resources are evicted only when no active stroke
  references them.
- Preview caches are separate and lower priority than active-canvas resources.
- A stroke captures an immutable compiled-preset handle at begin; editing or
  deleting the library entry cannot change the active stroke.

## Work and quality limits

- Existing `MAX_RESAMPLED_DABS` remains a hard upper bound until profiling
  justifies a smaller per-engine limit.
- Maximum particles per stroke: 1,048,576 after deterministic thinning.
- Maximum live bristles: 128.
- Maximum dual components: 2; recursive dual brushes are rejected.
- Maximum post-effect halo: 128 pixels in Phase 2.
- Maximum canvas-pickup radius: 128 pixels.
- Per-packet work must be interruptible between dabs/particles and observe
  operation cancellation.
- A preset that cannot satisfy limits is rejected at compile time or rendered
  with an explicit deterministic quality tier recorded in the stroke.

The engine may use SIMD, but scalar and SIMD implementations must produce the
same integer result. Approximate platform math is not allowed in committed
rendering.

## Migration from Phase 1

The five Phase 1 brushes map to v2 without visual changes:

- TechnicalPen -> Stamp + Solid + UniformStroke
- Pencil -> Stamp + texture-free legacy density behavior
- OpaqueRound -> Stamp + Solid + BuildUp
- SoftAirbrush -> procedural soft Stamp + low-flow BuildUp
- Marker -> Stamp + Marker accumulation

`CpuBrushV1` remains available for old documents and golden fixtures. New
documents may substitute equivalent v2 built-ins only when starting a new
stroke. Opening or replaying a Phase 1 document must not silently rewrite brush
IDs, hashes, or pixels.

## Automated tests

Rust tests:

- unit tests for every parameter range, sensor, curve, combine operation, tip
  engine, grain mode, paint mode, and post effect;
- property tests proving finite bounded output for arbitrary valid presets;
- golden tile hashes for every built-in using pressure, tilt, speed, azimuth,
  and barrel-roll recordings;
- arm64/x64 replay comparison for all golden strokes;
- preview/committed equivalence after predictions are confirmed;
- undo/recovery/time-lapse replay with brush revision changes;
- fuzzing for CBOR, ZIP, PNG/WebP, external importers, curves, and resource
  references;
- decompression-bomb, path-traversal, duplicate-name, malformed-image, huge
  dimension, resource-cycle, and cancellation tests;
- import reports tested against versioned fixtures.

Flutter tests:

- compact/touch/desktop editor layouts;
- accessible labels and keyboard/gesture alternatives for every control;
- draft commit/cancel/reset behavior;
- preview revision cancellation and stale-result rejection;
- library search, tags, favorites, duplicate, import report, and conflict UI.

Performance tests:

- representative simple stamp, textured pencil, bristle, smudge, watercolor,
  spray, ribbon, and dual brushes;
- p50/p95 packet-to-visible latency on the physical-device matrix;
- per-stroke allocation and peak resource-cache memory;
- one-hour mixed-brush session without latency or memory growth;
- worst-case preset rejection occurs before a UI-frame stall or large
  allocation.

The engine exposes `Document::estimated_working_memory_bytes()` for repeatable
benchmark collection. It includes sparse tiles, undo/redo snapshots, durable
brush resources, preview tiles, journals, and the decoded-resource LRU. The
`ink-engine` regression `single_point_vector_stroke_rasterizes_and_resource_cache_evicts_lru`
asserts eviction at a constrained budget; release performance runs should
record this value at the start and end of a one-hour mixed-brush session and
compare it with the Phase 1 900 MiB document ceiling.

## Phase 2 brush acceptance

- An artist can sketch, ink, flat, shade, paint, blend, apply a watercolor
  wash, add texture/effects, erase, and export without another application.
- At least one production-quality built-in from every library entry above has
  a golden fixture and physical-device sample sheet.
- Pressure, tilt, azimuth, and Apple Pencil Pro barrel rotation visibly affect
  supported presets, with deterministic fallbacks on older hardware.
- Every exposed setting changes the live scratch-pad preview and round-trips
  through `.inkbrush` without loss.
- The same recorded stroke produces identical committed tile hashes on arm64
  and x64 for a fixed engine-semantics version.
- Imported brushes show a compatibility report before installation and never
  claim exact parity unless a Project Ink native preset hash matches.
- Malformed or hostile brush files cannot escape staging, fetch the network,
  execute code, exhaust unbounded memory, or partially modify the library.
- A one-hour mixed-brush session remains inside the Phase 1 document memory
  ceiling plus the configured brush-resource cache and does not degrade p95
  latency.

## Implementation order for handoff

Work in this order, one subsystem per pull request:

1. Add v2 schema, validation, canonical CBOR, hashes, migration fixtures, and
   `CompiledBrush`; do not change rendering yet.
2. Move Phase 1 brushes onto the compiled stamp pipeline while retaining
   `CpuBrushV1` golden compatibility.
3. Add shared sensors, curves, parameter bindings, taper, and advanced
   stabilization with replay tests.
4. Add image tips, multi-tip sequencing, rotation/aspect dynamics, grain, and
   resource caches.
5. Add flow/density/accumulation modes and the sketch/ink built-in library.
6. Add spray and ribbon engines plus effects/decoration built-ins.
7. Add canvas pickup, deterministic RGB mixing, smudge/blur, and paint/blender
   built-ins.
8. Add the bristle engine and bristle/rake paint built-ins.
9. Add digital-watercolor deposits, granulation, and bounded edge finalization.
10. Add non-recursive dual brushes and combined work budgeting.
11. Add Rust draft/library APIs, Flutter Brush Studio, preview cancellation,
    tags, favorites, and accessible compact/desktop layouts.
12. Add native `.inkbrush`/`.inkbrushpack` import/export and security fuzzing.
13. Implement external converters in the order defined by the compatibility
    specification. Each converter lands separately with licensed fixtures.
14. Run the physical-device matrix and record visual sample sheets, latency,
    memory, import reports, and remaining incompatibilities.

Do not combine steps or introduce Phase 5 pigment/GPU dependencies. If a brush
class misses the latency target, profile its bounded CPU stages before changing
the renderer architecture.

## Research basis

This design is informed by brush-engine concepts documented by Krita and by
common digital-art brush controls. It does not copy another application's UI
or proprietary data:

- https://docs.krita.org/en/reference_manual/brushes/brush_engines.html
- https://docs.krita.org/en/reference_manual/brushes.html
