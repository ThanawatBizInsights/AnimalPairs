#!/usr/bin/env python3
"""Check that bundled audio matches the audio manifest and the app's effects.

Run from the repository root: ``python3 Tools/audio/check_audio.py``

* Only approved sounds and synthesized fallbacks are bundled in the app.
* Nothing awaiting review, planned or rejected is bundled.
* Every approved sound has its bundled file.
* Every ``SoundEffect`` in AudioManager.swift has a manifest entry; any
  bundled voice file has an approved English manifest entry.
* No Thai script in the app resources or the manifest (the app is English only).
* Every bundled audio/video file is inside the synchronized ``AnimalPairs/``
  folder with no target-membership exceptions, i.e. in the Xcode app target.
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
PROJECT = ROOT / "AnimalPairs.xcodeproj/project.pbxproj"
RESOURCES = ROOT / "AnimalPairs/Resources"


def has_thai(text: str) -> bool:
    return any("\u0e00" <= ch <= "\u0e7f" for ch in text)


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
    live = [s["file"] for s in sounds if s["status"] in ("approved", "fallback")]
    for name in {f for f in live if live.count(f) > 1}:
        problems.append(f"file claimed by more than one approved entry: {name}")
    for s in sounds:
        if s.get("replaces") and not any(o["name"] == s["replaces"] for o in sounds):
            problems.append(f"{s['name']} replaces unknown entry {s['replaces']}")

    names = {s["name"] for s in sounds}
    swift = SWIFT.read_text()
    enum_body = swift[swift.index("enum SoundEffect"):swift.index("/// Files tried, in order")]
    effects = set()
    for case, raw in re.findall(r'case (\w+)(?: = "([a-z_]+)")?', enum_body):
        effects.add(raw or case)
    for effect in sorted(effects - names):
        problems.append(f"SoundEffect '{effect}' has no manifest entry")
    approved_voice = {s["file"] for s in sounds if s.get("kind") == "voice" and s["status"] == "approved"
                      and s.get("language", "en") == "en"}
    for name in sorted(n for n in bundled if n.startswith("voice_") and n not in approved_voice):
        problems.append(f"voice file without an approved English manifest entry: {name}")

    if has_thai(MANIFEST.read_text()):
        problems.append("the audio manifest contains Thai text")
    for path in RESOURCES.rglob("*"):
        if path.suffix in {".xcstrings", ".json", ".strings", ".plist"} and has_thai(path.read_text(errors="ignore")):
            problems.append(f"Thai text in app resource {path.relative_to(ROOT)}")

    project = PROJECT.read_text()
    if "path = AnimalPairs;" not in project or "PBXFileSystemSynchronizedRootGroup" not in project:
        problems.append("AnimalPairs/ is not a synchronized group of the app target")
    if "membershipExceptions" in project:
        problems.append("the project excludes some files from the target; check membershipExceptions")
    videos = manifest.get("video", [])
    for video in videos:
        path = ROOT / video["file"]
        if not path.exists():
            problems.append(f"video missing: {video['file']}")
        elif not path.resolve().is_relative_to((ROOT / "AnimalPairs").resolve()):
            problems.append(f"video outside the app target folder: {video['file']}")

    by_status: dict[str, int] = {}
    for s in sounds:
        by_status[s["status"]] = by_status.get(s["status"], 0) + 1
    print(f"{len(sounds)} manifest entries {by_status}; {len(bundled)} bundled audio files; "
          f"{len(effects)} app effects; {len(videos)} video(s); target: synchronized AnimalPairs/ folder")
    if problems:
        print("\n".join(problems))
        return 1
    print("Audio bundle OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
