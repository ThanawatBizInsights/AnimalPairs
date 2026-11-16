#!/usr/bin/env python3
"""Build the home-screen character layers from the supplied PNGs.

Run from the repository root: ``python3 Tools/artwork/build_home_characters.py``

Each ``Design/Reference/Supplied/Home/home_<id>.png`` is cleaned exactly like
the card art (``clean_rgba``: stray near-transparent background specks removed,
the ~99 % opaque body made fully opaque; no colour is changed), trimmed to the
character so the image's bottom edge is the feet (the animation anchor), and
scaled down uniformly to at most 1024 px. Characters are never mirrored,
stretched or redrawn. Output: ``AnimalPairs/Assets.xcassets/Home/home_<id>``.
The trimmed aspect ratios are written to ``Tools/home/home_characters.json``.
"""
from __future__ import annotations

import json
from pathlib import Path

from PIL import Image

from build_artwork import clean_rgba

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "Design/Reference/Supplied/Home"
CATALOG = ROOT / "AnimalPairs/Assets.xcassets/Home"
ASPECTS = ROOT / "Tools/home/home_characters.json"
IDS = ["momo", "iris", "nori", "sprout", "mochi", "sunny", "maple", "clover", "rusty", "pebble"]
MAX_SIDE = 1024


def main() -> None:
    CATALOG.mkdir(parents=True, exist_ok=True)
    (CATALOG / "Contents.json").write_text(json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
    aspects = {}
    for cid in IDS:
        image = clean_rgba(Image.open(SOURCE / f"home_{cid}.png"))
        image = image.crop(image.getchannel("A").getbbox())
        scale = min(1.0, MAX_SIDE / max(image.size))
        if scale < 1:
            image = image.resize((round(image.width * scale), round(image.height * scale)), Image.LANCZOS)
        name = f"home_{cid}"
        folder = CATALOG / f"{name}.imageset"
        folder.mkdir(parents=True, exist_ok=True)
        image.save(folder / f"{name}.png", optimize=True)
        (folder / "Contents.json").write_text(json.dumps({
            "images": [{"filename": f"{name}.png", "idiom": "universal"}],
            "info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
        aspects[cid] = round(image.width / image.height, 4)
        print(f"{name}: {image.size}  aspect {aspects[cid]}")
    ASPECTS.write_text(json.dumps({"aspect_ratio_width_over_height": aspects}, indent=2) + "\n")


if __name__ == "__main__":
    main()
