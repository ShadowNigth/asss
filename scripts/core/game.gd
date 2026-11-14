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
var _need_nav_probe := false
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
	match_state.bomb_exploded.connect(_on_bomb_exploded)
	match_state.round_started.connect(_on_round_started)
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
	_assign_bomb()


func _on_round_started(_number: int, _freeze: float) -> void:
	## New round: everyone is alive again and back on a spawn, the C4 is back
	## on a terrorist and the CT defuse kits are re-rolled.
	_respawn_team("t")
	_respawn_team("ct")
	if player != null and is_instance_valid(player):
		player.teleport_to(map_loader.spawn_for_index("t", 0))
	_assign_bomb()


func _respawn_team(team: String) -> void:
	var slot := 0
	for agent in bots:
		if agent.team != team:
			continue
		agent.reset_actor(map_loader.spawn_for_index(team, slot + 1), team)
		slot += 1


func _assign_bomb() -> void:
	## One T carries the C4; half the CTs spawn with a defuse kit, as in retail.
	for agent in bots:
		agent.bomb_carrier = false
		agent.has_bomb = false
		agent.frozen = false
	var terrorists: Array = []
	for agent in bots:
		if agent.team == "t":
			terrorists.append(agent)
	if not terrorists.is_empty():
		var carrier: BotAgent = terrorists[randi() % terrorists.size()]
		carrier.bomb_carrier = true
		carrier.has_bomb = true
		if match_state != null:
			match_state.bomb_carrier = carrier.display_name
	for agent in bots:
		if agent.team == "ct":
			agent.has_defuse_kit = randf() < 0.5


func _spawn_bot(team: String, index: int) -> void:
	var agent := BotAgent.new()
	agent.name = "Bot_%s_%d" % [team, index]
	var spawn := map_loader.spawn_for_index(team, index + 1)
	add_child(agent)
	agent.setup(bot_names[index % bot_names.size()], team, index)
	agent.reset_actor(spawn, team)
	agent.configure(Cfg.BOT_SKILL + randf_range(-0.12, 0.12), _bot_loadout(team))
	agent.match_state = match_state
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
	# Keep every voxel-derived property a whole number of cells, otherwise the
	# baker rounds them and neighbouring polygons end up sharing edges.
	var cell := 0.25
	nav_mesh.cell_size = cell
	nav_mesh.cell_height = cell
	nav_mesh.agent_radius = ceilf(Cfg.HULL_RADIUS * Cfg.U2M / cell) * cell
	nav_mesh.agent_height = ceilf(Cfg.HULL_HEIGHT * Cfg.U2M / cell) * cell
	# Stairs in de_inferno/de_nuke rise in ~0.3 m steps; too low a climb value
	# severs the mesh there and bots stop dead halfway up.
	nav_mesh.agent_max_climb = ceilf(0.5 / cell) * cell
	nav_mesh.agent_max_slope = 50.0
	nav_mesh.region_min_size = 2.0
	navigation_region.navigation_mesh = nav_mesh
	if map_loader.collision_body != null:
		_add_to_nav_group(map_loader.collision_body)
	navigation_region.bake_navigation_mesh(false)
	_nav_mesh = nav_mesh
	if Cfg.telemetry_interval > 0.0:
		var polygons := nav_mesh.get_polygon_count()
		var verts := nav_mesh.get_vertices().size()
		print("[telemetry] navmesh polygons=%d vertices=%d cell=%.2f" % [polygons, verts, nav_mesh.cell_size])
		_need_nav_probe = true


func _dump_nav_coverage() -> void:
	## Probe the navmesh on a grid so "bots are stuck" can be told apart from
	## "the mesh has a hole here".
	var map: RID = get_world_3d().navigation_map
	var lo: Vector3 = map_loader.map_data.bounds_min
	var hi: Vector3 = map_loader.map_data.bounds_max
	var hits := 0
	var misses := 0
	var step := maxf((hi.x - lo.x) / 24.0, 1.0)
	var z := lo.z
	while z < hi.z:
		var x := lo.x
		while x < hi.x:
			var probe := Vector3(x, (lo.y + hi.y) * 0.5, z)
			var point := NavigationServer3D.map_get_closest_point(map, probe)
			# map_get_closest_point returns the query itself when nothing is
			# near, so a real hit is a point that actually moved and sits at a
			# plausible walkable height.
			if point.distance_to(probe) > 0.05 and absf(point.y - probe.y) < 25.0:
				hits += 1
			else:
				misses += 1
			x += step
		z += step
	print("[telemetry] nav coverage %d/%d" % [hits, hits + misses])
	for site in map_loader.map_data.bomb_sites:
		var lo2: Vector3 = site["min"]
		var hi2: Vector3 = site["max"]
		var inside := 0
		var verts2: PackedVector3Array = _nav_mesh.get_vertices()
		for v in verts2:
			if v.x >= lo2.x - 1.0 and v.x <= hi2.x + 1.0 and v.z >= lo2.z - 1.0 and v.z <= hi2.z + 1.0:
				inside += 1
		print("[telemetry] site %s nav verts=%d of %d (box x %.1f..%.1f z %.1f..%.1f)" % [
			site["name"], inside, verts2.size(), lo2.x, hi2.x, lo2.z, hi2.z])


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


func _on_bomb_exploded() -> void:
	## Everything inside the blast radius dies; armour does not help.
	var radius := Cfg.BOMB_DAMAGE_RADIUS * Cfg.U2M
	for agent in agents:
		if agent == null or not is_instance_valid(agent) or not agent.alive:
			continue
		var distance: float = agent.global_position.distance_to(match_state.bomb_position)
		if distance > radius:
			continue
		var falloff := clampf(1.0 - distance / radius, 0.15, 1.0)
		agent.apply_damage(int(500.0 * falloff), "C4", false)


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
	if _need_nav_probe and boot_time > 1.0:
		_need_nav_probe = false
		_dump_nav_coverage()


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
	var objective := ""
	if match_state.bomb_state == "planted":
		objective = " site=%s fuse=%.1f pos=%s" % [
			match_state.bomb_site, match_state.bomb_timer,
			str(match_state.bomb_position.snapped(Vector3(0.1, 0.1, 0.1)))]
	elif match_state.bomb_state == "carried":
		objective = " carrier=%s" % match_state.bomb_carrier
	else:
		objective = " result=%s" % match_state.bomb_state
	print("[telemetry] t=%.0f %s score=%d:%d alive t=%d ct=%d bomb=%s%s moving=%d/%d grounded=%d%s dead=%s %s" % [
		boot_time, match_state.status_line(), match_state.score_t, match_state.score_ct,
		match_state.alive["t"], match_state.alive["ct"],
		match_state.bomb_state, objective, moving, bots.size(), grounded, ys,
		",".join(dead), " ".join(names)])


func _update_agents(delta: float) -> void:
	if bots.is_empty():
		return
	# Freeze time: no movement and no shooting, exactly like the real game.
	var frozen: bool = match_state.phase != MatchState.Phase.LIVE
	for agent in bots:
		agent.frozen = frozen
	var site_positions := {}
	for site in map_loader.map_data.bomb_sites:
		site_positions[str(site["name"])] = site
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
