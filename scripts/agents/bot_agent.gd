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
## Seconds a bot holds a reached spot before repositioning inside the site.
const HOLD_TIME := 8.0

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
## Set during freeze time: hold position and do not shoot.
var frozen := false
## Lateral bias (-1..1) applied to the walk vector so bots do not stack.
var approach_offset := 0.0
## Bomb objective: the T carrying the C4, and the CT with a defuse kit.
var bomb_carrier := false
var has_defuse_kit := false
var match_state: MatchState
var _action_timer := 0.0
var _stuck_time := 0.0
var _hold_cooldown := 0.0
var _heading := Vector3.ZERO
var _carrier_stall := 0
var _carrier_stuck_for := 0.0
var _best_goal_distance := INF
var _goal_site_choice := ""
var _stuck_count := 0
var _last_position := Vector3.ZERO


func configure(skill_value: float, weapons: Array) -> void:
	skill = clampf(skill_value, 0.05, 0.98)
	approach_offset = randf_range(-0.22, 0.22)
	loadout = weapons.duplicate()
	move_speed = 3.6 + skill * 1.6


func think(delta: float, enemies: Array, site_positions: Dictionary) -> void:
	if not alive:
		return
	if frozen:
		velocity.x = 0.0
		velocity.z = 0.0
		if not is_on_floor():
			velocity.y -= Cfg.GRAVITY * Cfg.U2M * delta
		else:
			velocity.y = -0.1
		move_and_slide()
		return
	fire_cooldown = maxf(0.0, fire_cooldown - delta)
	reaction = maxf(0.0, reaction - delta)
	# A held bot still has to count down: the early return below would
	# otherwise leave it standing on its first hold for the rest of the round.
	if state == State.HOLD:
		_hold_cooldown -= delta
		if _hold_cooldown <= 0.0:
			state = State.ADVANCE
			goal_site = ""
			_goal_site_choice = ""
	# Objective first: a T standing in a site with the C4 plants it, and a CT
	# standing on a planted C4 defuses. Both actions are interruptible.
	if _run_objective(delta, site_positions):
		return
	var enemy := _closest_visible(enemies)
	if enemy != null:
		state = State.ENGAGE
		_aim_at(enemy, delta)
		if reaction <= 0.0 and fire_cooldown <= 0.0 and global_position.distance_to(enemy.global_position) < FIRE_RANGE:
			_fire(enemy)
		_strafe(delta, enemy)
		return

	# A planted C4 overrides every other goal: CTs converge on it, Ts guard it.
	if match_state != null and match_state.bomb_state == "planted":
		if state == State.HOLD:
			state = State.ADVANCE
			goal_site = ""
		if team == "ct":
			if global_position.distance_to(match_state.bomb_position) < 1.6:
				state = State.DEFUSE
				return
			target_position = match_state.bomb_position
		else:
			var guard := match_state.bomb_position
			var away := global_position - guard
			away.y = 0.0
			if away.length() < 6.0 and away.length() > 0.1:
				target_position = guard + away.normalized() * 7.0
			else:
				target_position = guard
		state = State.ADVANCE
		_walk_to(target_position, delta, site_positions)
		return

	var desired := goal_site
	if desired.is_empty() and not site_positions.is_empty():
		var keys := site_positions.keys()
		keys.sort()
		# The C4 carrier picks the site the whole T side commits to, so the team
		# does not split up and leave the bomb unprotected.
		goal_site = str(keys[randi() % keys.size()])
		desired = goal_site
	if not desired.is_empty() and site_positions.has(desired):
		var goal: Dictionary = site_positions[desired]
		# Pick the goal once per approach, not every frame: a target that is
		# re-randomised each tick can never be reached, so the bot both jitters
		# in place and reports no progress forever.
		if _goal_site_choice != desired:
			_goal_site_choice = desired
			# Walk to a spot *inside* the site rather than the shared centre, so
			# a squad does not stand in one pile. An interior point can still be
			# out of the hull's reach (chateau's A sits on a shelf the stairs
			# barely reach), so fall back to the nearest walkable point to the
			# centre.
			target_position = _reachable(_scatter(goal))
			var centre: Vector3 = goal.get("pos", Vector3.ZERO)
			var drift := target_position - centre
			drift.y = 0.0
			if drift.length() > Cfg.SITE_REACH * Cfg.U2M:
				target_position = _reachable(centre)
			_best_goal_distance = INF

		state = State.ADVANCE
		_best_goal_distance = INF
	_walk_to(target_position, delta, site_positions)


