#!/usr/bin/env python3
"""Generate, review and approve Animal Pairs sounds (ElevenLabs Sound Effects API).

OFFLINE developer tool. The iPad app never calls ElevenLabs: it only plays
files bundled in ``AnimalPairs/Resources/Sounds/``, and only *approved* files
are copied there.

Source of truth: ``Tools/audio/audio_manifest.json`` (prompts, durations,
credits, approval status). Every API attempt is also appended to
``Tools/audio/elevenlabs_credit_log.json``.

The API key is read only from ``ELEVENLABS_API_KEY``; it is never printed,
logged or written to disk:

    export ELEVENLABS_API_KEY='sk_…'

Usage (from the repository root):

    python3 Tools/audio/generate_elevenlabs_sfx.py --status
    python3 Tools/audio/generate_elevenlabs_sfx.py --batch batch2_interface --dry-run
    python3 Tools/audio/generate_elevenlabs_sfx.py --batch batch2_interface
    python3 Tools/audio/generate_elevenlabs_sfx.py --approve mode_select back
    python3 Tools/audio/generate_elevenlabs_sfx.py --reject confetti --reason "too loud"
    python3 Tools/audio/generate_elevenlabs_sfx.py --batch batch2_interface --only confetti   # regenerate a rejected one

Rules: approved sounds are never regenerated or overwritten; new audio goes
to ``Design/Audio/Review/`` until approved; a batch stops before its credit
limit (estimated at the documented 40 credits/second, ~4x the observed rate).

Requires: Python 3.10+, numpy, ffmpeg on PATH.
"""
from __future__ import annotations

import argparse
import json
import math
import os
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
MANIFEST = ROOT / "Tools/audio/audio_manifest.json"
LEDGER = ROOT / "Tools/audio/elevenlabs_credit_log.json"
MASTERS = ROOT / "Design/Audio/ElevenLabs"
REVIEW = ROOT / "Design/Audio/Review"
BUNDLE = ROOT / "AnimalPairs/Resources/Sounds"
API = "https://api.elevenlabs.io"
OUTPUT_FORMAT = "mp3_44100_128"
SAMPLE_RATE = 44_100
TARGET_LOUDNESS_DBFS = -18.0     # loudest 50 ms window (RMS) of every effect
PEAK_CEILING_DBFS = -3.0
SILENCE_DBFS = -50.0
UNUSABLE_PEAK_DBFS = -40.0       # anything quieter is treated as a failed take


# MARK: Manifest and ledger

def load_json(path: Path, default: dict) -> dict:
    return json.loads(path.read_text()) if path.exists() else default


def save_json(path: Path, data: dict) -> None:
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def estimate_credits(manifest: dict, duration: float) -> int:
    return math.ceil(duration * manifest["credit_policy"]["estimate_credits_per_second"])


def batch_charged(ledger: dict, batch: str) -> int:
    return sum(e.get("charged_credits", 0) for e in ledger["entries"] if e.get("batch") == batch)


# MARK: API

def request(method: str, path: str, key: str, body: dict | None = None,
            query: str = "") -> tuple[int, dict, bytes]:
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(f"{API}{path}{query}", data=data, method=method)
    req.add_header("xi-api-key", key)  # never logged
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            return resp.status, dict(resp.headers), resp.read()
    except urllib.error.HTTPError as error:
        return error.code, dict(error.headers or {}), error.read()


def account_remaining(key: str) -> int | None:
    """Remaining account credits, if the key may read them (user_read)."""
    status, _, body = request("GET", "/v1/user/subscription", key)
    if status != 200:
        return None
    try:
        data = json.loads(body)
        return int(data["character_limit"]) - int(data["character_count"])
    except (ValueError, KeyError, TypeError):
        return None


def error_detail(body: bytes) -> str:
    try:
        detail = json.loads(body).get("detail", {})
        if isinstance(detail, dict):
            return f"{detail.get('status', '')}: {detail.get('message', '')}".strip(": ")
        return str(detail)[:200]
    except (ValueError, AttributeError):
        return body[:200].decode(errors="replace")


