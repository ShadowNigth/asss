"""Palette selection for GoldSrc miptex.

Quake/GoldSrc textures are 8-bit indexed.  A WAD3 lump does not officially carry
a palette, so the classic pipeline uses a standalone ``palette.lmp``.  The CS 1.5
beta data does something else: every BSP (and every WAD) embeds its *own*
768-byte palette, appended after the mip chain of one of its miptex entries.
Those embedded palettes are the ones the maps were painted with — the
``palette.lmp`` that circulates online is the Quake ramp and decodes this art
into colour noise.

There are several palette-looking blobs inside a container (one per miptex, plus
alignment variants), and only one of them is the real one.  Two independent
signals pick it out:

* **Chroma** — the palette must be colourful.  Data blobs are grey or black.
* **Coherence** — neighbouring texels must stay correlated once decoded, and
  dividing the gradient by the image's own spread normalises for brightness.

Scoring the candidates against a handful of representative textures and taking
the best total yields the container's palette.
"""
from __future__ import annotations

import numpy as np

PALETTE_SIZE = 768


def normalise(values: bytes | None) -> np.ndarray | None:
    """Return a (256, 3) uint8 palette, or None when the input is unusable."""
    if values is None or len(values) < PALETTE_SIZE:
        return None
    return np.frombuffer(bytes(values[:PALETTE_SIZE]), dtype=np.uint8).reshape(256, 3)


def _index_array(indices: bytes, width: int, height: int) -> np.ndarray:
    return np.frombuffer(indices, dtype=np.uint8).reshape(height, width)


def decode_score(indices: bytes, width: int, height: int, palette: np.ndarray) -> float:
    """How plausible a palette is for one texture (higher is better)."""
    image = palette[_index_array(indices, width, height)].astype(np.float32)
    if image.shape[1] < 2 or image.shape[0] < 2:
        return 0.0
    gradient = np.abs(np.diff(image, axis=1)).mean() + np.abs(np.diff(image, axis=0)).mean()
    coherence = max(1.0, float(gradient)) / (float(image.std()) + 1e-3)
    chroma = float((image.max(axis=-1) - image.min(axis=-1)).mean())
    return chroma / coherence


LUMA = np.array([0.299, 0.587, 0.114], dtype=np.float32)


def luminance_ramp(palette: np.ndarray) -> tuple[float, float]:
    """Correlation and mean step of the palette's luminance ramp.

    GoldSrc palettes are organised dark→bright, so the luminance of entries
    0..255 rises almost monotonically.  Compressed texture data and other
    lumps that happen to be 768 bytes long do not.
    """
    luma = palette.astype(np.float32) @ LUMA
    corr = float(np.corrcoef(np.arange(256, dtype=np.float32), luma)[0, 1])
    steps = np.abs(np.diff(luma))
    return corr, float(steps.mean())


def is_plausible(palette) -> bool:
    """Reject blobs that cannot be a painted palette."""
    if not isinstance(palette, np.ndarray):
        palette = normalise(palette)
    if palette is None:
        return False
    if len(np.unique(palette, axis=0)) < 96:
        return False
    if palette.mean() < 12.0 or palette.mean() > 246.0:
        return False
    corr, step = luminance_ramp(palette)
    return corr > 0.9 and 0.4 < step < 14.0


def best_global(candidates: list[tuple[str, bytes]], samples: list[tuple[bytes, int, int]]):
    """Choose the one palette that decodes every sample texture coherently.

    Returns ``(palette, score, name)``.
    """
    prepared = []
    for name, values in candidates:
        palette = normalise(values)
        if palette is None or not is_plausible(palette):
            continue
        prepared.append((name, palette))
    if not prepared:
        return None, 0.0, ""
    if not samples:
        return prepared[0][1], 0.0, prepared[0][0]
    best, best_score, best_name = None, 0.0, ""
    for name, palette in prepared:
        total = sum(decode_score(indices, width, height, palette)
                    for indices, width, height in samples)
        if total > best_score:
            best, best_score, best_name = palette, total, name
    return best, best_score, best_name


def choose(indices: bytes, width: int, height: int, candidates: list):
    """Pick the palette that decodes `indices` best (per-texture fallback)."""
    best = None
    best_score = 0.0
    for candidate in candidates:
        palette = candidate if isinstance(candidate, np.ndarray) else normalise(candidate)
        if palette is None or palette.shape != (256, 3):
            continue
        score = decode_score(indices, width, height, palette)
        if score > best_score:
            best, best_score = palette, score
    return best, best_score


def decode(indices: bytes, width: int, height: int, palette: np.ndarray) -> bytes:
    """RGBA8 bytes for an indexed image (index 255 = transparent)."""
    source = _index_array(indices, width, height)
    rgba = np.zeros((height, width, 4), dtype=np.uint8)
    rgba[:, :, :3] = palette[source]
    rgba[:, :, 3] = np.where(source == 255, 0, 255).astype(np.uint8)
    return rgba.tobytes()


def looks_like_quake_palette(palette: np.ndarray) -> bool:
    """The 16-step black->white ramp at the start identifies Quake's palette."""
    head = palette[:16].tolist()
    expected = [[v, v, v] for v in (0, 15, 31, 47, 63, 79, 95, 111, 127, 143, 159, 175, 191, 207, 223, 239)]
    return head == expected
