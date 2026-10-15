#!/usr/bin/env python3
"""Compare a PSD's third-party rendered composite with a reference PNG.

Install psd-tools==1.11.0 and Pillow==10.4.0, then pass the exported PSD and
an independently rendered reference. This intentionally uses psd-tools' PSD
compositor instead of the Project Ink PSD decoder.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from PIL import Image, ImageChops
from psd_tools import PSDImage, __version__


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("psd", type=Path)
    parser.add_argument("oracle_png", type=Path)
    parser.add_argument("--max-channel-delta", type=int, default=2)
    args = parser.parse_args()

    if __version__ != "1.11.0":
        parser.error(f"expected psd-tools 1.11.0, found {__version__}")
    if args.max_channel_delta < 0 or args.max_channel_delta > 255:
        parser.error("--max-channel-delta must be between 0 and 255")

    psd = PSDImage.open(args.psd)
    actual = psd.composite(force=True).convert("RGBA")
    with Image.open(args.oracle_png) as oracle_file:
        oracle = oracle_file.convert("RGBA")
    if actual.size != oracle.size:
        raise SystemExit(f"dimension mismatch: PSD {actual.size}, PNG {oracle.size}")

    difference = ImageChops.difference(actual, oracle)
    extrema = difference.getextrema()
    channel_deltas = [channel_max for _, channel_max in extrema]
    if any(delta > args.max_channel_delta for delta in channel_deltas):
        raise SystemExit(
            f"render mismatch: max channel deltas {channel_deltas}, "
            f"allowed {args.max_channel_delta}"
        )

    layers = [
        {
            "name": layer.name,
            "kind": layer.kind,
            "bbox": list(layer.bbox),
            "visible": layer.visible,
            "clipping": layer.clipping,
            "has_user_mask": layer.mask is not None,
            "mask_bbox": list(layer.mask.bbox) if layer.mask is not None else None,
        }
        for layer in psd.descendants()
    ]
    print(
        json.dumps(
            {
                "psd": str(args.psd),
                "oracle": str(args.oracle_png),
                "size": list(actual.size),
                "max_channel_deltas": channel_deltas,
                "layers": layers,
            },
            indent=2,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
