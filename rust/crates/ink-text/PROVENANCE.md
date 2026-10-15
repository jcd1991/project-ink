# Text renderer provenance

The Japanese vertical-layout behavior was evaluated against PhotoCraft's
text-layout implementation at commit
[`5ecc860ac1abf8fa7e3f218c0474cdcce49fa6c7`](https://github.com/storytold/photocraft/tree/5ecc860ac1abf8fa7e3f218c0474cdcce49fa6c7/crates/text/src).
Project Ink keeps its own transport-neutral text types and uses Parley for
shaping plus Skrifa for glyph outlines. No PhotoCraft source files are vendored
in this crate; vertical punctuation, column order, source-cluster mapping, and
outline rasterization are implemented against Project Ink's value types.

This renderer does not depend on PhotoCraft's app, document model, or painting
engine. Its text dependencies and bundled fonts are licensed independently;
the font source commit and hashes are recorded in `rust/assets/fonts/cjk/PROVENANCE.md`.
