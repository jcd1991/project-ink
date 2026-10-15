# External Brush Import and Recreation Compatibility

Status: Phase 2 specification

This document defines how Project Ink accepts brushes created by other applications. It is deliberately conservative: external brush formats may be proprietary, partially documented, versioned without notice, or capable of expressing behavior that Project Ink does not implement.

The importer must preserve user trust. It must never call a brush an exact import when settings, rendering semantics, or resources were approximated.

## Terminology

- **Imported**: a native Project Ink preset or pack was decoded without semantic loss.
- **Converted**: an external preset was decoded and mapped to Project Ink settings, with any differences recorded.
- **Recreated**: a new Project Ink preset was made from extracted resources, visible settings, reference strokes, or user guidance. It is not the original preset.
- **Source application**: the application that created the external preset.
- **Source resource**: an image, texture, preview, or metadata item contained in or supplied with the source preset.

## Fidelity tiers

Every import result has one of these tiers:

| Tier | Name | Meaning |
| --- | --- | --- |
| A | Lossless | All supported source data and behavior have an equivalent Project Ink representation. |
| B | High fidelity | The primary stroke appearance and dynamics are mapped; small rendering differences are expected. |
| C | Approximate | Useful resources or settings were recovered, but one or more important behaviors were substituted. |
| D | Guided recreation | The format was not decoded. Project Ink helps the user build a new preset from legally supplied resources and reference strokes. |
| Rejected | Unsupported or unsafe | The input is malformed, exceeds safety limits, contains unsupported active content, or cannot be handled honestly. |

The UI shows the tier before the user saves the converted preset. Tier B and C results include a side-by-side stroke preview and a readable difference report.

## Phase 2 compatibility matrix

| Source | Extensions | Phase 2 support | Default tier | Notes |
| --- | --- | --- | --- | --- |
| Project Ink | `.inkbrush`, `.inkbrushpack` | Required | A | Native versioned format. |
| Krita preset | `.kpp` | Required | B | Parse the PNG container and bounded brush-preset XML annotation. Map supported engines and retain the original file hash. |
| Krita bundle | `.bundle` | Required | B/C | Import contained `.kpp` presets through the same bounded validation path; unsupported resource kinds are reported and never extracted to the filesystem. |
| MyPaint brush | `.myb` | After Krita | B/C | Parse the documented JSON settings directly. Do not link `libmypaint` into the runtime. |
| Photoshop brush | `.abr` | Experimental | C | Tip/resources and a conservative settings subset only. Never promise Photoshop-equivalent rendering. |
| SUT/TOS archives | `.sut`, `.tos` | Guided recreation by default | D | No metadata decoder is registered. Reuse only safe, ordinary image resources; require format and redistribution review before adding a decoder. |
| Brush archives | `.brush`, `.brushset`, `.brushlibrary` | Guided recreation by default | D | No settings decoder is registered. Reuse only bounded, ordinary image resources; require format and redistribution review before adding a decoder. |
| Images | PNG, JPEG, WebP | Required | C/D | Create a brush tip, grain, or reference image after explicit user choice. |

Phase 2 does not import executable plugins, scripts, SVG filters, shader code, or source-application automation. Brush archives cannot request network access or reference files outside their own archive.

## Why exact parity is often impossible

Brush appearance is the product of both the preset and the source application's renderer. Matching field names is not enough. Differences can include:

- dab placement and sub-pixel quantization;
- pressure and velocity sampling;
- response-curve interpolation;
- texture anchoring and filtering;
- opacity, flow, buildup, and blend math;
- wet mixing, color pickup, and canvas feedback;
- randomness, seeds, and per-stroke state;
- stabilization and prediction;
- undocumented defaults and version-specific behavior.

Project Ink therefore converts semantics, not just values. When no equivalent exists, the importer uses a named substitute, records it, and lowers the fidelity tier.

## Safe import workflow

