"""GoldSrc BSP30 parser: geometry, textures, lightmaps, entities, models.

Coordinate system
-----------------
GoldSrc is Z-up (x east, y north, z up) with a right-handed basis.  The port
uses Godot's Y-up, -Z forward convention, so every position is converted with::

    (x, y, z) -> (x·s, z·s, -y·s)          s = 0.0254 m per source unit

Normals use the same rotation without the scale, and AABBs are remapped by
swapping the y/z extremes (min.y = mins.z, max.z = -mins.y).

Triangle winding is preserved as-is: the rotation has determinant +1, so a
counter-clockwise GoldSrc face stays counter-clockwise in Godot.
"""
from __future__ import annotations

import struct
from pathlib import Path

from .textures import ResolvedTexture

SCALE = 0.0254

LUMP_ENTITIES = 0
LUMP_PLANES = 1
LUMP_TEXTURES = 2
LUMP_VERTICES = 3
LUMP_NODES = 5
LUMP_TEXINFO = 6
LUMP_FACES = 7
LUMP_LIGHTING = 8
LUMP_LEAFLIGHT = 10
LUMP_LEAFS = 10
LUMP_EDGES = 12
LUMP_SURFEDGES = 13
LUMP_MODELS = 14

SURF_SKY = 0x0004
SURF_WATER = 0x0020
SURF_TRANS33 = 0x0010
SURF_TRANS66 = 0x0020


class Entity:
    def __init__(self, properties: dict[str, str] | None = None) -> None:
        self.properties: dict[str, str] = properties or {}
        self.model_bounds: tuple[tuple[float, float, float], tuple[float, float, float]] | None = None

    @property
    def classname(self) -> str:
        return self.properties.get("classname", "").lower()

    def get(self, key: str, default: str = "") -> str:
        return self.properties.get(key, default)

    def number(self, key: str, default: float = 0.0) -> float:
        raw = self.properties.get(key)
        if raw is None:
            return default
        try:
            return float(raw.strip().split()[0])
        except (ValueError, IndexError):
            return default

    def vec(self, key: str, default: tuple[float, float, float] = (0.0, 0.0, 0.0)):
        raw = self.properties.get(key)
        if raw is None:
            return default
        parts = raw.split()
        if len(parts) < 3:
            return default
        try:
            return (float(parts[0]), float(parts[1]), float(parts[2]))
        except ValueError:
            return default

    def __repr__(self) -> str:  # pragma: no cover - debugging helper
        return f"<Entity {self.classname} {self.properties}>"


class MipTex:
    __slots__ = ("name", "width", "height", "offsets", "index")

    def __init__(self, name: str, width: int, height: int, offsets: tuple[int, ...], index: int) -> None:
        self.name = name
        self.width = width
        self.height = height
        self.offsets = offsets
        self.index = index

    @property
    def is_water(self) -> bool:
        key = self.name.lower()
        return key.startswith("*") or key.startswith("!") or (
            key.startswith("{") and "water" in key) or any(
            token in key for token in ("water", "slime", "lava", "teleport"))


