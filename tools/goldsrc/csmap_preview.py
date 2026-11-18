#!/usr/bin/env python3
"""Software-render a `.csmap` to a PNG (no GPU, no Godot needed).

This exists for validation: the headless Godot build has no framebuffer, so the
only way to eyeball a converted map from CI is to rasterise the payload the same
way the engine would — same vertex colours (baked light), same albedo textures,
same camera maths.

    python3 tools/goldsrc/csmap_preview.py --map de_dust2 --out /tmp/dust2.png
    python3 tools/goldsrc/csmap_preview.py --map de_inferno --yaw 30 --pitch -8
"""
from __future__ import annotations

import argparse
import json
import math
import struct
import sys
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[2]


def load_map(path: Path) -> dict:
    """Read a payload into numpy arrays (positions, indices, uv, colours)."""
    with path.open("rb") as handle:
        handle.read(8)
        header_len = struct.unpack("<I", handle.read(4))[0]
        header = json.loads(handle.read(header_len))
        groups = []
        for info in header["groups"]:
            verts, tris, mat = struct.unpack("<iii", handle.read(12))
            pos = np.frombuffer(handle.read(verts * 12), dtype=np.float32).reshape(-1, 3)
            handle.read(verts * 12)  # normals
            uv = np.frombuffer(handle.read(verts * 8), dtype=np.float32).reshape(-1, 2)
            handle.read(verts * 8)   # uv2
            colors = np.frombuffer(handle.read(verts * 3), dtype=np.uint8).reshape(-1, 3)
            idx = np.frombuffer(handle.read(tris * 12), dtype=np.int32).reshape(-1, 3)
            groups.append({"pos": pos, "uv": uv, "colors": colors, "idx": idx, "mat": mat})
    return {"header": header, "groups": groups}


def load_textures(header: dict, map_dir: Path) -> list:
    textures = []
    for entry in header["materials"]:
        path = map_dir / "textures" / Path(str(entry.get("file", ""))).name
        if path.exists():
            textures.append(np.asarray(Image.open(path).convert("RGB"), dtype=np.float32) / 255.0)
        else:
            textures.append(np.full((8, 8, 3), 0.5, dtype=np.float32))
    return textures


def camera_matrix(position, yaw_deg, pitch_deg):
    yaw = math.radians(yaw_deg)
    pitch = math.radians(pitch_deg)
    forward = np.array([-math.sin(yaw) * math.cos(pitch), math.sin(pitch), -math.cos(yaw) * math.cos(pitch)])
    right = np.cross(forward, np.array([0.0, 1.0, 0.0]))
    right /= np.linalg.norm(right)
    up = np.cross(right, forward)
    return forward, right, up


