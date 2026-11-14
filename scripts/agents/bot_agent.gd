class_name BotAgent
extends CharacterBodyAgent
## Bot: perception + simple goal-driven navigation on the baked navmesh.
##
## States are intentionally shallow (CS 1.5 bots were simple too): pick a
## bombsite or a hunt target, walk the navmesh, shoot whatever is in front of
## them, plant/defuse when close enough.  `BotAgent` never runs its own physics
## queries outside the navmesh except for line-of-sight.

enum State { IDLE, ROTATE, ADVANCE, ENGAGE, PLANT, DEFUSE, HOLD }

const SIGHT_RANGE := 60.0
const FIRE_RANGE := 45.0
const ENGAGE_TURN_SPEED := 4.5
const AIM_ERROR := 1.4

var loadout: Array = []
var plant_context := false
var state: int = State.IDLE
var target_position := Vector3.ZERO
var goal_site := ""
var has_bomb := false
var fire_cooldown := 0.0
var reaction := 0.0
var aim_offset := Vector3.ZERO
var skill := 0.55
var move_speed := 4.2
var strafe_dir := 1.0
var strafe_timer := 0.0


func configure(skill_value: float, weapons: Array) -> void:
	skill = clampf(skill_value, 0.05, 0.98)
	loadout = weapons.duplicate()
	move_speed = 3.6 + skill * 1.6


func think(delta: float, enemies: Array, site_positions: Dictionary) -> void:
	if not alive:
		return
	fire_cooldown = maxf(0.0, fire_cooldown - delta)
	reaction = maxf(0.0, reaction - delta)
	var enemy := _closest_visible(enemies)
	if enemy != null:
		state = State.ENGAGE
		_aim_at(enemy, delta)
		if reaction <= 0.0 and fire_cooldown <= 0.0 and global_position.distance_to(enemy.global_position) < FIRE_RANGE:
			_fire(enemy)
		_strafe(delta, enemy)
		return

	# no target: keep walking the current goal
	if state == State.HOLD and target_position.distance_to(global_position) < 2.0:
		return
	var desired := goal_site
	if desired.is_empty() and not site_positions.is_empty():
		var keys := site_positions.keys()
		keys.sort()
		goal_site = str(keys[randi() % keys.size()])
		desired = goal_site
	if not desired.is_empty() and site_positions.has(desired):
		target_position = site_positions[desired]
		state = State.ADVANCE
	_walk_to(target_position, delta)


func _walk_to(target: Vector3, delta: float) -> void:
	var flat := target - global_position
	flat.y = 0.0
	if flat.length() < 1.5:
		state = State.HOLD
		return
	var path := _next_path_point(target)
	var dir := (path - global_position)
	dir.y = 0.0
	if dir.length() < 0.05:
		return
	dir = dir.normalized()
	var desired_velocity := dir * move_speed
	velocity.x = move_toward(velocity.x, desired_velocity.x, delta * 22.0)
	velocity.z = move_toward(velocity.z, desired_velocity.z, delta * 22.0)
	if not is_on_floor():
		velocity.y -= Cfg.GRAVITY * Cfg.U2M * delta
	else:
		velocity.y = -0.1
	var look := atan2(-dir.x, -dir.z)
	rotation.y = lerp_angle(rotation.y, look, clampf(delta * 6.0, 0.0, 1.0))
	move_and_slide()


func _next_path_point(target: Vector3) -> Vector3:
	var navigation := NavigationServer3D.map_get_iteration_id(get_world_3d().navigation_map)
	if navigation == 0:
		return target
	var from := NavigationServer3D.map_get_closest_point(get_world_3d().navigation_map, global_position)
	var to := NavigationServer3D.map_get_closest_point(get_world_3d().navigation_map, target)
	var path := NavigationServer3D.map_get_path(get_world_3d().navigation_map, from, to, true)
	if path.size() > 1:
		return path[1]
	return target


func _closest_visible(enemies: Array) -> Node3D:
	var best: Node3D = null
	var best_distance := SIGHT_RANGE
	for entry in enemies:
		var enemy := entry as Node3D
		if enemy == null or not is_instance_valid(enemy):
			continue
		if enemy.has_method("is_alive") and not bool(enemy.call("is_alive")):
			continue
		var distance := global_position.distance_to(enemy.global_position)
		if distance > best_distance:
			continue
		if not _can_see(enemy):
			continue
		best_distance = distance
		best = enemy
	return best


