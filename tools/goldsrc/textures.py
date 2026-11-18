"""Texture resolution for GoldSrc maps.

Order of preference per texinfo entry:

1. a miptex embedded in the BSP itself (CS 1.5 maps embed a handful),
2. the same miptex from any of the retail WADs next to the map,
3. a procedural fallback that matches the texture-name family, so missing
   retail WADs (mainly ``halflife.wad``) degrade to plausible stone/sand/metal
   instead of checkerboards.  Every fallback is logged for auditing.
"""
from __future__ import annotations

import zlib
from dataclasses import dataclass
from pathlib import Path

import numpy as np

from .wad import Wad


@dataclass
class ResolvedTexture:
    name: str
    width: int
    height: int
    rgba: bytes
    source: str  # "bsp" | "wad:<file>" | "fallback:<family>"
    transparent: bool = False

    @property
    def family(self) -> str:
        if self.source.startswith("fallback:"):
            return self.source.split(":", 1)[1]
        return texture_family(self.name)


@dataclass
class TextureSet:
    textures: dict[str, ResolvedTexture]
    wad_files: list[str]
    missing: list[str]
    fallbacks: list[str]

    def get(self, name: str) -> ResolvedTexture | None:
        return self.textures.get(name.lower())


FAMILY_RULES = [
    ("water", ("water", "slime", "lava", "teleport", "!")),
    ("glass", ("glass", "window", "trans")),
    ("foliage", ("leaf", "leaves", "plant", "tree", "grass", "bush", "hedge")),
    ("snow", ("snow", "ice")),
    ("sand", ("sand", "dust", "desert", "dirt", "gravel")),
    ("wood", ("wood", "crate", "plank", "barrel", "board")),
    ("metal", ("metal", "steel", "iron", "rust", "pipe", "vent", "grate", "door")),
    ("brick", ("brick", "wall", "block")),
    ("tile", ("tile", "floor", "marble", "ceramic")),
    ("concrete", ("concrete", "cement", "stucco", "plaster", "cinder")),
]


def texture_family(name: str) -> str:
    key = name.lower()
    for family, tokens in FAMILY_RULES:
        if any(token in key for token in tokens):
            return family
    return "concrete"


FAMILY_PALETTE = {
    "water": ((28, 74, 96), (18, 48, 68)),
    "glass": ((150, 190, 205), (110, 150, 170)),
    "foliage": ((62, 96, 48), (40, 66, 32)),
    "snow": ((206, 214, 224), (176, 188, 204)),
    "sand": ((176, 154, 112), (150, 128, 92)),
    "wood": ((116, 84, 52), (88, 62, 38)),
    "metal": ((126, 130, 138), (86, 90, 98)),
    "brick": ((142, 82, 64), (112, 62, 48)),
    "tile": ((168, 168, 160), (132, 132, 126)),
    "concrete": ((146, 144, 138), (112, 110, 106)),
}


def _value_noise(width: int, height: int, seed: int) -> np.ndarray:
    rng = np.random.default_rng(seed)
    coarse = rng.random((max(2, height // 8), max(2, width // 8)), dtype=np.float32)
    image = np.repeat(np.repeat(coarse, 8, axis=0), 8, axis=1)[:height, :width]
    return image


def fallback_texture(name: str, width: int = 128, height: int = 128) -> ResolvedTexture:
    family = texture_family(name)
    dark, light = FAMILY_PALETTE.get(family, FAMILY_PALETTE["concrete"])
    seed = zlib.crc32(name.lower().encode("latin-1")) & 0xFFFFFFFF
    noise = _value_noise(width, height, seed)
    tiled = (np.sin(np.arange(width) / width * np.pi * 16) * 0.5 + 0.5).astype(np.float32)
    grain = (noise * 0.55 + (1.0 - tiled)[None, :] * 0.2 + 0.25).clip(0.0, 1.0)
    base = np.array(dark, dtype=np.float32)
    top = np.array(light, dtype=np.float32)
    rgb = base[None, None, :] + (top - base)[None, None, :] * grain[:, :, None]
    rgba = np.zeros((height, width, 4), dtype=np.uint8)
    rgba[:, :, :3] = np.clip(rgb, 0, 255).astype(np.uint8)
    rgba[:, :, 3] = 255
    return ResolvedTexture(name, width, height, rgba.tobytes(), f"fallback:{family}", name.startswith("{"))


def resolve_textures(bsp, wad_paths: list[Path], palette: bytes | None, log=print) -> TextureSet:
    embedded = bsp.embedded_textures(palette or bytes(768))
    wads: list[Wad] = []
    used: list[str] = []
    for path in wad_paths:
        if not Path(path).exists():
            continue
        try:
            wad = Wad(path, palette)
        except ValueError:
            continue
        wads.append(wad)
        used.append(Path(path).name)

    textures: dict[str, ResolvedTexture] = {}
    missing: list[str] = []
    fallbacks: list[str] = []
    for tex in bsp.textures:
        key = tex.name.lower()
        if not tex.name or key.startswith("__missing"):
            continue
        if key in textures:
            continue
        if key in embedded:
            textures[key] = embedded[key]
            continue
        found = None
        for wad in wads:
            resolved = wad.rgba(tex.name, palette)
            if resolved:
                width, height, rgba = resolved
                textures[key] = ResolvedTexture(tex.name, width, height, rgba, f"wad:{wad.path.name}",
                                                tex.name.startswith("{"))
                found = True
                break
        if found:
            continue
        if key.startswith("sky"):
            continue
        fallback = fallback_texture(tex.name)
        textures[key] = fallback
        fallbacks.append(tex.name)
    log(f"textures: {len(textures)} resolved ({len(embedded)} embedded, {len(fallbacks)} fallback), wads={used}")
    return TextureSet(textures, used, missing, fallbacks)
