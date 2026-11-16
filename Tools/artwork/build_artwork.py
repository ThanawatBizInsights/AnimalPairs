#!/usr/bin/env python3
"""Build the bundled artwork image sets from the artwork manifest.

Usage (from the repository root):

    python3 -m pip install -r Tools/requirements.txt
    python3 Tools/artwork/build_artwork.py

For every artwork in ``AnimalPairs/Resources/ArtworkManifest.json``:

* ``status == "final"``: the supplied illustration in
  ``Design/Reference/Supplied/<characterID>_<poseID>.png`` is cleaned (stray
  near-transparent specks removed, the ~99 % opaque body made fully opaque),
  trimmed and centred on a square canvas, and written to the asset catalog as
  the image set ``<characterID>_<poseID>`` (the manifest's ``resourceName``).
  Detached props (water droplets, splashes) are kept: only specks smaller than
  0.05 % of the body are removed. Sizes are balanced: a pose never fills more
  than ``MAX_FILL`` of the card (compact poses get a little more margin);
  nothing is ever stretched, enlarged past its fit or cropped.
* Image sets in the Artwork catalog that the manifest no longer names are removed.
* ``status == "placeholder"``: a clearly labelled DEVELOPMENT placeholder is
  generated from the character's signature illustration. Placeholders carry a
  large pose badge (star = play, moon = nap), a tinted disc and a
  "DEV PLACEHOLDER" banner so they are visibly distinct from each other and
  from final art. They are NOT release artwork; see ASSET_CHECKLIST.md.

The script never mirrors artwork and never creates a second copy of a pair:
both cards of a pair always reference the single image set written here.
"""
from __future__ import annotations

import json
import math
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont
from scipy import ndimage

ROOT = Path(__file__).resolve().parents[2]
MANIFEST = ROOT / "AnimalPairs/Resources/ArtworkManifest.json"
SUPPLIED = ROOT / "Design/Reference/Supplied"
CATALOG = ROOT / "AnimalPairs/Assets.xcassets/Artwork"
OUTPUT_SIZE = 1024
SPECK_FRACTION = 0.0005   # detached parts smaller than this share of the body are specks
MAX_FILL = 0.45           # largest share of the card a character may cover
FONT_CANDIDATES = [
    "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
    "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
    "/Library/Fonts/Arial Bold.ttf",
]

POSE_STYLE = {
    # pose id: (disc colour, badge colour, badge kind, rotation degrees, label)
    "play": ((205, 239, 224, 255), (63, 160, 120, 255), "star", -10, "PLAY"),
    "nap": ((214, 230, 250, 255), (86, 112, 190, 255), "moon", 10, "NAP"),
}


def font(size: int) -> ImageFont.ImageFont:
    for candidate in FONT_CANDIDATES:
        if Path(candidate).exists():
            return ImageFont.truetype(candidate, size)
    return ImageFont.load_default(size=size)


def clean_rgba(image: Image.Image, min_fraction: float = 0.02, min_pixels: int = 0,
               fill_holes: bool = True) -> Image.Image:
    """Remove stray near-transparent specks and edge haze from a cut-out.

    Keeps connected opaque regions of at least ``max(min_pixels,
    min_fraction × largest region)`` pixels plus a 4 px anti-aliased fringe,
    drops everything else, and makes the ~99 % opaque body fully opaque.
    The canvas size is unchanged.
    """
    rgba = np.array(image.convert("RGBA"))
    alpha = rgba[..., 3].astype(np.int32)

    body = alpha > 128
    labels, count = ndimage.label(body)
    if count == 0:
        raise SystemExit("image has no opaque subject")
    sizes = ndimage.sum(body, labels, index=range(1, count + 1))
    threshold = max(float(min_pixels), min_fraction * float(np.max(sizes)))
    keep = np.isin(labels, [i + 1 for i, s in enumerate(sizes) if s >= threshold])
    if fill_holes:
        keep = ndimage.binary_fill_holes(keep)
    near = ndimage.binary_dilation(keep, iterations=4)

    alpha = np.where(near, alpha, 0)
    alpha = np.where(alpha < 24, 0, alpha)
    alpha = np.where(keep & (alpha >= 200), 255, alpha)
    rgba[..., 3] = alpha.astype(np.uint8)
    rgba[alpha == 0, :3] = 0
    return Image.fromarray(rgba, "RGBA")


