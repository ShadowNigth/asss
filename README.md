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
  72/54 u hulls, ducking with a stand-up clearance check, and swimming.
* **Weapons** — 28 retail entries (pistols, SMGs, rifles, snipers, shotguns,
  machine gun, grenades, knife, C4) with per-weapon recoil patterns, the CS
  spread model (standing/walking/jumping/crouching), armour penetration,
  headshots and shotgun pellets.
* **Round flow** — 115 s rounds, 5 s freeze, 20 s buy window, 35 s C4 fuse,
  $3250/$1400 economy with loss streaks, first to 16.
* **Bots** — navmesh-driven T/CT agents that take sites, engage with
  line-of-sight checks, strafe and shoot.
* **Grenades** — HE, flashbang and smoke are throwable: they bounce, fuse,
  damage with distance falloff, blur the player's screen (and drop bot targets
  for a moment), or pop a smoke cloud. Bots carry one each and lob it at a
  target that is too far to shoot.
* **Objective** — the C4 is carried by a terrorist, can be dropped by the
  carrier dying and picked back up by either side, and is planted/defused by
  bots **and** by you: hold `E` (or `use`) inside a bombsite with the bomb, or
  on the planted bomb for 10 s (5 s with a defuse kit).
* **Presentation** — per-map panorama skies generated from the retail
  `gfx/env` faces, fog/mood per map, a CS-style HUD with radar, buy menu,
  scoreboard, kill feed and round banner, blocky but visible soldier models
  for the bots, muzzle flashes, and synthesised audio for every weapon class,
  footsteps, bullet impacts, the C4 beep and the round stingers.

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
| `--spectate` | park the player and let the bots play both sides |
| `--list-maps` | print every converted map and quit |

### Controls

| Key | Action |
| --- | --- |
| WASD | move |
| Space | jump |
| Ctrl / C | crouch |
| Shift | walk |
| Mouse 1 / 2 | fire / alt-fire (scope) |
| R | reload (also restarts the match once it is over) |
| 1–5 | primary, secondary, knife, grenade, C4 |
| E (use) | plant or defuse (hold, standing still) |
| Mouse wheel | cycle weapons |
| B | buy menu (freeze time + first 20 s) |
| E (use) | plant the C4 / defuse it (hold, standing still) |
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
tools/audio/               sound-effect synthesiser
tools/check_rounds.sh      round-flow regression suite (all 15 maps)
.github/workflows/         gdlint + round-flow CI
```

## Tests

```bash
gdlint $(find scripts -name '*.gd')     # style + a subset of parse errors
tools/check_rounds.sh                   # every map must resolve a round
tools/check_rounds.sh de_dust2 de_nuke  # or a subset
```

`check_rounds.sh` boots each map headless with `--spectate`, lets the bots play
and fails if no round reaches a result inside the frame budget. That is
deliberately the *only* assertion: the bot bugs this project actually hit were
all variants of "the round never ends" (a wedged carrier, a re-randomised goal
every frame, a spawn with no floor), and a nondeterministic bot match cannot
support anything finer-grained. `gdlint` alone is not enough — it misses
duplicate function names and some parse errors, which is why the suite boots
the real engine.

## Notes / known limits

* `3d/physics_engine` is intentionally **not** set to `JoltPhysics3D`: the
  reference build has no Jolt compiled in, and forcing it makes
  `CharacterBody3D` abort during the first physics step.
* Textures missing from the retail WAD set (mostly `halflife.wad`) are replaced
  by procedurally generated ones matched to the texture name family — the
  per-map counts are in `assets/maps/manifest.json`.
* Baked GoldSrc light is applied as mesh vertex colour; there is no dynamic
  light baking in engine, so moving objects do not cast baked shadows.
* Hostages and the `cs_*` escape objective are not implemented; only the
  bomb-defusal game mode exists.
* The ladder code path in `player_movement.gd` is inert: none of the 15
  `de_*` maps ship a ladder the converter could mark, so nothing ever sets the
  `surface` metadata it looks for. Every climbable route in these maps is a
  staircase or a ramp, which is what the bots use.
* Brush doors are rebuilt from their brush volumes, not from their retail
  models: they open like a sliding door and reuse a flat metal material rather
  than the original texture.
* Bots are single-mesh primitives, not the retail player models.
* There is no netcode: the human is a local client, the bots run in-process.
