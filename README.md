# Counter-Strike 1.5 in Godot 4.4

A source-accurate remake of the CS 1.5 beta build (GoldSrc BSP30 maps) in
Godot 4.4: the original 15 `de_*` bomb-defusal maps converted straight from the
retail BSPs, GoldSrc movement (`PM_Move`), the retail weapon table, and CS2
viewmodels for the first-person rig.

## What is in the box

* **15 maps** — dust, dust2, inferno, nuke, train, cbble, aztec, prodigy,
  vertigo, piranesi, chateau, storm, survivor, torn, vegas. Geometry, textures,
  baked lighting, skyboxes, spawns, bomb sites, buy zones, lights and water
  volumes all come from the original `.bsp` files.
* **GoldSrc movement** — 800 u/s² gravity, 301.99 u/s jump impulse, 5.5 ground
  accel, 12 air accel with the 30 u/s air cap, 5.2 friction, 18 u step height,
  72/54 u hulls, ducking with a stand-up clearance check, ladders and swimming.
* **Weapons** — 28 retail entries (pistols, SMGs, rifles, snipers, shotguns,
  machine gun, grenades, knife, C4) with per-weapon recoil patterns, the CS
  spread model (standing/walking/jumping/crouching), armour penetration,
  headshots and shotgun pellets.
* **Round flow** — 115 s rounds, 5 s freeze, 20 s buy window, 35 s C4 fuse,
  $3250/$1400 economy with loss streaks, first to 16.
* **Bots** — navmesh-driven T/CT agents that take sites, engage with
  line-of-sight checks, strafe and shoot.
* **Presentation** — per-map panorama skies generated from the retail
  `gfx/env` faces, fog/mood per map, a CS-style HUD with radar, buy menu and
  scoreboard.

## Requirements

* Godot **4.4.x** (the project targets 4.4 features; 4.3 will complain about
  `Sky.PROCESS_MODE_*` usage). A GL Compatibility build is enough — the project
  is configured for the compatibility renderer.
* Python 3.10+ with `numpy`, `Pillow` and `gh` (GitHub CLI) **only** if you want
  to regenerate the assets; the generated tree is committed.

## Run

```bash
godot --path .                                   # dust2, player + 7 bots
godot --path . -- --map=de_inferno --bots=9
godot --path . -- --map=de_nuke --no-bots --quality=ultra
godot --headless --path . --quit-after 600 -- --no-bots   # smoke test
```

Command line flags go after `--`:

| Flag | Meaning |
| --- | --- |
| `--map=<name>` | map to load (default `de_dust2`) |
| `--bots=<n>` | number of bots, split across both teams (default 7) |
| `--no-bots` | no AI, free roam |
| `--quality=low\|medium\|high\|ultra` | shadow/light/SSAO budget |
| `--no-mouse` | never capture the mouse (handy for screenshots) |
| `--team=t\|ct` | team the player spawns on |
| `--list-maps` | print every converted map and quit |

### Controls

| Key | Action |
| --- | --- |
| WASD | move |
| Space | jump |
| Ctrl / C | crouch |
| Shift | walk |
| Mouse 1 / 2 | fire / alt-fire (scope) |
| R | reload |
| 1–5 | primary, secondary, knife, grenade, C4 |
| Mouse wheel | cycle weapons |
| B | buy menu (freeze time + first 20 s) |
| Tab | scoreboard |
| F3 | FPS / draw calls |
| Esc | release mouse |

## Rebuilding the assets

```bash
python3 tools/build_assets.py --fetch      # sparse clone of the CS 1.5 retail branch
python3 tools/build_assets.py --all         # convert all 15 maps
python3 tools/cs2go/fetch_assets.py         # 23 CS2 GLBs (viewmodels, gloves, knife)
```

See [`docs/ASSETS.md`](docs/ASSETS.md) for the `.csmap` binary layout, the
coordinate mapping and how the sky panoramas are produced.

## Layout

```
project.godot              engine config (physics stays on GodotPhysics3D)
scenes/main.tscn           single entry scene -> scripts/core/game.gd
data/                      weapons.json, recoil.json, accuracy.json
scripts/core/              game loop, Cfg autoload, weapon DB autoload
scripts/world/             csmap reader, mesh/collision builder, sky, water, lights
scripts/player/            PM_Move port, first-person rig
scripts/weapons/           inventory, hitscan, spread/recoil
scripts/agents/            bots, viewmodel rig
scripts/round/             round + economy state machine
scripts/ui/                HUD, buy menu, scoreboard
tools/goldsrc/             BSP30 / WAD3 parsers, csmap writer
tools/cs2go/               CS2 model fetcher
```

## Notes / known limits

* `3d/physics_engine` is intentionally **not** set to `JoltPhysics3D`: the
  reference build has no Jolt compiled in, and forcing it makes
  `CharacterBody3D` abort during the first physics step.
* Textures missing from the retail WAD set (mostly `halflife.wad`) are replaced
  by procedurally generated ones matched to the texture name family — the
  per-map counts are in `assets/maps/manifest.json`.
* Baked GoldSrc light is applied as mesh vertex colour; there is no dynamic
  light baking in engine, so moving objects do not cast baked shadows.
* Audio, hostages and the escape objective are not implemented yet.
