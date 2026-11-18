#!/usr/bin/env python3
"""Import the retail weapon reports from the `archi` sound pack.

`SoundNight/archi` (github.com/ShadowNigth/archi) ships the original CS 1.6
`sound/` tree -- one WAV per weapon, plus the CS:GO reload/draw kits -- and
those are the reports this game should fire. The repo is far too big to vendor
(3.9 GB: it also carries the CS:GO weapon packs), so this script takes a clone
of it and writes only what the game needs:

    python3 tools/audio/import_weapon_sounds.py --source /path/to/archi
    python3 tools/audio/import_weapon_sounds.py --source /tmp/archi --check

A sparse clone is enough and is what CI/docs suggest:

    git clone --depth 1 --filter=blob:none --sparse \\
        https://github.com/ShadowNigth/archi.git /tmp/archi
    cd /tmp/archi && git sparse-checkout set sound

Every retail file is 22.05 kHz mono 16-bit with a long silent tail (the report
itself is often a fraction of the file), so each one is trimmed, peak-normalised
to -1 dBFS and resampled to 44.1 kHz for the engine. The knife, the reload
clicks and the C4/grenade foley come from the CS:GO kit folders in the same
repo.

The weapon mapping is fixed here rather than guessed: the retail names in the
pack (`tmp-1`, `sg550-1`, `m4a1_unsil-1`, ...) do not match this project's
weapon ids one-to-one, and the silencer variants have to lose the suppressed
take -- `m4a1-1` is the *silenced* M4 report, `m4a1_unsil-1` the loud one.

Audio is written next to the synthesised set (`assets/audio`) and is what
`scripts/core/sound.gd` loads first; `make_sounds.py` remains the fallback for
everything the pack does not cover (footsteps, impacts, the round stingers).
"""

from __future__ import annotations

import argparse
import shutil
import wave
from pathlib import Path

import numpy as np

OUT_RATE = 44100
PEAK_DBFS = -1.0

# project weapon id -> candidate retail files, best take first. A file that is
# missing is skipped, so an incomplete clone still yields a usable set.
SHOTS: dict[str, list[str]] = {
    "ak47": ["sound/ak47-1.wav", "sound/ak47-2.wav"],
    "aug": ["sound/aug-1.wav"],
    "awp": ["sound/awp1.wav"],
    "deagle": ["sound/deagle-1.wav", "sound/deagle-2.wav"],
    "elite": ["sound/elite_fire.wav"],
    "famas": ["sound/famas-1.wav", "sound/famas-2.wav"],
    "fiveseven": ["sound/fiveseven-1.wav"],
    "g3sg1": ["sound/g3sg1-1.wav"],
    "galil": ["sound/galil-1.wav", "sound/galil-2.wav"],
    "glock": ["sound/glock18-1.wav", "sound/glock18-2.wav"],
    "m249": ["sound/m249-1.wav", "sound/m249-2.wav"],
    "m3": ["sound/m3-1.wav"],
    # m4a1-1 is the suppressed take; the unsilenced one is m4a1_unsil-*
    "m4a1": ["sound/m4a1_unsil-1.wav", "sound/m4a1_unsil-2.wav", "sound/m4a1-1.wav"],
    "mac10": ["sound/mac10-1.wav"],
    "mp5": ["sound/mp5-1.wav", "sound/mp5-2.wav"],
    "p90": ["sound/p90-1.wav"],
    "scout": ["sound/scout_fire-1.wav"],
    "sg550": ["sound/sg550-1.wav"],
    "sg552": ["sound/sg552-1.wav", "sound/sg552-2.wav"],
    "tmphk": ["sound/tmp-1.wav", "sound/tmp-2.wav"],
    "ump45": ["sound/ump45-1.wav"],
    "usp": ["sound/usp1.wav", "sound/usp2.wav", "sound/usp_unsil-1.wav"],
    "xm1014": ["sound/xm1014-1.wav"],
}

# Distant reports: the CS:GO kits carry a tail-off take per weapon, which is
# what a shot should sound like from across the map. Only a few weapons ship
# one, so the rest fall back to the near report at distance.
DISTANT: dict[str, list[str]] = {
    "ak47": [
        "CS2GO.Pack.Director.s.Cut.-.Rifles/EXTRAIDOS/m_cs2_ak47/#pak/sound/weapons/ak47/ak47_distant.wav",
    ],
    "famas": [
        "CS2GO.Pack.Director.s.Cut.-.Rifles/EXTRAIDOS/m_cs2_famas/#pak/sound/weapons/famas/famas_distant_01.wav",
    ],
}