1. Read the file through a byte-limited, streaming input abstraction.
2. Identify the format from validated structure and magic bytes, not from the extension alone.
3. Compute a content hash and record the detected format and parser version.
4. Validate archive paths, member counts, compressed and expanded sizes, image dimensions, metadata sizes, nesting depth, and decompression ratios.
5. Decode metadata without executing scripts, resolving external entities, loading remote resources, or following filesystem links.
6. Decode image resources into bounded intermediate buffers and reject contradictory dimensions or truncated data.
7. Map source settings to `BrushPresetV2`, collecting every approximation, dropped setting, and warning.
8. Compile and render deterministic preview strokes in an isolated import workspace.
9. Show the source preview when legally present, the Project Ink preview, fidelity tier, and report.
10. Save only after user confirmation. The original file remains untouched.

Import is transactional. A failed member does not create a partially registered brush. A brush pack may optionally continue past failed members, but the user must see a complete per-member result before committing successful entries.

## Import result API

```rust
pub struct BrushImportReport {
    pub source_format: ExternalBrushFormat,
    pub source_sha256: [u8; 32],
    pub importer_version: String,
    pub fidelity: FidelityTier,
    pub preset: Option<BrushPresetV2>,
    pub mappings: Vec<SettingMapping>,
    pub warnings: Vec<ImportWarning>,
    pub omitted: Vec<OmittedSetting>,
    pub resources: Vec<ImportedResource>,
    pub preview: Option<BrushPreview>,
}

pub struct SettingMapping {
    pub source_path: String,
    pub source_value: DisplayValue,
    pub target_path: String,
    pub target_value: DisplayValue,
    pub quality: MappingQuality,
    pub note: Option<String>,
}

pub enum MappingQuality {
    Exact,
    Normalized,
    Approximated,
    Defaulted,
}
```

`DisplayValue` is a bounded, non-executable DTO intended for reports. It must not be an untyped deserialization escape hatch into engine state.

The bridge exposes:

```text
inspect_brush_import(bytes_or_path) -> BrushImportInspection
convert_brush_import(inspection_id, choices) -> BrushImportReport
commit_brush_import(report_id, destination_library) -> BrushId
discard_brush_import(report_id)
```

Inspection and conversion are cancellable. Temporary resources are removed on cancel, failure, application restart, or report expiry.

## Krita `.kpp` mapping

Krita paint presets are PNG files with preset metadata, including brush-engine XML, stored in annotations. Project Ink must parse only bounded PNG chunks and the expected annotation payload.

Initial engine mapping:

| Krita engine or feature | Project Ink mapping | Expected tier |
| --- | --- | --- |
| Pixel engine, simple tip | Stamp plus Solid/Glaze | B |
| Pixel engine, textured tip | Stamp plus Grain | B |
| Color Smudge | ColorPickup or Smudge | B/C |
| Spray | Spray | B |
| Sketch | Ribbon or repeated Stamp approximation | C |
| Hairy | Bristle | B/C |
| Particle | Spray with bounded particle rules | C |
| Clone | Clone only after the target behavior passes its implementation gate; otherwise omitted | C |
| Filter, deform, tangent-normal, multibrush, curve, grid | No direct Phase 2 conversion | C or rejected preset |

Common dynamics map through Project Ink's sensor/binding system: pressure, speed, drawing angle, tilt, rotation, distance, time, fade, fuzzy/random, and direction. The importer clamps values to Project Ink limits and records normalized units.

XML handling requirements:

- disable DTDs, external entities, XInclude, stylesheet processing, and network resolution;
- cap XML bytes, element count, attribute count, nesting depth, and text length;
- reject duplicate security-sensitive fields and non-finite numeric values;
- treat unknown elements as data to report, never as instructions;
- never deserialize source XML directly into runtime engine structs.

## Krita `.bundle` mapping

Treat a bundle as an untrusted archive. Import only allowlisted brush-related resource kinds needed by selected presets. Resolve resource names inside an isolated virtual namespace, not against the user's global library.

