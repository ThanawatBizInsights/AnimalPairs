#!/usr/bin/env python3
"""Generate, check and bundle the 40 animal clips (4 per animal) for Animal Pairs.

OFFLINE developer tool (ElevenLabs Sound Effects API). The app never calls
ElevenLabs: it only plays the finished files bundled in
``AnimalPairs/Resources/Sounds/Animals/``.

Prompts, status and metrics live in ``Tools/audio/audio_manifest.json``
(batch ``batch7_animal_clips``). Every paid call is appended to
``Tools/audio/elevenlabs_credit_log.json`` before anything else happens.
The API key is read only from ``ELEVENLABS_API_KEY`` and is never printed,
logged or written to disk.

    python3 Tools/audio/generate_animal_clips.py --dry-run
    python3 Tools/audio/generate_animal_clips.py                 # generate what is missing
    python3 Tools/audio/generate_animal_clips.py --only iris_calm --retake   # replace one clip
    python3 Tools/audio/generate_animal_clips.py --process-only  # re-choose from saved takes, rebuild files
    python3 Tools/audio/generate_animal_clips.py --verify        # decode and check every bundled clip

Per clip:
* every paid take kept in ``Design/Audio/Animals/takes/``; the chosen
  original download is copied to ``Design/Audio/Animals/raw/<name>.mp3``;
* processed 24-bit 44.1 kHz WAV master in ``Design/Audio/Animals/masters/``;
* app file: AAC-LC mono 96 kbps ``.m4a`` in the app bundle;
* leading/trailing silence trimmed, at most 5 s, integrated loudness
  -21 LUFS with peaks at or below -3 dBFS, short fades;
* ``matchEnd``: a natural pause between 1.0 and 2.1 s where the shorter
  "matched pair" version stops (written to ``animal_clips.json`` in the bundle).

Pauses longer than 0.7 s are shortened to 0.45 s (the model sometimes
leaves long dead air). A take is retaken once automatically if it is near-silent, shorter than
2.5 s, has fewer than three distinct sounds or a pause longer than 1.5 s.

Requires: Python 3.10+, numpy, ffmpeg on PATH.
"""
from __future__ import annotations

import argparse
import json
import math
import os
import re
import subprocess
import sys
import time
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from generate_elevenlabs_sfx import (LEDGER, MANIFEST, ROOT, SAMPLE_RATE, decode,  # noqa: E402
                                     error_detail, load_json, now_iso, request, save_json)

BATCH = "batch7_animal_clips"
RAW = ROOT / "Design/Audio/Animals/raw"
MASTERS = ROOT / "Design/Audio/Animals/masters"
TAKES = ROOT / "Design/Audio/Animals/takes"   # every paid take, chosen or not
BUNDLE = ROOT / "AnimalPairs/Resources/Sounds/Animals"
CLIP_INDEX = BUNDLE / "animal_clips.json"
OUTPUT_FORMAT = "mp3_44100_128"     # best format available on the account's plan
CREDITS_PER_SECOND = 10              # observed account rate for eleven_text_to_sound_v3
TARGET_LUFS = -21.0
PEAK_CEILING_DBFS = -3.0
MAX_SECONDS = 5.0
MIN_SECONDS = 2.5                    # shorter takes are retaken; 2.5-3 s is flagged
MATCH_WINDOW = (1.0, 2.1)
MATCH_FALLBACK = 2.0
FRAME = 0.02                         # envelope frame (s)
VARIANTS = ("greeting", "curious", "excited", "calm")


# MARK: Analysis

