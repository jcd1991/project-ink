# Vendored parser provenance

Source: `storytold/photocraft`, commit
`b4a297fe99a0fbc8603788b4b636be1c949e17d0`, crate `crates/psd` (upstream
package version `0.15.1`, Rust `1.95`).

The parser is dual-licensed MIT OR Apache-2.0; both upstream license texts are
retained here. Project Ink uses the pinned PSD/ABR format parser and keeps its
own document model, resource budgets, import report, and transaction boundary.
Project Ink limits parsing to 1,024 layers, 4,096 image resources, and 32
tagged blocks per section; these checks run before the corresponding vectors
grow. Allocation reservations for the resource and tagged-block lists are
fallible. The Ink builder retains group protection flags from the previous
vendored API and writes them as Photoshop protection blocks for PSD export.
The integration target requires `testgen` explicitly instead of upstream's
self dev-dependency, preserving the standalone-parser architecture boundary.
Upstream style lints are scoped to the vendored package; production code keeps
its explicit panic/unwrap denials, while test assertions may unwrap fixtures.
Further source changes must be recorded here.
