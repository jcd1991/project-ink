# Independent PSD import conformance fixtures

The Photoshop-authored group/clipping document and the source raster-mask
document come from the `psd-tools` test corpus at commit
[`b58704c1c9c9b2459f961560b1e368dfb102b513`](https://github.com/psd-tools/psd-tools/tree/b58704c1c9c9b2459f961560b1e368dfb102b513/tests/psd_files).
The upstream MIT license is retained as `LICENSE-psd-tools-MIT`.

`group-clipping/group-clipping.psd` exercises a nested Photoshop group,
non-zero layer offsets, and a raster clipping chain. Its external reference
image is `group-clipping/group-clipping-photoshop.png`. The reference matches
the layer composite produced by `psd-tools` 1.11.0. Ink compares the imported
Rust document's full pixel composite against that external image; it does not
use the PSD's embedded merged image as its expected result.

The simple raster-mask file in `simple-mask/` is derived from the upstream
`mask.psd`: `generate_fixture.py` removes its unsupported shape layer, embedded
ICC profile, and position-lock metadata while retaining the Photoshop raster
user mask. It saves the candidate PSD and renders the independent PNG oracle
with `psd-tools` 1.11.0. Regenerate with:

```sh
python -m pip install psd-tools==1.11.0 Pillow==10.4.0
python generate_fixture.py
```

| File | SHA-256 |
| --- | --- |
| `LICENSE-psd-tools-MIT` | `79f7e019a30b97542cce6f6482a75ba26771b4204c374fec305dc8cf558d137f` |
| `group-clipping/group-clipping.psd` | `b8e346ee1909c793c5d1be36b01dacad7152d3f40757b4271cfb869d4a5ba141` |
| `group-clipping/group-clipping-photoshop.png` | `ba0190dfa96f17dfa6a4f9ebdc608682c54df222adc01049f66143614fd46cef` |
| `simple-mask/source-mask.psd` | `a6928c0e306022d474876e61f4b1dc5b7c1ed1e1cb422e6e72511da0a6aae90b` |
| `simple-mask/masked-raster.psd` | `b9c34875ba84382a3ecc4c51efd0671a7df868acd932d30ae5236076365d159d` |
| `simple-mask/masked-raster-psd-tools-1.11.png` | `6109728dfa8123914867c573bbb401df2d2c0c6871b496d70a5e3bbc05a3c998` |