def envelope_db(audio: np.ndarray) -> np.ndarray:
    size = int(FRAME * SAMPLE_RATE)
    frames = audio[: audio.size // size * size].reshape(-1, size)
    return 20 * np.log10(np.sqrt(np.mean(frames ** 2, axis=1)) + 1e-9)


def activity(audio: np.ndarray) -> tuple[list[tuple[float, float]], list[tuple[float, float]]]:
    """Sounding segments and pauses (seconds). A pause is >= 80 ms more than
    28 dB below the clip's loudest frame."""
    env = envelope_db(audio)
    active = env > max(env.max() - 28, -60)
    segments, gaps, start = [], [], None
    for i, on in enumerate(list(active) + [False]):
        if on and start is None:
            start = i
        elif not on and start is not None:
            segments.append((start * FRAME, i * FRAME))
            start = None
    merged: list[tuple[float, float]] = []
    for seg in segments:
        if merged and seg[0] - merged[-1][1] < 0.08:
            merged[-1] = (merged[-1][0], seg[1])
        else:
            merged.append(seg)
    for a, b in zip(merged, merged[1:]):
        gaps.append((a[1], b[0]))
    return merged, gaps


def expression_changes(audio: np.ndarray) -> int:
    """Separate rises in the envelope (>= 6 dB above the dip before them):
    distinct calls, chirps or steps, even over a continuous purr or hum."""
    env = np.convolve(envelope_db(audio), np.ones(3) / 3, mode="same")
    floor = env.max() - 35
    count, dip, armed = 0, env[0], True
    for value in env:
        if value < dip:
            dip = value
        if armed and value > floor and value - dip >= 6:
            count += 1
            armed, peak = False, value
        if not armed:
            peak = max(peak, value)
            if peak - value >= 6:
                armed, dip = True, value
    return count


def lufs(audio: np.ndarray) -> float:
    """Integrated loudness (EBU R128) via ffmpeg."""
    pcm = audio.astype("<f4").tobytes()
    out = subprocess.run(["ffmpeg", "-nostats", "-f", "f32le", "-ar", str(SAMPLE_RATE), "-ac", "1", "-i", "-",
                          "-af", "ebur128", "-f", "null", "-"], input=pcm, capture_output=True).stderr.decode()
    found = re.findall(r"I:\s+(-?[\d.]+) LUFS", out)
    return float(found[-1]) if found else -70.0


def max_momentary(audio: np.ndarray) -> float:
    pcm = audio.astype("<f4").tobytes()
    out = subprocess.run(["ffmpeg", "-nostats", "-f", "f32le", "-ar", str(SAMPLE_RATE), "-ac", "1", "-i", "-",
                          "-af", "ebur128=metadata=1,ametadata=print:key=lavfi.r128.M", "-f", "null", "-"],
                         input=pcm, capture_output=True).stderr.decode()
    values = [float(v) for v in re.findall(r"lavfi\.r128\.M=(-?[\d.]+)", out) if float(v) > -70]
    return max(values) if values else -70.0


def limit(audio: np.ndarray) -> np.ndarray:
    """Gentle peak limiter at the ceiling (ffmpeg alimiter, 5 ms attack)."""
    ceiling = 10 ** (PEAK_CEILING_DBFS / 20)
    out = subprocess.run(["ffmpeg", "-v", "error", "-f", "f32le", "-ar", str(SAMPLE_RATE), "-ac", "1", "-i", "-",
                          "-af", f"alimiter=limit={ceiling:.4f}:attack=5:release=80:level=disabled",
                          "-f", "f32le", "-"], input=audio.astype("<f4").tobytes(), capture_output=True, check=True)
    limited = np.frombuffer(out.stdout, dtype=np.float32).astype(np.float64)
    return np.clip(limited, -ceiling, ceiling)


def fade(audio: np.ndarray, fade_in: float = 0.005, fade_out: float = 0.06) -> np.ndarray:
    audio = audio.copy()
    n_in, n_out = int(fade_in * SAMPLE_RATE), int(fade_out * SAMPLE_RATE)
    audio[:n_in] *= np.linspace(0, 1, n_in)
    audio[-n_out:] *= np.linspace(1, 0, n_out)
    return audio


def tighten_pauses(audio: np.ndarray, longest: float = 0.7, keep: float = 0.45) -> np.ndarray:
    """Shorten dead air: a pause longer than `longest` keeps only `keep` seconds
    (half before, half after the removed middle, with a short crossfade)."""
    _, gaps = activity(audio)
    for start, end in reversed(gaps):
        if end - start <= longest:
            continue
        a = int((start + keep / 2) * SAMPLE_RATE)
        b = int((end - keep / 2) * SAMPLE_RATE)
        x = int(0.01 * SAMPLE_RATE)
        joined = audio[a - x:a] * np.linspace(1, 0, x) + audio[b - x:b] * np.linspace(0, 1, x)
        audio = np.concatenate([audio[:a - x], joined, audio[b:]])
    return audio


def process(raw: Path) -> tuple[np.ndarray, dict, list[str]]:
    """Trim, shorten to <= 5 s at a pause, loudness-match; returns audio, metrics, problems."""
    audio = decode(raw)
    problems: list[str] = []
    if audio.size == 0 or np.max(np.abs(audio)) < 10 ** (-40 / 20):
        return audio, {}, ["near-silent"]
    # Trim lead-in and tail: anything 35 dB below the loudest moment counts
    # as silence (takes often end in seconds of faint room noise).
    env = envelope_db(audio)
    active = np.nonzero(env > max(env.max() - 35, -60))[0]
    first, last = active[0] * FRAME, (active[-1] + 1) * FRAME
    audio = audio[max(0, int((first - 0.01) * SAMPLE_RATE)): min(audio.size, int((last + 0.12) * SAMPLE_RATE))]
    audio = tighten_pauses(audio)
    if audio.size / SAMPLE_RATE > MAX_SECONDS:
        _, gaps = activity(audio)
        cuts = [g[0] + 0.05 for g in gaps if 3.0 <= g[0] <= MAX_SECONDS - 0.05]
        cut = cuts[-1] if cuts else MAX_SECONDS
        audio = audio[: int(cut * SAMPLE_RATE)]
        if not cuts:
            audio = fade(audio, fade_out=0.25)
    audio = fade(audio)

    audio = audio * 10 ** ((TARGET_LUFS - lufs(audio)) / 20)
    for _ in range(2):   # limit peaks to the ceiling, then restore the loudness the limiter took
        audio = limit(audio)
        audio = audio * 10 ** ((TARGET_LUFS - lufs(audio)) / 20)
    audio = limit(audio)

    duration = audio.size / SAMPLE_RATE
    segments, gaps = activity(audio)
    longest_gap = max((b - a for a, b in gaps), default=0.0)
    candidates = [g for g in gaps if MATCH_WINDOW[0] <= g[0] <= MATCH_WINDOW[1]]
    if candidates:
        best = min(candidates, key=lambda g: abs(g[0] - 1.6))
        match_end, match_cut = round(min(best[0] + 0.04, duration), 2), "pause"
    else:
        match_end, match_cut = round(min(MATCH_FALLBACK, duration), 2), "fade"
    if duration < MIN_SECONDS:
        problems.append(f"too short ({duration:.2f} s)")
    changes = expression_changes(audio)
    if changes < 3:
        problems.append(f"only {changes} distinct sounds")
    if longest_gap > 1.5:
        problems.append(f"pause of {longest_gap:.1f} s")
    metrics = {
        "final_duration_seconds": round(duration, 2),
        "loudness_lufs": round(lufs(audio), 1),
        "max_momentary_lufs": round(max_momentary(audio), 1),
        "peak_dbfs": round(20 * math.log10(float(np.max(np.abs(audio))) + 1e-12), 1),
        "sound_events": changes,
        "longest_pause_seconds": round(longest_gap, 2),
        "match_end_seconds": match_end,
        "match_cut": match_cut,
    }
    return audio, metrics, problems


def write_outputs(name: str, audio: np.ndarray) -> tuple[Path, Path]:
    MASTERS.mkdir(parents=True, exist_ok=True)
    BUNDLE.mkdir(parents=True, exist_ok=True)
    master, app = MASTERS / f"{name}.wav", BUNDLE / f"{name}.m4a"
    pcm = np.clip(audio, -1, 1).astype("<f4").tobytes()
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "f32le", "-ar", str(SAMPLE_RATE), "-ac", "1", "-i", "-",
                    "-c:a", "pcm_s24le", str(master)], input=pcm, check=True)
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(master), "-c:a", "aac", "-b:a", "96k", "-ac", "1",
                    "-movflags", "+faststart", str(app)], check=True)
    return master, app


