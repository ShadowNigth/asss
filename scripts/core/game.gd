class_name Game
extends Node3D
## Main game scene: loads a map, spawns the player + bots, runs the round loop.
##
## Headless-safe: no HUD is created when the display server is `headless`, and
## bots are optional (`--no-bots`), so `--headless --quit-after N` is a valid
## smoke test for map loading, navigation baking and round flow.

const HUD_SCENE := "res://scripts/ui/hud.gd"
const BUY_MENU := "res://scripts/ui/buy_menu.gd"
const SCOREBOARD := "res://scripts/ui/scoreboard.gd"

var map_loader: MapLoader
var atmosphere: Atmosphere
var match_state: MatchState
var player: PlayerController
var bots: Array = []
var agents: Array = []
var hud: CanvasLayer
var buy_menu: CanvasLayer
var scoreboard: CanvasLayer
var navigation_region: NavigationRegion3D
var effects: Node3D
var bot_names := ["Cliffe", "Minh", "Gooseman", "ZooL", "Barney", "Gina", "Vitaliy", "Vlad", "Simmons"]
var boot_time := 0.0
var ready_boot := false
var telemetry_time := 0.0
var _nav_mesh: NavigationMesh
const NAV_SOURCE_GROUP := "nav_world_source"


func _ready() -> void:
	randomize()
	_build_world()
	_build_agents()
	_build_ui()
	if match_state != null:
		match_state.start()
	ready_boot = true
	if Cfg.telemetry_interval > 0.0:
		for team in ["t", "ct"]:
			var pool: Array = map_loader.spawn_pool(team)
			var listing := PackedStringArray()
			for spawn in pool:
				listing.append(str(Vector3(spawn["pos"]).snapped(Vector3(0.01, 0.01, 0.01))))
			print("[telemetry] spawns %s (%d): %s" % [team, pool.size(), " ".join(listing)])
	if Cfg.headless_display:
		print("[game] %s loaded: %d groups, %d tris, %d collision tris (dropped %d), %d spawns, %d sites" % [
			Cfg.map_name, map_loader.stats.get("groups", 0), map_loader.stats.get("triangles", 0),
			map_loader.stats.get("collision_triangles", 0), map_loader.stats.get("dropped_triangles", 0),
			map_loader.map_data.spawns.size(), map_loader.map_data.bomb_sites.size()])


func _build_world() -> void:
	atmosphere = Atmosphere.new()
	atmosphere.name = "Atmosphere"
	add_child(atmosphere)
	map_loader = MapLoader.new()
	map_loader.name = "MapLoader"
	add_child(map_loader)
	if not map_loader.build(Cfg.map_name):
		push_error("failed to load map %s" % Cfg.map_name)
		return
	atmosphere.setup(map_loader.map_data.sky, Cfg.quality)
	effects = Node3D.new()
	effects.name = "Effects"
	add_child(effects)
	match_state = MatchState.new()
	match_state.name = "MatchState"
	add_child(match_state)
	_build_light_entities()


func _build_light_entities() -> void:
	if map_loader.map_data.lights.is_empty():
		return
	var holder := Node3D.new()
	holder.name = "Lights"
	add_child(holder)
	var lights: Array = map_loader.map_data.lights
	var budget := lights.size() if Cfg.quality == "ultra" else mini(lights.size(), 24)
	for index in budget:
		var entry: Dictionary = lights[index]
		var light := OmniLight3D.new()
		light.light_color = Atmosphere._color(entry.get("color", [1, 1, 1]))
		light.light_energy = clampf(float(entry.get("energy", 1.0)), 0.05, 8.0)
		light.omni_range = clampf(float(entry.get("range", 8.0)), 1.0, 48.0)
		light.omni_attenuation = 1.4
		light.shadow_enabled = false
		light.position = Atmosphere._vec3(entry.get("pos", [0, 0, 0]))
		holder.add_child(light)
		if bool(entry.get("flicker", false)):
			LightFlicker.attach(holder, light, LightFlicker.FLUORESCENT)


func _build_agents() -> void:
	if map_loader == null or map_loader.map_data == null:
		return
	navigation_region = NavigationRegion3D.new()
	navigation_region.name = "Navigation"
	add_child(navigation_region)
	_bake_navigation()

	var spawn := map_loader.spawn_for_index(Cfg.start_team, 0)
	player = PlayerController.new()
	player.name = "Player"
	add_child(player)
	player.setup(spawn, Cfg.start_team, true)
	player.died.connect(_on_player_died)
	agents.append(player)

	if Cfg.no_bots:
		return
	var team_t := Cfg.bots / 2
	var team_ct := Cfg.bots - team_t
	for index in team_t:
		_spawn_bot("t", index)
	for index in team_ct:
		_spawn_bot("ct", index + team_t)


func _spawn_bot(team: String, index: int) -> void:
	var agent := BotAgent.new()
	agent.name = "Bot_%s_%d" % [team, index]
	var spawn := map_loader.spawn_for_index(team, index + 1)
	add_child(agent)
	agent.setup(bot_names[index % bot_names.size()], team, index)
	agent.reset_actor(spawn, team)
	agent.configure(Cfg.BOT_SKILL + randf_range(-0.12, 0.12), _bot_loadout(team))
	agent.add_to_group("damageable")
	bots.append(agent)
	agents.append(agent)


