#!/usr/bin/env python3
"""Generate and prepare Animal Pairs instrumental music loops (ElevenLabs Music API).

OFFLINE developer tool; the app never calls ElevenLabs. Tracks are catalogued
in Tools/audio/audio_manifest.json (kind "music") and stay in review until
approved. Approved tracks are bundled with --bundle and played by BackgroundMusicPlayer.

    export ELEVENLABS_API_KEY='sk_…'      # never stored or printed
    python3 Tools/audio/generate_elevenlabs_music.py --dry-run
    python3 Tools/audio/generate_elevenlabs_music.py [--only music_focus]
    python3 Tools/audio/generate_elevenlabs_music.py --process-only   # rebuild loops from raw masters
    python3 Tools/audio/generate_elevenlabs_music.py --verify         # decode every file, measure loop joins
    python3 Tools/audio/generate_elevenlabs_music.py --bundle         # approve + copy into the app, write music_tracks.json

For each track: POST /v1/music (model music_v2_5, instrumental forced) for a
~48 s piece; keep the raw download; detect the tempo; cut a whole-bar loop of
30-45 s where the start and end sound most alike; join it with a one-beat
equal-power crossfade; set every loop to the same loudness (-24 LUFS, true
peak <= -3 dBTP, leaving room for effects); write a lossless 24-bit loop master
and a mobile AAC-LC .m4a; then decode the .m4a and measure the join.
"""
from __future__ import annotations

import argparse
import json
import math
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from generate_elevenlabs_sfx import (  # noqa: E402
    LEDGER, MANIFEST, ROOT, error_detail, load_json, now_iso, request, save_json,
)

RAW = ROOT / "Design/Audio/Music/raw"
MASTERS = ROOT / "Design/Audio/Music/masters"
REVIEW = ROOT / "Design/Audio/Review"
RATE = 48_000
MODEL = "music_v2_5"
REQUEST_MS = 48_000
TARGET_LUFS = -24.0
TRUE_PEAK_LIMIT = -3.0
LOOP_MIN, LOOP_MAX, LOOP_TARGET = 30.0, 45.0, 40.0


# MARK: Audio helpers

def decode_stereo(path: Path) -> np.ndarray:
    pcm = subprocess.run(["ffmpeg", "-v", "error", "-i", str(path), "-ac", "2", "-ar", str(RATE),
                          "-f", "f32le", "-"], check=True, capture_output=True).stdout
    return np.frombuffer(pcm, dtype=np.float32).astype(np.float64).reshape(-1, 2)


def write_wav(path: Path, audio: np.ndarray, codec: str = "pcm_s24le") -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    raw = np.clip(audio, -1, 1).astype("<f4").tobytes()
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "f32le", "-ar", str(RATE), "-ac", "2", "-i", "-",
                    "-c:a", codec, str(path)], input=raw, check=True)


def loudness(path: Path) -> tuple[float, float, float]:
    """Integrated loudness (LUFS), loudness range (LU) and true peak (dBTP)."""
    out = subprocess.run(["ffmpeg", "-nostats", "-i", str(path), "-af", "ebur128=peak=true", "-f", "null", "-"],
                         capture_output=True, text=True).stderr
    summary = out[out.rfind("Summary:"):]
    i = float(re.search(r"I:\s+(-?[\d.]+) LUFS", summary).group(1))
    lra = float(re.search(r"LRA:\s+(-?[\d.]+) LU", summary).group(1))
    tp = float(re.search(r"Peak:\s+(-?[\d.]+|-inf) dBFS", summary).group(1))
    return i, lra, tp


def onset_envelope(mono: np.ndarray, hop: int = 512, frame: int = 2048) -> np.ndarray:
    window = np.hanning(frame)
    frames = np.lib.stride_tricks.sliding_window_view(mono, frame)[::hop] * window
    mags = np.abs(np.fft.rfft(frames, axis=1))
    flux = np.maximum(np.diff(np.log1p(mags), axis=0), 0).sum(axis=1)
    return (flux - flux.mean()) / (flux.std() + 1e-9)