def write_index(manifest: dict) -> None:
    clips = {}
    for s in manifest["sounds"]:
        if s["batch"] == BATCH and s["status"] == "approved":
            clips[s["name"]] = {"character": s["character_id"], "variant": s["variant"],
                                "duration": s["final_duration_seconds"], "matchEnd": s["match_end_seconds"]}
    index = {"about": "Animal clips bundled with the app (generated offline). matchEnd: where the shorter "
                      "matched-pair version stops, at a natural pause where possible.",
             "clips": dict(sorted(clips.items()))}
    CLIP_INDEX.write_text(json.dumps(index, indent=2) + "\n")


# MARK: Commands

def takes_for(name: str) -> list[Path]:
    return sorted(TAKES.glob(f"{name}-take*.mp3"), key=lambda p: int(p.stem.rsplit("take", 1)[1]))


def choose(manifest: dict, sound: dict) -> dict:
    """Pick the best of every take of this clip (fewest problems, then the
    duration closest to 4 s) and write the original, master and app file."""
    name = sound["name"]
    scored = []
    for take in takes_for(name):
        audio, metrics, problems = process(take)
        if metrics:
            scored.append(((len(problems), abs(metrics["final_duration_seconds"] - 4.0)), take, audio, metrics, problems))
    if not scored:
        sound["status"] = "rejected"
        return sound
    _, take, audio, metrics, problems = min(scored, key=lambda item: item[0])
    RAW.mkdir(parents=True, exist_ok=True)
    original = RAW / f"{name}.mp3"
    original.write_bytes(take.read_bytes())
    master, app = write_outputs(name, audio)
    sound.update(metrics)
    sound.update({"raw_original": str(original.relative_to(ROOT)), "chosen_take": take.name,
                  "takes": len(scored), "master": str(master.relative_to(ROOT)),
                  "app_file_bytes": app.stat().st_size, "qa_flags": problems, "status": "approved",
                  "approved_at": sound.get("approved_at") or now_iso(),
                  "approval_note": "Bundled on generation at the user's request after the automatic checks."})
    sound.pop("rejections", None) if not problems else None
    save_json(MANIFEST, manifest)
    write_index(manifest)
    return sound