func _bot_loadout(team: String) -> Array:
	if team == "t":
		return ["ak47", "glock"]
	return ["m4a1", "usp"]


func _add_to_nav_group(node: Node) -> void:
	if node == null:
		return
	node.add_to_group(NAV_SOURCE_GROUP, true)


func _bake_navigation() -> void:
	if map_loader.collision_body == null:
		return
	var nav_mesh := NavigationMesh.new()
	nav_mesh.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS
	nav_mesh.geometry_collision_mask = 1
	# The world collision lives next to the region, not under it: the default
	# ROOT_NODE_CHILDREN source would parse the (empty) region and bake nothing.
	nav_mesh.geometry_source_geometry_mode = NavigationMesh.SOURCE_GEOMETRY_GROUPS_WITH_CHILDREN
	nav_mesh.geometry_source_group_name = NAV_SOURCE_GROUP
	nav_mesh.cell_size = 0.25
	nav_mesh.cell_height = 0.25
	nav_mesh.agent_radius = Cfg.HULL_RADIUS * Cfg.U2M
	nav_mesh.agent_height = Cfg.HULL_HEIGHT * Cfg.U2M
	nav_mesh.agent_max_climb = 0.35
	nav_mesh.agent_max_slope = 46.0
	nav_mesh.region_min_size = 4.0
	navigation_region.navigation_mesh = nav_mesh
	if map_loader.collision_body != null:
		_add_to_nav_group(map_loader.collision_body)
	navigation_region.bake_navigation_mesh(false)
	_nav_mesh = nav_mesh
	if Cfg.telemetry_interval > 0.0:
		var polygons := nav_mesh.get_polygon_count()
		var verts := nav_mesh.get_vertices().size()
		print("[telemetry] navmesh polygons=%d vertices=%d cell=%.2f" % [polygons, verts, nav_mesh.cell_size])


func _build_ui() -> void:
	if Cfg.headless_display:
		return
	hud = load(HUD_SCENE).new()
	add_child(hud)
	hud.setup(self, player, match_state)
	buy_menu = load(BUY_MENU).new()
	add_child(buy_menu)
	buy_menu.setup(self, player, match_state)
	scoreboard = load(SCOREBOARD).new()
	add_child(scoreboard)
	scoreboard.setup(self, match_state)


func _on_player_died(killer: String) -> void:
	if hud != null:
		hud.show_death(killer)


func _process(delta: float) -> void:
	boot_time += delta
	if match_state == null or not match_state.running:
		return
	_update_agents(delta)
	_update_alive_counts()
	_emit_telemetry(delta)


func _emit_telemetry(delta: float) -> void:
	## Headless smoke-test hook: one line per interval with the state a round
	## can be stuck in (phase, alive counts, bomb, bot movement).
	if Cfg.telemetry_interval <= 0.0:
		return
	telemetry_time += delta
	if telemetry_time < Cfg.telemetry_interval:
		return
	telemetry_time = 0.0
	var moving := 0
	var grounded := 0
	var distances := PackedFloat32Array()
	for index in bots.size():
		var agent: CharacterBody3D = bots[index]
		if agent.velocity.length() > 0.5:
			moving += 1
		if agent.is_on_floor():
			grounded += 1
		distances.append(agent.global_position.y)
	var names := PackedStringArray()
	var dead := PackedStringArray()
	for index in bots.size():
		var bot: CharacterBody3D = bots[index]
		if not bot.alive:
			dead.append(str(bot.name))
		else:
			names.append("%s@%s" % [bot.name, str(bot.global_position.snapped(Vector3(0.1, 0.1, 0.1)))])
	var ys := ""
	if not distances.is_empty():
		var lowest := INF
		var highest := -INF
		for value in distances:
			lowest = minf(lowest, value)
			highest = maxf(highest, value)
		ys = " y=[%.2f..%.2f]" % [lowest, highest]
	print("[telemetry] t=%.0f %s alive t=%d ct=%d bomb=%s moving=%d/%d grounded=%d%s dead=%s %s" % [
		boot_time, match_state.status_line(), match_state.alive["t"], match_state.alive["ct"],
		match_state.bomb_state, moving, bots.size(), grounded, ys, ",".join(dead), " ".join(names)])


func _update_agents(delta: float) -> void:
	if bots.is_empty():
		return
	# Freeze time: no movement and no shooting, exactly like the real game.
	var frozen: bool = match_state.phase != MatchState.Phase.LIVE
	for agent in bots:
		agent.frozen = frozen
	var site_positions := {}
	for site in map_loader.map_data.bomb_sites:
		site_positions[str(site["name"])] = site["pos"]
	var enemies_by_team := {"t": [], "ct": []}
	for agent in bots:
		if agent.alive:
			enemies_by_team[agent.team].append(agent)
	if player != null and player.alive:
		enemies_by_team[player.team].append(player)
	for agent in bots:
		var foes: Array = enemies_by_team["ct"] if agent.team == "t" else enemies_by_team["t"]
		agent.think(delta, foes, site_positions)


func _update_alive_counts() -> void:
	var counts := {"t": 0, "ct": 0}
	for agent in bots:
		if agent.alive:
			counts[agent.team] = int(counts.get(agent.team, 0)) + 1
	if player != null and player.alive:
		counts[player.team] = int(counts.get(player.team, 0)) + 1
	match_state.set_alive_counts(int(counts["t"]), int(counts["ct"]))