def clean(source: Path) -> Image.Image:
    """Clean a supplied character illustration and centre it on a square canvas."""
    cleaned = clean_rgba(Image.open(source), min_fraction=SPECK_FRACTION)
    cleaned = cleaned.crop(cleaned.getchannel("A").getbbox())
    fitted = square(cleaned, padding=0.05)
    fill = float((np.array(fitted.getchannel("A")) > 128).mean())
    if fill <= MAX_FILL:
        return fitted
    # Shrink (never enlarge) so compact poses look as big as the others.
    shrink = math.sqrt(MAX_FILL / fill)
    padding = (1 / shrink * 1.10 - 1) / 2
    return square(cleaned, padding=padding)


def square(image: Image.Image, padding: float) -> Image.Image:
    w, h = image.size
    side = int(max(w, h) * (1 + 2 * padding))
    canvas = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    canvas.paste(image, ((side - w) // 2, (side - h) // 2), image)
    return canvas.resize((OUTPUT_SIZE, OUTPUT_SIZE), Image.LANCZOS)


def star(cx: float, cy: float, r: float) -> list[tuple[float, float]]:
    points = []
    for i in range(10):
        radius = r if i % 2 == 0 else r * 0.45
        angle = -math.pi / 2 + i * math.pi / 5
        points.append((cx + radius * math.cos(angle), cy + radius * math.sin(angle)))
    return points


def placeholder(signature: Image.Image, pose_id: str, character_id: str) -> Image.Image:
    disc, badge, kind, rotation, label = POSE_STYLE[pose_id]
    size = OUTPUT_SIZE
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(canvas)
    draw.ellipse((40, 40, size - 40, size - 40), fill=disc, outline=badge, width=14)

    figure = signature.resize((int(size * 0.66), int(size * 0.66)), Image.LANCZOS)
    figure = figure.rotate(rotation, resample=Image.BICUBIC, expand=True)
    fx = (size - figure.width) // 2
    fy = (size - figure.height) // 2 + 30
    canvas.alpha_composite(figure, (fx, fy))

    draw = ImageDraw.Draw(canvas)
    bx, by, br = size - 190, 190, 130
    if kind == "star":
        draw.polygon(star(bx, by, br), fill=badge, outline=(255, 255, 255, 255))
    else:
        draw.ellipse((bx - br, by - br, bx + br, by + br), fill=badge)
        draw.ellipse((bx - br * 0.35, by - br * 1.05, bx + br * 1.25, by + br * 0.75), fill=disc)

    banner_font = font(50)
    draw.rounded_rectangle((90, size - 215, size - 90, size - 95), radius=40, fill=(74, 46, 33, 235))
    text = f"DEV PLACEHOLDER · {label}"
    tw = draw.textlength(text, font=banner_font)
    draw.text(((size - tw) / 2, size - 192), text, font=banner_font, fill=(255, 248, 236, 255))

    small = font(44)
    name = f"{character_id}.{pose_id}"
    nw = draw.textlength(name, font=small)
    draw.text(((size - nw) / 2, 70), name, font=small, fill=badge)
    return canvas


def write_imageset(name: str, image: Image.Image) -> None:
    folder = CATALOG / f"{name}.imageset"
    folder.mkdir(parents=True, exist_ok=True)
    image.save(folder / f"{name}.png", optimize=True)
    contents = {
        "images": [{"filename": f"{name}.png", "idiom": "universal"}],
        "info": {"author": "xcode", "version": 1},
    }
    (folder / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n")


def main() -> int:
    manifest = json.loads(MANIFEST.read_text())
    CATALOG.mkdir(parents=True, exist_ok=True)
    wanted = {art["resourceName"] for art in manifest["artworks"]}
    for stale in sorted(CATALOG.glob("*.imageset")):
        if stale.name.removesuffix(".imageset") not in wanted:
            for f in stale.iterdir():
                f.unlink()
            stale.rmdir()
            print(f"removed     {stale.name}")
    (CATALOG / "Contents.json").write_text(
        json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2) + "\n"
    )
    signatures: dict[str, Image.Image] = {}
    missing: list[str] = []
    for art in manifest["artworks"]:
        if art["status"] != "final":
            continue
        source = SUPPLIED / f"{art['characterID']}_{art['poseID']}.png"
        if not source.exists():
            missing.append(str(source.relative_to(ROOT)))
            continue
        image = clean(source)
        write_imageset(art["resourceName"], image)
        if art["poseID"] == "signature":
            signatures[art["characterID"]] = image
        print(f"final       {art['assetID']}")
    for art in manifest["artworks"]:
        if art["status"] != "placeholder":
            continue
        signature = signatures.get(art["characterID"])
        if signature is None:
            missing.append(f"signature art for {art['characterID']} (needed for placeholder)")
            continue
        write_imageset(art["resourceName"], placeholder(signature, art["poseID"], art["characterID"]))
        print(f"placeholder {art['assetID']}")
    if missing:
        print("Missing sources:\n  " + "\n  ".join(missing), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