def render(data: dict, textures: list, position, yaw, pitch, width, height, fov=90.0, near=0.05):
    forward, right, up = camera_matrix(position, yaw, pitch)
    focal = (width * 0.5) / math.tan(math.radians(fov) * 0.5)
    color = np.zeros((height, width, 3), dtype=np.float32)
    depth = np.full((height, width), np.inf, dtype=np.float32)
    ys, xs = np.mgrid[0:height, 0:width]
    sky = np.array([0.55, 0.68, 0.86], dtype=np.float32)
    horizon = (pitch * 0.01) * height
    t = np.clip((ys + horizon) / height, 0.0, 1.0)[..., None]
    color[:] = sky * (1.0 - t * 0.45) + np.array([0.78, 0.80, 0.86], dtype=np.float32) * t * 0.45

    stats = {"triangles": 0, "drawn": 0}
    for group in data["groups"]:
        pos = group["pos"].astype(np.float64) - np.asarray(position, dtype=np.float64)
        cam = np.stack([pos @ right, pos @ up, pos @ forward], axis=-1)
        uv = group["uv"]
        colors = group["colors"].astype(np.float32) / 255.0
        texture = textures[group["mat"]] if group["mat"] < len(textures) else np.full((8, 8, 3), 0.5)
        tri = group["idx"]
        stats["triangles"] += len(tri)
        for face in tri:
            pts = cam[face]
            if np.any(pts[:, 2] < near):
                continue
            screen = np.stack([width * 0.5 + focal * pts[:, 0] / pts[:, 2],
                               height * 0.5 - focal * pts[:, 1] / pts[:, 2]], axis=-1)
            x0 = max(int(np.floor(screen[:, 0].min())), 0)
            x1 = min(int(np.ceil(screen[:, 0].max())), width - 1)
            y0 = max(int(np.floor(screen[:, 1].min())), 0)
            y1 = min(int(np.ceil(screen[:, 1].max())), height - 1)
            if x1 < x0 or y1 < y0 or (x1 - x0) * (y1 - y0) > 400_000:
                continue
            px = xs[y0:y1 + 1, x0:x1 + 1] + 0.5
            py = ys[y0:y1 + 1, x0:x1 + 1] + 0.5
            ax, ay = screen[0]
            bx, by = screen[1]
            cx, cy = screen[2]
            area = (bx - ax) * (cy - ay) - (by - ay) * (cx - ax)
            if abs(area) < 1e-9:
                continue
            w0 = ((bx - px) * (cy - py) - (by - py) * (cx - px)) / area
            w1 = ((cx - px) * (ay - py) - (cy - py) * (ax - px)) / area
            w2 = 1.0 - w0 - w1
            inside = (w0 >= 0) & (w1 >= 0) & (w2 >= 0)
            if not inside.any():
                continue
            inv_z = (w0 / pts[0, 2] + w1 / pts[1, 2] + w2 / pts[2, 2])
            z = 1.0 / np.maximum(inv_z, 1e-6)
            better = inside & (z < depth[y0:y1 + 1, x0:x1 + 1])
            if not better.any():
                continue
            u = (w0 * uv[face[0], 0] + w1 * uv[face[1], 0] + w2 * uv[face[2], 0]) * inv_z * z
            v = (w0 * uv[face[0], 1] + w1 * uv[face[1], 1] + w2 * uv[face[2], 1]) * inv_z * z
            th, tw = texture.shape[0], texture.shape[1]
            # perspective-correct UVs; the payload uv is in texels / size
            tx = (np.floor(u * tw).astype(np.int64)) % tw
            ty = (np.floor(v * th).astype(np.int64)) % th
            texel = texture[ty, tx]
            shade = (w0[..., None] * colors[face[0]] + w1[..., None] * colors[face[1]]
                     + w2[..., None] * colors[face[2]])
            # same maths as shaders/world.gdshader (albedo x baked light x boost)
            lit = np.clip(texel * shade * 1.9, 0.0, 1.0)
            target_color = color[y0:y1 + 1, x0:x1 + 1]
            target_depth = depth[y0:y1 + 1, x0:x1 + 1]
            target_color[better] = lit[better]
            target_depth[better] = z[better]
            stats["drawn"] += 1
    return np.clip(color * 255.0, 0, 255).astype(np.uint8), stats


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--map", default="de_dust2")
    parser.add_argument("--maps-dir", type=Path, default=ROOT / "assets" / "maps")
    parser.add_argument("--out", type=Path, default=None)
    parser.add_argument("--width", type=int, default=960)
    parser.add_argument("--height", type=int, default=540)
    parser.add_argument("--yaw", type=float, default=None)
    parser.add_argument("--pitch", type=float, default=-6.0)
    parser.add_argument("--fov", type=float, default=90.0)
    parser.add_argument("--spawn", type=int, default=0, help="index into the map's spawn list")
    parser.add_argument("--eye", type=float, default=1.63, help="eye height in metres")
    args = parser.parse_args()

    map_dir = args.maps_dir / args.map
    payload = map_dir / f"{args.map}.csmap"
    if not payload.exists():
        print(f"missing {payload}", file=sys.stderr)
        return 2
    data = load_map(payload)
    textures = load_textures(data["header"], map_dir)
    spawns = data["header"].get("spawns", [])
    spawn = spawns[args.spawn % len(spawns)] if spawns else {"pos": [0, 0, 0], "yaw": 0}
    position = np.array(spawn["pos"], dtype=np.float64) + np.array([0.0, args.eye, 0.0])
    yaw = args.yaw if args.yaw is not None else float(spawn.get("yaw", 0.0))
    image, stats = render(data, textures, position, yaw, args.pitch, args.width, args.height, args.fov)
    out = args.out or (ROOT / "docs" / f"preview_{args.map}.png")
    out.parent.mkdir(parents=True, exist_ok=True)
    Image.fromarray(image).save(out)
    print(f"{args.map}: {stats['drawn']}/{stats['triangles']} triangles drawn -> {out}")
    print(f"  spawn={position.round(2).tolist()} yaw={yaw:.0f} sky={data['header'].get('sky', {}).get('mood')}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
