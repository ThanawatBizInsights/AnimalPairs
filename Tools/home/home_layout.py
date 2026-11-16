#!/usr/bin/env python3
"""Preview and check the home-screen layout from AnimalPairs/Resources/HomeLayout.json.

The SwiftUI HomeView reads the same JSON with the same maths, so these previews
show the app's arrangement at real device sizes (points x2). They are layout
previews, NOT simulator screenshots: fonts, shadows and the live animation are
approximations.

    python3 Tools/home/home_layout.py --check            # collision / safe-area check, all devices
    python3 Tools/home/home_layout.py --render OUT_DIR   # PNG previews (+ *_boxes.png with motion envelopes)

The check expands every character by its full wobble envelope (rotation about
the feet, bob and scale) and fails if any two characters touch, a character
touches the title, the Play button or the top controls (Resume, Sound,
Settings), or anything leaves the safe area.
"""
from __future__ import annotations

import argparse
import json
import math
import sys
from dataclasses import dataclass
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[2]
SPEC = ROOT / "AnimalPairs/Resources/HomeLayout.json"
ART = ROOT / "AnimalPairs/Assets.xcassets"
SCALE = 2


@dataclass(frozen=True)
class Device:
    name: str
    width: float
    height: float
    top: float      # safe-area insets in points
    bottom: float
    left: float = 0
    right: float = 0


DEVICES = [
    Device("iPad Air 11-inch (M3) landscape", 1180, 820, 24, 20),
    Device("iPad Air 11-inch (M3) portrait", 820, 1180, 24, 20),
    Device("iPhone 16 portrait", 393, 852, 59, 34),
    Device("iPhone 16 Pro Max portrait", 440, 956, 62, 34),
    Device("iPhone SE (3rd gen) portrait", 375, 667, 20, 0),
]

Rect = tuple[float, float, float, float]  # x0, y0, x1, y1


def hex_rgba(value: str, alpha: int = 255) -> tuple[int, int, int, int]:
    return (int(value[0:2], 16), int(value[2:4], 16), int(value[4:6], 16), alpha)


def intersects(a: Rect, b: Rect) -> bool:
    return a[0] < b[2] and b[0] < a[2] and a[1] < b[3] and b[1] < a[3]


def inside(a: Rect, b: Rect) -> bool:
    return a[0] >= b[0] - 0.5 and a[1] >= b[1] - 0.5 and a[2] <= b[2] + 0.5 and a[3] <= b[3] + 0.5


class Layout:
    """Mirrors HomeLayoutEngine in AnimalPairs/Screens/HomeView.swift."""

    def __init__(self, spec: dict, device: Device, aspects: dict[str, float]):
        self.spec, self.device, self.aspects = spec, device, aspects
        self.x0, self.y0 = device.left, device.top
        self.w = device.width - device.left - device.right
        self.h = device.height - device.top - device.bottom
        self.kind = "wide" if self.w > self.h else "tall"
        self.layout = spec["layouts"][self.kind]

    @property
    def safe(self) -> Rect:
        return (self.x0, self.y0, self.x0 + self.w, self.y0 + self.h)

    def character(self, cid: str) -> Rect:
        c = self.layout["characters"][cid]
        h = c["height"] * self.h
        w = h * self.aspects[cid]
        cx, bottom = self.x0 + c["cx"] * self.w, self.y0 + c["bottom"] * self.h
        return (cx - w / 2, bottom - h, cx + w / 2, bottom)

    def envelope(self, cid: str) -> Rect:
        x0, y0, x1, y1 = self.character(cid)
        w, h = x1 - x0, y1 - y0
        m = self.spec["motion"][cid]
        rad = math.radians(m["rotation"])
        side = h * math.sin(rad) + w * m["scale"] / 2
        top = m["bob"] + h * m["scale"] + (w / 2) * math.sin(rad)
        bottom = (w / 2) * math.sin(rad)
        return (x0 - side, y0 - top, x1 + side, y1 + bottom)

    def title(self) -> Rect:
        t = self.layout["title"]
        aspect = self.spec["wordmarkAspect"]
        width = min(t["widthFraction"] * self.w, t["maxHeightFraction"] * self.h * aspect)
        height = width / aspect
        cx, cy = self.x0 + t["cx"] * self.w, self.y0 + t["cy"] * self.h
        return (cx - width / 2, cy - height / 2, cx + width / 2, cy + height / 2)

    def play(self) -> Rect:
        p = self.layout["play"]
        width, height = min(p["width"], 0.8 * self.w), p["height"]
        cx, cy = self.x0 + p["cx"] * self.w, self.y0 + p["cy"] * self.h
        # The pulse grows the button by playPulse.scale.
        grow = self.spec["playPulse"]["scale"]
        return (cx - width * (1 + grow) / 2, cy - height * (1 + grow) / 2,
                cx + width * (1 + grow) / 2, cy + height * (1 + grow) / 2)

    def controls(self) -> list[tuple[str, Rect]]:
        bar = self.spec["topBar"]
        pad, size = bar["padding"], bar["controlSize"]
        y0 = self.y0 + (bar["height"] - size) / 2
        right = self.x0 + self.w - pad
        settings = (right - size, y0, right, y0 + size)
        sound = (right - 2 * size - 12, y0, right - size - 12, y0 + size)
        resume = (self.x0 + pad, y0, self.x0 + pad + bar["resumeWidth"], y0 + size)
        return [("Settings", settings), ("Sound", sound), ("Resume", resume)]