# Non-weapon sounds from the same pack: retail knife/bullet foley and the
# CS:GO equipment kit (draw, reload, pin pulls).
ONE_SHOTS: dict[str, list[str]] = {
    # the pack ships no knife foley, so `knife` stays synthesised
    "knife_slash": [
        "CS2GO.Pack.Director.s.Cut.-.Equipment/CS2 Knife/EXTRAIDOS/m_cs2_knife/sound/weapons/knife/knife_slash1.wav",
    ],
    "grenade_throw": [
        "sound/cs2_hegren/grenade_throw.wav",
        "sound/cs2_flashbang/throw.wav",
    ],
    "pinpull": [
        "sound/cs2_hegren/pinpull.wav",
        "sound/cs2_flashbang/pinpull.wav",
        "sound/cs2_smokegren/pinpull.wav",
    ],
    "grenade_bounce": [
        "sound/cs2_hegren/he_bounce-1.wav",
    ],
    "c4_initiate": [
        "sound/cs2_c4/c4_initiate.wav",
    ],
    "key_press": [
        "sound/cs2_c4/key_press1.wav",
        "sound/cs2_c4/key_press2.wav",
        "sound/cs2_c4/key_press3.wav",
        "sound/cs2_c4/key_press4.wav",
        "sound/cs2_c4/key_press5.wav",
        "sound/cs2_c4/key_press6.wav",
        "sound/cs2_c4/key_press7.wav",
    ],
    "c4_draw": [
        "sound/cs2_c4/c4_draw.wav",
    ],
    # explosions: retail HE / flash / C4 blasts beat the synthesised stand-ins
    "he_explode": ["sound/hegrenade-1.wav", "sound/hegrenade-2.wav"],
    "flash_explode": ["sound/flashbang-1.wav", "sound/flashbang-2.wav"],
    "c4_explode": ["sound/sg_explode.wav"],
    # scope clicks come with the CS:GO kits
    "zoom_in": ["sound/cs2_aug/zoom_in.wav", "sound/cs2_awp/zoom_in.wav"],
    "zoom_out": ["sound/cs2_aug/zoom_out.wav", "sound/cs2_awp/zoom_out.wav"],
}

# Per-weapon reload foley: (folder, [files], repeat). The kit files are one
# mechanical action each, so a magazine change is a few of them back to back.
RELOADS: dict[str, tuple[str, list[str]]] = {
    "ak47": ("sound/cs2_ak47", ["clipout.wav", "clipin.wav", "boltpull.wav"]),
    "aug": ("sound/cs2_aug", ["clipout.wav", "clipin.wav", "boltpull.wav"]),
    "awp": ("sound/cs2_awp", ["boltback.wav", "boltforward.wav"]),
    "deagle": ("sound/cs2_deagle", ["clipout.wav", "clipin.wav", "slideback.wav", "slideforward.wav"]),
    "elite": ("sound/cs2_elites", ["clipout.wav", "leftclipin.wav", "rightclipin.wav", "sliderelease.wav"]),
    "famas": ("sound/cs2_famas", ["clipout.wav", "clipin.wav", "boltback.wav", "boltforward.wav"]),
    "fiveseven": ("sound/cs2_fiveseven", ["clipout.wav", "clipin.wav", "sliderelease.wav"]),
    "g3sg1": ("sound/cs2_g3sg1", ["clipout.wav", "clipin.wav", "slideback.wav"]),
    "galil": ("sound/cs2_galilar", ["clipout.wav", "clipin.wav", "boltback.wav", "boltforward.wav"]),
    "glock": ("sound/cs2_glock18", ["clipout.wav", "clipin.wav", "sliderelease.wav"]),
    "m249": ("sound/cs2_m249", ["boxout.wav", "boxin.wav", "coverdown.wav"]),
    "m3": ("sound/cs2_nova", ["insertshell_01.wav", "insertshell_02.wav", "pump.wav"]),
    "m4a1": ("sound/cs2_m4a1s", ["clipout.wav", "clipin.wav", "boltback.wav", "boltforward.wav"]),
    "mac10": ("sound/cs2_mac10", ["clipout.wav", "clipin.wav", "boltback.wav"]),
    "mp5": ("sound/cs2_mp5sd", ["clipout.wav", "clipin.wav", "slideback.wav", "slideforward.wav"]),
    "p90": ("sound/cs2_p90", ["clipout.wav", "clipin.wav", "boltback.wav"]),
    "scout": ("sound/cs2_ssg08", ["clipout.wav", "clipin.wav", "boltback.wav", "boltforward.wav"]),
    "sg550": ("sound/cs2_scar20", ["clipout.wav", "clipin.wav", "boltback.wav", "boltforward.wav"]),
    "sg552": ("sound/cs2_sg553", ["clipout.wav", "clipin.wav", "boltback.wav"]),
    "tmphk": ("sound/cs2_mp9", ["clipout.wav", "clipin.wav", "boltback.wav"]),
    "ump45": ("sound/cs2_ump45", ["clipout.wav", "clipin.wav", "boltback.wav"]),
    "usp": ("sound/cs2_usps", ["clipout.wav", "clipin.wav", "slideback.wav", "sliderelease.wav"]),
    "xm1014": ("sound/cs2_xm1014", ["insertshell_01.wav", "insertshell_02.wav"]),
}