def beat_period(mono: np.ndarray, bpm_hint: float, hop: int = 512) -> float:
    env = onset_envelope(mono, hop)
    fps = RATE / hop
    ac = np.correlate(env, env, mode="full")[env.size - 1:]
    lags = np.arange(ac.size) / fps
    valid = (lags >= 60 / 190) & (lags <= 60 / 55)
    # Prefer tempi near the prompt's BPM (log-Gaussian prior), but trust the audio.
    prior = np.exp(-0.5 * (np.log2(np.where(lags > 0, lags, 1) / (60 / bpm_hint)) / 0.35) ** 2)
    score = np.where(valid, ac * prior, -np.inf)
    return float(lags[int(np.argmax(score))])


def spectrum(audio: np.ndarray, start: int, length: int) -> np.ndarray:
    seg = audio[max(0, start):start + length].mean(axis=1)
    if seg.size < length:
        seg = np.pad(seg, (0, length - seg.size))
    mag = np.abs(np.fft.rfft(seg * np.hanning(seg.size)))
    bands = np.array_split(mag, 48)
    return np.log1p(np.array([b.mean() for b in bands]))


def cosine(a: np.ndarray, b: np.ndarray) -> float:
    return float(np.dot(a, b) / (np.linalg.norm(a) * np.linalg.norm(b) + 1e-12))


def make_loop(audio: np.ndarray, bpm_hint: float) -> tuple[np.ndarray, dict]:
    mono = audio.mean(axis=1)
    beat = beat_period(mono, bpm_hint)
    bar = 4 * beat
    crossfade = int(min(1.0, max(0.4, beat)) * RATE)
    total = audio.shape[0]
    best = None
    for n_bars in range(1, 200):
        length = n_bars * bar
        if length < LOOP_MIN:
            continue
        if length > LOOP_MAX:
            break
        n = int(round(length * RATE))
        latest = total - n - crossfade - int(1.0 * RATE)   # keep clear of any fade at the very end
        for start in np.arange(int(0.25 * RATE), max(int(0.25 * RATE), latest) + 1, int(beat * RATE / 2)):
            if start + n + crossfade > total:
                break
            w = int(0.5 * RATE)
            score = cosine(spectrum(audio, start, w), spectrum(audio, start + n, w))
            score -= 0.002 * abs(length - LOOP_TARGET)  # mild preference for ~40 s
            if best is None or score > best[0]:
                best = (score, int(start), n, n_bars)
    if best is None:
        raise ValueError("generated piece too short for a 30-45 s loop")
    _, start, n, n_bars = best
    loop = audio[start:start + n].copy()
    t = np.linspace(0, np.pi / 2, crossfade)[:, None]
    tail = audio[start + n:start + n + crossfade]
    loop[:crossfade] = loop[:crossfade] * np.sin(t) + tail * np.cos(t)   # equal-power
    info = {"detected_bpm": round(60 / beat, 1), "bars": n_bars, "loop_start_seconds": round(start / RATE, 3),
            "loop_seconds": round(n / RATE, 3), "crossfade_seconds": round(crossfade / RATE, 3)}
    return loop, info


def join_report(loop: np.ndarray) -> dict:
    """Compare the wrap-around join with ordinary moments inside the loop."""
    mono = loop.mean(axis=1)
    w = int(0.25 * RATE)
    sims = [cosine(spectrum(loop, i, w), spectrum(loop, i + w, w)) for i in range(0, loop.shape[0] - 2 * w, w)]
    wrapped = np.concatenate([loop[-w:], loop[:w]])
    join_sim = cosine(spectrum(wrapped, 0, w), spectrum(wrapped, w, w))
    r = int(0.1 * RATE)
    rms = [20 * math.log10(max(np.sqrt(np.mean(mono[i:i + r] ** 2)), 1e-9)) for i in range(0, mono.size - r, r)]
    jumps = np.abs(np.diff(rms))
    join_jump = abs(20 * math.log10(max(np.sqrt(np.mean(mono[:r] ** 2)), 1e-9))
                    - 20 * math.log10(max(np.sqrt(np.mean(mono[-r:] ** 2)), 1e-9)))
    steps = np.abs(np.diff(loop, axis=0)).max(axis=1)
    join_step = float(np.abs(loop[0] - loop[-1]).max())
    report = {
        "join_spectral_similarity": round(join_sim, 4),
        "inside_similarity_p05": round(float(np.percentile(sims, 5)), 4),
        "join_level_jump_db": round(join_jump, 2),
        "inside_level_jump_p95_db": round(float(np.percentile(jumps, 95)), 2),
        "join_sample_step": round(join_step, 5),
        "inside_sample_step_p999": round(float(np.percentile(steps, 99.9)), 5),
    }
    report["smooth"] = bool(join_sim >= report["inside_similarity_p05"]
                            and join_jump <= report["inside_level_jump_p95_db"]
                            and join_step <= report["inside_sample_step_p999"])
    return report