func _run_objective(delta: float, site_positions: Dictionary) -> bool:
	## Returns true when the bot is busy planting/defusing this frame.
	if match_state == null or match_state.phase != MatchState.Phase.LIVE:
		_cancel_action()
		return false
	if team == "t" and bomb_carrier and match_state.bomb_state == "carried":
		var site := _site_at(global_position, site_positions)
		if site.is_empty():
			_action_timer = 0.0
			return false
		state = State.PLANT
		_action_timer += delta
		velocity.x = 0.0
		velocity.z = 0.0
		_hold_still(delta)
		if _action_timer >= Cfg.BOMB_PLANT_TIME:
			match_state.plant_bomb(site, global_position)
			bomb_carrier = false
			has_bomb = false
			_cancel_action()
		return true
	if team == "ct" and match_state.bomb_state == "planted":
		if global_position.distance_to(match_state.bomb_position) > 1.6:
			_cancel_action()
			return false
		state = State.DEFUSE
		_action_timer += delta
		velocity.x = 0.0
		velocity.z = 0.0
		_hold_still(delta)
		var need: float = Cfg.BOMB_DEFUSE_KIT_TIME if has_defuse_kit else Cfg.BOMB_DEFUSE_TIME
		if _action_timer >= need:
			match_state.defuse_bomb()
			_cancel_action()
		return true
	_cancel_action()
	return false