def load() -> tuple[dict, dict[str, float]]:
    spec = json.loads(SPEC.read_text())
    aspects = {}
    for cid in spec["motion"]:
        with Image.open(ART / f"Home/home_{cid}.imageset/home_{cid}.png") as im:
            aspects[cid] = im.width / im.height
    return spec, aspects


def check(spec: dict, aspects: dict[str, float]) -> list[str]:
    problems = []
    ids = list(spec["motion"])
    for layout_name, layout in spec["layouts"].items():
        if sorted(layout["characters"]) != sorted(ids):
            problems.append(f"{layout_name}: must place exactly one of each character")
    for cid, m in spec["motion"].items():
        host = cid == "iris"  # Iris may welcome a little more noticeably
        if abs(m["rotation"]) > (3.0 if host else 2.0):
            problems.append(f"{cid}: rotation {m['rotation']}° is above the limit")
        if not (2 <= m["bob"] <= (6 if host else 5)):
            problems.append(f"{cid}: bob {m['bob']} pt is outside 2-5 pt")
        if not (0.01 <= m["scale"] <= (0.03 if host else 0.02)):
            problems.append(f"{cid}: scale {m['scale']} is outside 1-2 %")
    phases = sorted(m["phase"] for m in spec["motion"].values())
    if len({round(p, 2) for p in phases}) != len(phases) or len({m["period"] for m in spec["motion"].values()}) < 6:
        problems.append("motion timing is not staggered enough")
    for device in DEVICES:
        lay = Layout(spec, device, aspects)
        tag = f"[{device.name} · {lay.kind}]"
        fixed = [("title", lay.title()), ("Play", lay.play())] + lay.controls()
        for i, (a_name, a) in enumerate(fixed):
            if not inside(a, lay.safe):
                problems.append(f"{tag} {a_name} leaves the safe area")
            for b_name, b in fixed[i + 1:]:
                if intersects(a, b):
                    problems.append(f"{tag} {a_name} overlaps {b_name}")
        for i, cid in enumerate(ids):
            env = lay.envelope(cid)
            if not inside(env, lay.safe):
                problems.append(f"{tag} {cid} (with wobble) leaves the safe area")
            for name, rect in fixed:
                if intersects(env, rect):
                    problems.append(f"{tag} {cid} (with wobble) touches {name}")
            for other in ids[i + 1:]:
                if intersects(env, lay.envelope(other)):
                    problems.append(f"{tag} {cid} and {other} can collide")
    return problems


def font(size: int) -> ImageFont.ImageFont:
    for path in ("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
                 "/System/Library/Fonts/Supplemental/Arial Rounded Bold.ttf"):
        if Path(path).exists():
            return ImageFont.truetype(path, size)
    return ImageFont.load_default(size=size)


