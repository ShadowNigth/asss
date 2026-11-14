class_name ViewModel
extends Node3D
## First-person weapon model with CS-style sway, bob and kick.
##
## The model is rendered on its own camera layer (`Cfg.VIEWMODEL_LAYER`) so it
## never clips into walls, and it is attached under the camera.  Models come
## from the CS2 viewmodel kit; a missing GLB leaves an empty rig rather than
## breaking the game.

const BASE_POSITION := Vector3(0.145, -0.135, -0.30)
const BASE_SCALE := 0.62

var camera: Camera3D
var current_id := "knife"
var model_root: Node3D
var current_model: Node3D
var sway := Vector2.ZERO
var bob_time := 0.0
var kick_amount := 0.0
var reload_amount := 0.0
var equip_amount := 0.0


func setup(camera_ref: Camera3D) -> void:
	camera = camera_ref
	position = BASE_POSITION
	rotation = Vector3.ZERO
	model_root = Node3D.new()
	model_root.name = "Model"
	add_child(model_root)
	var light := OmniLight3D.new()
	light.light_energy = 0.4
	light.omni_range = 1.2
	light.position = Vector3(0.1, 0.1, 0.2)
	add_child(light)


func equip(id: String) -> void:
	current_id = id
	if current_model != null:
		current_model.queue_free()
		current_model = null
	var path := Weapons.viewmodel_path(id)
	if path.is_empty():
		return
	var scene := load(path) as PackedScene
	if scene == null:
		return
	current_model = scene.instantiate() as Node3D
	if current_model == null:
		return
	model_root.add_child(current_model)
	current_model.scale = Vector3.ONE * BASE_SCALE
	current_model.position = Vector3.ZERO
	current_model.rotation = Vector3(0.0, deg_to_rad(180.0), 0.0)
	_set_layers(current_model)
	equip_amount = 1.0
	var player := current_model.find_children("*", "AnimationPlayer", true, false)
	for node in player:
		var anim := node as AnimationPlayer
		var names := anim.get_animation_list()
		if names.is_empty():
			continue
		for candidate in ["draw", "deploy", "idle"]:
			if names.has(candidate):
				anim.play(candidate)
				break


func _set_layers(node: Node) -> void:
	if node is GeometryInstance3D:
		(node as GeometryInstance3D).layers = 1 << (Cfg.VIEWMODEL_LAYER - 1)
	for child in node.get_children():
		_set_layers(child)


func kick(id: String) -> void:
	var data := Weapons.get_weapon(id)
	var punch := 0.01 + float(data.get("recoil", 1.0)) * 0.004
	kick_amount = minf(kick_amount + punch, 0.16)
	rotation.z += randf_range(-0.02, 0.02)


func reload() -> void:
	reload_amount = 1.0


func tick(delta: float, velocity: Vector3, on_ground: bool) -> void:
	var speed := velocity.length()
	if on_ground and speed > 0.3:
		bob_time += delta * (6.0 + speed * 2.0)
	var bob_strength := 0.0
	if on_ground:
		bob_strength = minf(speed / (Cfg.MAXSPEED * Cfg.U2M), 1.0) * 0.012
	var bob := Vector3(sin(bob_time) * bob_strength, absf(cos(bob_time * 2.0)) * bob_strength * 0.6, 0.0)
	kick_amount = move_toward(kick_amount, 0.0, delta * 0.9)
	reload_amount = move_toward(reload_amount, 0.0, delta * 2.2)
	equip_amount = move_toward(equip_amount, 0.0, delta * 3.0)
	var sway_offset := Vector3(-sway.x * 0.02, sway.y * 0.02, 0.0)
	var reload_dip := Vector3(0.0, -0.18 * reload_amount, 0.06 * reload_amount)
	var equip_dip := Vector3(0.0, -0.25 * equip_amount, 0.0)
	position = BASE_POSITION + bob + sway_offset + reload_dip + equip_dip + Vector3(0.0, 0.0, kick_amount * 0.5)
	rotation = Vector3(kick_amount * 1.6, sway.x * 0.25, sway.y * 0.3)
	sway = sway.lerp(Vector2.ZERO, clampf(delta * 5.0, 0.0, 1.0))


func add_look(delta_look: Vector2) -> void:
	sway = (sway + delta_look * 0.02).limit_length(1.0)
