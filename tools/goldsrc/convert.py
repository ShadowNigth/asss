"""CS 1.5 (GoldSrc BSP30) -> Godot payload converter.

Output per map, under ``assets/maps/<map>/``:

* ``<map>.csmap``   binary: JSON header + per-material vertex streams,
* ``textures/*.png`` albedo atlases per material,
* ``lightmaps/atlas_*.png`` baked GoldSrc light (kept for reference/decals),
* ``sky.png``       the six skybox faces projected to an equirectangular image.

The header also carries everything gameplay needs: spawns, bomb sites, buy
zones, lights, water pools and the CS2-style atmosphere preset for the sky.
"""
from __future__ import annotations

import json
import math
import struct
from pathlib import Path

import numpy as np

from .bsp import SCALE, Bsp, Entity
from .textures import TextureSet, resolve_textures

MAP_MAGIC = b"CS15MAP\x01"

SKY_SUFFIXES = ("rt", "lf", "ft", "bk", "up", "dn")
SKY_FACES = {
    "rt": "east", "lf": "west", "bk": "south", "ft": "north", "up": "zenith", "dn": "ground",
}
SKY_HORIZON_FACES = ("east", "west", "south", "north")

# (horizon_rgb, zenith_rgb, mood, sun_rgb, sun_energy, fog_density)
# GoldSrc skynames are inconsistent ("tsccity_", "snowlake_", "de_storm"), so
# presets are matched by substring with the longest key winning.
SKY_PRESETS = {
    "des": ((0.86, 0.74, 0.52), (0.29, 0.44, 0.72), "dust", (1.0, 0.88, 0.66), 1.6, 0.10),
    "2desert": ((0.88, 0.77, 0.55), (0.33, 0.46, 0.72), "dust", (1.0, 0.90, 0.72), 1.55, 0.08),
    "desert": ((0.88, 0.77, 0.55), (0.33, 0.46, 0.72), "dust", (1.0, 0.90, 0.72), 1.5, 0.09),
    "badlands": ((0.78, 0.63, 0.42), (0.28, 0.40, 0.62), "dust", (1.0, 0.84, 0.62), 1.35, 0.12),
    "doom1": ((0.74, 0.55, 0.35), (0.28, 0.32, 0.45), "dust", (1.0, 0.82, 0.58), 1.45, 0.14),
    "dusk": ((0.66, 0.52, 0.48), (0.18, 0.2, 0.34), "dusk", (1.0, 0.72, 0.5), 0.85, 0.3),
    "tsccity": ((0.58, 0.62, 0.7), (0.18, 0.24, 0.36), "urban", (0.92, 0.9, 0.95), 0.85, 0.28),
    "city1": ((0.55, 0.62, 0.74), (0.18, 0.26, 0.42), "urban", (0.92, 0.92, 0.97), 0.85, 0.3),
    "backalley": ((0.42, 0.45, 0.5), (0.12, 0.15, 0.22), "urban", (0.8, 0.82, 0.9), 0.6, 0.4),
    "vegas": ((0.42, 0.36, 0.46), (0.08, 0.06, 0.14), "night", (0.7, 0.52, 0.9), 0.45, 0.5),
    "trainyard": ((0.48, 0.52, 0.58), (0.16, 0.2, 0.28), "overcast", (0.76, 0.8, 0.88), 0.7, 0.45),
    "de_storm": ((0.3, 0.34, 0.4), (0.05, 0.07, 0.13), "storm", (0.66, 0.72, 0.88), 0.45, 0.7),
    "tornsky": ((0.55, 0.52, 0.55), (0.13, 0.15, 0.22), "storm", (0.78, 0.8, 0.9), 0.55, 0.55),
    "snowlake": ((0.86, 0.91, 0.96), (0.36, 0.52, 0.76), "snow", (1.0, 0.98, 0.95), 1.15, 0.28),
    "snow": ((0.82, 0.87, 0.93), (0.34, 0.48, 0.72), "snow", (1.0, 0.98, 0.96), 1.1, 0.26),
    "cx": ((0.62, 0.66, 0.7), (0.2, 0.27, 0.4), "cloudy", (0.9, 0.9, 0.92), 0.8, 0.3),
    "forest": ((0.31, 0.43, 0.31), (0.06, 0.12, 0.15), "forest", (0.84, 0.9, 0.72), 0.6, 0.55),
    "drkg": ((0.07, 0.08, 0.13), (0.01, 0.02, 0.05), "night", (0.40, 0.50, 0.75), 0.35, 0.6),
}