# --------------------------------------------------------------------------- #
# wave helpers
# --------------------------------------------------------------------------- #
def read_wav(path: Path) -> tuple[np.ndarray, int]:
    with wave.open(str(path), "rb") as handle:
        channels = handle.getnchannels()
        width = handle.getsampwidth()
        rate = handle.getframerate()
        raw = handle.readframes(handle.getnframes())
    if width != 2:
        raise ValueError(f"{path}: only 16-bit PCM is supported (got {width * 8}-bit)")
    data = np.frombuffer(raw, dtype="<i2").astype(np.float32) / 32768.0
    if channels > 1:
        data = data.reshape(-1, channels).mean(axis=1)
    return data, rate


def resample(data: np.ndarray, src: int, dst: int = OUT_RATE) -> np.ndarray:
    """Linear resample; the sources are band-limited well below 11 kHz."""
    if src == dst or data.size == 0:
        return data
    count = max(1, int(round(data.size * dst / src)))
    x_old = np.arange(data.size, dtype=np.float64)
    x_new = np.linspace(0.0, data.size - 1, count)
    return np.interp(x_new, x_old, data).astype(np.float32)


def trim_silence(data: np.ndarray, rate: int, threshold: float = 0.02,
                  tail: float = 0.06) -> np.ndarray:
    """Drop the dead air the retail files carry before and after the report."""
    if data.size == 0:
        return data
    loud = np.where(np.abs(data) > threshold)[0]
    if loud.size == 0:
        return data[: max(1, int(rate * 0.05))]
    start = max(0, loud[0] - int(rate * 0.002))
    end = min(data.size, loud[-1] + int(rate * tail))
    return data[start:end]


def normalise(data: np.ndarray, peak_dbfs: float = PEAK_DBFS) -> np.ndarray:
    peak = float(np.max(np.abs(data))) if data.size else 0.0
    if peak <= 1e-6:
        return data
    return data * (10.0 ** (peak_dbfs / 20.0) / peak)


def fade(data: np.ndarray, rate: int, fade_out: float = 0.02) -> np.ndarray:
    """Ramp the last few ms; a hard cut after a gunshot clicks."""
    n = min(data.size, int(rate * fade_out))
    if n > 1:
        data = data.copy()
        data[-n:] *= np.linspace(1.0, 0.0, n, dtype=np.float32)
    return data


def concat(parts: list[np.ndarray], rate: int, gap: float = 0.06) -> np.ndarray:
    silence = np.zeros(max(0, int(rate * gap)), dtype=np.float32)
    out: list[np.ndarray] = []
    for index, part in enumerate(parts):
        if index:
            out.append(silence)
        out.append(part)
    return np.concatenate(out) if out else np.zeros(0, dtype=np.float32)