def draw_decor(img: Image.Image, spec: dict, layout: dict, device: Device) -> None:
    d = ImageDraw.Draw(img, "RGBA")
    W, H = device.width * SCALE, device.height * SCALE
    unit = min(W, H)
    colors = spec["colors"]
    for item in layout["decor"]:
        kind = item["kind"]
        if kind == "hill":
            cx, cy, w, h = item["cx"] * W, item["cy"] * H, item["w"] * W, item["h"] * H
            d.ellipse((cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2), fill=hex_rgba(colors[item["color"]], 200))
        elif kind == "ground":
            d.rectangle((0, item["top"] * H, W, H), fill=hex_rgba(colors[item["color"]], 255))
        elif kind == "cloud":
            cx, cy, s = item["cx"] * W, item["cy"] * H, item["size"] * unit
            for dx, dy, r in ((-0.35, 0.1, 0.32), (0, -0.1, 0.42), (0.38, 0.08, 0.3), (0.05, 0.18, 0.34)):
                d.ellipse((cx + dx * s - r * s, cy + dy * s - r * s, cx + dx * s + r * s, cy + dy * s + r * s),
                          fill=hex_rgba(colors[item["color"]], 230))
        elif kind == "bunting":
            x1, y1, x2, y2 = item["x1"] * W, item["y1"] * H, item["x2"] * W, item["y2"] * H
            sag, n = item["sag"] * H, item["flags"]
            pts = [(x1 + (x2 - x1) * t / 40, y1 + (y2 - y1) * t / 40 + sag * math.sin(math.pi * t / 40)) for t in range(41)]
            d.line(pts, fill=hex_rgba("B39A88", 180), width=2 * SCALE)
            for k in range(n):
                t = (k + 0.5) / n
                px = x1 + (x2 - x1) * t
                py = y1 + (y2 - y1) * t + sag * math.sin(math.pi * t)
                fw, fh = unit * 0.022, unit * 0.034
                d.polygon([(px - fw, py), (px + fw, py), (px, py + fh)],
                          fill=hex_rgba(colors[item["colors"][k % len(item["colors"])]], 210))
        elif kind == "swing":
            cx, bottom, h = item["cx"] * W, item["bottom"] * H, item["height"] * H
            w = h * 0.9
            frame = hex_rgba(colors[item["frame"]], 220)
            d.line([(cx - w / 2, bottom), (cx - w / 2.6, bottom - h), (cx + w / 2.6, bottom - h), (cx + w / 2, bottom)],
                   fill=frame, width=int(h * 0.05))
            d.line([(cx - w / 8, bottom - h), (cx - w / 8, bottom - h * 0.3)], fill=hex_rgba("B39A88", 160), width=SCALE)
            d.line([(cx + w / 8, bottom - h), (cx + w / 8, bottom - h * 0.3)], fill=hex_rgba("B39A88", 160), width=SCALE)
            d.rounded_rectangle((cx - w / 6, bottom - h * 0.32, cx + w / 6, bottom - h * 0.25), radius=4,
                                fill=hex_rgba(colors[item["seat"]], 230))
        elif kind == "flower":
            cx, cy, s = item["cx"] * W, item["cy"] * H, item["size"] * unit
            for k in range(5):
                a = k * 2 * math.pi / 5
                px, py = cx + math.cos(a) * s * 0.42, cy + math.sin(a) * s * 0.42
                d.ellipse((px - s * 0.3, py - s * 0.3, px + s * 0.3, py + s * 0.3), fill=hex_rgba(colors[item["color"]], 220))
            d.ellipse((cx - s * 0.2, cy - s * 0.2, cx + s * 0.2, cy + s * 0.2), fill=hex_rgba(colors["butter"], 255))
        elif kind == "sparkle":
            cx, cy, s = item["cx"] * W, item["cy"] * H, item["size"] * unit
            pts = []
            for k in range(8):
                r = s / 2 if k % 2 == 0 else s / 7
                a = -math.pi / 2 + k * math.pi / 4
                pts.append((cx + math.cos(a) * r, cy + math.sin(a) * r))
            d.polygon(pts, fill=hex_rgba(colors[item["color"]], 220))


