# Independent layered PSD fixture

`sample-design-640x480.psd` is the 640 × 480, RGB 8-bit, four-layer sample
published by [Pine & Birch](https://www.pine-and-birch.com/sample-files/images/psd).
The publisher says it was authored byte-by-byte against Adobe's public PSD
format specification, generated artwork, and is free to use and redistribute
for any purpose. It is independently authored rather than saved by Photoshop.

The `.oracle.png` is the flattened RGBA result independently rendered from the
PSD with `psd-tools` 1.11.0 and Pillow, with no color-profile conversion. The
integration test verifies editable layer names and availability, then compares
the Rust merged-image decoder against that oracle byte-for-byte.

| File | SHA-256 |
| --- | --- |
| `sample-design-640x480.psd` | `1191c7975329d5668a4154b8b7a418d08eb16c4063d8fb44e22d94799d844937` |
| `sample-design-640x480.oracle.png` | `50a0b2a0853f24e10b0cf467daad54f4b8f0af627edb089dca9f922ecaadea16` |
