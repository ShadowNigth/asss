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


def load_palette(path: Path) -> bytes:
    data = Path(path).read_bytes()
    if len(data) < 768:
        raise ValueError(f"{path} is not a 768-byte palette")
    return data[:768]


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
        self.palette = palette
        self._by_name = {name.lower(): (pos, size, typ) for name, pos, _d, size, typ in self.entries}

    def has(self, name: str) -> bool:
        return name.lower() in self._by_name

    def read_miptex(self, name: str):
        entry = self._by_name.get(name.lower())
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
        palette_at = start
        for level in range(4):
            if offsets[level] == 0:
                break
            palette_at = offsets[level] + (width >> level) * (height >> level)
        palette = blob[palette_at:palette_at + 768] if palette_at + 768 <= len(blob) else self.palette
        if palette is None or len(palette) < 768:
            return None
        return width, height, mip0, palette

    def rgba(self, name: str, palette: bytes | None = None):
        result = self.read_miptex(name)
        if result is None:
            return None
        width, height, indices, pal = result
        lookup = pal if len(pal) >= 768 else (palette or self.palette)
        if lookup is None:
            return None
        table = bytes(lookup)
        rgba = bytearray(width * height * 4)
        for i, index in enumerate(indices):
            src = index * 3
            dst = i * 4
            rgba[dst] = table[src]
            rgba[dst + 1] = table[src + 1]
            rgba[dst + 2] = table[src + 2]
            rgba[dst + 3] = 0 if index == 255 else 255
        return width, height, bytes(rgba)