def low_end_share(loop: np.ndarray) -> float:
    mono = loop.mean(axis=1)
    mag = np.abs(np.fft.rfft(mono)) ** 2
    freqs = np.fft.rfftfreq(mono.size, 1 / RATE)
    return float(mag[freqs < 100].sum() / (mag.sum() + 1e-12))


# MARK: Pipeline

def prepare(track: dict) -> None:
    """Raw download → loop → loudness → lossless master + mobile .m4a → verify."""
    raw = RAW / f"{track['name']}.mp3"
    audio = decode_stereo(raw)
    loop, info = make_loop(audio, track["bpm_hint"])
    with tempfile.TemporaryDirectory() as tmp:
        probe = Path(tmp) / "probe.wav"
        write_wav(probe, loop)
        lufs, _, _ = loudness(probe)
        gain = 10 ** ((TARGET_LUFS - lufs) / 20)
        write_wav(probe, loop * gain)
        _, _, tp = loudness(probe)
        if tp > TRUE_PEAK_LIMIT:
            gain *= 10 ** ((TRUE_PEAK_LIMIT - tp - 0.1) / 20)
    loop = loop * gain
    master = MASTERS / f"{track['name']}_loop.wav"
    write_wav(master, loop)
    mobile = REVIEW / track["file"]
    mobile.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(master), "-c:a", "aac", "-b:a", "128k",
                    "-ar", str(RATE), "-movflags", "+faststart", str(mobile)], check=True)
    track["loop"] = info
    track["master"] = str(master.relative_to(ROOT))
    track["raw_master"] = str(raw.relative_to(ROOT))
    track.update(verify_track(track))


def verify_track(track: dict) -> dict:
    """Decode every file of the track and measure the delivered loop."""
    results = {}
    for key in ("raw_master", "master"):
        decoded = decode_stereo(ROOT / track[key])
        results[f"{key}_plays"] = bool(decoded.shape[0] > RATE and np.isfinite(decoded).all())
    mobile = REVIEW / track["file"] if (REVIEW / track["file"]).exists() else ROOT / track.get("bundle_dir", "") / track["file"]
    decoded = decode_stereo(mobile)
    lufs, lra, tp = loudness(mobile)
    master_len = decode_stereo(ROOT / track["master"]).shape[0]
    return {
        **results,
        "mobile_plays": bool(decoded.shape[0] > RATE and np.isfinite(decoded).all()),
        "mobile_duration_seconds": round(decoded.shape[0] / RATE, 3),
        "mobile_length_matches_master": abs(decoded.shape[0] - master_len) <= 2,
        "mobile_bytes": mobile.stat().st_size,
        "format": "AAC-LC 128 kbps, 48 kHz stereo (.m4a)",
        "loudness_lufs": lufs, "loudness_range_lu": lra, "true_peak_dbtp": tp,
        "low_end_share_below_100hz": round(low_end_share(decoded), 4),
        "join": join_report(decoded),
    }


USES = {
    "music_playground": "Home, Welcome and choosing a board",
    "music_focus": "During card matching (and the pause menu)",
    "music_celebration": "Results screen, fading in 3 s after the jingle",
    "music_meadow": "Parents area and its gate",
}


