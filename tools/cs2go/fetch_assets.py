#!/usr/bin/env python3
"""Fetch the CS2 viewmodel / glove GLBs used by the first-person rig.

The models come from 3kh0/cs2go (asset mirror of the CS2 workshop kit).  They
are pulled through the GitHub *blobs* API because `raw.githubusercontent.com`
is not reachable from the build sandbox and `git-lfs` is not available.

Every GLB is validated (magic + chunk table) and, when the file uses
quantisation or meshopt compression that Godot cannot decode, it is passed
through `gltf-transform copy` + `dequantize` first.

    python3 tools/cs2go/fetch_assets.py            # fetch the curated set
    python3 tools/cs2go/fetch_assets.py --list     # show what would be fetched
    python3 tools/cs2go/fetch_assets.py --all      # every weapon viewmodel
"""
from __future__ import annotations

import argparse
import base64
import json
import shutil
import struct
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
REPO = "3kh0/cs2go"
API_ROOT = "packages/assets/public/models"
OUT_DIR = ROOT / "assets" / "cs2go" / "models"
MANIFEST_PATH = Path(__file__).resolve().parent / "manifest.json"

# The retail CS 1.5 arsenal, mapped onto the closest CS2 viewmodel.
VIEWMODELS = [
	"ak-47", "m4a4", "awp", "deagle", "glock", "usp-s", "mp5sd", "p90",
	"aug", "famas", "ssg08", "nova", "xm1014", "m249", "ump45", "mac10",
	"galilar", "elite", "p250", "tec9", "fiveseven",
]

EXTRA = [
	"agents/view-hands.glb",
	"animations/knives/knife-ct.glb",
]


def git_head() -> str:
	try:
		out = subprocess.run(["git", "-C", str(ROOT / ".cache" / "cs2go"), "rev-parse", "HEAD"],
							 capture_output=True, text=True, check=True)
		return out.stdout.strip()
	except (subprocess.CalledProcessError, FileNotFoundError, OSError):
		return "89f2e5b584871cb37122c9ebfb8da58eb4e1faec"


def blob_sha(path: str) -> str:
	out = subprocess.run(["gh", "api", f"repos/{REPO}/contents/{path}", "--jq", ".sha"],
						 capture_output=True, text=True)
	sha = out.stdout.strip()
	if not sha or "Not Found" in sha:
		raise FileNotFoundError(f"{path} is not in {REPO}")
	return sha


def download(path: str, target: Path) -> int:
	sha = blob_sha(path)
	raw = subprocess.run(["gh", "api", f"repos/{REPO}/git/blobs/{sha}"],
						 capture_output=True, text=True, check=True).stdout
	payload = base64.b64decode(json.loads(raw)["content"])
	target.parent.mkdir(parents=True, exist_ok=True)
	target.write_bytes(payload)
	return len(payload)


def validate(path: Path) -> dict:
	data = path.read_bytes()
	if data[:4] != b"glTF":
		raise ValueError(f"{path.name}: not a GLB")
	version, length = struct.unpack("<II", data[4:12])
	json_len, json_type = struct.unpack("<II", data[12:20])
	if json_type != 0x4E4F534A:
		raise ValueError(f"{path.name}: malformed JSON chunk")
	doc = json.loads(data[20:20 + json_len])
	return {
		"version": version,
		"length": length,
		"meshes": len(doc.get("meshes", [])),
		"nodes": len(doc.get("nodes", [])),
		"animations": [a.get("name", "") for a in doc.get("animations", [])],
		"extensions_before": doc.get("extensionsRequired", []),
		"images": len(doc.get("images", [])),
	}


# Godot 4.4's glTF importer rejects EXT_texture_webp, KHR_mesh_quantization and
# EXT_meshopt_compression; the CS2 mirror requires all three.  Each model is
# normalised with the gltf-transform CLI plus a small Node script that swaps the
# WebP images for PNGs.
WEBP_SCRIPT = Path(__file__).resolve().parent / "glb_webp_to_png.js"


def transform_binary() -> str | None:
	return shutil.which("gltf-transform")


def normalise(path: Path) -> dict:
	binary = transform_binary()
	if binary is None:
		raise RuntimeError("gltf-transform is required: npm install @gltf-transform/cli")
	tmp_a = path.with_suffix(".a.glb")
	tmp_b = path.with_suffix(".b.glb")
	tmp_c = path.with_suffix(".c.glb")
	run([binary, "copy", str(path), str(tmp_a)])
	run([binary, "dequantize", str(tmp_a), str(tmp_b)])
	run(["node", str(WEBP_SCRIPT), str(tmp_b), str(tmp_c)])
	shutil.move(str(tmp_c), str(path))
	for leftover in (tmp_a, tmp_b):
		leftover.unlink(missing_ok=True)
	info = validate(path)
	if info["extensions_before"]:
		raise RuntimeError(f"{path.name}: unsupported extensions remain: {info['extensions_before']}")
	return info


def run(cmd: list[str]) -> None:
	result = subprocess.run(cmd, capture_output=True, text=True)
	if result.returncode != 0:
		raise RuntimeError(f"{Path(cmd[0]).name} failed: {result.stderr[-300:]}")


def main() -> int:
	parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
	parser.add_argument("--all", action="store_true", help="fetch every weapon viewmodel")
	parser.add_argument("--list", action="store_true", help="print the planned downloads")
	parser.add_argument("--out", type=Path, default=OUT_DIR)
	args = parser.parse_args()

	planned = [f"viewmodels/{name}.glb" for name in VIEWMODELS] + EXTRA
	if args.list:
		print("\n".join(planned))
		return 0

	manifest = {"repo": REPO, "revision": git_head(), "files": {}}
	failures = 0
	for rel in planned:
		target = args.out / rel
		try:
			size = download(f"{API_ROOT}/{rel}", target)
			info = normalise(target)
		except Exception as error:  # noqa: BLE001 - report and continue
			print(f"  FAILED {rel}: {error}", file=sys.stderr)
			failures += 1
			continue
		manifest["files"][rel] = {"bytes": size, **info}
		print(f"  {rel:34} {size / 1024:8.0f} KiB  {info['meshes']} mesh  "
			  f"{info['nodes']} nodes  {len(info['animations'])} anims")
	MANIFEST_PATH.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
	print(f"\n{len(manifest['files'])} models, manifest: {MANIFEST_PATH}")
	return 1 if failures else 0


if __name__ == "__main__":
	raise SystemExit(main())
