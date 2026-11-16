#!/usr/bin/env python3
"""Check that bundled audio matches the audio manifest and the app's effects.

Run from the repository root: ``python3 Tools/audio/check_audio.py``

* Only approved sounds and synthesized fallbacks are bundled in the app.
* Nothing awaiting review, planned or rejected is bundled.
* Every approved sound has its bundled file.
* Every ``SoundEffect`` / voice line in AudioManager.swift has a manifest entry.
Exits non-zero on any problem.
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MANIFEST = ROOT / "Tools/audio/audio_manifest.json"
BUNDLE = ROOT / "AnimalPairs/Resources/Sounds"
SWIFT = ROOT / "AnimalPairs/Audio/AudioManager.swift"
CORE = ROOT / "Packages/AnimalPairsKit/Sources/AnimalPairsCore/Audio/NarrationPolicy.swift"


def main() -> int:
    manifest = json.loads(MANIFEST.read_text())
    sounds = manifest["sounds"]
    problems: list[str] = []
    bundled = {p.name for p in BUNDLE.glob("*") if p.suffix in {".wav", ".caf", ".m4a", ".mp3"}}
    allowed = {s["file"] for s in sounds if s["status"] in ("approved", "fallback")}

    for name in sorted(bundled - allowed):
        owner = next((s for s in sounds if s.get("file") == name), None)
        state = owner["status"] if owner else "not in the manifest"
        problems.append(f"bundled but not approved: {name} ({state})")
    for s in sounds:
        if s["status"] in ("approved", "fallback") and s["file"] not in bundled:
            problems.append(f"{s['status']} but missing from the bundle: {s['file']}")
    files = [s["file"] for s in sounds]
    for name in {f for f in files if files.count(f) > 1}:
        problems.append(f"file used by more than one manifest entry: {name}")

    names = {s["name"] for s in sounds}
    swift = SWIFT.read_text()
    enum_body = swift[swift.index("enum SoundEffect"):swift.index("static func animal")]
    effects = set()
    for case, raw in re.findall(r'case (\w+)(?: = "([a-z_]+)")?', enum_body):
        effects.add(raw or case)
    for effect in sorted(effects - names):
        problems.append(f"SoundEffect '{effect}' has no manifest entry")
    for cue in re.findall(r'case \w+ = "([a-z_]+)"', CORE.read_text()):
        if f"voice_{cue}" not in names:
            problems.append(f"voice line '{cue}' has no manifest entry")

    by_status: dict[str, int] = {}
    for s in sounds:
        by_status[s["status"]] = by_status.get(s["status"], 0) + 1
    print(f"{len(sounds)} manifest entries {by_status}; {len(bundled)} bundled files; "
          f"{len(effects)} app effects")
    if problems:
        print("\n".join(problems))
        return 1
    print("Audio bundle OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