# MARK: Audio processing

def decode(path: Path) -> np.ndarray:
    pcm = subprocess.run(
        ["ffmpeg", "-v", "error", "-i", str(path), "-ac", "1", "-ar", str(SAMPLE_RATE), "-f", "f32le", "-"],
        check=True, capture_output=True).stdout
    return np.frombuffer(pcm, dtype=np.float32).astype(np.float64)


def window_loudness(audio: np.ndarray, window_seconds: float = 0.05) -> float:
    """RMS of the loudest short window: how loud a brief effect is perceived."""
    size = max(1, min(audio.size, int(window_seconds * SAMPLE_RATE)))
    power = np.convolve(audio ** 2, np.ones(size) / size, mode="valid")
    return float(np.sqrt(np.max(power)))


def process(master: Path, target: Path) -> dict:
    """Trim silence, loudness-match, fade, and write 16-bit mono WAV."""
    audio = decode(master)
    if audio.size == 0:
        raise ValueError("decoded to no audio")
    peak_in = 20 * math.log10(max(float(np.max(np.abs(audio))), 1e-9))
    if peak_in < UNUSABLE_PEAK_DBFS:
        raise ValueError(f"near-silent output (peak {peak_in:.0f} dBFS)")
    threshold = 10 ** (SILENCE_DBFS / 20)
    loud = np.nonzero(np.abs(audio) > threshold)[0]
    start = max(0, loud[0] - int(0.005 * SAMPLE_RATE))
    end = min(audio.size, loud[-1] + int(0.05 * SAMPLE_RATE))
    audio = audio[start:end]

    gain = 10 ** (TARGET_LOUDNESS_DBFS / 20) / max(window_loudness(audio), 1e-9)
    ceiling = 10 ** (PEAK_CEILING_DBFS / 20)
    peak = float(np.max(np.abs(audio))) * gain
    if peak > ceiling:
        gain *= ceiling / peak
    audio = audio * gain

    fade_in = min(int(0.005 * SAMPLE_RATE), audio.size // 4)
    fade_out = min(int(0.04 * SAMPLE_RATE), audio.size // 4)
    if fade_in:
        audio[:fade_in] *= np.linspace(0, 1, fade_in)
    if fade_out:
        audio[-fade_out:] *= np.linspace(1, 0, fade_out)

    target.parent.mkdir(parents=True, exist_ok=True)
    pcm = (np.clip(audio, -1, 1) * 32767).astype("<i2").tobytes()
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "s16le", "-ar", str(SAMPLE_RATE), "-ac", "1",
                    "-i", "-", str(target)], input=pcm, check=True)
    return {"final_duration_seconds": round(audio.size / SAMPLE_RATE, 3),
            "peak_dbfs": round(20 * math.log10(max(float(np.max(np.abs(audio))), 1e-9)), 1),
            "loudness_dbfs": round(20 * math.log10(max(window_loudness(audio), 1e-9)), 1)}


# MARK: Commands

def review_path(sound: dict) -> Path:
    """Review copies are named after the manifest entry, so a revision
    (e.g. star_earn_v2) never collides with the approved file it may replace."""
    return REVIEW / f"{sound['name']}{Path(sound['file']).suffix}"


def bundle_path(sound: dict) -> Path:
    return ROOT / sound.get("bundle_dir", "AnimalPairs/Resources/Sounds") / sound["file"]


def show_status(manifest: dict) -> None:
    print(f"{'name':<22}{'batch':<18}{'status':<16}{'req s':>6}{'final s':>8}  file")
    for s in manifest["sounds"]:
        print(f"{s['name']:<22}{s['batch']:<18}{s['status']:<16}{s.get('duration_seconds', ''):>6}"
              f"{s.get('final_duration_seconds', ''):>8}  {s.get('file', '')}")


