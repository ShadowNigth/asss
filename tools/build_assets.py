#!/usr/bin/env python3
"""Convert the CS 1.5 (GoldSrc BSP30) maps into Godot-ready payloads.

Pipeline
--------
1. ``--fetch`` clones the CS 1.5 retail branch of Ch0wW/counterstrike-betas
   with a sparse git checkout (maps + WADs + skyboxes only).
2. Every ``de_*`` map (bombsites) is parsed: geometry, lightmaps, entities.
3. Textures come from the BSP itself, then from the retail WADs, then from a
   procedural fallback chosen by texture-name family (reported in the log).
4. The original six-face skyboxes from ``gfx/env`` are projected into an
   equirectangular panorama (``sky.png``) so each map keeps its own sky.
5. Output lands in ``assets/maps/<map>/`` as ``.csmap`` + ``textures/*.png`` +
   ``lightmaps/atlas_*.png`` + ``sky.png``; the Godot runtime streams them.

Examples
--------
    python3 tools/build_assets.py --fetch
    python3 tools/build_assets.py --cstrike /path/to/cstrike --out .
    python3 tools/build_assets.py --out . --maps de_dust2,de_inferno
    python3 tools/build_assets.py --report
"""
from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))

from goldsrc.convert import write_map  # noqa: E402
from goldsrc.wad import load_palette  # noqa: E402

CS15_REPO = "https://github.com/Ch0wW/counterstrike-betas.git"
CS15_BRANCH = "cs15_retail"
CACHE = ROOT / ".cache" / "cs15"
DEFAULT_MAPS = [
    "de_dust2", "de_dust", "de_inferno", "de_nuke", "de_train",
    "de_cbble", "de_aztec", "de_prodigy", "de_vertigo",
    "de_piranesi", "de_chateau", "de_storm", "de_survivor",
    "de_torn", "de_vegas",
]


def fetch(sparse: bool = True) -> Path:
    """Sparse clone of the CS 1.5 retail branch (maps + WADs + gfx/env)."""
    CACHE.mkdir(parents=True, exist_ok=True)
    repo = CACHE / "repo"
    if not (repo / ".git").exists():
        subprocess.run(
            ["git", "clone", "--filter=blob:none", "--sparse", "--depth", "1",
             "--branch", CS15_BRANCH, CS15_REPO, str(repo)],
            check=True,
        )
        subprocess.run(["git", "-C", str(repo), "config", "gc.auto", "0"], check=False)
    subprocess.run(
        ["git", "-C", str(repo), "sparse-checkout", "set", "cstrike/maps", "cstrike/gfx", "cstrike"],
        check=True,
    )
    return repo / "cstrike"


def wad_files(cstrike: Path) -> list[Path]:
    return sorted(list(cstrike.glob("*.wad")) + list(cstrike.glob("*.WAD")))


def report(out_root: Path) -> int:
    """Summarize what has been converted so far."""
    rows = []
    for map_dir in sorted((out_root / "assets" / "maps").glob("*")):
        payload = map_dir / f"{map_dir.name}.csmap"
        if not payload.exists():
            continue
        with payload.open("rb") as handle:
            head = handle.read(12)
            length = int.from_bytes(head[8:12], "little")
            header = json.loads(handle.read(length))
        rows.append({
            "map": map_dir.name,
            "tris": header.get("stats", {}).get("triangles", 0),
            "materials": len(header.get("materials", [])),
            "sites": len(header.get("bomb_sites", [])),
            "spawns": len(header.get("spawns", [])),
            "lights": len(header.get("lights", [])),
            "water": len(header.get("water_volumes", [])),
            "sky": header.get("sky", {}).get("skyname", "?"),
            "weather": header.get("sky", {}).get("weather", "?"),
            "kib": payload.stat().st_size // 1024,
        })
    if not rows:
        print("nothing converted yet")
        return 1
    print(f"{'map':14} {'tris':>7} {'mats':>5} {'sites':>5} {'spawns':>6} {'lights':>6} "
          f"{'water':>5} {'kib':>7}  sky/weather")
    for row in rows:
        print(f"{row['map']:14} {row['tris']:7} {row['materials']:5} {row['sites']:5} "
              f"{row['spawns']:6} {row['lights']:6} {row['water']:5} {row['kib']:7}  "
              f"{row['sky']}/{row['weather']}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--fetch", action="store_true", help="sparse-clone the CS 1.5 retail branch")
    parser.add_argument("--cstrike", type=Path, help="existing cstrike/ directory to read maps and WADs from")
    parser.add_argument("--wads", type=Path, nargs="*", default=[],
                        help="extra WAD directories (e.g. valve/ with halflife.wad)")
    parser.add_argument("--out", type=Path, default=ROOT, help="project root that receives assets/maps")
    parser.add_argument("--maps", default="", help="comma separated map list (default: every de_* bombsite map)")
    parser.add_argument("--all", action="store_true", help="convert every de_* map found")
    parser.add_argument("--report", action="store_true", help="only print the conversion report")
    parser.add_argument("--palette", type=Path, default=ROOT / "assets" / "goldsrc" / "palette.lmp")
    args = parser.parse_args()

    if args.report:
        return report(args.out)

    cstrike = args.cstrike
    if args.fetch and cstrike is None:
        cstrike = fetch()
    if cstrike is None:
        cached = CACHE / "repo" / "cstrike"
        if cached.exists():
            cstrike = cached
        else:
            print("no --cstrike given and no cached checkout; run with --fetch", file=sys.stderr)
            return 2
    cstrike = Path(cstrike)
    if not (cstrike / "maps").is_dir():
        print(f"{cstrike} does not look like a cstrike/ directory", file=sys.stderr)
        return 2

    palette_path = args.palette if args.palette.exists() else None
    palette = load_palette(palette_path) if palette_path else b""
    if palette_path is None:
        print("warning: palette.lmp missing, embedded miptex will use a grey palette", file=sys.stderr)

    if args.maps:
        wanted = [name.strip().lower() for name in args.maps.split(",") if name.strip()]
    else:
        wanted = sorted(path.stem.lower() for path in (cstrike / "maps").glob("de_*.bsp"))
        if not args.all:
            wanted = [name for name in DEFAULT_MAPS if name in wanted] or wanted

    wads = wad_files(cstrike)
    for extra in args.wads or []:
        wads.extend(p for p in wad_files(Path(extra)) if p not in wads)
    env_dir = cstrike / "gfx" / "env"
    results = []
    print(f"converting {len(wanted)} maps from {cstrike} ({len(wads)} wads)")
    for name in wanted:
        bsp = cstrike / "maps" / f"{name}.bsp"
        if not bsp.exists():
            print(f"  skipping {name}: no bsp", file=sys.stderr)
            continue
        try:
            results.append(write_map(bsp, wads, palette, args.out, env_dir=env_dir))
        except Exception as error:  # noqa: BLE001 - keep going, report at the end
            print(f"  {name} failed: {error}", file=sys.stderr)

    manifest_path = args.out / "assets" / "maps" / "manifest.json"
    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    manifest = {"maps": {row["map"]: row for row in results}}
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")

    print("\nconverted:")
    for row in results:
        print(f"  {row['map']}: {row['triangles']} tris, {row['textures']} textures "
              f"({row['fallback_textures']} procedural), {row['bomb_sites']} bombsites, "
              f"sky={row['sky']} weather={row['weather']}")
    print(f"\nmanifest: {manifest_path}")
    return 0 if results else 1


if __name__ == "__main__":
    raise SystemExit(main())
