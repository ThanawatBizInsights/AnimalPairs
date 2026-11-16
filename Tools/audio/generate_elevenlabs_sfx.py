#!/usr/bin/env python3
"""Generate Animal Pairs sound effects with the ElevenLabs Sound Effects API.

This is an OFFLINE developer tool. The iPad app never calls ElevenLabs; it
only plays the processed WAV files this script writes into
``AnimalPairs/Resources/Sounds/``.

The API key is read from the ``ELEVENLABS_API_KEY`` environment variable only.
It is never printed, logged or written to disk. Set it for one shell session:

    export ELEVENLABS_API_KEY='…'        # macOS/Linux (zsh/bash)

Usage (from the repository root):

    python3 Tools/audio/generate_elevenlabs_sfx.py --dry-run     # plan + cost, no API calls
    python3 Tools/audio/generate_elevenlabs_sfx.py               # generate missing sounds
    python3 Tools/audio/generate_elevenlabs_sfx.py --only pair_miss --regenerate
    python3 Tools/audio/generate_elevenlabs_sfx.py --process-only # re-normalize from saved masters

Budget: every call is charged against ``credit_limit`` in the batch file using
a conservative estimate (the larger of 40 credits/second and 200 credits per
generation). The script stops *before* a call that could exceed the limit.
Every attempt is appended to ``Tools/audio/elevenlabs_credit_log.json``, with
the credit use reported by ElevenLabs where the account allows reading it.

Requires: Python 3.10+, numpy, ffmpeg on PATH.
"""
from __future__ import annotations

import argparse
import json
import math
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
BATCH = ROOT / "Tools/audio/sfx_batch1.json"
LEDGER = ROOT / "Tools/audio/elevenlabs_credit_log.json"
MASTERS = ROOT / "Design/Audio/ElevenLabs"
OUTPUT = ROOT / "AnimalPairs/Resources/Sounds"
API = "https://api.elevenlabs.io"
OUTPUT_FORMAT = "mp3_44100_128"
CREDITS_PER_SECOND = 40          # documented rate when duration_seconds is set
CREDITS_FLOOR_PER_CALL = 200     # conservative floor (rate reported for auto-duration)
SAMPLE_RATE = 44_100
TARGET_LOUDNESS_DBFS = -18.0     # loudest 50 ms window (RMS) of every effect
PEAK_CEILING_DBFS = -3.0
SILENCE_DBFS = -50.0


def estimate_credits(duration: float) -> int:
    return max(math.ceil(duration * CREDITS_PER_SECOND), CREDITS_FLOOR_PER_CALL)


def load_ledger() -> dict:
    if LEDGER.exists():
        return json.loads(LEDGER.read_text())
    return {"note": "Each ElevenLabs generation attempt. 'charged_credits' uses the reported value "
                    "when available, otherwise the conservative estimate.", "entries": []}


def save_ledger(ledger: dict) -> None:
    LEDGER.write_text(json.dumps(ledger, indent=2) + "\n")


def charged_total(ledger: dict) -> int:
    return sum(e.get("charged_credits", 0) for e in ledger["entries"])


def api_key() -> str | None:
    key = os.environ.get("ELEVENLABS_API_KEY", "").strip()
    return key or None


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


def credits_used(key: str) -> int | None:
    """Account credit counter, if the key may read it (user_read permission)."""
    status, _, body = request("GET", "/v1/user/subscription", key)
    if status != 200:
        return None
    try:
        return int(json.loads(body)["character_count"])
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


def decode(path: Path) -> np.ndarray:
    pcm = subprocess.run(
        ["ffmpeg", "-v", "error", "-i", str(path), "-ac", "1", "-ar", str(SAMPLE_RATE), "-f", "f32le", "-"],
        check=True, capture_output=True).stdout
    return np.frombuffer(pcm, dtype=np.float32).astype(np.float64)


def process(master: Path, target: Path) -> dict:
    """Trim silence, loudness-match, fade, and write 16-bit mono WAV."""
    audio = decode(master)
    if audio.size == 0:
        raise ValueError(f"{master.name} decoded to no audio")
    threshold = 10 ** (SILENCE_DBFS / 20)
    loud = np.nonzero(np.abs(audio) > threshold)[0]
    if loud.size == 0:
        raise ValueError(f"{master.name} is silent")
    start = max(0, loud[0] - int(0.005 * SAMPLE_RATE))
    end = min(audio.size, loud[-1] + int(0.05 * SAMPLE_RATE))
    audio = audio[start:end]

    loudness = window_loudness(audio)
    gain = 10 ** (TARGET_LOUDNESS_DBFS / 20) / max(loudness, 1e-9)
    peak = float(np.max(np.abs(audio))) * gain
    ceiling = 10 ** (PEAK_CEILING_DBFS / 20)
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
    return {"duration_seconds": round(audio.size / SAMPLE_RATE, 3),
            "peak_dbfs": round(20 * math.log10(max(np.max(np.abs(audio)), 1e-9)), 1),
            "loudness_dbfs": round(20 * math.log10(max(window_loudness(audio), 1e-9)), 1)}