WEATHER_BY_SKY = {
    "des": "clear", "2desert": "clear", "desert": "clear", "badlands": "clear", "doom1": "clear",
    "vegas": "drizzle", "drkg": "night", "dusk": "clear", "cx": "clear", "city1": "clear",
    "tsccity": "clear", "forest": "clear", "backalley": "drizzle",
    "trainyard": "drizzle", "de_storm": "rain", "tornsky": "rain",
    "snowlake": "snow", "snow": "snow",
}


# ---------------------------------------------------------------- entities
def _vec3(entity: Entity, key: str) -> list[float]:
    return list(entity.vec(key))


def _bounds_gap(a: dict, b: dict) -> float:
    gap = -1e9
    for axis in range(3):
        gap = max(gap, b["min"][axis] - a["max"][axis], a["min"][axis] - b["max"][axis])
    return gap


def _union_bounds(a: dict, b: dict) -> dict:
    return {
        "min": [min(a["min"][i], b["min"][i]) for i in range(3)],
        "max": [max(a["max"][i], b["max"][i]) for i in range(3)],
    }


def _brush_bounds(entity: Entity) -> dict | None:
    if entity.model_bounds is None:
        return None
    mins, maxs = entity.model_bounds
    # GoldSrc (x east, y north, z up) -> Godot (x east, y up, z south)
    return {
        "min": [mins[0] * SCALE, mins[2] * SCALE, -maxs[1] * SCALE],
        "max": [maxs[0] * SCALE, maxs[2] * SCALE, -mins[1] * SCALE],
    }


def _cluster_boxes(boxes: list[dict], tolerance: float) -> list[list[dict]]:
    clusters: list[list[dict]] = []
    for box in boxes:
        for cluster in clusters:
            if any(_bounds_gap(box, other) <= tolerance for other in cluster):
                cluster.append(box)
                break
        else:
            clusters.append([box])
    merged = True
    while merged:
        merged = False
        for i in range(len(clusters)):
            for j in range(i + 1, len(clusters)):
                if any(_bounds_gap(a, b) <= tolerance for a in clusters[i] for b in clusters[j]):
                    clusters[i].extend(clusters[j])
                    del clusters[j]
                    merged = True
                    break
            if merged:
                break
    return clusters


def merge_bomb_sites(sites: list[dict], tolerance: float = 2.0) -> list[dict]:
    """de_prodigy/de_torn split one site over several func_bomb_target brushes.

    Cluster brushes that touch, then label the clusters A, B, C...
    """
    clusters = _cluster_boxes([s["bounds"] for s in sites], tolerance)
    out: list[dict] = []
    for index, cluster in enumerate(clusters):
        bounds = cluster[0]
        for box in cluster[1:]:
            bounds = _union_bounds(bounds, box)
        centre = [(bounds["min"][i] + bounds["max"][i]) * 0.5 for i in range(3)]
        name = ""
        for site in sites:
            if any(site["bounds"] is box for box in cluster) and site.get("name"):
                name = site["name"]
                break
        if not name:
            name = chr(ord("A") + index) if index < 26 else f"site{index + 1}"
        out.append({"name": name, "bounds": bounds, "pos": [round(c, 4) for c in centre]})
    out.sort(key=lambda s: s["name"])
    return out


def water_volumes(water_faces: list[tuple[list[float], list[int]]], tolerance: float = 0.35) -> list[dict]:
    """Cluster water faces into pools (AABB + surface level) for swimming."""
    boxes = []
    for points, _indices in water_faces:
        n = len(points) // 3
        if n < 3:
            continue
        xs = [points[i * 3] for i in range(n)]
        ys = [points[i * 3 + 1] for i in range(n)]
        zs = [points[i * 3 + 2] for i in range(n)]
        boxes.append({"min": [min(xs), min(ys), min(zs)], "max": [max(xs), max(ys), max(zs)]})
    out = []
    for cluster in _cluster_boxes(boxes, tolerance):
        box = cluster[0]
        for other in cluster[1:]:
            box = _union_bounds(box, other)
        if box["max"][1] - box["min"][1] < 0.5:
            box = {"min": [box["min"][0], box["max"][1] - 0.5, box["min"][2]], "max": list(box["max"])}
        out.append({
            "min": [round(v, 3) for v in box["min"]],
            "max": [round(v, 3) for v in box["max"]],
            "level": round(box["max"][1], 3),
        })
    out.sort(key=lambda b: -((b["max"][0] - b["min"][0]) * (b["max"][2] - b["min"][2])))
    return out


