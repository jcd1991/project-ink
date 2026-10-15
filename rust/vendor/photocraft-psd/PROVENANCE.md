# Vendored parser provenance

Source: `storytold/photocraft`, commit
`5ecc860ac1abf8fa7e3f218c0474cdcce49fa6c7`, crate `crates/psd`.

The parser source is distributed under MIT; the upstream `LICENSE-MIT` is
retained here. Project Ink uses the pinned PSD/ABR format parser and keeps its
own document model, resource budgets, import report, and transaction boundary.
Local changes should be limited to the Cargo manifest and narrow compatibility
fixes required by Project Ink. The parser has Project Ink limits of 1,024
layers, 4,096 image resources, and 32 tagged blocks per section; these checks
run before the corresponding vectors grow. Record any further source changes
in this file.
