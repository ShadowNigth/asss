class_name CharacterBodyAgent
extends CharacterBody3D
## Shared third-person actor body (bots and, later, humans in multiplayer).
##
## Keeps a `PlayerMovement`-compatible hull and exposes the same `apply_damage`
## contract the combat system expects, plus a zombie-style "head" marker so the
## headshot test works on models without a skeleton.

signal died(agent: Node)

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
	var capsule := CapsuleShape3D.new()
	capsule.radius = Cfg.HULL_RADIUS * Cfg.U2M
	capsule.height = Cfg.HULL_HEIGHT * Cfg.U2M
	collider.shape = capsule
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


func apply_damage(amount: int, from: String = "", headshot: bool = false) -> void:
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