def extract_entities(bsp: Bsp) -> dict:
    spawns: list[dict] = []
    bomb_sites: list[dict] = []
    buy_zones: list[dict] = []
    rescue_zones: list[dict] = []
    lights: list[dict] = []
    doors: list[dict] = []
    breakables: list[dict] = []
    triggers: list[dict] = []
    camera = None
    light_environment = None
    for entity in bsp.entities:
        cls = entity.classname
        raw_origin = _vec3(entity, "origin")
        origin = [raw_origin[0] * SCALE, raw_origin[2] * SCALE, -raw_origin[1] * SCALE]
        yaw = entity.number("angle", 0.0)
        if cls in ("info_player_start", "info_player_deathmatch", "info_player_terrorist"):
            spawns.append({"pos": origin, "yaw": yaw, "team": "t" if cls.endswith("terrorist") else "any"})
        elif cls == "info_player_counterterrorist":
            spawns.append({"pos": origin, "yaw": yaw, "team": "ct"})
        elif cls in ("func_bomb_target", "info_bomb_target"):
            bounds = _brush_bounds(entity)
            if bounds:
                bomb_sites.append({"name": entity.get("targetname", ""), "bounds": bounds, "pos": origin})
        elif cls == "func_buyzone":
            buy_zones.append({"team": "ct" if entity.number("team", 0) == 1 else "t", "bounds": _brush_bounds(entity)})
        elif cls in ("func_hostage_rescue", "info_hostage_rescue"):
            rescue_zones.append({"bounds": _brush_bounds(entity)})
        elif cls == "light":
            raw = entity.get("_light", "255 255 255 200").split()
            try:
                color = [min(1.0, float(raw[i]) / 255.0) for i in range(3)]
                brightness = float(raw[3]) if len(raw) > 3 else 200.0
            except (ValueError, IndexError):
                color, brightness = [1.0, 1.0, 1.0], 200.0
            radius = max(2.0, brightness / 60.0)
            lights.append({
                "pos": origin,
                "color": color,
                "energy": min(12.0, brightness / 40.0),
                "range": min(40.0, radius * 3.0),
                "flicker": "style" in entity.properties and "+0~" in entity.get("style", ""),
            })
        elif cls == "light_environment":
            light_environment = {"origin": origin, "raw": entity.get("_light", "")}
        elif cls in ("func_door", "func_door_rotating"):
            bounds = _brush_bounds(entity)
            if bounds:
                doors.append({"name": entity.get("targetname", ""), "bounds": bounds,
                              "speed": entity.number("speed", 100.0), "wait": entity.number("wait", 3.0)})
        elif cls == "func_breakable":
            bounds = _brush_bounds(entity)
            if bounds:
                breakables.append({"name": entity.get("targetname", ""), "bounds": bounds,
                                   "health": entity.number("health", 1.0)})
        elif cls.startswith("trigger_"):
            bounds = _brush_bounds(entity)
            if bounds:
                triggers.append({"cls": cls, "name": entity.get("targetname", ""), "bounds": bounds,
                                 "target": entity.get("target", "")})
        elif cls == "trigger_camera" and camera is None:
            camera = {"pos": origin, "yaw": yaw}
    return {
        "spawns": spawns,
        "bomb_sites": merge_bomb_sites(bomb_sites),
        "buy_zones": buy_zones,
        "rescue_zones": rescue_zones,
        "lights": lights,
        "doors": doors,
        "breakables": breakables,
        "triggers": triggers,
        "camera": camera,
        # kept out of the "sky" key, which holds the atmosphere settings
        "light_environment": light_environment,
    }


