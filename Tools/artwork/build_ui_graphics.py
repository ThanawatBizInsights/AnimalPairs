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
* Little Penguin Studio brand art (promo, mascot poses, stickers): see
  ``build_brand_art`` below.

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


# --- Little Penguin Studio brand art (mascot, stickers, promo) -------------
#
# Sources (kept untouched) in ``Design/Reference/Supplied/``:
#
# * ``ui_promo_penguin_cards.png`` → ``UI/promo_penguin_cards`` (Parents banner)
# * ``ui_mascot_poses.png``        → ``UI/mascot_{wave,star,peek,reading}``
# * ``ui_sticker_sheet.png``       → ``UI/sticker_*`` (only the stickers in use)
# * ``ui_pastel_card_set.png``     → not built: its faces don't match the game's
#                                    characters (see ASSET_CHECKLIST.md)
#
# The penguin is the studio mascot, not Pebble (Pebble's card art is unchanged).

# Sheet layouts, row by row.
MASCOT_GRID = [["mascot_wave", "mascot_star"],
               ["mascot_peek", "mascot_reading"]]
STICKER_GRID = [["sticker_star", "sticker_cloud_blue", "sticker_flower", "sticker_ring"],
                ["sticker_leaf", "sticker_squiggle", "sticker_heart", "sticker_sparkles"],
                ["sticker_cloud_lilac", "sticker_bubbles", "sticker_rainbow", "sticker_confetti"]]
# Stickers bundled in the app today; the rest stay as sources until needed.
STICKERS_IN_USE = {"sticker_star", "sticker_heart", "sticker_flower", "sticker_sparkles",
                   "sticker_confetti", "sticker_rainbow", "sticker_bubbles", "sticker_cloud_lilac"}

PAD_FRACTION = 0.06      # equal transparent margin around every extracted item
SPECK_PIXELS = 40        # components smaller than this are noise, not artwork


def require_transparency(image: Image.Image, name: str) -> None:
    """Fail unless the source really has an alpha channel with transparent areas."""
    if "A" not in image.getbands():
        raise SystemExit(f"{name}: no alpha channel — a dark/black preview background is not transparency")
    clear = float((np.array(image.getchannel("A")) < 10).mean())
    if clear < 0.05:
        raise SystemExit(f"{name}: only {clear:.1%} transparent — expected a cut-out sheet")


def padded(image: Image.Image) -> Image.Image:
    """Trim to the artwork and add the same transparent margin on every side."""
    item = trimmed(image)
    pad = round(max(item.size) * PAD_FRACTION)
    canvas = Image.new("RGBA", (item.width + 2 * pad, item.height + 2 * pad), (0, 0, 0, 0))
    canvas.paste(item, (pad, pad))
    return canvas


def split_sheet(sheet: Image.Image, grid: list[list[str]], name: str) -> dict[str, Image.Image]:
    """Cut a sprite sheet into one image per grid cell.

    Every connected piece of artwork (motion lines, sparkle clusters and
    bubbles included) is assigned to the cell holding its centre. A piece that
    reaches well into a neighbouring cell stops the build, so no item can pick
    up part of its neighbour. Other cells' pixels are cleared from each crop.
    """
    rgba = np.array(sheet.convert("RGBA"))
    h, w = rgba.shape[:2]
    rows, cols = len(grid), len(grid[0])
    cell_w, cell_h = w / cols, h / rows

    present = rgba[..., 3] > 8
    # Join anti-aliased fringes of one piece without merging separate items.
    labels, count = ndimage.label(ndimage.binary_dilation(present, iterations=2))
    labels = np.where(present, labels, 0)
    owner = np.full(count + 1, -1, dtype=np.int32)
    for index, box in enumerate(ndimage.find_objects(labels), start=1):
        if box is None or int((labels[box] == index).sum()) < SPECK_PIXELS:
            continue  # stray speck: belongs to nothing and is dropped
        cy = (box[0].start + box[0].stop) / 2
        cx = (box[1].start + box[1].stop) / 2
        row, col = min(int(cy // cell_h), rows - 1), min(int(cx // cell_w), cols - 1)
        slack_x, slack_y = cell_w * 0.12, cell_h * 0.12
        if (box[1].start < col * cell_w - slack_x or box[1].stop > (col + 1) * cell_w + slack_x
                or box[0].start < row * cell_h - slack_y or box[0].stop > (row + 1) * cell_h + slack_y):
            raise SystemExit(f"{name}: a piece at x={box[1].start}-{box[1].stop}, y={box[0].start}-{box[0].stop} "
                             f"crosses into a neighbouring cell — the sheet layout does not match {rows}×{cols}")
        owner[index] = row * cols + col

    items: dict[str, Image.Image] = {}
    for row in range(rows):
        for col in range(cols):
            mine = owner[labels] == row * cols + col
            if not mine.any():
                raise SystemExit(f"{name}: cell {row},{col} ({grid[row][col]}) is empty")
            cell = rgba.copy()
            cell[..., 3] = np.where(mine, cell[..., 3], 0)
            items[grid[row][col]] = Image.fromarray(cell, "RGBA")
    return items


def extracted(item: Image.Image) -> Image.Image:
    """Speck cleanup that keeps small real details (motion lines, confetti dots)."""
    return padded(clean_rgba(item, min_fraction=0.0, min_pixels=SPECK_PIXELS, fill_holes=False))


def build_brand_art(source: Path = SUPPLIED) -> dict[str, Image.Image]:
    """Build the brand art image sets; returns them (name → image) for previews."""
    out: dict[str, Image.Image] = {}

    promo_src = Image.open(source / "ui_promo_penguin_cards.png")
    require_transparency(promo_src, "ui_promo_penguin_cards.png")
    out["promo_penguin_cards"] = fit(extracted(promo_src), 1600)

    poses_src = Image.open(source / "ui_mascot_poses.png")
    require_transparency(poses_src, "ui_mascot_poses.png")
    for item_name, item in split_sheet(poses_src, MASCOT_GRID, "ui_mascot_poses.png").items():
        out[item_name] = fit(extracted(item), 1024)

    stickers_src = Image.open(source / "ui_sticker_sheet.png")
    require_transparency(stickers_src, "ui_sticker_sheet.png")
    for item_name, item in split_sheet(stickers_src, STICKER_GRID, "ui_sticker_sheet.png").items():
        if item_name in STICKERS_IN_USE:
            out[item_name] = fit(extracted(item), 512)

    # Checked for transparency only; deliberately not added to the catalog.
    require_transparency(Image.open(source / "ui_pastel_card_set.png"), "ui_pastel_card_set.png")
    return out


def main() -> None:
    UI.mkdir(parents=True, exist_ok=True)
    (UI / "Contents.json").write_text(json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
    build_icon()
    build_transparent()
    brand = build_brand_art()
    for item_name, image in brand.items():
        write_imageset(item_name, image)
    print(f"brand art     {', '.join(sorted(brand))}")


if __name__ == "__main__":
    main()
