#!/usr/bin/env python3
"""Compose a DEVELOPMENT app icon (opaque, 1024x1024) from the supplied art.

Run after build_artwork.py. Replace with a designed icon before release
(listed in ASSET_CHECKLIST.md).
"""
from pathlib import Path
import json
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[2]
ART = ROOT / "AnimalPairs/Assets.xcassets/Artwork"
OUT = ROOT / "AnimalPairs/Assets.xcassets/AppIcon.appiconset"


def art(name: str, size: int) -> Image.Image:
    return Image.open(ART / f"art_{name}.imageset/art_{name}.png").resize((size, size), Image.LANCZOS)


icon = Image.new("RGBA", (1024, 1024), (255, 248, 236, 255))
draw = ImageDraw.Draw(icon)
draw.rounded_rectangle((70, 150, 520, 870), radius=70, fill=(201, 184, 232, 255))
draw.rounded_rectangle((504, 150, 954, 870), radius=70, fill=(201, 184, 232, 255))
icon.alpha_composite(art("momo_signature", 470), (60, 280))
icon.alpha_composite(art("momo_signature", 470), (494, 280))
OUT.mkdir(parents=True, exist_ok=True)
icon.convert("RGB").save(OUT / "AppIcon.png", optimize=True)
(OUT / "Contents.json").write_text(json.dumps({
    "images": [{"filename": "AppIcon.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}],
    "info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
print("wrote AppIcon.png")