# ---------------------------------------------------------------- sky params
def load_skybox(env_dir: Path | None, skyname: str) -> dict[str, np.ndarray] | None:
    """Load the six retail skybox faces named ``<skyname><suffix>`` from gfx/env.

    ``env_dir`` may be a single directory or a list of them searched in order,
    so a Half-Life ``valve/gfx/env`` can supply skies that the CS 1.5 download
    does not ship (``dusk`` on cbble/prodigy lives in Half-Life's pak).
    """
    if isinstance(env_dir, (list, tuple)):
        for candidate in env_dir:
            faces = load_skybox(candidate, skyname)
            if faces:
                return faces
        return None
    if env_dir is None or not Path(env_dir).is_dir() or not skyname:
        return None
    wanted = skyname.lower().lstrip("2")
    available: dict[str, dict[str, Path]] = {}
    for path in Path(env_dir).iterdir():
        if path.suffix.lower() not in (".tga", ".bmp", ".pcx"):
            continue
        stem = path.stem.lower()
        for suffix in SKY_SUFFIXES:
            if stem.endswith(suffix) and len(stem) > len(suffix):
                available.setdefault(stem[: -len(suffix)], {}).setdefault(suffix, path)
                break
    group = available.get(wanted)
    if group is None:
        for length in range(len(wanted) - 1, 2, -1):
            if wanted[:length] in available:
                group = available[wanted[:length]]
                break
    if group is None:
        return None
    from PIL import Image

    faces: dict[str, np.ndarray] = {}
    for suffix, path in group.items():
        if path.stat().st_size < 4096:
            continue
        try:
            image = Image.open(path).convert("RGB")
        except Exception:  # noqa: BLE001 - a broken face must not abort the map
            continue
        if image.size != (256, 256):
            image = image.resize((256, 256), Image.BILINEAR)
        faces[suffix] = np.asarray(image, dtype=np.uint8)
    if not faces:
        return None
    for suffix in SKY_SUFFIXES:  # mirror partial skyboxes across the missing sides
        if suffix not in faces:
            faces[suffix] = faces[sorted(faces)[0]]
    return faces


def skybox_stats(faces: dict[str, np.ndarray]) -> dict:
    horizon_parts = [faces[s] for s in ("rt", "lf", "ft", "bk") if s in faces]
    horizon = np.concatenate([f.reshape(-1, 3) for f in horizon_parts]).mean(axis=0) / 255.0 if horizon_parts else None
    zenith = faces["up"].reshape(-1, 3).mean(axis=0) / 255.0 if "up" in faces else None
    ground = faces["dn"].reshape(-1, 3).mean(axis=0) / 255.0 if "dn" in faces else None
    if horizon is None and zenith is None:
        return {}
    if horizon is None:
        horizon = zenith * 0.85
    if zenith is None:
        zenith = horizon * 0.65
    return {
        "horizon": [round(float(c), 4) for c in horizon],
        "zenith": [round(float(c), 4) for c in zenith],
        "ground": [round(float(c), 4) for c in (ground if ground is not None else horizon * 0.5)],
    }