func _hold_still(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= Cfg.GRAVITY * Cfg.U2M * delta
	else:
		velocity.y = -0.1
	move_and_slide()


func _cancel_action() -> void:
	_action_timer = 0.0
	if state == State.PLANT or state == State.DEFUSE:
		state = State.ADVANCE


func is_planting() -> bool:
	return state == State.PLANT


func is_defusing() -> bool:
	return state == State.DEFUSE


## Radius in metres inside which a T may plant on a site.
const PLANT_RADIUS := 7.0


func _site_at(position: Vector3, site_positions: Dictionary) -> String:
	## The bombsite whose brush volume contains the bot.

	## Sites are 6-19 m across, so a radius around the centre misses the
	## corners of the big ones (Inferno B is 11x11 m); test the real bounds.
	for name in site_positions.keys():
		var site: Dictionary = site_positions[name]
		var lo: Vector3 = site.get("min", Vector3.ZERO)
		var hi: Vector3 = site.get("max", Vector3.ZERO)
		if hi == Vector3.ZERO and lo == Vector3.ZERO:
			var flat: Vector3 = site.get("pos", Vector3.ZERO) - position
			flat.y = 0.0
			if flat.length() <= PLANT_RADIUS:
				return str(name)
			continue
		# Horizontal containment only: the func_bomb_target brush often floats
		# a couple of units above the floor the bot actually stands on.
		if (position.x >= lo.x - 0.6 and position.x <= hi.x + 0.6
				and position.z >= lo.z - 0.6 and position.z <= hi.z + 0.6):
			return str(name)
	return ""


func plant_time_left() -> float:
	return maxf(0.0, Cfg.BOMB_PLANT_TIME - _action_timer)


func _walk_to(target: Vector3, delta: float, sites: Dictionary) -> void:
	var flat := target - global_position
	flat.y = 0.0
	if flat.length() < 1.5:
		# Reached the goal: hold it for a while and then pick a fresh spot
		# inside the site instead of freezing here. Only arm the timer on the
		# transition, otherwise re-entering every frame would restart it.
		if state != State.HOLD:
			state = State.HOLD
			_hold_cooldown = HOLD_TIME
		return
	var path := _next_path_point(target)
	var dir := (path - global_position)
	dir.y = 0.0
	if dir.length() < 0.05:
		return
	dir = dir.normalized()
	_heading = dir
	# Spread the team out on the way in: a per-bot lateral offset keeps squad
	# mates from walking the exact same line into the same wall.
	dir = (dir + dir.cross(Vector3.UP) * approach_offset).normalized()
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
	# GoldSrc maps are full of 18-unit steps and CharacterBody3D cannot climb
	# them on its own, so a bot walking at a step would wedge into it forever.
	if is_on_wall():
		_try_step_up(dir)
	_detect_stuck(delta, sites)



func _try_step_up(dir: Vector3) -> void:
	## Climb a step the hull bumped into: lift, push forward, drop back down.
	## The move is kept only when the bot ends up on the floor and further
	## along than it started, so walls taller than a step are left alone.
	if not is_on_floor():
		return
	var start := global_position
	var step := Cfg.STEP_SIZE * Cfg.U2M
	for rise in [step, step * 1.5]:
		global_position.y += rise
		velocity.y = 0.0
		var moved := move_and_collide(dir * 0.4)
		move_and_collide(Vector3(0.0, -(rise + 0.25), 0.0))
		var progress := Vector2(global_position.x - start.x, global_position.z - start.z).length()
		if is_on_floor() and progress > 0.08 and global_position.y > start.y - 0.05:
			velocity.y = -0.1
			return
		global_position = start
	# Nothing climbable: undo and let the stuck recovery pick another line.
	global_position = start
	velocity.y = -0.1


func _detect_stuck(delta: float, sites: Dictionary) -> void:
	## Walking into a doorway lintel or a ledge lip is common in GoldSrc
	## geometry. Judge progress by distance to the goal rather than by motion:
	## a bot jinking against a wall moves every frame while getting nowhere,
	## and that is exactly what strands a carrier (and therefore a round).
	_stuck_time += delta
	if _stuck_time < 0.4:
		return
	var goal_distance := 0.0
	if target_position != Vector3.ZERO:
		var to_goal := target_position - global_position
		to_goal.y = 0.0
		goal_distance = to_goal.length()
	if goal_distance < _best_goal_distance - 0.4:
		# Real progress: try again from here.
		_best_goal_distance = goal_distance
		_stuck_time = 0.0
		_stuck_count = 0
		_carrier_stall = 0
		_carrier_stuck_for = 0.0
		return
	if goal_distance > _best_goal_distance + 2.0:
		# Lost ground (knocked back, or a fresh goal): start over.
		_best_goal_distance = goal_distance
		_stuck_time = 0.0
		_stuck_count = 0
		return
	_stuck_count += 1
	_stuck_time = 0.0
	if _stuck_count < 3:
		return
	_stuck_count = 0
	# A carrier that cannot reach the site strands the whole round (nobody
	# plants and the CTs just wait). Give it a fresh approach line, and if
	# that keeps failing, move it to the site outright.
	if bomb_carrier:
		_carrier_stall += 1
		_carrier_stuck_for += 1.2
		if _carrier_stuck_for > Cfg.CARRIER_RESCUE_AFTER:
			_carrier_stuck_for = 0.0
			_rescue_carrier(sites)
			return
		if _carrier_stall >= 6:
			_carrier_stall = 0
			goal_site = ""
			_goal_site_choice = ""
	approach_offset = -approach_offset if absf(approach_offset) > 0.05 else randf_range(-0.3, 0.3)
	# Hop: the lip is often just above the step height.
	if is_on_floor():
		velocity.y = Cfg.JUMP_IMPULSE * Cfg.U2M
	_climb_ledge()


func _rescue_carrier(sites: Dictionary) -> void:
	## Last resort for a carrier that cannot path to the site: drop it on the
	## navmesh next to the site it committed to. The bomb must not be able to
	## strand a round, and every other failure above has already been tried.
	var site := goal_site
	if site.is_empty() or not sites.has(site):
		return
	var goal: Dictionary = sites[site]
	var landing := _reachable(goal.get("pos", Vector3.ZERO))
	if landing == Vector3.ZERO:
		return
	global_position = landing + Vector3.UP * 0.1
	velocity = Vector3.ZERO
	goal_site = ""
	_goal_site_choice = ""
	_best_goal_distance = INF


func _climb_ledge() -> void:
	## Some routes start with a ledge a metre high that the hull can neither
	## walk nor jump onto (survivor's ridge). The navmesh already connects
	## across it, so step up directly -- but only for a genuine ledge: a rise
	## reached within a short distance, with head room above the landing.
	var map := get_world_3d().navigation_map
	if NavigationServer3D.map_get_iteration_id(map) == 0:
		return
	var here := NavigationServer3D.map_get_closest_point(map, global_position)
	var ahead := NavigationServer3D.map_get_closest_point(map, global_position + _heading * 0.9)
	var rise := ahead.y - here.y
	if rise < 0.5 or rise > 1.6:
		return
	if Vector2(ahead.x - global_position.x, ahead.z - global_position.z).length() > 1.0:
		return
	var space := get_world_3d().direct_space_state
	var probe := ahead + Vector3(0.0, 0.15, 0.0)
	var query := PhysicsRayQueryParameters3D.create(probe, probe + Vector3(0.0, 1.9, 0.0))
	if not space.intersect_ray(query).is_empty():
		return
	global_position = Vector3(ahead.x, global_position.y + rise + 0.05, ahead.z)
	velocity.y = -0.1


func _scatter(goal: Dictionary) -> Vector3:
	## A per-bot point inside the site box (or near the centre when the payload
	## has no bounds), so several bots can hold a site side by side.
	var centre: Vector3 = goal.get("pos", Vector3.ZERO)
	var lo: Vector3 = goal.get("min", Vector3.ZERO)
	var hi: Vector3 = goal.get("max", Vector3.ZERO)
	if hi == Vector3.ZERO and lo == Vector3.ZERO:
		return centre
	var spot := centre
	spot.x = lerpf(lo.x + 1.0, hi.x - 1.0, 0.5 + approach_offset)
	spot.z = lerpf(lo.z + 1.0, hi.z - 1.0, 0.5 + randf_range(-0.35, 0.35))
	spot.y = centre.y
	return spot


func _reachable(target: Vector3) -> Vector3:
	## Nearest point on the navmesh, so a goal inside a brush or on a ledge does
	## not send the bot into a wall it can never climb.
	var map: RID = get_world_3d().navigation_map
	if NavigationServer3D.map_get_iteration_id(map) == 0:
		return target
	return NavigationServer3D.map_get_closest_point(map, target)


func _next_path_point(target: Vector3) -> Vector3:
	var navigation := NavigationServer3D.map_get_iteration_id(get_world_3d().navigation_map)
	if navigation == 0:
		return target
	var from := NavigationServer3D.map_get_closest_point(get_world_3d().navigation_map, global_position)
	var to := NavigationServer3D.map_get_closest_point(get_world_3d().navigation_map, target)
	var path := NavigationServer3D.map_get_path(get_world_3d().navigation_map, from, to, true)

	# A path of one point (or zero) means the query failed; walking straight at
	# the target then pushes every bot into the same wall corner.
	if path.size() < 2:
		return global_position
	# Skip waypoints we have already reached, otherwise a bot hovering on a
	# navigation polygon edge keeps aiming at the point behind it.
	var point := path[1]
	for index in range(1, path.size()):
		if global_position.distance_to(path[index]) > 0.6:
			point = path[index]
			break
	return point


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
	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	var from := eye_position()
	var to := enemy.global_position + Vector3.UP * 1.4
	var query := PhysicsRayQueryParameters3D.create(from, to, 1)
	query.exclude = [get_rid()]
	var hit: Dictionary = space.intersect_ray(query)
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
	var hit: Dictionary = get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return
	var collider := hit.get("collider") as Node
	if collider == null:
		return
	var victim: Node = collider
	while victim != null:
		if victim.has_method("apply_damage") and victim != self:
			var damage := int(data.get("damage", 20))
			var headshot: bool = (hit["position"] as Vector3).y > victim.global_position.y + 1.5
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
