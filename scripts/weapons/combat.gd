class_name Combat
extends Node
## Hitscan resolution, damage falloff, penetration and spread.
##
## A shot is a ray (or a cone of rays for shotguns) from the camera.  Damage
## falls off linearly after `falloff_start` and is reduced by armour exactly the
## way GoldSrc's `CTakeDamageInfo` does it, including the headshot multiplier.

signal shot_fired(from: Vector3, to: Vector3, hit: bool, victim: Node)
signal player_hit(victim: Node, damage: int, headshot: bool)
signal noise(position: Vector3, loudness: float)

const HEAD_RADIUS := 0.11
const LIMB_DAMAGE_SCALE := 0.75
const GRAVITY_ARM := 0.0

var owner_controller: PlayerController
var hitscan_mask := 1 | (1 << 1) | (1 << 3)
var last_impact: Vector3
var rng := RandomNumberGenerator.new()


func setup(controller: PlayerController) -> void:
	owner_controller = controller
	rng.randomize()


## Fire one logical shot for `weapon_id`, returning the damage dealt.
func fire(weapon_id: String, origin: Vector3, direction: Vector3, inaccuracy_deg: float) -> int:
	var data := Weapons.get_weapon(weapon_id)
	if data.is_empty():
		return 0
	var pellets := int(data.get("pellets", 1))
	var total_damage := 0
	for index in pellets:
		var spread := inaccuracy_deg + float(data.get("spread_degrees", 0.0)) * 0.5
		var dir := _spread(direction, spread)
		total_damage += _trace(weapon_id, data, origin, dir)
	noise.emit(origin, _loudness(weapon_id))
	return total_damage


func _trace(weapon_id: String, data: Dictionary, origin: Vector3, direction: Vector3) -> int:
	var space := get_world_3d().direct_space_state
	var max_range := float(data.get("range", 100.0))
	var query := PhysicsRayQueryParameters3D.create(origin, origin + direction * max_range, hitscan_mask)
	if owner_controller != null and owner_controller.body != null:
		query.exclude = [owner_controller.body.get_rid()]
	query.collide_with_areas = false
	var hit := space.intersect_ray(query)
	if hit.is_empty():
		shot_fired.emit(origin, origin + direction * max_range, false, null)
		return 0
	var point: Vector3 = hit["position"]
	var collider: Object = hit["collider"]
	last_impact = point
	var damage := int(data.get("damage", 0))
	var headshot := false
	var victim := _resolve_victim(collider, point)
	if victim != null and damage > 0:
		headshot = _is_headshot(victim, point)
		var distance := origin.distance_to(point)
		damage = _falloff(damage, distance, max_range)
		if headshot:
			damage = int(round(float(damage) * Cfg.HEADSHOT_MULTIPLIER))
		_apply_hit(victim, damage, weapon_id, headshot)
		player_hit.emit(victim, damage, headshot)
	elif damage > 0:
		_spawn_impact(point, hit["normal"])
	shot_fired.emit(origin, point, true, victim if victim != null else collider)
	return damage


func _falloff(damage: int, distance: float, max_range: float) -> int:
	var start := max_range * 0.35
	if distance <= start:
		return damage
	var t := clampf((distance - start) / maxf(0.001, max_range - start), 0.0, 1.0)
	return int(round(lerpf(float(damage), float(damage) * 0.45, t)))


func _spread(direction: Vector3, degrees: float) -> Vector3:
	if degrees <= 0.001:
		return direction
	var up := Vector3.UP if absf(direction.dot(Vector3.UP)) < 0.98 else Vector3.RIGHT
	var right := direction.cross(up).normalized()
	up = right.cross(direction).normalized()
	var angle := deg_to_rad(degrees) * sqrt(rng.randf())
	var rotation := rng.randf() * TAU
	return (direction + right * sin(rotation) * tan(angle) + up * cos(rotation) * tan(angle)).normalized()


func _resolve_victim(collider: Object, point: Vector3) -> Node:
	if collider == null:
		return null
	var node := collider as Node
	while node != null:
		if node.has_method("apply_damage") and node.is_in_group("damageable"):
			return node
		if node is PlayerController:
			return node
		node = node.get_parent()
	return null


func _is_headshot(victim: Node, point: Vector3) -> bool:
	var head: Node3D = victim.get_node_or_null("Head") as Node3D
	if head == null:
		head = victim.get_node_or_null("Body/Head") as Node3D
	if head == null:
		var eye: Vector3 = victim.call("eye_position") if victim.has_method("eye_position") else victim.global_position
		return point.y > eye.y - HEAD_RADIUS
	return point.distance_to(head.global_position) <= HEAD_RADIUS * 1.4


func _apply_hit(victim: Node, damage: int, weapon_id: String, headshot: bool) -> void:
	var attacker := owner_controller.player_name if owner_controller != null else "world"
	if victim.has_method("apply_damage"):
		victim.call("apply_damage", damage, attacker, headshot)
	elif victim.has_method("take_damage"):
		victim.call("take_damage", damage)
	_spawn_impact(victim.global_position, -_flat_direction(victim), true)


func _flat_direction(target: Node) -> Vector3:
	if owner_controller == null:
		return Vector3.UP
	return (target.global_position - owner_controller.eye_position()).normalized()


func _spawn_impact(point: Vector3, normal: Vector3, blood: bool = false) -> void:
	var parent := get_parent()
	var holder := parent.get_node_or_null("Effects") as Node3D
	if holder == null:
		return
	var color := Color(0.55, 0.06, 0.06) if blood else Color(0.82, 0.78, 0.66)
	var burst := CPUParticles3D.new()
	burst.one_shot = true
	burst.amount = 7
	burst.lifetime = 0.45
	burst.explosiveness = 1.0
	burst.direction = normal
	burst.spread = 35.0
	burst.initial_velocity_min = 1.4
	burst.initial_velocity_max = 3.6
	burst.gravity = Vector3(0.0, -9.0, 0.0)
	burst.scale_amount_min = 0.015
	burst.scale_amount_max = 0.035
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	var mesh := SphereMesh.new()
	mesh.radius = 1.0
	mesh.height = 2.0
	mesh.material = material
	burst.mesh = mesh
	holder.add_child(burst)
	burst.global_position = point
	burst.emitting = true
	get_tree().create_timer(1.2).timeout.connect(burst.queue_free)


func _loudness(weapon_id: String) -> float:
	var data := Weapons.get_weapon(weapon_id)
	return 30.0 if str(data.get("slot", "")) in ["primary", "secondary"] else 8.0