def approve(manifest: dict, names: list[str]) -> int:
    failures = 0
    for name in names:
        sound = next((s for s in manifest["sounds"] if s["name"] == name), None)
        if sound is None or sound["status"] != "awaiting_review":
            print(f"skip {name}: not awaiting review ({sound['status'] if sound else 'unknown'})")
            failures += 1
            continue
        target = bundle_path(sound)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(review_path(sound), target)
        sound["status"] = "approved"
        sound["approved_at"] = now_iso()
        replaced = next((s for s in manifest["sounds"] if s["name"] == sound.get("replaces")), None)
        if replaced is not None:
            replaced["status"] = "superseded"
            replaced["superseded_by"] = name
        print(f"approved {name} -> {target.relative_to(ROOT)}"
              f"{' (supersedes ' + replaced['name'] + ')' if replaced else ''}")
    save_json(MANIFEST, manifest)
    return 1 if failures else 0


def reject(manifest: dict, names: list[str], reason: str) -> int:
    for name in names:
        sound = next((s for s in manifest["sounds"] if s["name"] == name), None)
        if sound is None or sound["status"] != "awaiting_review":
            print(f"skip {name}: only sounds awaiting review can be rejected")
            continue
        stamp = now_iso().replace(":", "")
        for path in (MASTERS / f"{name}.mp3", review_path(sound)):
            if path.exists():
                dest = MASTERS / "rejected" / f"{path.stem}-{stamp}{path.suffix}"
                dest.parent.mkdir(parents=True, exist_ok=True)
                path.replace(dest)
        sound["status"] = "rejected"
        sound.setdefault("rejections", []).append({"time": now_iso(), "reason": reason})
        print(f"rejected {name}: {reason}")
    save_json(MANIFEST, manifest)
    return 0