def panorama(faces: dict[str, np.ndarray], width: int = 1536, height: int = 768,
             blend: float = 0.3) -> np.ndarray:
    """Project the six GoldSrc skybox faces onto an equirectangular image.

    The output follows the usual panorama convention (``u = atan2(n.x, -n.z)``,
    ``v = acos(n.y) / pi`` in *Godot* space).  GoldSrc is Z-up, so the sampled
    direction is converted back to GoldSrc (x east, y north, z up) to pick a
    face: rt=+X, lf=-X, ft=+Y, bk=-Y, up=+Z, dn=-Z.  Side faces are seen from
    inside, so ``u`` grows to the viewer's right and ``v`` runs downwards.

    Two problems have to be handled that a naive cube->equirect conversion
    leaves visible:

    * **Seams.**  The retail faces were hand-drawn and do not match exactly at
      their borders (mean edge mismatch ~35/255).  Pixels near a face border
      are cross-faded with the neighbour (``blend`` is the distance in unit
      cube space over which the fade happens).
    * **Aliasing.**  Near the poles and near the horizon a single sky texel
      covers a huge part of the panorama, so point sampling turns clouds into
      radial streaks.  Each face is mip-mapped and the level is chosen per
      pixel from the local magnification.
    """
    height_of = height
    u = (np.arange(width, dtype=np.float32) + 0.5) / width
    v = (np.arange(height_of, dtype=np.float32) + 0.5) / height_of
    phi = u * (2.0 * np.pi)
    theta = v * np.pi
    sin_theta = np.sin(theta)[:, None]
    gx = np.broadcast_to(np.sin(phi)[None, :] * sin_theta, (height_of, width))
    gz = np.broadcast_to(-np.cos(phi)[None, :] * sin_theta, (height_of, width))
    gy = np.broadcast_to(np.cos(theta)[:, None] * np.ones((1, width), dtype=np.float32), (height_of, width))
    # Godot -> GoldSrc: x stays, north = -Z, up = Y
    dx, dy, dz = gx, -gz, gy

    # face -> (component along the face's u axis, component along its v axis)
    face_uv = {
        "rt": (-dy, -dz), "lf": (dy, -dz),
        "ft": (dx, -dz), "bk": (-dx, -dz),
        "up": (-dx, -dy), "dn": (dx, -dy),
    }
    face_axis = {
        "rt": (dx, 1.0), "lf": (dx, -1.0),
        "ft": (dy, 1.0), "bk": (dy, -1.0),
        "up": (dz, 1.0), "dn": (dz, -1.0),
    }
    acc = np.zeros((height_of, width, 3), dtype=np.float32)
    weight_sum = np.zeros((height_of, width, 1), dtype=np.float32)
    for suffix in SKY_SUFFIXES:
        if suffix not in faces:
            continue
        axis_values, sign = face_axis[suffix]
        scaled = axis_values * sign
        # 0 on the face border (a neighbouring face dominates) and 1 once the
        # sample is well inside the face; the tiny floor keeps the corners,
        # where all six faces meet, numerically stable.
        weight = np.clip(scaled / blend, 0.0, 1.0)
        weight = weight * weight * (3.0 - 2.0 * weight)
        if suffix in ("up", "dn"):
            # A cube's top/bottom face becomes infinitely magnified towards the
            # horizon (it was only ever visible when looking well up/down), so
            # it is faded out before it reaches the horizon; the four side faces
            # carry the horizon band on their own.
            elevation = gy if suffix == "up" else -gy
            # the up/down faces are only meaningful past the cube corner
            # (elevation 0.577), so the crossover sits right on it
            gate = np.clip((elevation - 0.46) / 0.13, 0.0, 1.0)
            weight = weight * (gate * gate * (3.0 - 2.0 * gate))
        else:
            # Side faces are degenerate at the poles, where their texture
            # coordinate diverges; hand the top/bottom band over to the up/down
            # face so no face is sampled far outside its valid cube region.
            elevation = np.abs(gy)
            fade = np.clip((elevation - 0.46) / 0.13, 0.0, 1.0)
            fade = fade * fade * (3.0 - 2.0 * fade)
            weight = weight * (1.0 - fade)
        weight = np.maximum(weight, 1e-4)
        mask = weight > 9e-5
        if not mask.any():
            continue
        comp_u, comp_v = face_uv[suffix]
        denom = np.maximum(np.abs(scaled), 1e-6)
        face = faces[suffix]
        px = (comp_u / denom * 0.5 + 0.5) * (face.shape[1] - 1)
        py = (comp_v / denom * 0.5 + 0.5) * (face.shape[0] - 1)
        sample = _sample_mipped(face, px, py)
        acc += sample * weight[..., None]
        weight_sum += weight[..., None]
    weight_sum[weight_sum < 1e-6] = 1.0
    image = acc / weight_sum
    return np.clip(image + 0.5, 0, 255).astype(np.uint8)


_MIP_CACHE: dict[int, list[np.ndarray]] = {}


def _mips(face: np.ndarray) -> list[np.ndarray]:
    """Box-filtered mip chain (kept per array identity for a whole build)."""
    key = id(face)
    chain = _MIP_CACHE.get(key)
    if chain is not None and chain[0] is face:
        return chain
    chain = [face]
    current = face.astype(np.float32)
    while current.shape[0] > 16 and current.shape[1] > 16:
        h, w = current.shape[0] // 2, current.shape[1] // 2
        current = (current[0:2 * h:2, 0:2 * w:2] + current[1:2 * h:2, 0:2 * w:2]
                   + current[0:2 * h:2, 1:2 * w:2] + current[1:2 * h:2, 1:2 * w:2]) * 0.25
        chain.append(current)
    _MIP_CACHE[key] = chain
    return chain


def _sample_bilinear(face: np.ndarray, px: np.ndarray, py: np.ndarray) -> np.ndarray:
    height, width = face.shape[0], face.shape[1]
    px = np.clip(px, 0.0, width - 1.0)
    py = np.clip(py, 0.0, height - 1.0)
    x0 = np.floor(px).astype(np.int32)
    y0 = np.floor(py).astype(np.int32)
    x1 = np.minimum(x0 + 1, width - 1)
    y1 = np.minimum(y0 + 1, height - 1)
    fx = (px - x0)[..., None]
    fy = (py - y0)[..., None]
    source = face.astype(np.float32, copy=False)
    top = source[y0, x0] * (1.0 - fx) + source[y0, x1] * fx
    bottom = source[y1, x0] * (1.0 - fx) + source[y1, x1] * fx
    return top * (1.0 - fy) + bottom * fy