Project Ink's Phase 2 implementation converts every bounded `.kpp` member in a
bundle transactionally. The bundle source hash is retained for TOCTOU checking,
each member receives a deterministic identity derived from its member hash, and
non-`.kpp` members remain inert. Image resources that cannot be mapped by the
KPP scalar converter are reported as omissions rather than extracted or
executed. A bundle with multiple converted presets is installed as one
undoable library operation.

If two members use the same logical name but different hashes, assign stable disambiguated names. Deduplicate identical resources by content hash. A preset that references a missing resource remains visible in the report but cannot be committed until the user chooses a replacement or accepts a declared fallback.

## MyPaint `.myb` mapping

Parse the versioned JSON format and map the documented base values and input mappings to Project Ink bindings. Initial mappings include radius/diameter, opacity, hardness, spacing, pressure gain, speed response, random offset, dab density, color variation, smudge, smudge length, and eraser behavior.

Project Ink does not use MyPaint's renderer and must not claim pixel parity. Settings without bounded equivalents are omitted with an explanation. Reference previews and replay fixtures determine whether a preset qualifies for B or C.

## Photoshop `.abr` mapping

ABR support is explicitly experimental because the format is not publicly specified as a stable interoperability contract and implementations commonly support only subsets. Project Ink pins the MIT-licensed PhotoCraft parser at commit `5ecc860ac1abf8fa7e3f218c0474cdcce49fa6c7`; parsing and conversion live in `ink-brush`, outside the engine.

The current bounded importer handles legacy v1/v2 computed and sampled tips, plus sectioned v6+ sampled data and brush preset descriptors exposed by the pinned parser. It maps diameter, hardness, roundness, angle, spacing, and sampled coverage into Ink's existing tip/preset model. Sixteen-bit sampled coverage is reduced to eight-bit. Converted presets remain **Approximate, Tier C** and carry a renderer-parity warning. Unsupported descriptor settings are listed by source key; tips without a usable descriptor are reported as omitted. Source identity is hash-checked before the entire selected report is registered as one library transaction.

Limits apply before reading the source and while converting resources: the source is bounded by the existing 256 MiB brush-import cap, each decoded tip by the existing resource/dimension limits, at most 256 reports are produced, and cumulative converted resource bytes are bounded. Parsing warnings and unsupported records appear in the report. Cancellation or any conversion, source-hash, preset-validation, or library-budget failure registers nothing.

Version-specific fixtures cover v1/v2 computed and sampled tips, v6 sampled data/settings, detection, coverage polarity, and Tier C labeling. Extend fixtures for malformed/truncated records, cumulative resource limits, and additional v6+ descriptor variants as parser support is expanded. Do not add a source application's name to the saved Project Ink preset unless the user entered it.

## SUT and TOS archive files

These archives can contain brush tips, textures, stroke settings, and other resources, but the formats do not provide a stable public decoding contract for third-party applications.

Phase 2 therefore ships a guided recreation path:

1. The user chooses a Project Ink archetype such as pencil, pressure pen, watercolor, spray, or effect brush.
2. The assistant asks for source-authorized tip and texture images, screenshots of visible settings, and optional reference strokes.
3. Project Ink maps visible values to its own settings and identifies behaviors without a direct equivalent.
4. The user tunes a split preview and saves a newly authored `.inkbrush`.

An experimental `.sut` or `.tos` decoder may be added only after:

- legal and license review of the decoding approach and fixtures;
- independent parser fuzzing and archive/resource limits;
- validation against multiple application versions;
- proof that the decoder does not bypass encryption, licensing, or marketplace controls;
- UI language that distinguishes conversion from exact compatibility.

For `.sut`, Project Ink may reuse a referenced ordinary PNG material thumbnail as a low-resolution guided tip or texture when the SQLite reference and TAR member can be matched without decoding protected payloads. It must not decrypt, decode, or bypass an opaque material format. A thumbnail is an approximation, not the source material. Extracted user-provided assets stay inside that user's document/library; Project Ink must never redistribute marketplace brush resources without permission.