def window_loudness(audio: np.ndarray, window_seconds: float = 0.05) -> float:
    """RMS of the loudest short window: how loud a brief effect is perceived."""
    size = max(1, min(audio.size, int(window_seconds * SAMPLE_RATE)))
    power = np.convolve(audio ** 2, np.ones(size) / size, mode="valid")
    return float(np.sqrt(np.max(power)))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--dry-run", action="store_true", help="show the plan and estimated cost only")
    parser.add_argument("--only", nargs="*", help="limit to these sound names")
    parser.add_argument("--regenerate", action="store_true", help="generate even if a master exists")
    parser.add_argument("--process-only", action="store_true", help="re-normalize existing masters")
    args = parser.parse_args()

    batch = json.loads(BATCH.read_text())
    sounds = [s for s in batch["sounds"] if not args.only or s["name"] in args.only]
    ledger = load_ledger()
    limit = int(batch["credit_limit"])

    if args.process_only:
        for sound in sounds:
            master = MASTERS / f"{sound['name']}.mp3"
            if master.exists():
                print(f"processed {sound['name']}.wav {process(master, OUTPUT / (sound['name'] + '.wav'))}")
        return 0

    todo = [s for s in sounds if args.regenerate or not (MASTERS / f"{s['name']}.mp3").exists()]
    planned = sum(estimate_credits(s["duration_seconds"]) for s in todo)
    print(f"model {batch['model_id']} · {len(todo)} to generate · conservative estimate {planned} credits · "
          f"already charged {charged_total(ledger)} · limit {limit}")
    for s in todo:
        print(f"  {s['name']:<18} {s['duration_seconds']:>4}s  ≤{estimate_credits(s['duration_seconds'])} credits")
    if args.dry_run or not todo:
        return 0

    key = api_key()
    if key is None:
        print("\nELEVENLABS_API_KEY is not set. Set it for this shell, then rerun:\n"
              "  export ELEVENLABS_API_KEY='your-key'   # zsh/bash; the key is never stored or printed",
              file=sys.stderr)
        return 2

    MASTERS.mkdir(parents=True, exist_ok=True)
    for sound in todo:
        estimate = estimate_credits(sound["duration_seconds"])
        if charged_total(ledger) + estimate > limit:
            print(f"STOP before {sound['name']}: {charged_total(ledger)} + {estimate} would exceed {limit} credits")
            break
        before = credits_used(key)
        body = {"text": sound["prompt"], "model_id": batch["model_id"],
                "duration_seconds": sound["duration_seconds"], "prompt_influence": batch["prompt_influence"]}
        status, headers, payload = request("POST", "/v1/sound-generation", key, body,
                                           query=f"?output_format={OUTPUT_FORMAT}")
        after = credits_used(key) if status == 200 else before
        reported = (after - before) if (before is not None and after is not None) else None
        entry = {
            "time": datetime.now(timezone.utc).isoformat(timespec="seconds"),
            "batch": batch["batch"], "name": sound["name"], "model_id": batch["model_id"],
            "duration_seconds": sound["duration_seconds"], "http_status": status,
            "request_id": headers.get("request-id") or headers.get("Request-Id"),
            "estimated_credits": estimate, "reported_credits": reported,
            "charged_credits": (reported if reported is not None else estimate) if status == 200 else 0,
        }
        if status != 200:
            entry["error"] = error_detail(payload)
            ledger["entries"].append(entry)
            save_ledger(ledger)
            print(f"FAILED {sound['name']}: HTTP {status} {entry['error']}")
            if status in (401, 403, 429) or status >= 500:
                print("Stopping: fix the key/quota or retry later.")
                break
            continue
        master = MASTERS / f"{sound['name']}.mp3"
        master.write_bytes(payload)
        entry["processed"] = process(master, OUTPUT / f"{sound['name']}.wav")
        entry["review"] = "awaiting review"
        ledger["entries"].append(entry)
        save_ledger(ledger)
        print(f"ok {sound['name']}.wav  credits {entry['charged_credits']}"
              f"{' (reported)' if reported is not None else ' (estimated)'}  total {charged_total(ledger)}")
        time.sleep(0.5)
    print(f"Total charged against budget: {charged_total(ledger)} / {limit}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