def _sample_mipped(face: np.ndarray, px: np.ndarray, py: np.ndarray) -> np.ndarray:
    """Bilinear sample with a per-pixel mip level driven by the local footprint."""
    chain = _mips(face)
    gx_px = np.abs(np.gradient(px, axis=1))
    gy_px = np.abs(np.gradient(px, axis=0))
    gx_py = np.abs(np.gradient(py, axis=1))
    gy_py = np.abs(np.gradient(py, axis=0))
    footprint = np.maximum(np.maximum(gx_px, gy_px), np.maximum(gx_py, gy_py))
    level = np.clip(np.log2(np.maximum(footprint, 1.0)), 0.0, len(chain) - 1)
    out = np.zeros(px.shape + (3,), dtype=np.float32)
    for index in range(len(chain)):
        near = index == 0
        far = index == len(chain) - 1
        mask = (level >= index - 0.5) & (level < index + 0.5) if not far else (level >= index - 0.5)
        if not mask.any():
            continue
        scale = 2 ** index
        out[mask] = _sample_bilinear(chain[index], px[mask] / scale, py[mask] / scale)
    return out


def average_sky_color(bsp: Bsp, textures: TextureSet) -> list[float] | None:
    """Average colour of embedded sky textures when a map ships its own skybox."""
    for key, resolved in textures.textures.items():
        if not key.startswith("sky"):
            continue
        arr = np.frombuffer(resolved.rgba, dtype=np.uint8).reshape(-1, 4)[:, :3]
        if arr.size == 0:
            continue
        mean = arr.mean(axis=0) / 255.0
        if float(mean.max()) < 0.08:
            continue
        return [float(c) for c in mean]
    return None


def sky_settings(skyname: str, light_env: Entity | None, sun_from_tex: list[float] | None,
                 sampled: dict | None = None) -> dict:
    key = (skyname or "des").lower()
    preset = None
    preset_key = "des"
    for name in sorted(SKY_PRESETS, key=len, reverse=True):
        if key.startswith(name) or name in key:
            preset, preset_key = SKY_PRESETS[name], name
            break
    if preset is None:
        preset = SKY_PRESETS["des"]
    horizon, zenith, mood, sun_color, sun_energy, fog = preset
    direction = [0.35, -0.85, 0.4]
    if light_env is not None:
        # light_environment carries "pitch"/"angle"; only fall back to "angles"
        # when pitch is missing (several maps leave "angles" at 0 0 0).
        pitch = light_env.number("pitch", -60.0)
        yaw = light_env.number("angle", 0.0)
        if "angles" in light_env.properties and "pitch" not in light_env.properties:
            parts = light_env.properties["angles"].split()
            if len(parts) >= 2:
                pitch, yaw = float(parts[0]), float(parts[1])
        p, y = math.radians(pitch), math.radians(yaw)
        direction = [math.cos(p) * math.cos(y), math.sin(p), -math.cos(p) * math.sin(y)]
        raw = light_env.get("_light", "").split()
        if len(raw) >= 4:
            try:
                color = [min(1.0, float(raw[i]) / 255.0) for i in range(3)]
                brightness = float(raw[3])
                if brightness > 20.0:
                    sun_color = color
                    sun_energy = max(0.2, min(3.2, brightness / 80.0))
            except ValueError:
                pass
    if sun_from_tex and light_env is None:
        sun_color = [min(1.0, c * 1.1) for c in sun_from_tex]
    if sampled:
        horizon = sampled["horizon"]
        zenith = sampled["zenith"]
        mean = sum(horizon) / 3.0
        if mean < 0.35:  # very dark skyboxes stay readable
            horizon = [min(1.0, c + (0.35 - mean) * 0.8) for c in horizon]
            zenith = [min(1.0, c + (0.35 - mean) * 0.5) for c in zenith]
    return {
        "skyname": key,
        "mood": mood,
        "horizon": [round(c, 4) for c in horizon],
        "zenith": [round(c, 4) for c in zenith],
        "sun_direction": [round(c, 4) for c in direction],
        "sun_color": [round(c, 4) for c in sun_color],
        "sun_energy": round(sun_energy, 3),
        "fog_density": round(fog, 3),
        "weather": WEATHER_BY_SKY.get(preset_key, "clear"),
        "wind": round(0.35 + fog * 1.6, 3),
    }


