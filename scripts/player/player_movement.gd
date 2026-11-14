class_name PlayerMovement
extends CharacterBody3D
## GoldSrc `PM_Move` ported to Godot's `CharacterBody3D`.
##
## Everything in this class is in GoldSrc units (1 u = 0.0254 m) and converted
## once, at the boundary, so the numbers can be compared against `pm_shared.c`
## directly.  Gravity, acceleration, friction, air-strafing, ducking and
## ladders follow the retail constants in `Cfg`.

signal landed(impact_speed: float)

const HULL_RADIUS := 16.0
const STAND_HEIGHT := 72.0
const DUCK_HEIGHT := 54.0
const EYE_STAND := 64.0
const EYE_DUCK := 46.0

var on_ground := false
var was_on_ground := false
var ducking := false
var duck_amount := 0.0
var in_water := false
var water_level := 0.0
var ladder_normal := Vector3.ZERO
var speed_modifier := 1.0
var frozen := false
var input_enabled := true
var wish_dir := Vector3.ZERO
var jump_queued := false
var last_jump_time := -10.0
var fall_velocity := 0.0
var step_height := 18.0 * Cfg.U2M
var gravity_scale := 1.0

var _bob := 0.0
var _time := 0.0

@onready var capsule: CollisionShape3D = $Collider


func _ready() -> void:
	floor_max_angle = deg_to_rad(46.5)
	floor_snap_length = 4.0 * Cfg.U2M
	floor_stop_on_slope = false
	slide_on_ceiling = true
	wall_min_slide_angle = deg_to_rad(15.0)
	collision_layer = 1 << 1
	collision_mask = 1
	_apply_height(STAND_HEIGHT)


func _apply_height(height_units: float) -> void:
	if capsule == null:
		return
	var shape := CapsuleShape3D.new()
	var height := height_units * Cfg.U2M
	shape.radius = HULL_RADIUS * Cfg.U2M
	shape.height = maxf(height, shape.radius * 2.0 + 0.01)
	capsule.shape = shape
	capsule.position = Vector3(0.0, height * 0.5, 0.0)


## Read the intent (buttons) for this tick.  Called by the controller/bots.
func set_intent(move_dir: Vector3, crouch: bool, jump: bool, walk: bool = false) -> void:
	wish_dir = move_dir
	if crouch != ducking:
		set_ducking(crouch)
	if jump:
		jump_queued = true
	speed_modifier = Cfg.MAXSPEED_WALK / Cfg.MAXSPEED if walk else 1.0


func set_ducking(value: bool) -> void:
	if value == ducking:
		return
	if not value and not _can_stand():
		return
	ducking = value
	_apply_height(DUCK_HEIGHT if ducking else STAND_HEIGHT)
	if ducking:
		velocity.y = minf(velocity.y, 0.0)


func _can_stand() -> bool:
	if not is_inside_tree():
		return true
	var space := get_world_3d().direct_space_state
	var params := PhysicsShapeQueryParameters3D.new()
	var shape := CapsuleShape3D.new()
	shape.radius = HULL_RADIUS * Cfg.U2M * 0.98
	shape.height = STAND_HEIGHT * Cfg.U2M
	params.shape = shape
	params.transform = Transform3D(Basis(), global_position + Vector3.UP * STAND_HEIGHT * Cfg.U2M * 0.5)
	params.collision_mask = 1
	params.exclude = [get_rid()]
	return space.intersect_shape(params, 1).is_empty()


func _physics_process(delta: float) -> void:
	_time += delta
	_update_environment(delta)
	if not input_enabled or frozen:
		wish_dir = Vector3.ZERO
		jump_queued = false

	var wish_speed := _wish_speed()
	if on_ground:
		_apply_friction(delta)
		_accelerate(wish_dir, wish_speed, Cfg.ACCELERATE, delta)
	else:
		_air_accelerate(wish_dir, wish_speed, delta)

	if ladder_normal != Vector3.ZERO:
		_ladder_move(wish_speed, delta)

	_apply_gravity(delta)
	if in_water:
		_apply_water(delta)

	if jump_queued:
		jump_queued = false
		if on_ground or in_water:
			_jump()

	was_on_ground = on_ground
	var before := velocity.y
	move_and_slide()
	on_ground = is_on_floor()
	if on_ground and not was_on_ground:
		fall_velocity = maxf(0.0, -before / Cfg.U2M)
		landed.emit(fall_velocity)
	if on_ground and velocity.y < 0.0:
		velocity.y = 0.0
	duck_amount = move_toward(duck_amount, 1.0 if ducking else 0.0, delta / Cfg.CROUCH_TRANSITION)
	if on_ground and velocity.length() > 0.2:
		_bob += delta * velocity.length() * 1.6


func _wish_speed() -> float:
	var speed := Cfg.MAXSPEED
	if ducking:
		speed = Cfg.MAXSPEED_DUCK
	elif speed_modifier < 1.0:
		speed = Cfg.MAXSPEED * speed_modifier
	if ladder_normal != Vector3.ZERO:
		speed = Cfg.MAX_LADDER_SPEED
	return speed


