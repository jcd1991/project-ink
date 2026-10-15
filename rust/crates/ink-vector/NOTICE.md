# VectorCraft source notice

This crate adapts selected geometry code from VectorCraft, pinned at
[`11fceda13e2423c28cd2c60d8d80689c760a54f8`](https://github.com/storytold/vectorcraft/tree/11fceda13e2423c28cd2c60d8d80689c760a54f8).
The upstream MIT license is included in `LICENSE-MIT.upstream`.

| Local file | Upstream file | Local changes |
|---|---|---|
| `src/source_recognize.rs` | `crates/geom/src/recognize.rs` | Imports Kurbo directly; retained recognition geometry/classification with bounded Ink adapter behavior. |
| `src/source_contour.rs` | `crates/trace/src/contour.rs` | Replaced unbounded entry point with checked dimensions and foreground-boundary/component limits; returns failure on limit overflow. |
| `src/source_fit.rs` | `crates/pathops/src/fit.rs` | Adapted least-squares cubic fitting to return failure on allocation/iteration/segment limits; Ink wrapper detects and preserves sharp corners. |

Geometry dependency: Kurbo `0.13.1` (resolved in the workspace lockfile). No
VectorCraft application, document model, text subsystem, renderer, or PDF
crate is imported.
