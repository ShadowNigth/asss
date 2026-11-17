#!/usr/bin/env python3
"""Generate the game's sound effects procedurally.

The retail CS 1.5 sound files are not part of the asset set this project is
allowed to ship, so every sound here is synthesised from scratch with numpy and
written as 16-bit mono WAV.  They are deliberately short and mono: distance
attenuation and stereo placement are done by Godot's `AudioStreamPlayer3D`.

    python3 tools/audio/make_sounds.py --out assets/audio

Each sound is built from a small vocabulary of primitives (noise bursts,
decaying sine partials, filtered clicks) so the set sounds coherent without any
sampled material.
"""

from __future__ import annotations

import argparse
import struct
import wave
from pathlib import Path

import numpy as np

RATE = 44100


# --------------------------------------------------------------------------- #
# primitives
# --------------------------------------------------------------------------- #
def _t(duration: float) -> np.ndarray:
    return np.linspace(0.0, duration, int(RATE * duration), endpoint=False)


def noise(duration: float, rng: np.random.Generator) -> np.ndarray:
    return rng.uniform(-1.0, 1.0, int(RATE * duration))


def decay(n: int, rate: float) -> np.ndarray:
    """Exponential decay envelope, `rate` in 1/seconds."""
    return np.exp(-np.arange(n) / RATE * rate)


def lowpass(signal: np.ndarray, cutoff: float) -> np.ndarray:
    """One-pole low pass; good enough to shape a noise burst."""
    alpha = 1.0 - np.exp(-2.0 * np.pi * cutoff / RATE)
    out = np.zeros_like(signal)
    acc = 0.0
    for i, value in enumerate(signal):
        acc += alpha * (value - acc)
        out[i] = acc
    return out


def highpass(signal: np.ndarray, cutoff: float) -> np.ndarray:
    return signal - lowpass(signal, cutoff)


def sine(freq: float, duration: float, phase: float = 0.0) -> np.ndarray:
    return np.sin(2.0 * np.pi * freq * _t(duration) + phase)


def sweep(start: float, end: float, duration: float) -> np.ndarray:
    n = int(RATE * duration)
    frequencies = np.linspace(start, end, n)
    phase = np.cumsum(2.0 * np.pi * frequencies / RATE)
    return np.sin(phase)


def mix(*layers: np.ndarray) -> np.ndarray:
    length = max(len(layer) for layer in layers)
    out = np.zeros(length)
    for layer in layers:
        out[: len(layer)] += layer
    return out


def normalise(signal: np.ndarray, peak: float = 0.85) -> np.ndarray:
    highest = float(np.max(np.abs(signal))) or 1.0
    return signal / highest * peak


def fade(signal: np.ndarray, milliseconds: float = 4.0) -> np.ndarray:
    """Tiny fade in/out so the clip does not click."""
    count = max(1, int(RATE * milliseconds / 1000.0))
    if len(signal) <= count * 2:
        return signal
    envelope = np.ones(len(signal))
    envelope[:count] = np.linspace(0.0, 1.0, count)
    envelope[-count:] = np.linspace(1.0, 0.0, count)
    return signal * envelope


# --------------------------------------------------------------------------- #
# sounds
# --------------------------------------------------------------------------- #
def gunshot(rng: np.random.Generator, *, low: float, high: float, body: float) -> np.ndarray:
    """A gunshot: transient crack, filtered noise body, low thump.

    `low` / `high` pick the noise band (heavier weapons sit lower), `body` is
    the length of the tail in seconds.
    """
    crack = highpass(noise(0.012, rng), 2500.0) * decay(int(RATE * 0.012), 260.0) * 1.4
    burst = lowpass(noise(body, rng), high) * decay(int(RATE * body), 9.0)
    burst = highpass(burst, low)
    thump = sweep(140.0, 55.0, body * 0.5) * decay(int(RATE * body * 0.5), 22.0) * 0.8
    return fade(normalise(mix(crack, burst, thump)))