func _apply_friction(delta: float) -> void:
	if in_water:
		return
	var speed := Vector2(velocity.x, velocity.z).length() / Cfg.U2M
	if speed < 0.1:
		return
	var control := maxf(speed, Cfg.STOPSPEED)
	var drop := control * Cfg.FRICTION * delta
	var new_speed := maxf(0.0, speed - drop)
	if new_speed != speed:
		var scale := new_speed / speed
		velocity.x *= scale
		velocity.z *= scale


func _accelerate(direction: Vector3, wish_speed: float, accel: float, delta: float) -> void:
	var wish_speed_units := wish_speed / Cfg.U2M
	var wish := direction
	var flat := Vector3(velocity.x, 0.0, velocity.z) / Cfg.U2M
	var current := flat.dot(wish)
	var add_speed := wish_speed_units - current
	if add_speed <= 0.0:
		return
	var accel_speed := minf(accel * wish_speed_units * delta, add_speed)
	velocity.x += wish.x * accel_speed * Cfg.U2M
	velocity.z += wish.z * accel_speed * Cfg.U2M


func _air_accelerate(direction: Vector3, wish_speed: float, delta: float) -> void:
	var wish_speed_units := minf(wish_speed / Cfg.U2M, Cfg.AIR_MAXSPEED)
	var flat := Vector3(velocity.x, 0.0, velocity.z) / Cfg.U2M
	var current := flat.dot(direction)
	var add_speed := wish_speed_units - current
	if add_speed <= 0.0:
		return
	var accel_speed := minf(Cfg.AIRACCELERATE * wish_speed_units * delta, add_speed)
	velocity.x += direction.x * accel_speed * Cfg.U2M
	velocity.z += direction.z * accel_speed * Cfg.U2M


func _apply_gravity(delta: float) -> void:
	if on_ground or ladder_normal != Vector3.ZERO:
		return
	var gravity := Cfg.GRAVITY * Cfg.U2M * gravity_scale
	if in_water:
		gravity *= 0.35
	velocity.y -= gravity * delta
	velocity.y = maxf(velocity.y, -60.0)


func _jump() -> void:
	if in_water:
		velocity.y = Cfg.JUMP_IMPULSE * Cfg.U2M * 0.6
	else:
		velocity.y = Cfg.JUMP_IMPULSE * Cfg.U2M
	last_jump_time = _time
	frozen = false


func _apply_water(delta: float) -> void:
	var submerge := float(water_level)
	if submerge <= 0.0:
		return
	velocity *= pow(0.92, delta * 64.0)
	var depth := submerge * (DUCK_HEIGHT if ducking else STAND_HEIGHT) * Cfg.U2M
	if depth > Cfg.SWIM_DEPTH:
		velocity.y += Cfg.WATER_BUOYANCY * (depth - Cfg.SWIM_DEPTH) * delta * 60.0 * Cfg.U2M


func _ladder_move(wish_speed: float, delta: float) -> void:
	var up := -ladder_normal
	var along := wish_dir.dot(up)
	velocity += up * along * wish_speed * Cfg.U2M * delta * 8.0
	velocity.y = clampf(velocity.y, -Cfg.MAX_LADDER_SPEED * Cfg.U2M, Cfg.MAX_LADDER_SPEED * Cfg.U2M)


func _update_environment(delta: float) -> void:
	on_ground = is_on_floor()
	var feet := global_position
	var surface := _water_surface(feet)
	if surface != NAN and feet.y < surface:
		in_water = true
		var height := (DUCK_HEIGHT if ducking else STAND_HEIGHT) * Cfg.U2M
		water_level = clampf((surface - feet.y) / height, 0.0, 1.0)
	else:
		in_water = false
		water_level = 0.0
	_update_ladder()


func _water_surface(at: Vector3) -> float:
	var parent := get_parent()
	if parent == null:
		return NAN
	var loader := parent.get_node_or_null("MapLoader") as MapLoader
	if loader == null:
		return NAN
	return loader.water_surface_at(at)


func _update_ladder() -> void:
	ladder_normal = Vector3.ZERO
	if not is_inside_tree():
		return
	var space := get_world_3d().direct_space_state
	var forwards := -global_transform.basis.z
	for probe in [Vector3(0, 0.9, 0), Vector3(0, 0.1, 0), Vector3(0, -0.6, 0)]:
		var from := global_position + probe
		var query := PhysicsRayQueryParameters3D.create(from, from + forwards * 0.5, 1)
		query.exclude = [get_rid()]
		var hit := space.intersect_ray(query)
		if hit.is_empty():
			continue
		var collider := hit.get("collider")
		if collider == null:
			continue
		if str(collider.get_meta("surface", "")) in ["ladder", "trigger_ladder"]:
			ladder_normal = (hit["normal"] as Vector3).normalized()
			return


func eye_height() -> float:
	var stand := EYE_STAND * Cfg.U2M
	var duck := EYE_DUCK * Cfg.U2M
	return lerpf(stand, duck, duck_amount)


func bob_offset() -> Vector3:
	if not on_ground or velocity.length() < 0.5:
		return Vector3.ZERO
	var amount := 0.012 * minf(velocity.length() / Cfg.MAXSPEED, 1.0)
	return Vector3(sin(_bob) * amount, -absf(cos(_bob)) * amount * 0.7, 0.0)