func _can_see(enemy: Node3D) -> bool:
	var space := get_world_3d().direct_space_state
	var from := eye_position()
	var to := enemy.global_position + Vector3.UP * 1.4
	var query := PhysicsRayQueryParameters3D.create(from, to, 1)
	query.exclude = [get_rid()]
	var hit := space.intersect_ray(query)
	if hit.is_empty():
		return true
	var collider := hit.get("collider") as Node
	return collider != null and (collider == enemy or collider.is_ancestor_of(enemy) or enemy.is_ancestor_of(collider))


func eye_position() -> Vector3:
	return global_position + Vector3.UP * (Cfg.EYE_HEIGHT * Cfg.U2M)


func _aim_at(enemy: Node3D, delta: float) -> void:
	if reaction <= 0.0 and aim_offset == Vector3.ZERO:
		reaction = lerpf(0.45, 0.12, skill)
		aim_offset = Vector3(randf_range(-1.0, 1.0), randf_range(-0.5, 0.5), randf_range(-1.0, 1.0)) * (1.0 - skill) * AIM_ERROR
	var aim_point := enemy.global_position + Vector3.UP * 1.35 + aim_offset
	var dir := (aim_point - eye_position()).normalized()
	var look := atan2(-dir.x, -dir.z)
	rotation.y = lerp_angle(rotation.y, look, clampf(delta * ENGAGE_TURN_SPEED, 0.0, 1.0))


func _strafe(delta: float, enemy: Node3D) -> void:
	strafe_timer -= delta
	if strafe_timer <= 0.0:
		strafe_timer = randf_range(0.5, 1.8)
		strafe_dir = -strafe_dir
	var to_enemy := (enemy.global_position - global_position)
	to_enemy.y = 0.0
	if to_enemy.length() > 12.0:
		to_enemy = to_enemy.normalized()
	else:
		to_enemy = Vector3.ZERO
	var side := Vector3(-to_enemy.z, 0.0, to_enemy.x) * strafe_dir
	velocity.x = (to_enemy * move_speed + side * move_speed * 0.6).x
	velocity.z = (to_enemy * move_speed + side * move_speed * 0.6).z
	if not is_on_floor():
		velocity.y -= Cfg.GRAVITY * Cfg.U2M * delta
	move_and_slide()


func _fire(enemy: Node3D) -> void:
	var weapon_id := _best_weapon()
	var data := Weapons.get_weapon(weapon_id)
	if data.is_empty():
		return
	fire_cooldown = float(data.get("fire_rate", 0.1)) * randf_range(1.1, 2.4)
	var origin := eye_position()
	var dir := ((enemy.global_position + Vector3.UP * 1.35) - origin).normalized()
	var spread := lerpf(6.0, 1.2, skill)
	var angle := deg_to_rad(spread) * sqrt(randf())
	var up := Vector3.UP if absf(dir.dot(Vector3.UP)) < 0.98 else Vector3.RIGHT
	var right := dir.cross(up).normalized()
	up = right.cross(dir).normalized()
	var rotation := randf() * TAU
	var aim := (dir + right * sin(rotation) * tan(angle) + up * cos(rotation) * tan(angle)).normalized()
	var query := PhysicsRayQueryParameters3D.create(origin, origin + aim * float(data.get("range", 60.0)), 1 | (1 << 1))
	query.exclude = [get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return
	var collider := hit.get("collider") as Node
	if collider == null:
		return
	var victim: Node = collider
	while victim != null:
		if victim.has_method("apply_damage") and victim != self:
			var damage := int(data.get("damage", 20))
			var headshot := (hit["position"] as Vector3).y > victim.global_position.y + 1.5
			if headshot:
				damage = int(damage * Cfg.HEADSHOT_MULTIPLIER)
			victim.call("apply_damage", damage, display_name, headshot)
			return
		victim = victim.get_parent()


func _best_weapon() -> String:
	if has_bomb and plant_context:
		return "c4"
	var candidates := ["ak47", "m4a1", "mp5", "glock"]
	if team == "ct":
		candidates = ["m4a1", "mp5", "usp"]
	for id in candidates:
		if loadout.has(id):
			return id
	return "glock" if team == "t" else "usp"
