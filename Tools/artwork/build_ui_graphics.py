#!/usr/bin/env python3
"""Build the app icon and interface graphics from the supplied originals.

Run from the repository root (after ``pip install -r Tools/requirements.txt``):

    python3 Tools/artwork/build_ui_graphics.py

Sources (kept untouched) in ``Design/Reference/Supplied/``:

* ``ui_app_icon.png``       → ``AppIcon.appiconset`` (1024 px, opaque, square)
* ``ui_wordmark.png``       → ``UI/brand_wordmark``      (Home and Welcome title)
* ``ui_group_animals.png``  → ``UI/home_group_animals``  (Home and Welcome)
* ``ui_trophy_badge.png``   → ``UI/results_trophy``      (Results)
* ``ui_floral_corners.png`` → ``UI/decor_corner_*``      (four corner accents)
* ``ui_card_back.webp``     → ``UI/card_back``          (back of every card)

Processing:

* The icon was delivered with white, pre-rounded corners. iPadOS applies its
  own (smaller-radius) mask, which would leave white slivers, so the white
  corner regions are filled from the neighbouring artwork. Nothing is cropped.
* Transparent graphics get the same speck/halo cleanup as the character art
  (``clean_rgba``), are trimmed, and are downscaled to a sensible maximum.
* The floral sheet is split into four independent corner images so each can
  be pinned to a screen corner at any window size without stretching.
"""
from __future__ import annotations

import json
from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter
from scipy import ndimage

from build_artwork import clean_rgba

ROOT = Path(__file__).resolve().parents[2]
SUPPLIED = ROOT / "Design/Reference/Supplied"
CATALOG = ROOT / "AnimalPairs/Assets.xcassets"
UI = CATALOG / "UI"


def write_imageset(name: str, image: Image.Image) -> None:
    folder = UI / f"{name}.imageset"
    folder.mkdir(parents=True, exist_ok=True)
    image.save(folder / f"{name}.png", optimize=True)
    contents = {"images": [{"filename": f"{name}.png", "idiom": "universal"}],
                "info": {"author": "xcode", "version": 1}}
    (folder / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n")


def fit(image: Image.Image, max_side: int) -> Image.Image:
    scale = min(1.0, max_side / max(image.size))
    if scale == 1.0:
        return image
    return image.resize((round(image.width * scale), round(image.height * scale)), Image.LANCZOS)


def trimmed(image: Image.Image) -> Image.Image:
    return image.crop(image.getchannel("A").getbbox())


def build_icon() -> None:
    source = Image.open(SUPPLIED / "ui_app_icon.png").convert("RGB")
    rgb = np.array(source).astype(np.float32)
    # White regions connected to the four corners are the baked-in rounding.
    near_white = rgb.min(axis=2) >= 246
    labels, _ = ndimage.label(near_white)
    h, w = near_white.shape
    corner_labels = {labels[0, 0], labels[0, w - 1], labels[h - 1, 0], labels[h - 1, w - 1]} - {0}
    mask = ndimage.binary_dilation(np.isin(labels, list(corner_labels)), iterations=3)

    # Fill every masked pixel from its nearest unmasked neighbour, then soften
    # only the filled region so the fill reads as out-of-focus background.
    _, (iy, ix) = ndimage.distance_transform_edt(mask, return_indices=True)
    filled = rgb[iy, ix]
    blurred = np.array(Image.fromarray(filled.astype(np.uint8)).filter(ImageFilter.GaussianBlur(6))).astype(np.float32)
    soft = ndimage.gaussian_filter(mask.astype(np.float32), 2)[..., None]
    result = rgb * (1 - soft) + blurred * soft
    icon = Image.fromarray(np.clip(result, 0, 255).astype(np.uint8), "RGB").resize((1024, 1024), Image.LANCZOS)

    folder = CATALOG / "AppIcon.appiconset"
    folder.mkdir(parents=True, exist_ok=True)
    icon.save(folder / "AppIcon.png", optimize=True)
    (folder / "Contents.json").write_text(json.dumps({
        "images": [{"filename": "AppIcon.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}],
        "info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
    print(f"app icon      filled {int(mask.sum())} corner pixels")


def build_transparent() -> None:
    wordmark = trimmed(clean_rgba(Image.open(SUPPLIED / "ui_wordmark.png")))
    write_imageset("brand_wordmark", fit(wordmark, 1600))

    group = trimmed(clean_rgba(Image.open(SUPPLIED / "ui_group_animals.png")))
    write_imageset("home_group_animals", fit(group, 1600))

    # Small sparkle dashes are real content: keep components ≥ 300 px.
    trophy = trimmed(clean_rgba(Image.open(SUPPLIED / "ui_trophy_badge.png"),
                                min_fraction=0.0, min_pixels=300, fill_holes=False))
    write_imageset("results_trophy", fit(trophy, 1024))

    floral = Image.open(SUPPLIED / "ui_floral_corners.png").convert("RGBA")
    w, h = floral.size
    quadrants = {
        "decor_corner_top_left": (0, 0, w // 2, h // 2),
        "decor_corner_top_right": (w // 2, 0, w, h // 2),
        "decor_corner_bottom_left": (0, h // 2, w // 2, h),
        "decor_corner_bottom_right": (w // 2, h // 2, w, h),
    }
    for name, box in quadrants.items():
        corner = trimmed(clean_rgba(floral.crop(box), min_fraction=0.0, min_pixels=200, fill_holes=False))
        write_imageset(name, fit(corner, 640))
    # The card back is drawn at card size, so keep it crisp but modest.
    card_back = trimmed(clean_rgba(Image.open(SUPPLIED / "ui_card_back.webp")))
    write_imageset("card_back", fit(card_back, 1024))
    print("ui graphics   wordmark, group, trophy, 4 floral corners, card back")


def main() -> None:
    UI.mkdir(parents=True, exist_ok=True)
    (UI / "Contents.json").write_text(json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
    build_icon()
    build_transparent()


if __name__ == "__main__":
    main()
