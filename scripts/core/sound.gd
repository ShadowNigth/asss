extends Node
## Sound effects: a small pool of players plus 3D ones for world events.
##
## Two sources feed this:
##
## * `assets/audio/shots`, `reloads` and `foley` -- the retail reports and
##   mechanical foley, imported from the `archi` pack by
##   `tools/audio/import_weapon_sounds.py`. These are what the game uses.
## * `assets/audio/*.wav` -- the synthesised set from `tools/audio/make_sounds.py`,
##   which stays as the fallback for anything the pack does not cover
##   (footsteps, bullet impacts, the knife, the round stingers) and for a
##   checkout where the import has not been run.
##
## Loading is lazy and tolerant: a missing file is a silent no-op, so the game
## still runs on a bare checkout with no audio at all.

const DIR := "res://assets/audio"

## Weapon id -> its retail report. One file per weapon, because the pack ships
## a distinct report for each; the class shots below are only the fallback.
const SHOT_BY_CLASS := {
	"pistol": "shot_pistol",
	"smg": "shot_smg",
	"rifle": "shot_rifle",
	"sniper": "shot_sniper",
	"shotgun": "shot_shotgun",
}

## Which synthesised class each weapon falls back to when the retail report is
## missing (e.g. a checkout without the import step).
const CLASS_OF_WEAPON := {
	"glock": "pistol", "usp": "pistol", "deagle": "pistol", "elite": "pistol",
	"fiveseven": "pistol",
	"mp5": "smg", "tmphk": "smg", "p90": "smg", "ump45": "smg", "mac10": "smg",
	"ak47": "rifle", "m4a1": "rifle", "galil": "rifle", "famas": "rifle",
	"sg552": "rifle", "aug": "rifle", "m249": "rifle",
	"awp": "sniper", "scout": "sniper", "g3sg1": "sniper", "sg550": "sniper",
	"m3": "shotgun", "xm1014": "shotgun",
}

const POOL_SIZE := 8

var _streams := {}
var _ui_players: Array[AudioStreamPlayer] = []
var _ui_cursor := 0
var _world_root: Node3D
var _step_index := 0
var _enabled := true
## How many retail (imported) files are in the set; read by the telemetry line.
var _imported_count := 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_load_set("", ["knife", "reload", "step_0", "step_1", "step_2", "land", "impact",
		"flesh", "beep", "plant", "defuse", "explosion", "round_win", "round_lose", "switch",
		"shot_pistol", "shot_smg", "shot_rifle", "shot_sniper", "shot_shotgun"])
	_load_set("shots/", CLASS_OF_WEAPON.keys())
	_load_set("reloads/", CLASS_OF_WEAPON.keys())
	_load_set("foley/", ["he_explode", "flash_explode", "c4_explode", "grenade_throw",
		"grenade_bounce", "pinpull", "c4_initiate", "key_press", "zoom_in", "zoom_out"])
	var imported := 0
	for key in _streams:
		if str(key).begins_with("shots/") or str(key).begins_with("reloads/") or str(key).begins_with("foley/"):
			imported += 1
	_imported_count = imported
	if _streams.is_empty():
		_enabled = false
		push_warning("no audio found; run tools/audio/make_sounds.py")
		return
	for _index in POOL_SIZE:
		var player := AudioStreamPlayer.new()
		player.bus = "Master"
		add_child(player)
		_ui_players.append(player)


func _load_set(prefix: String, names: Array) -> void:
	for name in names:
		var key := str(name)
		var path := "%s/%s%s.wav" % [DIR, prefix, key]
		if ResourceLoader.exists(path):
			_streams["%s%s" % [prefix, key]] = load(path)


func _attach_world(root: Node3D) -> void:
	_world_root = root


func summary() -> String:
	## One line for the boot telemetry: total streams and how many are retail.
	return "%d streams (%d retail, %d synthesised)" % [
		_streams.size(), _imported_count, _streams.size() - _imported_count]


func has_sound(name: String) -> bool:
	return _streams.has(name)