def bundle(manifest: dict, tracks: list[dict]) -> int:
    """Approve the reviewed loops and bundle them with their exact loop
    lengths (the app trims any AAC encoder delay a decoder keeps)."""
    out = ROOT / "AnimalPairs/Resources/Music"
    out.mkdir(parents=True, exist_ok=True)
    index = {}
    for t in tracks:
        source = REVIEW / t["file"]
        if t["status"] not in ("awaiting_review", "approved") or not source.exists():
            print(f"MISSING {t['name']}: {source.relative_to(ROOT)} ({t['status']})")
            continue
        frames = int(subprocess.run(["ffprobe", "-v", "error", "-show_entries", "stream=duration_ts", "-of",
                                     "csv=p=0", str(ROOT / t["master"])], capture_output=True, text=True,
                                    check=True).stdout.strip())
        target = out / t["file"]
        target.write_bytes(source.read_bytes())
        t["status"] = "approved"
        t["approved_at"] = t.get("approved_at") or now_iso()
        t["approval_note"] = "Bundled as background music at the user's request."
        t["event"] = USES.get(t["name"], t.get("event", ""))
        index[t["name"]] = {"frames": frames, "sampleRate": RATE}
        print(f"bundled {t['name']}: {frames} frames ({frames / RATE:.2f} s) -> {target.relative_to(ROOT)}")
    (out / "music_tracks.json").write_text(json.dumps(
        {"about": "Background loops bundled with the app. frames: exact loop length at sampleRate.",
         "tracks": dict(sorted(index.items()))}, indent=2) + "\n")
    manifest["music"]["note"] = ("Four instrumental loops bundled as background music, one per scene; "
                                 "played by BackgroundMusicPlayer (AVAudioEngine, gapless).")
    save_json(MANIFEST, manifest)
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--only", nargs="*")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--process-only", action="store_true")
    parser.add_argument("--verify", action="store_true")
    parser.add_argument("--bundle", action="store_true",
                        help="approve the reviewed tracks, copy them into the app and write music_tracks.json")
    args = parser.parse_args()
    manifest = load_json(MANIFEST, {})
    tracks = [s for s in manifest["sounds"] if s.get("kind") == "music" and (not args.only or s["name"] in args.only)]

    if args.verify:
        for t in tracks:
            if t.get("master"):
                t.update(verify_track(t))
                print(f"{t['name']}: plays={t['mobile_plays']} {t['mobile_duration_seconds']}s join smooth={t['join']['smooth']}")
        save_json(MANIFEST, manifest)
        return 0
    if args.bundle:
        return bundle(manifest, tracks)
    if args.process_only:
        for t in tracks:
            if (RAW / f"{t['name']}.mp3").exists():
                prepare(t)
                print(f"processed {t['name']}: {t['loop']}")
        save_json(MANIFEST, manifest)
        return 0

    todo = [t for t in tracks if t["status"] in ("planned", "rejected")]
    print(f"model {MODEL} · {len(todo)} track(s) · {REQUEST_MS / 1000:.0f} s each, instrumental forced")
    for t in todo:
        print(f"  {t['name']}")
    if args.dry_run or not todo:
        return 0
    key = os.environ.get("ELEVENLABS_API_KEY", "").strip()
    if not key:
        print("ELEVENLABS_API_KEY is not set (export it for this shell; it is never stored).", file=sys.stderr)
        return 2
    ledger = load_json(LEDGER, {"entries": []})
    RAW.mkdir(parents=True, exist_ok=True)
    for t in todo:
        body = {"prompt": t["prompt"], "music_length_ms": REQUEST_MS, "model_id": MODEL, "force_instrumental": True}
        status, headers, payload = request("POST", "/v1/music", key, body)
        entry = {"time": now_iso(), "batch": t["batch"], "name": t["name"], "model_id": MODEL,
                 "duration_seconds": REQUEST_MS / 1000, "http_status": status,
                 "request_id": headers.get("request-id") or headers.get("Request-Id"),
                 "content_type": headers.get("content-type") or headers.get("Content-Type")}
        if status != 200:
            entry["error"] = error_detail(payload)
            ledger["entries"].append(entry)
            save_json(LEDGER, ledger)
            print(f"FAILED {t['name']}: HTTP {status} {entry['error']}")
            return 1
        (RAW / f"{t['name']}.mp3").write_bytes(payload)
        ledger["entries"].append(entry)
        save_json(LEDGER, ledger)
        t["generations"] = t.get("generations", 0) + 1
        t["model_id"] = MODEL
        prepare(t)
        t["status"] = "awaiting_review"
        save_json(MANIFEST, manifest)
        print(f"ok {t['name']}: loop {t['loop']['loop_seconds']} s, {t['loudness_lufs']} LUFS, "
              f"join smooth={t['join']['smooth']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