# ---------------------------------------------------------------- atlas / png
class AtlasPacker:
    def __init__(self, size: int = 1024) -> None:
        self.size = size
        self.image = np.zeros((size, size, 4), dtype=np.uint8)
        self.x = 0
        self.y = 0
        self.row_height = 0

    def add(self, width: int, height: int, rgba: np.ndarray):
        if width > self.size or height > self.size:
            return None
        if self.x + width > self.size:
            self.x = 0
            self.y += self.row_height + 2
            self.row_height = 0
        if self.y + height > self.size:
            return None
        self.image[self.y:self.y + height, self.x:self.x + width] = rgba
        coords = (self.x, self.y)
        self.x += width + 2
        self.row_height = max(self.row_height, height)
        return coords

    def png(self) -> bytes:
        from PIL import Image

        return _png(Image.fromarray(self.image, "RGBA"))


def _png(image) -> bytes:
    """Encode a PNG, palette-indexing fully opaque images.

    GoldSrc textures are 8-bit palettised to begin with, so quantising back to
    a 256-colour palette is lossless in practice (and ~3x smaller on disk);
    masked ``{`` textures keep their alpha channel as RGBA.
    """
    import io

    buffer = io.BytesIO()
    if image.mode == "RGBA" and _is_opaque(image):
        image = image.convert("RGB").convert("P", palette=0, colors=255)
    image.save(buffer, format="PNG", optimize=True, compress_level=9)
    return buffer.getvalue()


def _is_opaque(image) -> bool:
    alpha = image.getchannel("A")
    return alpha.getextrema() == (255, 255)


