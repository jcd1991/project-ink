"""Regenerate the bounded raster-mask PSD and psd-tools pixel oracle."""

from pathlib import Path

from psd_tools import PSDImage, __version__
from psd_tools.constants import Resource, Tag


if __version__ != "1.11.0":
    raise SystemExit(f"expected psd-tools 1.11.0, found {__version__}")

root = Path(__file__).resolve().parent
psd = PSDImage.open(root / "source-mask.psd")
if [layer.name for layer in psd] != ["Background", "Background copy", "Shape 1"]:
    raise SystemExit("upstream mask fixture changed; review before regenerating")

# Keep the actual Photoshop raster user mask. Remove the separate shape layer,
# ICC profile, and position-lock metadata that are outside Ink's editable PSD
# subset and unrelated to the mask composite this fixture exercises.
psd.pop(2)
psd._record.image_resources.pop(Resource.ICC_PROFILE, None)
for layer in psd:
    layer._record.tagged_blocks.pop(Tag.PROTECTED_SETTING, None)

output = root / "masked-raster.psd"
psd.save(output)
reopened = PSDImage.open(output)
mask = reopened[1].mask
if mask is None or mask.bbox != (23, 10, 94, 67):
    raise SystemExit("upstream raster-mask bounds changed")
reopened.composite(force=True).convert("RGBA").save(
    root / "masked-raster-psd-tools-1.11.png"
)
