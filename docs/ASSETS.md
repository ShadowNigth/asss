# Asset pipeline

Everything under `assets/` is generated from retail CS 1.5 data plus the CS2
viewmodel kit. Nothing is checked in by hand, so the whole tree can be rebuilt
from scratch with the two commands at the bottom of this file.

```
assets/
  goldsrc/palette.lmp          last-resort Quake palette (see "Palettes" below)
  maps/<map>/<map>.csmap       geometry + gameplay payload (see below)
  maps/<map>/textures/*.png    one albedo per BSP miptex (or procedural fallback)
  maps/<map>/lightmaps/*.png   original baked light, packed into atlases
  maps/<map>/sky.png           retail skybox reprojected to equirectangular
  maps/manifest.json           per-map conversion summary
  cs2go/models/…               viewmodels, gloves, knife, first-person hands
  audio/*.wav                  synthesised effects (shots, steps, C4, stingers)
```

## Sources

| What | Where | Size |
| --- | --- | --- |
| CS 1.5 retail (BSP30 maps, WADs, `gfx/env` skyboxes) | `Ch0wW/counterstrike-betas`, branch `cs15_retail` | 128 MB |
| CS2 viewmodel / glove GLBs | `3kh0/cs2go`, revision `89f2e5b` | ~43 MB after pruning |
| GoldSrc palette | `Perkedel/HexagonEngine` `addons/qodot/palette.lmp` | 768 B |

`halflife.wad` is not distributed with the CS 1.5 branch (it is Valve content
under LFS), so ~3–200 textures per map are missing from the retail WADs. Point
`--wads` at a `valve/` directory you already own and those resolve instead:

```sh
python3 tools/build_assets.py --cstrike <cstrike> --wads <valve> --all
```

Without it, the missing ones
are replaced by a procedural texture chosen from the texture name family
(`sand`, `metal`, `wood`, `brick`, `tile`, `concrete`, `glass`, `foliage`,
`snow`, `water`), and the count is reported per map by the build script.

## Palettes

A GoldSrc miptex is stored as **four mip levels, then `uint16 paletteCount`,
then `paletteCount * 3` palette bytes** — in both the BSP `TEXTURE` lump and in
WAD3 lumps. The count word is the byte in front of every palette, so the real
palette starts 2 bytes after the last mip level; treating that as alignment
padding and guessing a single palette for the whole map picks up a neighbouring
texture's ramp and decodes plausible-looking but wrong colours (Dust II's
double doors came out green and the walls purple).

The converter therefore reads one palette per miptex. Only textures with no
palette of their own (a handful of maps) fall back to the best global candidate
(`palette.best_global`), and `palette.lmp` is used only if a lump has neither —
it is Quake's ramp, not Counter-Strike's, and applying it to CS art produces
noise.

BSP texture names carry a two-character render stamp (`+0`, `-a`, `+1~`), while
the WAD stores the bare name, so `wad.Wad.resolve_name()` strips the stamp,
drops the `~` fullbright marker and reconciles the `{` masked prefix before
looking a lump up.

## `.csmap` format

```
magic      "CS15MAP\x01"
header     u32 length + UTF-8 JSON
group[i]   i32 verts, i32 tris, i32 material
           f32x3 position   (Godot space, metres)
           f32x3 normal
           f32x2 uv         (GoldSrc texinfo projection, normalised per miptex)
           f32x2 uv2        (lightmap atlas coordinates)
           u8x3  colour     (baked light × albedo, used as vertex colour)
           i32x3 indices
water[j]   i32 verts, i32 tris, f32x3 positions, i32x3 indices
```

The JSON header carries `bounds`, `sky`, `materials`, `emissive`, `groups`,
`lightmap_atlases`, `spawns`, `bomb_sites`, `buy_zones`, `lights`, `doors`,
`breakables`, `triggers`, `water_volumes` and `stats`.

### Coordinates

GoldSrc is Z-up: `(x, y, z) · 0.0254 → (x, y, z)` in metres with
`Gy = Gz`, `Gz = −Gy`. The rotation has determinant +1, so face winding is
preserved; the loader never flips triangles.

### Materials

One material per BSP miptex, deduplicated by name. `family` drives the
procedural fallback, `emissive` marks light textures, `transparent` marks glass
and grates. Albedo is `textures/tex_NNN.png`; light is baked into the mesh
vertex colour (`Color8(r,g,b)` from the lightmap sample at each vertex).

## Sky handling

Each map's `worldspawn/skyname` is matched against the retail `gfx/env` TGA
faces (`rt lf ft bk up dn`). When found, the six 256×256 faces are projected to
an equirectangular panorama (`sky.png`, 1536×768) with:

* a cross-fade band around every face border (retail faces were hand-painted
  and disagree by ~35/255 at the seams),
* mip-mapped sampling so clouds do not turn into radial streaks near the poles
  and the horizon,
* the up/down faces handed over only past the cube corner, where they carry
  real information.

`de_cbble` and `de_prodigy` reference `dusk`, which is not in the CS 1.5
`gfx/env` set at all; they fall back to a procedural sky tuned to their
`light_environment`.

## Commands

```bash
# CS 1.5 maps -> assets/maps  (fetch the sparse retail checkout first)
python3 tools/build_assets.py --fetch
python3 tools/build_assets.py --all           # or --maps de_dust2,de_inferno
python3 tools/build_assets.py --report

# CS2 viewmodels / gloves / knife -> assets/cs2go/models
python3 tools/cs2go/fetch_assets.py

# sound effects -> assets/audio  (20 mono 16-bit WAVs, ~600 KB in total)
python3 tools/audio/make_sounds.py
```

## Audio

There is no retail sound data in the sources above, so every effect under
`assets/audio` is synthesised by `tools/audio/make_sounds.py` from seeded noise
and oscillators: five weapon-report classes, knife, reload, three footstep
variants, landing, world impact, flesh hit, the C4 beep/plant/defuse cues, the
explosion, and win/loss stingers. `scripts/core/sound.gd` maps each weapon to
one of the shot classes and plays everything else positionally through an
8-voice pool, so a distant firefight is quieter and panned by the listener.

Both scripts are idempotent and need `numpy` + `Pillow` (and `gh` for the CS2
mirror, whose blobs are pulled through the GitHub API because the sandbox
cannot reach `raw.githubusercontent.com`).
