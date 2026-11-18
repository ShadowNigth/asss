class_name Grenade
extends Node3D
## A thrown projectile: HE, flashbang or smoke, simulated as a bouncing body.
##
## Retail grenades are simple ballistics -- throw, bounce with friction, fuse
## out after `fuse` seconds -- and the effect is an area test rather than a
## volume query, so a raycast against the world is enough for the bounce.
## The node owns its own mesh so it is visible while it flies, which is what a
## player actually needs to judge a throw.

const RADIUS := 0.09
const FRICTION := 0.55
const RESTITUTION := 0.42
const GRAVITY := 800.0 * 0.0254 * 3.0

var kind := "hegrenade"
var velocity := Vector3.ZERO
var fuse := 2.4
var owner_name := ""
var owner_team := ""
var damage := 98.0
var radius := 6.5

var _mesh: MeshInstance3D
var _light: OmniLight3D
var _fuse_left := 0.0
var _resting := false


func launch(from: Vector3, direction: Vector3, speed: float, thrower: String, team: String) -> void:
	kind = kind.to_lower()
	global_position = from + direction * 0.35
	velocity = direction * speed + Vector3.UP * 2.4
	owner_name = thrower
	owner_team = team
	_fuse_left = fuse
	match kind:
		"flashbang":
			damage = 0.0
			radius = 7.0
		"smokegrenade":
			damage = 0.0
			radius = 5.0
		_:
			damage = 98.0
			radius = 6.5
	_build()


func _build() -> void:
	if _mesh != null:
		return
	_mesh = MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = RADIUS
	sphere.height = RADIUS * 2.0
	sphere.radial_segments = 8
	sphere.rings = 4
	_mesh.mesh = sphere
	var material := StandardMaterial3D.new()
	match kind:
		"flashbang":
			material.albedo_color = Color(0.85, 0.86, 0.9)
		"smokegrenade":
			material.albedo_color = Color(0.35, 0.45, 0.32)
		_:
			material.albedo_color = Color(0.32, 0.34, 0.22)
	_mesh.material_override = material
	add_child(_mesh)
	_light = OmniLight3D.new()
	_light.light_color = Color(1.0, 0.55, 0.2)
	_light.light_energy = 0.6
	_light.omni_range = 2.0
	_light.visible = kind == "hegrenade"
	add_child(_light)


func _physics_process(delta: float) -> void:
	_fuse_left -= delta
	if _fuse_left <= 0.0:
		detonate()
		return
	if _resting:
		return
	var motion := velocity * delta
	var space := get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(global_position, global_position + motion + motion.normalized() * RADIUS, 1)
	var hit := space.intersect_ray(query)
	if hit.is_empty():
		global_position += motion
		velocity.y -= GRAVITY * delta
		velocity *= 0.995
		return
	## Bounce: reflect on the surface normal, lose energy, and stop sliding
	## once the bounce is small enough to look like rolling.
	var normal: Vector3 = (hit["normal"] as Vector3).normalized()
	global_position = (hit["position"] as Vector3) + normal * RADIUS
	var into := velocity.dot(normal)
	velocity -= normal * into * (1.0 + RESTITUTION)
	velocity *= FRICTION
	if velocity.length() > 1.2:
		Sound.play_foley("grenade_bounce", global_position, true, -10.0, 25.0)
	if velocity.length() < 0.6 and absf(normal.y) > 0.7:
		_resting = true
	if _light != null:
		_light.visible = kind == "hegrenade"


func detonate() -> void:
	## Area effect: everything within `radius` with a clear-ish line takes
	## damage that falls off with distance, like the retail grenade.
	var effects := get_parent().get_node_or_null("Effects") as Node3D
	if effects != null:
		_effect(effects)
	if damage > 0.0:
		for agent in get_tree().get_nodes_in_group("damageable"):
			var target := agent as Node3D
			if target == null or not target.is_inside_tree():
				continue
			var offset := target.global_position + Vector3.UP * 0.9 - global_position
			var distance := offset.length()
			if distance > radius:
				continue
			var falloff := clampf(1.0 - distance / radius, 0.0, 1.0)
			var amount := int(damage * falloff * falloff)
			if amount <= 0:
				continue
			if target.has_method("apply_damage"):
				target.apply_damage(amount, owner_name, false, kind)
	elif kind == "flashbang":
		for agent in get_tree().get_nodes_in_group("damageable"):
			var target := agent as Node3D
			if target != null and target.is_inside_tree() and target.global_position.distance_to(global_position) <= radius:
				if target.has_method("flash"):
					target.flash()
	elif kind == "smokegrenade":
		_smoke(effects)
	match kind:
		"flashbang":
			Sound.play_foley("flash_explode", global_position, true, 0.0, 90.0)
		"smokegrenade":
			Sound.play_foley("flash_explode", global_position, true, -6.0, 40.0)
		_:
			Sound.play_foley("he_explode", global_position, true, 0.0, 90.0)
	queue_free()


func _effect(effects: Node3D) -> void:
	var burst := CPUParticles3D.new()
	burst.one_shot = true
	burst.amount = 36
	burst.lifetime = 0.8
	burst.explosiveness = 1.0
	burst.direction = Vector3.UP
	burst.spread = 90.0
	burst.initial_velocity_min = 3.0
	burst.initial_velocity_max = 7.5
	burst.gravity = Vector3(0.0, -6.0, 0.0)
	burst.scale_amount_min = 0.05
	burst.scale_amount_max = 0.16
	var sphere := SphereMesh.new()
	sphere.radius = 0.5
	sphere.height = 1.0
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(1.0, 0.6, 0.2)
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color.a = 0.7
	sphere.material = material
	burst.mesh = sphere
	effects.add_child(burst)
	burst.global_position = global_position
	burst.emitting = true
	get_tree().create_timer(1.4).timeout.connect(burst.queue_free)


func _smoke(effects: Node3D) -> void:
	if effects == null:
		return
	var cloud := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = radius * 0.75
	sphere.height = radius * 1.1
	sphere.radial_segments = 16
	sphere.rings = 8
	cloud.mesh = sphere
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(0.62, 0.64, 0.66, 0.86)
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	sphere.material = material
	effects.add_child(cloud)
	cloud.global_position = global_position + Vector3.UP * radius * 0.4
	get_tree().create_timer(14.0).timeout.connect(cloud.queue_free)