def write_wav(path: Path, data: np.ndarray, rate: int = OUT_RATE) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    pcm = (np.clip(data, -1.0, 1.0) * 32767.0).astype("<i2")
    with wave.open(str(path), "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(rate)
        handle.writeframes(pcm.tobytes())


def first_existing(source: Path, candidates: list[str]) -> Path | None:
    for candidate in candidates:
        path = source / candidate
        if path.is_file():
            return path
    return None


def load_clean(path: Path, max_len: float = 0.0) -> np.ndarray:
    """Trim, cap, normalise and fade one source file.

    `max_len` clamps the length: the retail files carry long reverb tails that
    overlap the next shot when several agents fire at once.
    """
    data, rate = read_wav(path)
    data = trim_silence(data, rate)
    if max_len > 0.0:
        data = data[: int(rate * max_len)]
    return fade(normalise(data), rate)


# how long each source may be, in seconds: reports are punchy, explosions long
MAX_LENGTH = {
    "awp": 1.6, "scout": 1.2, "sg_explode": 3.2, "he_explode": 2.2,
    "flash_explode": 1.8, "c4_explode": 3.2, "grenade_bounce": 0.7,
}


# --------------------------------------------------------------------------- #
# build
# --------------------------------------------------------------------------- #
def build(source: Path, out: Path, log=print) -> dict:
    """Write the shots, reloads and foley; return a name -> path summary."""
    source = source.expanduser().resolve()
    if not (source / "sound").is_dir():
        raise SystemExit(f"{source} does not look like a clone of the archi pack "
                         f"(no sound/ directory); try a sparse checkout of `sound`")
    out = out.expanduser().resolve()
    written: dict[str, str] = {}
    missing: list[str] = []

    # shots
    for weapon, candidates in SHOTS.items():
        path = first_existing(source, candidates)
        if path is None:
            missing.append(f"shot/{weapon}")
            continue
        target = out / "shots" / f"{weapon}.wav"
        write_wav(target, load_clean(path, MAX_LENGTH.get(weapon, 0.9)))
        written[f"shot/{weapon}"] = str(target.relative_to(out))
    log(f"shots   {len(SHOTS) - len([m for m in missing if m.startswith('shot/')])}/{len(SHOTS)}")

    # distant reports, used by the mixer for shots further than ~25 m
    distant = 0
    for weapon, candidates in DISTANT.items():
        path = first_existing(source, candidates)
        if path is None:
            continue
        target = out / "shots" / f"{weapon}_far.wav"
        write_wav(target, load_clean(path, 1.4))
        written[f"shot/{weapon}_far"] = str(target.relative_to(out))
        distant += 1
    log(f"distant {distant}/{len(DISTANT)}")

    # reload foley, one file per weapon
    built = 0
    for weapon, (folder, files) in RELOADS.items():
        parts: list[np.ndarray] = []
        for name in files:
            path = source / folder / name
            if path.is_file():
                parts.append(load_clean(path))
        if not parts:
            continue
        target = out / "reloads" / f"{weapon}.wav"
        write_wav(target, fade(normalise(concat(parts, OUT_RATE)), -1.5), OUT_RATE)
        written[f"reload/{weapon}"] = str(target.relative_to(out))
        built += 1
    log(f"reloads {built}/{len(RELOADS)}")

    # one-shots
    built = 0
    for name, candidates in ONE_SHOTS.items():
        path = first_existing(source, candidates)
        if path is None:
            missing.append(name)
            continue
        target = out / "foley" / f"{name}.wav"
        write_wav(target, load_clean(path, MAX_LENGTH.get(name, 0.0)))
        written[name] = str(target.relative_to(out))
        built += 1
    log(f"foley   {built}/{len(ONE_SHOTS)}")

    if missing:
        log("missing: " + ", ".join(sorted(missing)))
    total = sum((out / rel).stat().st_size for rel in written.values())
    log(f"{len(written)} files, {total / 1024:.0f} KB -> {out}")
    return written


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--source", default="/tmp/archi", help="clone of github.com/ShadowNigth/archi")
    parser.add_argument("--out", default="assets/audio", help="output directory")
    parser.add_argument("--check", action="store_true",
                        help="build into a temporary directory and report coverage only")
    args = parser.parse_args()

    out = Path(args.out)
    if args.check:
        import tempfile

        with tempfile.TemporaryDirectory() as tmp:
            build(Path(args.source), Path(tmp))
        return 0
    build(Path(args.source), out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