def generate(manifest: dict, batch: str, only: list[str] | None, dry_run: bool) -> int:
    ledger = load_json(LEDGER, {"entries": []})
    in_batch = [s for s in manifest["sounds"] if s["batch"] == batch]
    if not in_batch:
        print(f"unknown batch {batch}")
        return 2
    if any(s["kind"] != "sfx" for s in in_batch):
        print(f"{batch} is not a sound-effects batch (music: Tools/audio/generate_elevenlabs_music.py).")
        return 2
    todo = [s for s in in_batch
            if s["status"] in ("planned", "rejected") and (not only or s["name"] in only)]
    skipped = [s["name"] for s in in_batch if only and s["name"] in only and s not in todo]
    for name in skipped:
        print(f"skip {name}: status is not planned/rejected (approved sounds are never regenerated)")

    limit = manifest["credit_policy"]["per_batch_limit"]
    planned = sum(estimate_credits(manifest, s["duration_seconds"]) for s in todo)
    print(f"model {manifest['sfx_model_id']} · batch {batch} · {len(todo)} to generate · "
          f"estimate ≤{planned} credits · already charged to batch {batch_charged(ledger, batch)} · limit {limit}")
    for s in todo:
        print(f"  {s['name']:<20} {s['duration_seconds']:>4}s  ≤{estimate_credits(manifest, s['duration_seconds'])}")
    if dry_run or not todo:
        return 0

    key = os.environ.get("ELEVENLABS_API_KEY", "").strip()
    if not key:
        print("\nELEVENLABS_API_KEY is not set. Set it for this shell, then rerun:\n"
              "  export ELEVENLABS_API_KEY='sk_…'   # never stored or printed", file=sys.stderr)
        return 2

    stop_below = manifest["credit_policy"]["stop_if_account_remaining_below"]
    MASTERS.mkdir(parents=True, exist_ok=True)
    for sound in todo:
        estimate = estimate_credits(manifest, sound["duration_seconds"])
        if batch_charged(ledger, batch) + estimate > limit:
            print(f"STOP before {sound['name']}: batch would exceed {limit} credits")
            break
        remaining = account_remaining(key)
        if remaining is not None and remaining - estimate < stop_below:
            print(f"STOP before {sound['name']}: only {remaining} account credits remain")
            break
        body = {"text": sound["prompt"], "model_id": manifest["sfx_model_id"],
                "duration_seconds": sound["duration_seconds"], "prompt_influence": manifest["prompt_influence"]}
        status, headers, payload = request("POST", "/v1/sound-generation", key, body,
                                           query=f"?output_format={OUTPUT_FORMAT}")
        entry = {"time": now_iso(), "batch": batch, "name": sound["name"], "model_id": manifest["sfx_model_id"],
                 "duration_seconds": sound["duration_seconds"], "http_status": status,
                 "request_id": headers.get("request-id") or headers.get("Request-Id"),
                 "estimated_credits": estimate, "charged_credits": estimate if status == 200 else 0}
        if status != 200:
            entry["error"] = error_detail(payload)
            ledger["entries"].append(entry)
            save_json(LEDGER, ledger)
            print(f"FAILED {sound['name']}: HTTP {status} {entry['error']}")
            if status in (401, 403, 429) or status >= 500:
                print("Stopping: fix the key/quota or retry later.")
                break
            continue
        master = MASTERS / f"{sound['name']}.mp3"
        master.write_bytes(payload)
        ledger["entries"].append(entry)          # record the paid call first
        save_json(LEDGER, ledger)
        sound["generations"] = sound.get("generations", 0) + 1
        credits = sound.setdefault("credits", {"script_estimate": 0, "account_rate_estimate": 0})
        credits["script_estimate"] += estimate
        credits["account_rate_estimate"] += round(
            sound["duration_seconds"] * manifest["credit_policy"]["observed_credits_per_second"])
        try:
            sound.update(process(master, review_path(sound)))
            sound["master"] = str(master.relative_to(ROOT))
            sound["status"] = "awaiting_review"
            entry["review"] = "awaiting review"
            print(f"ok {sound['name']:<20} {sound['final_duration_seconds']}s  "
                  f"loudness {sound['loudness_dbfs']} dBFS  -> {review_path(sound).relative_to(ROOT)}")
        except (ValueError, subprocess.CalledProcessError) as error:
            dest = MASTERS / "rejected" / f"{sound['name']}-{entry['time'].replace(':', '')}.mp3"
            dest.parent.mkdir(parents=True, exist_ok=True)
            master.replace(dest)
            sound["status"] = "rejected"
            sound.setdefault("rejections", []).append({"time": entry["time"], "reason": f"automatic: {error}"})
            entry["review"] = f"unusable: {error}"
            print(f"UNUSABLE {sound['name']}: {error} (kept in rejected/)")
        save_json(LEDGER, ledger)
        save_json(MANIFEST, manifest)
        time.sleep(0.5)
    print(f"Batch {batch}: {batch_charged(ledger, batch)} credits charged by estimate (limit {limit})")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--status", action="store_true", help="list every sound and its approval status")
    parser.add_argument("--batch", help="generate the planned/rejected sounds of this batch")
    parser.add_argument("--only", nargs="*", help="limit generation to these names")
    parser.add_argument("--dry-run", action="store_true", help="plan and estimate only, no API calls")
    parser.add_argument("--approve", nargs="*", help="bundle these reviewed sounds into the app")
    parser.add_argument("--reject", nargs="*", help="reject these reviewed sounds")
    parser.add_argument("--reason", default="rejected in review", help="reason for --reject")
    args = parser.parse_args()

    manifest = load_json(MANIFEST, {})
    if args.status:
        show_status(manifest)
        return 0
    if args.approve:
        return approve(manifest, args.approve)
    if args.reject:
        return reject(manifest, args.reject, args.reason)
    if args.batch:
        return generate(manifest, args.batch, args.only, args.dry_run)
    parser.print_help()
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