# ---------------------------------------------------------------- writer
def write_map(bsp_path: Path, wad_paths: list[Path], palette: bytes, out_root: Path,
              log=print, env_dir=None) -> dict:
    slug = bsp_path.stem.lower()
    bsp = Bsp(bsp_path)
    bsp.resolve_model_bounds()
    textures = resolve_textures(bsp, wad_paths, palette, log=log)
    surfaces = bsp.build_surfaces(SCALE)

    map_dir = out_root / "assets" / "maps" / slug
    tex_dir = map_dir / "textures"
    lm_dir = map_dir / "lightmaps"
    tex_dir.mkdir(parents=True, exist_ok=True)
    lm_dir.mkdir(parents=True, exist_ok=True)

    # -- materials: one atlas per BSP miptex, deduplicated by texture name
    materials: list[dict] = []
    material_index: dict[str, int] = {}
    emissive: list[int] = []
    for group in surfaces:
        miptex = group["mat"]
        if isinstance(miptex, str):
            name = miptex
        elif 0 <= miptex < len(bsp.textures):
            name = bsp.textures[miptex].name
        else:
            name = f"tex_{miptex}"
        key = name.lower()
        if key in material_index:
            group["mat"] = material_index[key]
            continue
        resolved = textures.get(name)
        entry = {"name": name, "family": "concrete", "emissive": False, "transparent": False, "file": ""}
        if resolved is not None:
            entry["family"] = resolved.family
            entry["transparent"] = resolved.transparent or any(
                token in key for token in ("glass", "grate", "fence", "ladder"))
            entry["emissive"] = any(token in key for token in ("light", "lamp", "neon", "glow", "+0~", "+a~"))
            array = np.frombuffer(resolved.rgba, dtype=np.uint8).reshape(resolved.height, resolved.width, 4)
            if entry["emissive"]:
                emissive.append(len(materials))
            file_name = f"tex_{len(materials):03d}.png"
            (tex_dir / file_name).write_bytes(_png(_image_from_array(array)))
            entry["file"] = f"res://assets/maps/{slug}/textures/{file_name}"
        material_index[key] = len(materials)
        materials.append(entry)
        group["mat"] = len(materials) - 1

    # -- baked light: packed per-face lightmaps into shared atlases
    atlases: list[AtlasPacker] = [AtlasPacker()]
    for face in bsp.faces[: bsp.models[0]["num_faces"]]:
        baked = bsp.lightmap_bytes(face)
        if baked is None:
            continue
        extents, data = baked
        width, height = extents["width"], extents["height"]
        array = np.frombuffer(data, dtype=np.uint8).reshape(height, width, 3)
        rgba = np.zeros((height, width, 4), dtype=np.uint8)
        rgba[:, :, :3] = array
        rgba[:, :, 3] = 255
        packer = atlases[-1]
        if packer.add(width, height, rgba) is None:
            packer = AtlasPacker()
            atlases.append(packer)
            if packer.add(width, height, rgba) is None:
                continue
    for index, packer in enumerate(atlases):
        (lm_dir / f"atlas_{index}.png").write_bytes(packer.png())

    # -- entity / env data
    ent = extract_entities(bsp)
    worldspawn = next((e for e in bsp.entities if e.classname == "worldspawn"), Entity({}))
    skyname = worldspawn.get("skyname", "des")
    faces = load_skybox(env_dir, skyname)
    sampled = skybox_stats(faces) if faces else None
    sky = sky_settings(skyname, next((e for e in bsp.entities if e.classname == "light_environment"), None),
                       average_sky_color(bsp, textures), sampled)
    sky_panorama = 0
    if faces is not None:
        from PIL import Image

        pano_path = map_dir / "sky.png"
        Image.fromarray(panorama(faces)).save(pano_path, optimize=True, compress_level=9)
        sky["panorama"] = f"res://assets/maps/{slug}/sky.png"
        sky_panorama = pano_path.stat().st_size

    water_faces = bsp.water_surfaces()
    pools = water_volumes(water_faces)
    bounds = bsp.world_bounds()
    header = {
        "format": 1,
        "map": slug,
        "scale": SCALE,
        "bounds": {
            "min": [bounds[0][0] * SCALE, bounds[0][2] * SCALE, -bounds[1][1] * SCALE],
            "max": [bounds[1][0] * SCALE, bounds[1][2] * SCALE, -bounds[0][1] * SCALE],
        },
        "sky": sky,
        "materials": materials,
        "emissive": emissive,
        "groups": [
            {"mat": g["mat"], "flags": g["flags"], "verts": g["verts"], "tris": g["tris"]}
            for g in surfaces
        ],
        "lightmap_atlases": [f"res://assets/maps/{slug}/lightmaps/atlas_{i}.png" for i in range(len(atlases))],
        "water": [{"points": len(points) // 3, "indices": len(indices)} for points, indices in water_faces],
        "water_volumes": pools,
        "stats": {"groups": len(surfaces), "triangles": int(sum(g["tris"] for g in surfaces))},
        **ent,
    }

    # -- binary payload
    blob = bytearray()
    blob.extend(MAP_MAGIC)
    header_bytes = json.dumps(header, separators=(",", ":")).encode("utf-8")
    blob.extend(struct.pack("<I", len(header_bytes)))
    blob.extend(header_bytes)
    for group in surfaces:
        positions = np.asarray(group["positions"], dtype=np.float32)
        normals = np.asarray(group["normals"], dtype=np.float32)
        uv = np.asarray(group["uv"], dtype=np.float32)
        uv2 = np.asarray(group["uv2"], dtype=np.float32)
        colors = np.asarray(group["colors"], dtype=np.uint8)
        indices = np.asarray(group["indices"], dtype=np.int32)
        blob.extend(struct.pack("<iii", group["verts"], group["tris"], int(group["mat"])))
        blob.extend(positions.tobytes())
        blob.extend(normals.tobytes())
        blob.extend(uv.tobytes())
        blob.extend(uv2.tobytes())
        blob.extend(colors.tobytes())
        blob.extend(indices.tobytes())
    for points, indices in water_faces:
        arr = np.asarray(points, dtype=np.float32)
        idx = np.asarray(indices, dtype=np.int32)
        blob.extend(struct.pack("<ii", len(arr) // 3, len(idx) // 3))
        blob.extend(arr.tobytes())
        blob.extend(idx.tobytes())
    (map_dir / f"{slug}.csmap").write_bytes(bytes(blob))

    return {
        "map": slug,
        "bytes": len(blob),
        "groups": len(surfaces),
        "triangles": header["stats"]["triangles"],
        "textures": len(materials),
        "fallback_textures": len(textures.fallbacks),
        "spawns": len(ent["spawns"]),
        "bomb_sites": len(ent["bomb_sites"]),
        "buy_zones": len(ent["buy_zones"]),
        "lights": len(ent["lights"]),
        "water_pools": len(pools),
        "sky": sky["skyname"],
        "weather": sky["weather"],
        "skybox": sky.get("panorama", ""),
        "skybox_bytes": sky_panorama,
    }


def _image_from_array(array: np.ndarray):
    from PIL import Image

    return Image.fromarray(array, "RGBA")