## Brush archive files

These archives may describe stroke path, stabilization, taper, shape, grain, rendering, wet mix, color dynamics, stylus response, and combined brushes. Those settings are useful mapping concepts, but the archive contents do not provide a stable public interchange format.

Phase 2 uses guided recreation rather than source-setting conversion. For a user-selected `.brush` archive, the importer may reuse ordinary `Shape.png` and `Grain.png` members after bounded ZIP and image validation. It normalizes monochrome shape luminance into tip coverage and applies Project Ink grain defaults. Archive settings remain uninterpreted, and the result is marked recreated.

When a guided report includes supported image resources, the report offers an explicit **Create from extracted images** action. This is a user-confirmed creation of a new Project Ink brush, not automatic conversion or installation. The report identifies source settings and rendering behavior that were not carried across.

An experimental decoder must handle unknown keyed-archive classes as inert data, never instantiate archive-named runtime classes, and enforce object-graph depth and object-count limits. It also requires legal and license review, independent parser fuzzing, bounded resource handling, and validation against multiple format versions.

## Brush Recreation Assistant

The recreation assistant is local and deterministic. It is useful even when no source format can be decoded.

Inputs:

- a selected brush archetype;
- user-owned tip/grain images;
- screenshots or manually entered source settings;
- one or more source reference-stroke images;
- optional Project Ink test-stroke recordings.

Workflow:

- crop, normalize, and preview tip/grain resources without overwriting originals;
- expose the likely high-impact controls first;
- overlay reference and Project Ink strokes with an opacity slider and difference view;
- offer bounded local parameter search for measurable properties such as width, opacity envelope, spacing, scatter, and texture scale;
- require the user to approve the final visual match;
- write the source application's name only into optional provenance metadata, not as a compatibility guarantee.

Automated fitting must not infer or copy hidden proprietary assets. It optimizes only Project Ink parameters and resources the user supplied.

## Licensing and attribution

Each converted or recreated preset stores:

- source format and source-file hash;
- import/recreation timestamp and importer version;
- optional original author and homepage entered by the user or present in parseable metadata;
- declared license or `unknown`;
- whether included resources may be redistributed;
- the full conversion report.

A preset with an unknown or non-redistributable resource license works locally but is excluded from pack export by default. The UI must not imply that technical import grants permission to redistribute the brush.

## Test fixtures

- Native round-trip fixtures for every schema version.
- Publicly redistributable Krita `.kpp` fixtures covering Pixel, Color Smudge, Spray, Sketch, and Hairy engines.
- Krita bundles with duplicate, missing, oversized, nested, and path-traversal members.
- Publicly redistributable MyPaint fixtures with linear and nonlinear mappings.
- Synthetic malformed PNG, XML, JSON, ZIP, keyed-archive, and ABR corpora.
- Versioned goldens for every supported external parser.
- Fuzz targets that begin at raw bytes and never depend on a filename extension.
- Tests proving rejected imports do not mutate the brush library.
- Tests proving original files and resources are never modified.
- UI tests for tier display, omitted-setting disclosure, preview comparison, and redistribution warnings.

Fixtures copied from commercial brush marketplaces are forbidden unless their licenses explicitly permit inclusion and redistribution in an open-source test suite.

## Research references

- Krita brush engines: <https://docs.krita.org/en/reference_manual/brushes/brush_engines.html>
- Krita paint preset structure: <https://docs.krita.org/en/reference_manual/resource_management/paintoppresets.html>
- Krita FAQ on Photoshop brush support: <https://docs.krita.org/en/KritaFAQ.html#can-krita-load-photoshop-brushes>
- MyPaint brush settings: <https://github.com/mypaint/libmypaint/blob/master/brushsettings.json>