def render(spec: dict, aspects: dict[str, float], out: Path) -> list[Path]:
    out.mkdir(parents=True, exist_ok=True)
    written = []
    wordmark = Image.open(ART / "UI/brand_wordmark.imageset/brand_wordmark.png").convert("RGBA")
    for device in DEVICES:
        lay = Layout(spec, device, aspects)
        W, H = int(device.width * SCALE), int(device.height * SCALE)
        img = Image.new("RGBA", (W, H))
        top, bot = hex_rgba(spec["colors"]["cream"]), hex_rgba(spec["colors"]["creamDeep"])
        grad = ImageDraw.Draw(img)
        for y in range(H):
            t = y / H
            grad.line([(0, y), (W, y)], fill=tuple(int(top[i] * (1 - t) + bot[i] * t) for i in range(3)) + (255,))
        draw_decor(img, spec, lay.layout, device)

        def box(r: Rect) -> tuple[int, int, int, int]:
            return tuple(int(v * SCALE) for v in r)  # type: ignore[return-value]

        # Back rows first so nearer characters overlap correctly (sorted by feet).
        for cid in sorted(spec["motion"], key=lambda c: lay.layout["characters"][c]["bottom"]):
            x0, y0, x1, y1 = box(lay.character(cid))
            art = Image.open(ART / f"Home/home_{cid}.imageset/home_{cid}.png").convert("RGBA")
            art = art.resize((max(1, x1 - x0), max(1, y1 - y0)), Image.LANCZOS)
            img.alpha_composite(art, (x0, y0))
        tx0, ty0, tx1, ty1 = box(lay.title())
        img.alpha_composite(wordmark.resize((tx1 - tx0, ty1 - ty0), Image.LANCZOS), (tx0, ty0))

        d = ImageDraw.Draw(img, "RGBA")
        p = lay.layout["play"]
        pw, ph = min(p["width"], 0.8 * lay.w) * SCALE, p["height"] * SCALE
        pcx, pcy = (lay.x0 + p["cx"] * lay.w) * SCALE, (lay.y0 + p["cy"] * lay.h) * SCALE
        d.rounded_rectangle((pcx - pw / 2, pcy - ph / 2 + 6, pcx + pw / 2, pcy + ph / 2 + 6), radius=ph / 2, fill=(126, 87, 59, 50))
        d.rounded_rectangle((pcx - pw / 2, pcy - ph / 2, pcx + pw / 2, pcy + ph / 2), radius=ph / 2,
                            fill=(255, 180, 140, 255), outline=(227, 128, 85, 255), width=2 * SCALE)
        f = font(int(ph * 0.38))
        label = "Play"
        tw = d.textlength(label, font=f)
        d.text((pcx - tw / 2, pcy - ph * 0.24), label, font=f, fill=(74, 46, 33, 255))
        for name, r in lay.controls():
            x0, y0, x1, y1 = box(r)
            if name == "Resume":
                d.rounded_rectangle((x0, y0, x1, y1), radius=(y1 - y0) / 2, fill=(168, 224, 197, 255), outline=(43, 133, 94, 255), width=SCALE)
                fr = font(int((y1 - y0) * 0.32))
                d.text((x0 + 22 * SCALE, y0 + (y1 - y0) * 0.3), "Keep playing", font=fr, fill=(74, 46, 33, 255))
            else:
                d.ellipse((x0, y0, x1, y1), fill=(255, 253, 248, 255), outline=(157, 137, 206, 120), width=SCALE)
                icon = "♪" if name == "Sound" else "⚙"
                fi = font(int((y1 - y0) * 0.45))
                iw = d.textlength(icon, font=fi)
                d.text(((x0 + x1) / 2 - iw / 2, y0 + (y1 - y0) * 0.22), icon, font=fi, fill=(74, 46, 33, 255))
        # Unsafe areas (status bar / notch, home indicator) shaded for reference.
        if device.top:
            d.rectangle((0, 0, W, device.top * SCALE), fill=(40, 30, 60, 40))
        if device.bottom:
            d.rectangle((0, H - device.bottom * SCALE, W, H), fill=(40, 30, 60, 40))
            d.rounded_rectangle((W / 2 - 70 * SCALE, H - 12 * SCALE, W / 2 + 70 * SCALE, H - 7 * SCALE), radius=3 * SCALE, fill=(20, 20, 20, 160))
        slug = device.name.lower().replace(" ", "_").replace("(", "").replace(")", "").replace("-", "")
        path = out / f"home_{slug}.png"
        img.convert("RGB").save(path, optimize=True)
        written.append(path)

        boxes = img.copy()
        bd = ImageDraw.Draw(boxes, "RGBA")
        for cid in spec["motion"]:
            bd.rectangle(box(lay.character(cid)), outline=(43, 133, 94, 255), width=SCALE)
            bd.rectangle(box(lay.envelope(cid)), outline=(227, 80, 60, 255), width=SCALE)
        for name, r in [("title", lay.title()), ("Play", lay.play())] + lay.controls():
            bd.rectangle(box(r), outline=(80, 80, 200, 255), width=SCALE)
        bd.rectangle(box(lay.safe), outline=(0, 0, 0, 200), width=SCALE)
        boxes.convert("RGB").save(out / f"home_{slug}_boxes.png", optimize=True)
    return written


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--render", type=Path)
    args = parser.parse_args()
    spec, aspects = load()
    status = 0
    if args.check or not args.render:
        problems = check(spec, aspects)
        for device in DEVICES:
            lay = Layout(spec, device, aspects)
            print(f"{device.name:<34} {device.width:.0f}x{device.height:.0f} pt  safe {lay.w:.0f}x{lay.h:.0f}  layout {lay.kind}")
        print("\n".join(problems) if problems else "Home layout OK: no collisions (with wobble), controls clear, inside safe areas")
        status = 1 if problems else 0
    if args.render:
        for path in render(spec, aspects, args.render):
            print("wrote", path)
    return status


if __name__ == "__main__":
    sys.exit(main())
