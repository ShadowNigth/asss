"""Minimal GoldSrc WAD3 reader (textures only).

WAD3 layout::

    char  magic[4]        "WAD3"
    int32 numlumps
    int32 infotableofs
    lump[n] { int32 pos; int32 disksize; int32 size; char type;
              uint8 compression; uint8 pad[2]; char name[16]; }

Only ``type == 0x43`` (miptex) lumps are used; the rest (font/decal) are
skipped.  Textures are decoded straight to RGBA8 with the 768-byte palette in
``palette.lmp`` (or the palette embedded in the BSP).
"""
from __future__ import annotations

import struct
from pathlib import Path

from .palette import choose, decode, normalise


def load_palette(path: Path) -> bytes:
    data = Path(path).read_bytes()
    if len(data) < 768:
        raise ValueError(f"{path} is not a 768-byte palette")
    return data[:768]


def _name_variants(name: str):
    """Yield the plausible WAD spellings of a BSP texture name."""
    yield name
    candidates = []
    # the stamp is exactly two characters: +0 -0 +a -a +1 -1 ...
    candidates.append(name[2:])
    # names pasted into the BSP sometimes lose/gain the { masked prefix
    if name[:1] in "+-":
        candidates.append(name[3:] if name[2:3] == "~" else name[2:].lstrip("~"))
    for candidate in list(candidates):
        candidates.append(candidate.lstrip("{"))
        candidates.append(candidate.lstrip("~"))
        candidates.append(candidate.lstrip("~{").lstrip("{~"))
    seen = set()
    for candidate in candidates:
        if candidate and candidate not in seen:
            seen.add(candidate)
            yield candidate


class Wad:
    def __init__(self, path: Path, palette: bytes | None = None) -> None:
        self.path = Path(path)
        self.data = self.path.read_bytes()
        if self.data[:4] not in (b"WAD3", b"WAD2"):
            raise ValueError(f"{self.path} is not a WAD file")
        count, table = struct.unpack("<ii", self.data[4:12])
        self.entries: list[tuple[str, int, int, int, int]] = []
        for index in range(count):
            base = table + index * 32
            if base + 32 > len(self.data):
                break
            pos, disk_size, size, typ, _comp = struct.unpack("<iiIBB", self.data[base:base + 14])
            name = self.data[base + 16:base + 32].split(b"\x00")[0].decode("latin-1")
            self.entries.append((name, pos, disk_size, size, typ))
        self.palette = palette if palette is not None and len(palette) >= 768 else None
        self._by_name = {name.lower(): (pos, size, typ) for name, pos, _d, size, typ in self.entries}

    def has(self, name: str) -> bool:
        return self.resolve_name(name) is not None

    def resolve_name(self, name: str) -> str | None:
        """Map a BSP texture name onto the actual WAD lump.

        Embedded miptex names carry the BSP's lighting/mirror stamp, which is
        always two leading characters (``+0``, ``-a``, ``+1``), optionally
        followed by ``~`` (fullbright).  The WAD stores the bare name, and a
        ``{`` prefix marks a masked texture in both places.
        """
        key = name.lower()
        if key in self._by_name:
            return key
        for candidate in _name_variants(key):
            if candidate in self._by_name:
                return candidate
        return None

    def read_miptex(self, name: str):
        key = self.resolve_name(name)
        if key is None:
            return None
        entry = self._by_name.get(key)
        if entry is None:
            return None
        pos, size, typ = entry
        if typ != 0x43:
            return None
        blob = self.data[pos:pos + size]
        if len(blob) < 40:
            return None
        width, height = struct.unpack("<II", blob[16:24])
        offsets = struct.unpack("<IIII", blob[24:40])
        if width <= 0 or height <= 0 or width > 4096 or height > 4096:
            return None
        start = offsets[0]
        if start == 0 or start + width * height > len(blob):
            return None
        mip0 = blob[start:start + width * height]
        embedded_palette = None
        palette_at = start
        for level in range(4):
            if offsets[level] == 0:
                break
            palette_at = offsets[level] + (width >> level) * (height >> level)
        # the mip chain is followed by a uint16 paletteCount and then the
        # palette itself, exactly like the BSP TEXTURE lump
        if palette_at + 2 <= len(blob):
            count = struct.unpack("<H", blob[palette_at:palette_at + 2])[0]
            if 2 <= count <= 256 and palette_at + 2 + count * 3 <= len(blob):
                embedded_palette = blob[palette_at + 2:palette_at + 2 + 768]
        # every miptex in these WADs carries its own palette; the standalone
        # palette.lmp is Quake's ramp and only a last-resort fallback
        palette = embedded_palette or self.palette
        if palette is None or len(palette) < 768:
            return None
        return width, height, mip0, palette

    def rgba(self, name: str, palette: bytes | None = None):
        """Decode a miptex, choosing the best of the candidate palettes."""
        result = self.read_miptex(name)
        if result is None:
            return None
        width, height, indices, embedded = result
        table = normalise(embedded)
        if table is None:
            table, _score = choose(indices, width, height, [palette, self.palette])
        if table is None:
            return None
        return width, height, decode(indices, width, height, table)
