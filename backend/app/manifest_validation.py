"""Server-side validation of artwork manifests.

Mirrors `ArtworkManifest.validate()` in the Swift package so the app never
receives a manifest it would reject, and adds publish-time checks (every
artwork has an uploaded file of the same version; placeholders blocked in
production).
"""
from __future__ import annotations

import re
from collections.abc import Callable
from typing import Any

SUPPORTED_SCHEMA_VERSION = 1
ID_PATTERN = re.compile(r"^[a-z][a-z0-9_]*$")
ASSET_PATTERN = re.compile(r"^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$")
TIERS = {"free", "premium"}
STATUSES = {"final", "placeholder"}


def validate_manifest(payload: dict[str, Any]) -> list[str]:
    """Structural validation. Returns a list of human-readable problems."""
    errors: list[str] = []
    if payload.get("schemaVersion") != SUPPORTED_SCHEMA_VERSION:
        errors.append(f"schemaVersion must be {SUPPORTED_SCHEMA_VERSION}")
    if not isinstance(payload.get("manifestVersion"), str) or not payload["manifestVersion"]:
        errors.append("manifestVersion is required")
    characters = payload.get("characters")
    artworks = payload.get("artworks")
    if not isinstance(characters, list) or not characters:
        return errors + ["characters must be a non-empty list"]
    if not isinstance(artworks, list) or not artworks:
        return errors + ["artworks must be a non-empty list"]

    character_ids: set[str] = set()
    defaults: dict[str, str] = {}
    for c in characters:
        cid = c.get("id", "")
        if not ID_PATTERN.match(cid or ""):
            errors.append(f"invalid character id {cid!r}")
            continue
        if cid in character_ids:
            errors.append(f"duplicate character {cid}")
        character_ids.add(cid)
        for key in ("nameKey", "speciesKey", "defaultPoseID"):
            if not c.get(key):
                errors.append(f"character {cid}: {key} is required")
        defaults[cid] = c.get("defaultPoseID", "")

    assets: set[str] = set()
    poses: set[tuple[str, str]] = set()
    resources: set[str] = set()
    for a in artworks:
        aid = a.get("assetID", "")
        if not ASSET_PATTERN.match(aid or ""):
            errors.append(f"invalid assetID {aid!r}")
            continue
        if aid in assets:
            errors.append(f"duplicate asset {aid}")
        assets.add(aid)
        if a.get("characterID") not in character_ids:
            errors.append(f"{aid}: unknown character {a.get('characterID')!r}")
        pose = (a.get("characterID", ""), a.get("poseID", ""))
        if pose in poses:
            errors.append(f"{aid}: duplicate pose {pose}")
        poses.add(pose)
        if not isinstance(a.get("version"), int) or a["version"] < 1:
            errors.append(f"{aid}: version must be a positive integer")
        resource = a.get("resourceName", "")
        if not resource:
            errors.append(f"{aid}: resourceName is required")
        elif resource in resources:
            errors.append(f"{aid}: duplicate resourceName {resource}")
        resources.add(resource)
        if not a.get("accessibilityKey"):
            errors.append(f"{aid}: accessibilityKey is required")
        if a.get("tier") not in TIERS:
            errors.append(f"{aid}: tier must be one of {sorted(TIERS)}")
        if a.get("status") not in STATUSES:
            errors.append(f"{aid}: status must be one of {sorted(STATUSES)}")

    for cid, default_pose in defaults.items():
        match = [a for a in artworks if a.get("characterID") == cid and a.get("poseID") == default_pose]
        if not match:
            errors.append(f"{cid}: default pose {default_pose!r} has no artwork")
        elif match[0].get("tier") != "free":
            errors.append(f"{cid}: default pose must be free")
    return errors


def publish_problems(
    payload: dict[str, Any],
    stored_version: Callable[[str, int], bool],
    allow_placeholders: bool,
) -> list[str]:
    """Checks that must pass before a manifest becomes visible to apps."""
    errors = validate_manifest(payload)
    for a in payload.get("artworks", []):
        aid, version = a.get("assetID"), a.get("version")
        if isinstance(aid, str) and isinstance(version, int) and not stored_version(aid, version):
            errors.append(f"{aid}: file for version {version} has not been uploaded")
        if a.get("status") == "placeholder" and not allow_placeholders:
            errors.append(f"{aid}: placeholder artwork cannot be published in production")
    return errors