def report(sound: dict) -> None:
    flags = f"  FLAGS: {', '.join(sound['qa_flags'])}" if sound.get("qa_flags") else ""
    print(f"ok {sound['name']:<16} {sound['final_duration_seconds']:>4}s  {sound['loudness_lufs']} LUFS  "
          f"{sound['sound_events']} sounds  match {sound['match_end_seconds']}s ({sound['match_cut']})  "
          f"take {sound['chosen_take']} of {sound['takes']}{flags}")


def generate(manifest: dict, only: list[str] | None, retake: bool, dry_run: bool) -> int:
    sounds = [s for s in manifest["sounds"] if s["batch"] == BATCH and (not only or s["name"] in only)]
    todo = [s for s in sounds if s["status"] != "approved" or retake]
    budget = manifest["credit_policy"]["batch_limits"][BATCH]["account_credits"]
    ledger = load_json(LEDGER, {"entries": []})
    spent = sum(e.get("account_rate_credits", 0) for e in ledger["entries"] if e.get("batch") == BATCH)
    estimate = sum(math.ceil(s["duration_seconds"] * CREDITS_PER_SECOND) for s in todo)
    print(f"{len(todo)} clips to generate · about {estimate} credits (+ retakes) · "
          f"{spent} spent on this batch · budget {budget}")
    if dry_run or not todo:
        return 0
    key = os.environ.get("ELEVENLABS_API_KEY", "").strip()
    if not key:
        print("ELEVENLABS_API_KEY is not set.", file=sys.stderr)
        return 2
    TAKES.mkdir(parents=True, exist_ok=True)
    for sound in todo:
        name = sound["name"]
        for attempt in (1, 2):
            cost = math.ceil(sound["duration_seconds"] * CREDITS_PER_SECOND)
            if spent + cost > budget:
                print(f"STOP before {name}: the batch budget of {budget} credits would be exceeded")
                return 1
            body = {"text": sound["prompt"], "model_id": manifest["sfx_model_id"],
                    "duration_seconds": sound["duration_seconds"], "prompt_influence": manifest["prompt_influence"]}
            status, headers, payload = request("POST", "/v1/sound-generation", key, body,
                                               query=f"?output_format={OUTPUT_FORMAT}")
            entry = {"time": now_iso(), "batch": BATCH, "name": name, "attempt": attempt,
                     "model_id": manifest["sfx_model_id"], "duration_seconds": sound["duration_seconds"],
                     "http_status": status, "request_id": headers.get("request-id") or headers.get("Request-Id"),
                     "account_rate_credits": cost if status == 200 else 0}
            if status != 200:
                entry["error"] = error_detail(payload)
            ledger["entries"].append(entry)        # record the paid call first
            save_json(LEDGER, ledger)
            if status != 200:
                print(f"FAILED {name}: HTTP {status} {entry['error']}")
                if status in (401, 403, 429) or status >= 500:
                    return 1
                break
            spent += cost
            sound["generations"] = sound.get("generations", 0) + 1
            sound["account_rate_credits"] = sound.get("account_rate_credits", 0) + cost
            number = max([int(p.stem.rsplit("take", 1)[1]) for p in takes_for(name)] + [0]) + 1
            take = TAKES / f"{name}-take{number}.mp3"
            take.write_bytes(payload)
            save_json(MANIFEST, manifest)
            _, metrics, problems = process(take)
            if metrics and not problems:
                break
            print(f"  retake {name}: {', '.join(problems)}")
            time.sleep(0.4)
        report(choose(manifest, sound))
        time.sleep(0.4)
    print(f"Batch {BATCH}: about {spent} credits at the observed rate")
    return 0


