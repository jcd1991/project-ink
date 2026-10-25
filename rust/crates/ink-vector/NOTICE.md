# VectorCraft source notice

This crate adapts selected geometry code from VectorCraft, pinned at
[`8bf090b25389b48aa6f9d7415de57c9ce7ccf8cb`](https://github.com/storytold/vectorcraft/tree/8bf090b25389b48aa6f9d7415de57c9ce7ccf8cb).
The upstream MIT license is included in `LICENSE-MIT.upstream`.

| Local file | Upstream file | Local changes |
|---|---|---|
| `src/source_recognize.rs` | `crates/geom/src/recognize.rs` | Imports Kurbo directly; retains bounded Ink adapter behavior and the upstream deterministic equivalent-angle fix. |
| `src/source_contour.rs` | `crates/trace/src/contour.rs` | Adapts the upstream one-bit-per-pixel contour walk with checked dimensions, fallible allocations, foreground-boundary/component limits, and bounded traversal. |
| `src/source_fit.rs` | `crates/pathops/src/fit.rs` | Adapted least-squares cubic fitting to return failure on allocation/iteration/segment limits; Ink wrapper detects and preserves sharp corners. |

Geometry dependency: Kurbo `0.13.1` (resolved in the workspace lockfile). No
VectorCraft application, document model, text subsystem, renderer, or PDF
crate is imported.