func play(name: String, volume_db: float = 0.0, pitch: float = 1.0) -> void:
	## Non-positional playback (UI, own weapon, own footsteps).
	if not _enabled or not _streams.has(name):
		return
	var player := _ui_players[_ui_cursor]
	_ui_cursor = (_ui_cursor + 1) % _ui_players.size()
	player.stream = _streams[name]
	player.volume_db = volume_db
	player.pitch_scale = clampf(pitch, 0.35, 3.0)
	player.play()


func play_at(name: String, position: Vector3, volume_db: float = 0.0, pitch: float = 1.0,
		max_distance: float = 45.0) -> void:
	## Positional playback for anything happening in the world: gunshots from
	## bots, impacts, the C4 going off. The player is attached to the scene so
	## Godot can compute distance attenuation against the listener.
	if not _enabled or not _streams.has(name) or _world_root == null:
		return
	var player := AudioStreamPlayer3D.new()
	player.stream = _streams[name]
	player.volume_db = volume_db
	player.pitch_scale = clampf(pitch, 0.35, 3.0)
	player.max_distance = max_distance
	player.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	player.unit_size = 8.0
	_world_root.add_child(player)
	player.global_position = position
	player.finished.connect(player.queue_free)
	player.play()


func shot_sound(weapon_id: String) -> String:
	## The retail report for this weapon, or the class stand-in.
	var key := "shots/%s" % weapon_id
	if _streams.has(key):
		return key
	if weapon_id == "knife":
		return "knife"
	var kind := str(CLASS_OF_WEAPON.get(weapon_id, ""))
	if kind.is_empty():
		var slot := str(Weapons.get_weapon(weapon_id).get("slot", ""))
		kind = "pistol" if slot == "secondary" else ("rifle" if slot == "primary" else "")
	if SHOT_BY_CLASS.has(kind):
		return str(SHOT_BY_CLASS[kind])
	return ""


func reload_sound(weapon_id: String) -> String:
	## Per-weapon magazine foley when the pack has it, generic click otherwise.
	var key := "reloads/%s" % weapon_id
	return key if _streams.has(key) else "reload"


func foley(name: String) -> String:
	## Retail foley if imported, otherwise the synthesised sound of that name.
	var key := "foley/%s" % name
	return key if _streams.has(key) else name


func _listener_position() -> Vector3:
	## The camera, when there is one; the world origin otherwise (headless).
	var camera := get_viewport().get_camera_3d() if is_inside_tree() else null
	return camera.global_position if camera != null else Vector3.ZERO


func play_shot(weapon_id: String, position: Vector3, positional: bool, volume_db: float = 0.0) -> void:
	var name := shot_sound(weapon_id)
	if name.is_empty():
		return
	# A shot fired from across the map reads as the distant take when the pack
	# has one; the near report would otherwise sound like a shot next to you.
	if positional and _streams.has("shots/%s_far" % weapon_id):
		var listener := _listener_position()
		if listener.distance_to(position) > 25.0:
			name = "shots/%s_far" % weapon_id
	# Retail reports already carry their own variation; only jitter the
	# synthesised fallbacks, which are a single take each.
	var pitch := randf_range(0.97, 1.03) if name.begins_with("shots/") else randf_range(0.94, 1.06)
	if positional:
		play_at(name, position, volume_db, pitch, 90.0)
	else:
		play(name, volume_db, pitch)


func play_reload(weapon_id: String) -> void:
	play(reload_sound(weapon_id), -4.0, randf_range(0.97, 1.03))


func play_foley(name: String, position: Vector3, positional: bool, volume_db: float = 0.0,
		max_distance: float = 45.0) -> void:
	var key := foley(name)
	if positional:
		play_at(key, position, volume_db, randf_range(0.97, 1.03), max_distance)
	else:
		play(key, volume_db, randf_range(0.97, 1.03))


func footstep(position: Vector3, positional: bool) -> void:
	var name := "step_%d" % _step_index
	_step_index = (_step_index + 1) % 3
	if positional:
		play_at(name, position, -6.0, randf_range(0.9, 1.1), 18.0)
	else:
		play(name, -9.0, randf_range(0.9, 1.1))