def choose_all(manifest: dict) -> int:
    for s in manifest["sounds"]:
        if s["batch"] == BATCH and takes_for(s["name"]):
            report(choose(manifest, s))
    return 0


def verify(manifest: dict) -> int:
    """Decode every bundled clip end to end and check it against the index.
    Clips not generated yet are listed; flagged clips are warnings."""
    index = json.loads(CLIP_INDEX.read_text())["clips"]
    problems = warnings = missing = 0
    for s in (x for x in manifest["sounds"] if x["batch"] == BATCH):
        name, path = s["name"], BUNDLE / f"{s['name']}.m4a"
        if s["status"] != "approved":
            missing += 1
            print(f"MISSING {name:<16} not generated yet")
            continue
        try:
            audio = decode(path)
        except (subprocess.CalledProcessError, FileNotFoundError):
            problems += 1
            print(f"FAIL    {name:<16} does not decode")
            continue
        duration = audio.size / SAMPLE_RATE
        info = index.get(name)
        broken = (info is None or abs(info["duration"] - duration) > 0.06 or np.max(np.abs(audio)) < 0.05
                  or not 0.3 <= info["matchEnd"] <= 2.2)
        short = duration < 2.5
        problems += broken
        warnings += short and not broken
        label = "FAIL   " if broken else "SHORT  " if short else "ok     "
        print(f"{label} {name:<16} {duration:5.2f}s decoded  matchEnd {info and info['matchEnd']}  "
              f"{path.stat().st_size // 1024} KB")
    print(f"{len(index)} bundled clips decode: {problems} problem(s), {warnings} short, {missing} not generated")
    return 1 if problems else 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--only", nargs="*")
    parser.add_argument("--retake", action="store_true", help="regenerate even approved clips (with --only)")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--process-only", action="store_true", help="re-choose and rebuild from the saved takes")
    parser.add_argument("--verify", action="store_true")
    args = parser.parse_args()
    manifest = load_json(MANIFEST, {})
    if args.verify:
        return verify(manifest)
    if args.process_only:
        return choose_all(manifest)
    if args.retake and not args.only:
        parser.error("--retake needs --only")
    return generate(manifest, args.only, args.retake, args.dry_run)


if __name__ == "__main__":
    raise SystemExit(main())
