#!/usr/bin/env python3
"""Verify the String Catalog covers every key the app uses, in every language.

Run from the repository root: ``python3 Tools/localization/check_strings.py``

Checks:
* every literal key passed to the Localizer (``t["key"]``, ``t("key", …)``,
  ``localizer[...]``) exists in Localizable.xcstrings;
* every manifest character/artwork key exists;
* every entry has a translated ``en`` and ``th`` value;
* format specifiers (%@, %lld, …) match between languages.
Exits non-zero on any problem.
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CATALOG = ROOT / "AnimalPairs/Resources/Localizable.xcstrings"
MANIFEST = ROOT / "AnimalPairs/Resources/ArtworkManifest.json"
LANGUAGES = ("en", "th")
KEY_PATTERN = re.compile(r'(?:\bt|localizer|self)(?:\[|\()"([a-z][A-Za-z0-9_.]*)"')
SPEC_PATTERN = re.compile(r"%(?:\d+\$)?(?:lld|ld|d|@|f|\.\d+f)")


def main() -> int:
    catalog = json.loads(CATALOG.read_text())["strings"]
    problems: list[str] = []

    used: set[str] = set()
    for swift in (ROOT / "AnimalPairs").rglob("*.swift"):
        used.update(m for m in KEY_PATTERN.findall(swift.read_text()) if "." in m)
    manifest = json.loads(MANIFEST.read_text())
    for character in manifest["characters"]:
        used.update({character["nameKey"], character["speciesKey"]})
    for art in manifest["artworks"]:
        used.add(art["accessibilityKey"])
    used.update(f"number.{n}" for n in range(3, 10))

    for key in sorted(used):
        if key not in catalog:
            problems.append(f"missing key: {key}")

    for key, entry in catalog.items():
        locs = entry.get("localizations", {})
        values = {}
        for lang in LANGUAGES:
            unit = locs.get(lang, {}).get("stringUnit", {})
            if unit.get("state") != "translated" or not unit.get("value"):
                problems.append(f"{key}: no translated '{lang}' value")
            values[lang] = unit.get("value", "")
        specs = {lang: sorted(SPEC_PATTERN.findall(v)) for lang, v in values.items()}
        if len({tuple(s) for s in specs.values()}) > 1:
            problems.append(f"{key}: format specifiers differ {specs}")

    unused = sorted(set(catalog) - used)
    print(f"{len(used)} keys used, {len(catalog)} in catalog, {len(unused)} not referenced statically")
    if problems:
        print("\n".join(problems))
        return 1
    print("String Catalog OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