class Bsp:
    def __init__(self, path: Path) -> None:
        self.path = Path(path)
        self.data = self.path.read_bytes()
        self.version = struct.unpack("<i", self.data[:4])[0]
        if self.version != 30:
            raise ValueError(f"{self.path.name} is not a BSP30 file (version {self.version})")
        # header: version (4 bytes) + 15 {offset, length} pairs (8 bytes each)
        self.lumps: list[tuple[int, int]] = []
        for index in range(15):
            offset, length = struct.unpack("<ii", self.data[4 + index * 8:12 + index * 8])
            self.lumps.append((offset, length))
        self._parse_entities()
        self._parse_textures()
        self._parse_vertices()
        self._parse_edges()
        self._parse_faces()
        self._parse_texinfo()
        self._parse_models()

    # -------------------------------------------------------------- lumps
    def lump(self, index: int) -> bytes:
        offset, length = self.lumps[index]
        return self.data[offset:offset + length]

    def _parse_entities(self) -> None:
        raw = self.lump(LUMP_ENTITIES)
        text = raw.split(b"\x00")[0].decode("latin-1")
        self.entities: list[Entity] = []
        current: dict[str, str] = {}
        in_block = False
        for token in _tokenize(text):
            if token == "{":
                current, in_block = {}, True
            elif token == "}":
                if in_block:
                    self.entities.append(Entity(current))
                current, in_block = {}, False
            elif in_block and "=" not in token and token in current:
                continue
            elif in_block and token:
                key, _, value = token.partition("\" \"")
                current[key.strip("\"")] = value.strip("\"")

    def _parse_textures(self) -> None:
        raw = self.lump(LUMP_TEXTURES)
        self.textures: list[MipTex] = []
        if len(raw) < 4:
            return
        count = struct.unpack("<i", raw[:4])[0]
        offsets = struct.unpack(f"<{count}i", raw[4:4 + 4 * count])
        for index, offset in enumerate(offsets):
            if offset <= 0 or offset + 40 > len(raw):
                self.textures.append(MipTex("__missing", 16, 16, (0, 0, 0, 0), index))
                continue
            name = raw[offset:offset + 16].split(b"\x00")[0].decode("latin-1")
            width, height = struct.unpack("<II", raw[offset + 16:offset + 24])
            mip_offsets = struct.unpack("<IIII", raw[offset + 24:offset + 40])
            self.textures.append(MipTex(name, width, height, mip_offsets, index))

    def _parse_vertices(self) -> None:
        raw = self.lump(LUMP_VERTICES)
        count = len(raw) // 12
        self.vertices: list[tuple[float, float, float]] = list(struct.iter_unpack("<fff", raw[:count * 12]))

    def _parse_edges(self) -> None:
        raw = self.lump(LUMP_EDGES)
        self.edges = list(struct.iter_unpack("<HH", raw[:len(raw) // 4 * 4]))
        surf = self.lump(LUMP_SURFEDGES)
        self.surfedges = list(struct.unpack(f"<{len(surf) // 4}i", surf[:len(surf) // 4 * 4]))

    def _parse_faces(self) -> None:
        raw = self.lump(LUMP_FACES)
        self.faces: list[dict] = []
        for record in struct.iter_unpack("<HHihhBBBBi", raw[:len(raw) // 20 * 20]):
            plane, side, first_edge, num_edges, texinfo, s1, s2, s3, s4, light_ofs = record
            self.faces.append({
                "plane": plane, "side": side, "first_edge": first_edge, "edge_count": num_edges,
                "texinfo": texinfo, "light_offset": light_ofs,
                "styles": (s1, s2, s3, s4),
            })

    def _parse_texinfo(self) -> None:
        raw = self.lump(LUMP_TEXINFO)
        self.texinfos: list[tuple[int, int, int, int]] = []
        for record in struct.iter_unpack("<8fii", raw[:len(raw) // 40 * 40]):
            *vecs, miptex, flags = record
            self.texinfos.append((vecs, miptex, flags))

    def _parse_models(self) -> None:
        raw = self.lump(LUMP_MODELS)
        self.models: list[dict] = []
        # dmodel_t: float mins[3], maxs[3], origin[3]; int headnode[4];
        #            int visleafs, firstface, numfaces   (64 bytes)
        for record in struct.iter_unpack("<9f7i", raw[:len(raw) // 64 * 64]):
            mins = record[0:3]
            maxs = record[3:6]
            first_face = record[14]
            num_faces = record[15]
            self.models.append({"mins": mins, "maxs": maxs, "first_face": first_face, "num_faces": num_faces})

    # -------------------------------------------------------------- helpers
    def resolve_model_bounds(self) -> None:
        for entity in self.entities:
            model = entity.get("model", "")
            if not model.startswith("*"):
                continue
            try:
                index = int(model[1:])
            except ValueError:
                continue
            if 0 <= index < len(self.models):
                entry = self.models[index]
                entity.model_bounds = (entry["mins"], entry["maxs"])

    def face_vertices(self, face: dict) -> list[int]:
        out: list[int] = []
        first, count = face["first_edge"], face["edge_count"]
        for i in range(count):
            surfedge = self.surfedges[first + i]
            if surfedge >= 0:
                out.append(self.edges[surfedge][0])
            else:
                out.append(self.edges[-surfedge][1])
        return out

    def world_bounds(self):
        model = self.models[0]
        return model["mins"], model["maxs"]

    def lightmap_extents(self, face: dict):
        texinfo = self.texinfos[face["texinfo"]]
        vecs = texinfo[0]
        verts = self.face_vertices(face)
        if not verts:
            return None
        su, sv = vecs[0:3], vecs[4:7]
        s_shift, t_shift = vecs[3], vecs[7]
        mins = [99999.0, 99999.0]
        maxs = [-99999.0, -99999.0]
        for index in verts:
            x, y, z = self.vertices[index]
            s = x * su[0] + y * su[1] + z * su[2] + s_shift
            t = x * sv[0] + y * sv[1] + z * sv[2] + t_shift
            mins[0] = min(mins[0], s)
            mins[1] = min(mins[1], t)
            maxs[0] = max(maxs[0], s)
            maxs[1] = max(maxs[1], t)
        width = int((maxs[0] - mins[0]) / 16.0) + 1
        height = int((maxs[1] - mins[1]) / 16.0) + 1
        if width <= 0 or height <= 0 or width > 512 or height > 512:
            return None
        return {
            "width": width, "height": height,
            "mins": mins, "maxs": maxs,
            "su": su, "sv": sv, "s_shift": s_shift, "t_shift": t_shift,
        }

    def lightmap_bytes(self, face: dict):
        extents = self.lightmap_extents(face)
        if extents is None or face["light_offset"] < 0:
            return None
        size = extents["width"] * extents["height"] * 3
        start = face["light_offset"]
        raw = self.lump(LUMP_LIGHTING)
        if start + size > len(raw):
            return None
        return extents, raw[start:start + size]

    # -------------------------------------------------------------- geometry
    def build_surfaces(self, scale: float = SCALE) -> list[dict]:
        """Group world faces by material and emit GPU-ready arrays."""
        groups: dict[tuple[int, int], dict] = {}
        world = self.models[0]
        first, count = world["first_face"], world["num_faces"]
        sky_color = (0.62, 0.72, 0.86)
        for face in self.faces[first:first + count]:
            if face["edge_count"] < 3 or face["texinfo"] >= len(self.texinfos):
                continue
            vecs, miptex, tex_flags = self.texinfos[face["texinfo"]]
            if miptex < 0 or miptex >= len(self.textures):
                continue
            mip = self.textures[miptex]
            key = miptex.lower() if isinstance(miptex, str) else miptex
            water = mip.is_water
            flags = 0
            if mip.name.lower().startswith("sky"):
                flags |= 1
            if water:
                flags |= 2
            if tex_flags & SURF_WATER:
                flags |= 2
                water = True
            tex_key = (key if isinstance(key, str) else miptex, flags)
            group = groups.get(tex_key)
            if group is None:
                group = {
                    "mat": miptex, "flags": flags, "positions": [], "normals": [],
                    "uv": [], "uv2": [], "colors": [], "indices": [], "verts": 0, "tris": 0,
                }
                groups[tex_key] = group

            verts = self.face_vertices(face)
            if len(verts) < 3:
                continue
            width = max(1, mip.width)
            height = max(1, mip.height)
            su, sv = vecs[0:3], vecs[4:7]
            s_shift, t_shift = vecs[3], vecs[7]
            extents = self.lightmap_extents(face)
            baked = self.lightmap_bytes(face)
            base = group["verts"]
            plane_normal = self._plane_normal(face)
            for index in verts:
                x, y, z = self.vertices[index]
                group["positions"].extend((x * scale, z * scale, -y * scale))
                nx, ny, nz = plane_normal
                group["normals"].extend((nx, nz, -ny))
                s = (x * su[0] + y * su[1] + z * su[2] + s_shift) / width
                t = (y * sv[1] + x * sv[0] + z * sv[2] + t_shift) / height
                group["uv"].extend((s, -t))
                if extents is not None and baked is not None:
                    lm_s = (x * su[0] + y * su[1] + z * su[2] + s_shift)
                    lm_t = (y * sv[1] + x * sv[0] + z * sv[2] + t_shift)
                    u = (lm_s - extents["mins"][0]) / 16.0
                    v = (lm_t - extents["mins"][1]) / 16.0
                    group["uv2"].extend((u / extents["width"], v / extents["height"]))
                    sample = _sample_lightmap(baked, extents["width"], extents["height"], u, v)
                    if flags & 1:
                        sample = tuple(int(c * 255) for c in sky_color)
                    group["colors"].extend(sample)
                else:
                    group["uv2"].extend((0.0, 0.0))
                    if flags & 1:
                        group["colors"].extend((int(sky_color[0] * 255), int(sky_color[1] * 255), int(sky_color[2] * 255)))
                    else:
                        group["colors"].extend((168, 168, 168))
            group["verts"] += len(verts)
            for i in range(1, len(verts) - 1):
                group["indices"].extend((base, base + i, base + i + 1))
                group["tris"] += 1
        return list(groups.values())

    def _plane_normal(self, face: dict):
        raw = self.lump(LUMP_PLANES)
        index = face["plane"] * 20
        if index + 12 > len(raw):
            return (0.0, 0.0, 1.0)
        nx, ny, nz, _dist = struct.unpack("<ffff", raw[index:index + 16])
        if face["side"]:
            nx, ny, nz = -nx, -ny, -nz
        return (nx, ny, nz)

    def water_surfaces(self) -> list[tuple[list[float], list[int]]]:
        out: list[tuple[list[float], list[int]]] = []
        for face in self.faces:
            if face["edge_count"] < 3 or face["texinfo"] >= len(self.texinfos):
                continue
            _vecs, miptex, flags = self.texinfos[face["texinfo"]]
            if miptex < 0 or miptex >= len(self.textures):
                continue
            if not (self.textures[miptex].is_water or flags & SURF_WATER):
                continue
            verts = self.face_vertices(face)
            if len(verts) < 3:
                continue
            points: list[float] = []
            for vi in verts:
                x, y, z = self.vertices[vi]
                points.extend((x * SCALE, z * SCALE, -y * SCALE))
            indices: list[int] = []
            for i in range(1, len(verts) - 1):
                indices.extend((0, i, i + 1))
            out.append((points, indices))
        return out

    def embedded_textures(self, palette: bytes) -> dict[str, ResolvedTexture]:
        """Decode the miptex pixels that live inside the BSP itself."""
        raw = self.lump(LUMP_TEXTURES)
        out: dict[str, ResolvedTexture] = {}
        for mip in self.textures:
            if mip.offsets[0] == 0:
                continue
            start = mip.offsets[0]
            if start + mip.width * mip.height > len(raw):
                continue
            indices = raw[start:start + mip.width * mip.height]
            palette_at = mip.offsets[0]
            for level in range(4):
                if mip.offsets[level]:
                    palette_at = mip.offsets[level] + (mip.width >> level) * (mip.height >> level)
            pal = raw[palette_at:palette_at + 768] if palette_at + 768 <= len(raw) else palette
            if len(pal) < 768:
                continue
            out[mip.name.lower()] = _indexed_to_rgba(mip.name, mip.width, mip.height, indices, pal)
        return out


def _indexed_to_rgba(name: str, width: int, height: int, indices: bytes, palette: bytes) -> ResolvedTexture:
    rgba = bytearray(width * height * 4)
    for i, index in enumerate(indices):
        src = index * 3
        dst = i * 4
        rgba[dst] = palette[src]
        rgba[dst + 1] = palette[src + 1]
        rgba[dst + 2] = palette[src + 2]
        rgba[dst + 3] = 0 if index == 255 else 255
    return ResolvedTexture(name, width, height, bytes(rgba), "bsp", name.startswith("{"))


def _sample_lightmap(baked: bytes, width: int, height: int, u: float, v: float) -> tuple[int, int, int]:
    x = max(0, min(width - 1, int(u + 0.5)))
    y = max(0, min(height - 1, int(v + 0.5)))
    index = (y * width + x) * 3
    if index + 2 >= len(baked):
        return (168, 168, 168)
    return (baked[index], baked[index + 1], baked[index + 2])


def _tokenize(text: str):
    """Split a GoldSrc entity lump into braces and ``key" "value`` tokens."""
    out: list[str] = []
    i = 0
    length = len(text)
    while i < length:
        char = text[i]
        if char in "{}":
            out.append(char)
            i += 1
            continue
        if char == '"':
            end = text.find('"', i + 1)
            if end < 0:
                break
            key = text[i + 1:end]
            i = end + 1
            while i < length and text[i] in " \t\r\n":
                i += 1
            value = ""
            if i < length and text[i] == '"':
                end = text.find('"', i + 1)
                if end < 0:
                    break
                value = text[i + 1:end]
                i = end + 1
            out.append(f"{key}\" \"{value}")
            continue
        i += 1
    return out