def build_sounds(rng: np.random.Generator) -> dict[str, np.ndarray]:
    sounds: dict[str, np.ndarray] = {}

    # Weapons: one per broad class, pitch-shifted per weapon at runtime.
    sounds["shot_rifle"] = gunshot(rng, low=260.0, high=4200.0, body=0.20)
    sounds["shot_pistol"] = gunshot(rng, low=420.0, high=5200.0, body=0.13)
    sounds["shot_smg"] = gunshot(rng, low=380.0, high=4800.0, body=0.15)
    sounds["shot_sniper"] = gunshot(rng, low=150.0, high=3200.0, body=0.34)
    sounds["shot_shotgun"] = gunshot(rng, low=120.0, high=2600.0, body=0.36)

    # Knife: a short metallic swish, no crack.
    swish = lowpass(noise(0.16, rng), 5200.0) * decay(int(RATE * 0.16), 26.0)
    swish += sine(1800.0, 0.16) * decay(int(RATE * 0.16), 40.0) * 0.12
    sounds["knife"] = fade(normalise(swish, 0.55))

    # Reload: magazine out, magazine in, bolt.
    def click(freq: float, length: float) -> np.ndarray:
        return highpass(noise(length, rng), freq) * decay(int(RATE * length), 120.0)

    sounds["reload"] = fade(normalise(mix(
        np.concatenate([click(1800.0, 0.05), np.zeros(int(RATE * 0.16)), click(1200.0, 0.07),
                        np.zeros(int(RATE * 0.09)), click(2600.0, 0.05)]),
    ), 0.6))

    # Footsteps: soft filtered thuds, three variants so walking does not loop.
    for index in range(3):
        step = lowpass(noise(0.09, rng), 700.0 + index * 90.0) * decay(int(RATE * 0.09), 70.0)
        sounds[f"step_{index}"] = fade(normalise(step, 0.32))

    # Landing from a jump.
    land = lowpass(noise(0.14, rng), 520.0) * decay(int(RATE * 0.14), 42.0)
    land += sweep(120.0, 60.0, 0.14) * decay(int(RATE * 0.14), 30.0) * 0.5
    sounds["land"] = fade(normalise(land, 0.5))

    # Bullet impact on a wall.
    impact = highpass(noise(0.07, rng), 1500.0) * decay(int(RATE * 0.07), 120.0)
    sounds["impact"] = fade(normalise(impact, 0.45))

    # Bullet hit on a player (flesh).
    flesh = lowpass(noise(0.10, rng), 900.0) * decay(int(RATE * 0.10), 60.0)
    sounds["flesh"] = fade(normalise(flesh, 0.55))

    # C4: plant beep, then the armed countdown beep.
    beep = sine(1400.0, 0.07) * decay(int(RATE * 0.07), 30.0)
    sounds["beep"] = fade(normalise(beep, 0.4))
    plant = mix(sine(900.0, 0.10) * decay(int(RATE * 0.10), 24.0),
                sine(1350.0, 0.10) * decay(int(RATE * 0.10), 24.0) * 0.5)
    sounds["plant"] = fade(normalise(plant, 0.55))
    defuse = mix(sine(1500.0, 0.09) * decay(int(RATE * 0.09), 22.0),
                 sine(2000.0, 0.09) * decay(int(RATE * 0.09), 22.0) * 0.6)
    sounds["defuse"] = fade(normalise(defuse, 0.55))

    # The explosion: long low rumble with a bright transient.
    length = 1.6
    rumble = lowpass(noise(length, rng), 320.0) * decay(int(RATE * length), 3.2)
    rumble += sweep(90.0, 28.0, length) * decay(int(RATE * length), 2.4) * 1.1
    transient = highpass(noise(0.05, rng), 2000.0) * decay(int(RATE * 0.05), 90.0)
    sounds["explosion"] = fade(normalise(mix(rumble, transient, np.zeros(int(RATE * length)))), 0.95)

    # Round start / end stingers.
    win = mix(sine(523.25, 0.55), sine(659.25, 0.55) * 0.7, sine(783.99, 0.55) * 0.5)
    win *= np.minimum(1.0, decay(int(RATE * 0.55), 3.0))
    sounds["round_win"] = fade(normalise(win, 0.5))
    lose = mix(sine(392.0, 0.7), sine(311.13, 0.7) * 0.8)
    lose *= np.minimum(1.0, decay(int(RATE * 0.7), 2.4))
    sounds["round_lose"] = fade(normalise(lose, 0.5))

    # Weapon switch: a small cloth/plastic shuffle.
    switch = lowpass(noise(0.09, rng), 2400.0) * decay(int(RATE * 0.09), 55.0)
    sounds["switch"] = fade(normalise(switch, 0.3))

    return sounds


# --------------------------------------------------------------------------- #
# writing
# --------------------------------------------------------------------------- #
def write_wav(path: Path, samples: np.ndarray) -> None:
    clipped = np.clip(samples, -1.0, 1.0)
    pcm = (clipped * 32767.0).astype("<i2")
    path.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(path), "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(RATE)
        handle.writeframes(pcm.tobytes())


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", default="assets/audio", help="output directory")
    parser.add_argument("--seed", type=int, default=15, help="noise seed")
    args = parser.parse_args()

    rng = np.random.default_rng(args.seed)
    out = Path(args.out)
    sounds = build_sounds(rng)
    total = 0
    for name, samples in sorted(sounds.items()):
        path = out / f"{name}.wav"
        write_wav(path, samples)
        total += len(samples)
        print(f"  {name:14s} {len(samples) / RATE:5.2f}s  {path}")
    print(f"{len(sounds)} sounds, {total / RATE:.1f}s of audio -> {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
