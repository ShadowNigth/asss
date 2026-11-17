class_name CharacterBodyAgent
extends CharacterBody3D
## Shared third-person actor body (bots and, later, humans in multiplayer).
##
## Keeps a `PlayerMovement`-compatible hull and exposes the same `apply_damage`
## contract the combat system expects, plus a zombie-style "head" marker so the
## headshot test works on models without a skeleton.

signal died(agent: Node)
## Emitted on every kill, so the HUD can show a kill feed like retail.
signal killed(victim: String, killer: String, weapon: String, headshot: bool)

var display_name := "bot"
var team := "t"
var health := 100
var armor := 0
var alive := true
var movement_speed := 4.6
var agent_index := 0
var model_root: Node3D
var head: Node3D


func setup(name_value: String, team_value: String, index: int) -> void:
	display_name = name_value
	team = team_value
	agent_index = index
	add_to_group("damageable")
	add_to_group("agents")
	collision_layer = 1 << 1
	collision_mask = 1
	_build()


func _build() -> void:
	var collider := CollisionShape3D.new()
	# A capsule's rounded bottom rolls off shallow ledges and steps instead of
	# climbing them; a cylinder is flat-footed like the GoldSrc box hull.
	var hull := CylinderShape3D.new()
	hull.radius = Cfg.HULL_RADIUS * Cfg.U2M
	hull.height = Cfg.HULL_HEIGHT * Cfg.U2M
	collider.shape = hull
	collider.position = Vector3(0.0, Cfg.HULL_HEIGHT * Cfg.U2M * 0.5, 0.0)
	collider.name = "Collider"
	add_child(collider)
	head = Node3D.new()
	head.name = "Head"
	head.position = Vector3(0.0, Cfg.EYE_HEIGHT * Cfg.U2M, 0.0)
	add_child(head)
	model_root = Node3D.new()
	model_root.name = "Model"
	add_child(model_root)
	_build_model()


func _build_model() -> void:
	## A blocky CS-style soldier: torso, head, legs and a carrying arm. The
	## retail player models are not in the asset set (only viewmodels are), so
	## this is built from primitives but keeps the GoldSrc proportions -- the
	## 72 u hull, so 1.83 m, with the head at 1.68 m.
	var height := Cfg.HULL_HEIGHT * Cfg.U2M
	var skin := _material(Color(0.72, 0.56, 0.44))
	var clothes := _material(_team_colour())
	_mesh(Vector3(0.34, height * 0.24, 0.22), Vector3(0.0, height * 0.79, 0.0), clothes, "Torso")
	_mesh(Vector3(0.17, height * 0.13, 0.17), Vector3(0.0, height * 0.93, 0.0), skin, "Head")
	_mesh(Vector3(0.15, height * 0.34, 0.16), Vector3(0.0, height * 0.51, 0.0), clothes, "Hips")
	_mesh(Vector3(0.13, height * 0.34, 0.14), Vector3(-0.08, height * 0.17, 0.0), clothes, "LegL")
	_mesh(Vector3(0.13, height * 0.34, 0.14), Vector3(0.08, height * 0.17, 0.0), clothes, "LegR")
	_mesh(Vector3(0.09, height * 0.30, 0.09), Vector3(-0.21, height * 0.72, 0.0), clothes, "ArmL")
	_mesh(Vector3(0.09, height * 0.30, 0.09), Vector3(0.21, height * 0.72, 0.0), clothes, "ArmR")
	# A stubby receiver so a bot reads as armed from a distance.
	_mesh(Vector3(0.06, 0.06, 0.5), Vector3(0.16, height * 0.70, -0.28), _material(Color(0.13, 0.13, 0.15)), "Rifle")
	# The head is the hit volume the headshot test uses.
	# head already sits at EYE_HEIGHT from _build(); nothing to move here.


func _team_colour() -> Color:
	if team == "ct":
		return Color(0.24, 0.31, 0.42)
	return Color(0.42, 0.34, 0.22)


func _material(colour: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = colour
	material.roughness = 0.85
	return material


func _mesh(size: Vector3, offset: Vector3, material: StandardMaterial3D, label: String) -> void:
	var piece := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	piece.mesh = box
	piece.material_override = material
	piece.position = offset
	piece.name = label
	model_root.add_child(piece)


func apply_damage(amount: int, from: String = "", headshot: bool = false, weapon: String = "") -> void:
	if not alive:
		return
	var damage := amount
	if armor > 0:
		var absorbed := clampf(float(amount) * Cfg.ARMOR_ABSORB, 0.0, float(armor))
		armor = maxi(0, armor - int(absorbed * Cfg.ARMOR_BONUS))
		damage = amount - int(absorbed * (1.0 - Cfg.ARMOR_BONUS))
	health -= damage
	if health <= 0:
		health = 0
		alive = false
		movement_speed = 0.0
		_respawn_ragdoll()
		killed.emit(display_name, from, weapon, headshot)
		died.emit(self)


func is_alive() -> bool:
	return alive


func _respawn_ragdoll() -> void:
	if model_root != null:
		model_root.rotation.z = deg_to_rad(84.0)
		model_root.position.y = 0.1
	collision_layer = 0


func reset_actor(spawn: Dictionary, team_value: String) -> void:
	alive = true
	health = 100
	armor = 0
	team = team_value
	collision_layer = 1 << 1
	movement_speed = 4.6
	global_position = spawn.get("pos", Vector3.ZERO)
	velocity = Vector3.ZERO
	rotation.y = deg_to_rad(float(spawn.get("yaw", 0.0)))
	if model_root != null:
		model_root.rotation = Vector3.ZERO
		model_root.position = Vector3.ZERO
