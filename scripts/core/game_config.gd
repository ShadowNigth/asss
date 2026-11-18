extends Node
## Global tuning constants and CLI overrides (autoload singleton `Cfg`).
##
## Every value here mirrors the CS 1.5 (GoldSrc) `hl.dll` / `cstrike` numbers so
## that map geometry, jump heights and weapon behaviour line up with the retail
## game.  Units are GoldSrc units unless a name says otherwise; metres are
## u * 0.0254.

# --- world ------------------------------------------------------------------
const U2M := 0.0254
const MAPS_DIR := "res://assets/maps"
const DEFAULT_MAP := "de_dust2"

# --- movement (player_movement.gd) -----------------------------------------
const GRAVITY := 800.0
const MAXSPEED := 320.0
const MAXSPEED_WALK := 166.4
const MAXSPEED_DUCK := 108.8
const ACCELERATE := 5.5
const AIRACCELERATE := 12.0
const AIR_MAXSPEED := 30.0
const FRICTION := 5.2
const STOPSPEED := 80.0
const JUMP_IMPULSE := 301.99338  # = sqrt(2 * 800 * 57) -> 57 u jump
const STEP_SIZE := 18.0
## How far (GoldSrc units) a goal point may be snapped and still count as the
## bombsite; beyond this the walk-in target falls back to the site centre.
const SITE_REACH := 260.0
## A T carrying the C4 that has been stuck for this long is teleported to a
## walkable point at the bombsite. Without it a single wedged carrier stalls
## the whole round: nobody plants, so nothing resolves until the clock runs out.
const CARRIER_RESCUE_AFTER := 45.0
const MAX_LADDER_SPEED := 200.0
const DUCK_SPEED_MULT := 0.34
const CROUCH_TRANSITION := 0.12
const FALL_DAMAGE_VELOCITY := 580.0
const FALL_DAMAGE_SCALE := 0.012

# player hull (GoldSrc VEC_HULL / VEC_DUCK_HULL)
const HULL_RADIUS := 16.0
const HULL_HEIGHT := 72.0
const DUCK_HULL_HEIGHT := 54.0
const EYE_HEIGHT := 64.0
const DUCK_EYE_HEIGHT := 46.0

# --- combat ---------------------------------------------------------------
const HEADSHOT_MULTIPLIER := 4.0
const ARMOR_ABSORB := 0.5
const ARMOR_BONUS := 0.5
const KNIFE_RANGE := 1.0
const LADDER_RANGE := 0.5
const SWIM_DEPTH := 0.62
const WATER_BUOYANCY := 2.4

# --- round flow (round/match_state.gd) ------------------------------------
const ROUND_TIME := 115.0
const FREEZE_TIME := 5.0
const BUY_TIME := 20.0
const BOMB_TIMER := 35.0
const BOMB_PLANT_TIME := 3.0
const BOMB_DEFUSE_TIME := 10.0
const BOMB_DEFUSE_KIT_TIME := 5.0
const BOMB_DAMAGE_RADIUS := 500.0
const ROUND_WIN_MONEY := 3250
const ROUND_LOSS_MONEY := 1400
const START_MONEY := 800
const MAX_MONEY := 16000
const SCORE_LIMIT := 16

# --- presentation ---------------------------------------------------------
const FOV := 90.0
const VIEWMODEL_LAYER := 2
const MAX_BOTS := 9
const DEFAULT_BOTS := 7
const BOT_SKILL := 0.55
const SUN_SHAFTS_ENABLED := true
# GoldSrc composites  texture × lightmap × 2 ; 1.9 keeps bright sand bright
# without clipping the concrete in shadow.
const WORLD_LIGHT_BOOST := 1.9

# --- CLI / runtime flags (populated in _ready) ----------------------------
var map_name: String = DEFAULT_MAP
var bots: int = DEFAULT_BOTS
var no_bots := false
var quality := "high"
var no_mouse := false
var headless_display := false
var start_team := "t"
## Spectator mode: no human body is simulated, bots play both sides.
var spectator := false
## Seconds between gameplay telemetry lines in headless mode (0 = off).
var telemetry_interval := 0.0


func _ready() -> void:
	headless_display = DisplayServer.get_name() == "headless"
	_parse_args()


func _parse_args() -> void:
	for arg in OS.get_cmdline_user_args():
		var cleaned := arg.strip_edges()
		if not cleaned.begins_with("--"):
			continue
		var parts := cleaned.substr(2).split("=", true, 1)
		var key := parts[0]
		var value := parts[1] if parts.size() > 1 else ""
		match key:
			"map":
				if not value.is_empty():
					map_name = value
			"bots":
				bots = int(value)
			"spectate":
				spectator = true
			"no-bots":
				no_bots = true
				bots = 0
			"quality":
				quality = value if not value.is_empty() else "high"
			"no-mouse":
				no_mouse = true
			"team":
				start_team = value if not value.is_empty() else "t"
			"telemetry":
				telemetry_interval = float(value) if not value.is_empty() else 5.0
			"list-maps":
				print("available maps: ", ", ".join(available_maps()))
				get_tree().quit()
			_:
				push_warning("unknown command line flag: --%s" % key)


func available_maps() -> Array:
	var names: Array = []
	var dir := DirAccess.open(MAPS_DIR)
	if dir == null:
		return names
	dir.list_dir_begin()
	var entry := dir.get_next()
	while not entry.is_empty():
		if dir.current_is_dir() and not entry.begins_with(".") and entry != "textures":
			if FileAccess.file_exists("%s/%s/%s.csmap" % [MAPS_DIR, entry, entry]):
				names.append(entry)
		entry = dir.get_next()
	dir.list_dir_end()
	names.sort()
	return names


func map_payload_path(map_name_arg: String = "") -> String:
	var slug := map_name_arg if not map_name_arg.is_empty() else map_name
	return "%s/%s/%s.csmap" % [MAPS_DIR, slug, slug]


func quality_scale() -> float:
	match quality.to_lower():
		"low":
			return 0.5
		"medium":
			return 0.75
		"ultra":
			return 1.0
		_:
			return 0.85


func u2m(value: float) -> float:
	return value * U2M


func m2u(value: float) -> float:
	return value / U2M
