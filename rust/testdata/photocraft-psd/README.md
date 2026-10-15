# Photoshop-authored PSD oracle fixtures

These unmodified PSDs come from the PhotoCraft Corpus at commit
`b2e1dcba8954efa9ad0e7944c258cc0e9a5efc1e`:
<https://github.com/storytold/photocraft-corpus/tree/b2e1dcba8954efa9ad0e7944c258cc0e9a5efc1e/photoshop/adjustments/rgb8>.
The corpus README identifies these files as generated from scratch in Adobe
Photoshop 2026 and saved with Photoshop's merged composite. The corpus is
dual-licensed under MIT or Apache-2.0; the applicable licenses and NOTICE are
included beside the fixtures. The upstream SHA256SUMS file was verified before
copying, and the source hashes are recorded below.

| File | Upstream SHA-256 | Purpose |
|---|---|---|
| `baseline-layer-copy.psd` | `9f8891cc875196eb26a91e91879bae1e59719cf7fb806d5d7c80301d0ca18914` | Two ordinary raster layers; also exercises explicit flatten fallback because its background has unsupported position lock. |
| `clipped-hue-sat-blend-color.psd` | `d8e9eefd434a1c762a2df2ef17a19e13e2b0d16218a8235d3294748e9f45fd9b` | Pixel layers plus a clipped, masked Hue/Saturation adjustment with an unsupported blend mode. |
| `masked-curves-gradient-mask-opacity60.psd` | `0431b691dc293ebb00ef423ebf23bc7f74500753e1c927380c3d9ad8bbb8f601` | Pixel layer plus a masked Curves adjustment. |

The `.rgba` files are row-major RGBA8 copies of the embedded merged image,
extracted using `psd-tools` 1.11.0 (Pillow) with ICC conversion disabled. They
are independent expected pixels for the PSD decoder's merged-image path; the
layer recomposition of the unsupported adjustment examples is deliberately
not treated as an oracle for Photoshop's adjustment evaluator.
