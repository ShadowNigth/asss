class_name PlayerController
extends Node3D
## First-person rig: movement body + `Camera3D` + viewmodel + weapon handling.
##
## The controller never touches map geometry directly: it feeds input to
## `PlayerMovement` (physics tick) and the camera/viewmodel follow the body in
## `_process`, so mouse look stays smooth at monitor refresh rate.

signal weapon_changed(id: String)
signal health_changed(health: int, armor: int)
signal died(killer: String)
signal killed(victim: String, killer: String, weapon: String, headshot: bool)
## Emitted while the C4 is being planted or defused, so the HUD can show a
## progress bar; `progress` is 0..1 and `label` is what is being done.
signal objective_progress(progress: float, label: String)
signal objective_cancelled

const MOUSE_SENSITIVITY := 0.0022
const PITCH_LIMIT := deg_to_rad(89.0)
const VIEWMODEL_FOV := 54.0

var body: PlayerMovement
var camera: Camera3D
var viewmodel: ViewModel
var weapon_manager: WeaponManager
var combat: Combat

var health := 100
var armor := 0
var helmet := false
var team := "t"
var player_name := "player"
var alive := true
var mouse_captured := false
var yaw := 0.0
var pitch := 0.0
var recoil_offset := Vector2.ZERO
var fov_target := Cfg.FOV
var zoom_level := 0
## Round state, injected by `Game` so the local player can plant and defuse.
var match_state: MatchState
var has_defuse_kit := false
var has_bomb := false
var _objective_timer := 0.0
var _objective_kind := ""
var _step_distance := 0.0

var _mouse_blocked := false


func setup(spawn: Dictionary, team_name: String, allow_mouse: bool) -> void:
	team = team_name
	player_name = "Player"
	global_position = spawn.get("pos", Vector3.ZERO)
	yaw = deg_to_rad(float(spawn.get("yaw", 0.0)))
	rotation.y = yaw
	_create_body()
	_create_camera()
	_create_viewmodel()
	weapon_manager = WeaponManager.new()
	weapon_manager.name = "WeaponManager"
	add_child(weapon_manager)
	weapon_manager.setup(self)
	combat = Combat.new()
	combat.name = "Combat"
	add_child(combat)
	combat.setup(self)
	_mouse_blocked = not allow_mouse
	if allow_mouse and not Cfg.headless_display and not Cfg.no_mouse:
		capture_mouse()
	health_changed.emit(health, armor)


func _create_body() -> void:
	body = PlayerMovement.new()
	body.name = "Body"
	var collider := CollisionShape3D.new()
	collider.name = "Collider"
	body.add_child(collider)
	add_child(body)
	# The body simulates in world space and the rig simply follows it; without
	# `top_level` the parent's own motion would feed back into the body and
	# double every displacement (it made the player fall through the map).
	body.top_level = true
	body.global_position = global_position


func _create_camera() -> void:
	camera = Camera3D.new()
	camera.name = "Camera"
	camera.fov = Cfg.FOV
	camera.near = 0.03
	camera.far = 900.0
	camera.current = true
	add_child(camera)


func _create_viewmodel() -> void:
	viewmodel = ViewModel.new()
	viewmodel.name = "Viewmodel"
	camera.add_child(viewmodel)
	viewmodel.position = Vector3(0.14, -0.14, -0.28)
	viewmodel.setup(camera)


func capture_mouse() -> void:
	if _mouse_blocked or Cfg.headless_display:
		return
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	mouse_captured = true


func release_mouse() -> void:
	if Cfg.headless_display:
		return
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	mouse_captured = false


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and mouse_captured:
		var motion := event as InputEventMouseMotion
		yaw -= motion.relative.x * MOUSE_SENSITIVITY * (1.0 / maxf(0.3, zoom_level_scale()))
		pitch = clampf(pitch - motion.relative.y * MOUSE_SENSITIVITY, -PITCH_LIMIT, PITCH_LIMIT)
	elif event is InputEventMouseButton and event.pressed and not mouse_captured:
		if not _mouse_blocked:
			capture_mouse()
	elif event.is_action_pressed("pause"):
		if mouse_captured:
			release_mouse()
		else:
			capture_mouse()


func zoom_level_scale() -> float:
	if zoom_level <= 0:
		return 1.0
	return 0.55


func _process(delta: float) -> void:
	if body == null:
		return
	global_position = body.global_position
	rotation.y = yaw
	var eye := body.eye_height()
	var bob := body.bob_offset()
	camera.position = bob + Vector3(0.0, eye, 0.0)
	recoil_offset = recoil_offset.lerp(Vector2.ZERO, clampf(delta * 7.0, 0.0, 1.0))
	camera.rotation = Vector3(pitch + recoil_offset.y, recoil_offset.x, 0.0)
	camera.fov = lerpf(camera.fov, fov_target, clampf(delta * 8.0, 0.0, 1.0))
	if viewmodel != null:
		viewmodel.tick(delta, body.velocity, body.on_ground)
	_tick_footsteps(delta)


