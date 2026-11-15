#!/usr/bin/env python3
"""Synthesize the game's gentle sound effects as small mono WAV files.

Run from the repository root: ``python3 Tools/audio/build_sounds.py``.
Sounds are original sine/bell tones with soft envelopes, peaking around
-16 dBFS so nothing is startling. Output: AnimalPairs/Resources/Sounds/*.wav
"""
from __future__ import annotations

import math
import struct
import wave
from pathlib import Path

RATE = 44_100
OUT = Path(__file__).resolve().parents[2] / "AnimalPairs/Resources/Sounds"
PEAK = 10 ** (-16 / 20)


def bell(freq: float, start: float, length: float, decay: float = 6.0):
    return (freq, start, length, decay)


def render(notes, total: float) -> list[float]:
    samples = [0.0] * int(RATE * total)
    for freq, start, length, decay in notes:
        begin = int(start * RATE)
        for i in range(int(length * RATE)):
            t = i / RATE
            attack = min(1.0, t / 0.008)
            env = attack * math.exp(-decay * t)
            value = math.sin(2 * math.pi * freq * t) + 0.25 * math.sin(2 * math.pi * freq * 2 * t)
            if begin + i < len(samples):
                samples[begin + i] += env * value
    peak = max(abs(s) for s in samples) or 1.0
    return [s / peak * PEAK for s in samples]


def write(name: str, samples: list[float]) -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    with wave.open(str(OUT / f"{name}.wav"), "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(RATE)
        fade = int(0.01 * RATE)
        for i in range(fade):
            samples[-1 - i] *= i / fade
        wav.writeframes(b"".join(struct.pack("<h", int(s * 32767)) for s in samples))


SOUNDS = {
    "flip": (render([bell(880, 0, 0.14, 28)], 0.16)),
    "match": (render([bell(1046.5, 0, 0.5, 7), bell(1318.5, 0.11, 0.6, 6)], 0.75)),
    "mismatch": (render([bell(523.25, 0, 0.3, 10), bell(440, 0.14, 0.35, 10)], 0.52)),
    "hint": (render([bell(1568, 0, 0.25, 14), bell(1760, 0.08, 0.25, 14), bell(2093, 0.16, 0.3, 12)], 0.5)),
    "complete": (render([bell(523.25, 0, 0.6, 5), bell(659.25, 0.15, 0.6, 5), bell(783.99, 0.3, 0.6, 5), bell(1046.5, 0.45, 0.9, 4)], 1.4)),
    "tap": (render([bell(660, 0, 0.08, 40)], 0.1)),
}

if __name__ == "__main__":
    for name, samples in SOUNDS.items():
        write(name, samples)
        print(f"wrote {name}.wav")