func _physics_process(delta: float) -> void:
	if body == null or not alive:
		_cancel_objective()
		return
	if _tick_objective(delta):
		return
	var input_dir := Vector2.ZERO
	if body.input_enabled and mouse_captured or (body.input_enabled and Cfg.no_mouse):
		input_dir = Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var forward := -global_transform.basis.z
	var right := global_transform.basis.x
	var wish := (right * input_dir.x + forward * -input_dir.y)
	if wish.length() > 1.0:
		wish = wish.normalized()
	body.set_intent(wish, Input.is_action_pressed("crouch"), Input.is_action_just_pressed("jump"), Input.is_action_pressed("walk"))
	if weapon_manager != null:
		weapon_manager.tick(delta, Input.is_action_pressed("fire"), Input.is_action_just_pressed("fire"),
			Input.is_action_pressed("alt_fire"), Input.is_action_just_pressed("reload"))


func _tick_footsteps(delta: float) -> void:
	## Steps are distance-driven, so walking is quiet and running is not.
	if body == null or not body.on_ground:
		return
	var speed := Vector2(body.velocity.x, body.velocity.z).length()
	if speed < 0.6:
		_step_distance = 0.0
		return
	_step_distance += speed * delta
	if _step_distance < 2.1:
		return
	_step_distance = 0.0
	Sound.footstep(global_position, false)


func add_armor(amount: int, with_helmet: bool) -> void:
	armor = clampi(amount, 0, 100)
	if with_helmet:
		helmet = true
	health_changed.emit(health, armor)


func _site_here() -> String:
	## The bombsite whose brush volume the player is standing in. Sites are up
	## to 19 m across, so the real bounds decide, not a radius round the centre.
	if match_state == null:
		return ""
	return match_state.site_at(global_position)


func _tick_objective(delta: float) -> bool:
	## Planting and defusing mirror the bot rules: hold the use key, stand
	## still, and the timer resets if you walk away or the state changes.
	if match_state == null or match_state.phase != MatchState.Phase.LIVE:
		_cancel_objective()
		return false
	var kind := ""
	var want := 0.0
	if team == "t" and has_bomb and match_state.bomb_state == "carried":
		kind = "plant" if not _site_here().is_empty() else ""
		want = Cfg.BOMB_PLANT_TIME
	elif team == "ct" and match_state.bomb_state == "planted":
		var near := global_position.distance_to(match_state.bomb_position) <= 1.9
		kind = "defuse" if near else ""
		want = Cfg.BOMB_DEFUSE_KIT_TIME if has_defuse_kit else Cfg.BOMB_DEFUSE_TIME
	if kind.is_empty():
		_cancel_objective()
		return false
	if not Input.is_action_pressed("use"):
		_cancel_objective()
		objective_progress.emit(0.0, "get closer" if kind == "defuse" else "hold use to plant")
		return false
	if _objective_kind != kind:
		_objective_kind = kind
		_objective_timer = 0.0
	# Standing still is required: any movement cancels the action, as in retail.
	body.set_intent(Vector3.ZERO, Input.is_action_pressed("crouch"), false, false)
	_objective_timer += delta
	objective_progress.emit(clampf(_objective_timer / want, 0.0, 1.0), "planting" if kind == "plant" else "defusing")
	if _objective_timer >= want:
		if kind == "plant":
			match_state.plant_bomb(_site_here(), global_position)
			has_bomb = false
		else:
			match_state.defuse_bomb()
		_cancel_objective()
	return true


func _cancel_objective() -> void:
	if _objective_kind.is_empty():
		return
	_objective_kind = ""
	_objective_timer = 0.0
	objective_cancelled.emit()


func apply_damage(amount: int, from: String = "", headshot: bool = false, weapon: String = "") -> void:
	if not alive:
		return
	var damage := amount
	if armor > 0:
		var absorbed := clampf(float(amount) * Cfg.ARMOR_ABSORB, 0.0, float(armor))
		armor = maxi(0, armor - int(absorbed * Cfg.ARMOR_BONUS))
		damage = amount - int(absorbed * (1.0 - Cfg.ARMOR_BONUS))
	health -= damage
	health_changed.emit(maxi(health, 0), armor)
	if health <= 0:
		alive = false
		health = 0
		body.frozen = true
		killed.emit(player_name, from, weapon, headshot)
		died.emit(from)


func heal(amount: int) -> void:
	health = mini(100, health + amount)
	health_changed.emit(health, armor)


func eye_position() -> Vector3:
	return camera.global_position if camera != null else global_position + Vector3.UP * 1.6


func aim_direction() -> Vector3:
	if camera == null:
		return -global_transform.basis.z
	return -camera.global_transform.basis.z


func teleport_to(spawn: Dictionary) -> void:
	# A round restart also revives the player; without this the corpse flag and
	# the frozen body carry over and the player never moves again.
	alive = true
	health = 100
	global_position = spawn.get("pos", Vector3.ZERO)
	body.global_position = global_position
	yaw = deg_to_rad(float(spawn.get("yaw", 0.0)))
	rotation.y = yaw
	pitch = 0.0
	body.velocity = Vector3.ZERO
	body.frozen = false
	health_changed.emit(health, armor)
