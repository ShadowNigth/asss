class_name SlidingDoor
extends AnimatableBody3D
## A convert-time `func_door`, rebuilt as a real moving body.
##
## Retail brush doors are carried in their own BSP models, not in the world
## model, so a map drawn from the world alone simply has a hole where the door
## is. `MapData.doors` keeps the brush volume; this node fills it with a slab,
## slides it open when an agent walks up, and closes it again after `hold`.
##
## The door is kinematic (`AnimatableBody3D`), so it sweeps agents out of the
## way rather than letting them push it round, and it stops at whatever the
## controller says the brush volume is -- no navmesh rebuild, because a closed
## door still leaves the navigation region intact.

const OPEN_SPEED := 1.35
const HOLD_TIME := 3.0
const TRIGGER_PAD := 0.85

var size := Vector3(2.0, 2.0, 0.12)
var travel := 1.6
var direction := Vector3.RIGHT
var _closed_position := Vector3.ZERO
var _offset := 0.0
var _hold := 0.0
var _body_material: StandardMaterial3D


func setup(bounds_min: Vector3, bounds_max: Vector3) -> void:
	## Build the slab from the brush volume the converter recorded.
	size = (bounds_max - bounds_min).abs()
	size.x = maxf(size.x, 0.06)
	size.y = maxf(size.y, 0.06)
	size.z = maxf(size.z, 0.06)
	_closed_position = (bounds_min + bounds_max) * 0.5
	travel = maxf(0.0, (size.x if size.x < size.z else size.z) - 0.25)
	# slide along the short axis, like a retail door does
	direction = Vector3.RIGHT if size.x <= size.z else Vector3.BACK
	var mesh_instance := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	mesh_instance.mesh = box
	mesh_instance.material_override = _material()
	mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	add_child(mesh_instance)
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	collision.shape = shape
	add_child(collision)
	# 0.5 m wider than the slab, so brushing past the frame still opens it
	position = _closed_position


func _material() -> StandardMaterial3D:
	if _body_material == null:
		_body_material = StandardMaterial3D.new()
		_body_material.albedo_color = Color(0.34, 0.3, 0.26)
		_body_material.roughness = 0.8
	return _body_material


func _ready() -> void:
	position = _closed_position


func _physics_process(delta: float) -> void:
	## Doors open on approach and close after a moment, so a doorway never
	## needs a trigger brush (the CS 1.5 maps do not carry usable ones).
	var want := 0.0
	for agent in get_tree().get_nodes_in_group("agents"):
		var body := agent as Node3D
		if body == null or not body.is_inside_tree():
			continue
		var flat := body.global_position - _closed_position
		flat.y = 0.0
		var reach := maxf(size.x, size.z) * 0.5 + TRIGGER_PAD
		if flat.length() <= reach and absf(body.global_position.y - _closed_position.y) < size.y:
			want = 1.0
			break
	if want > 0.0:
		_hold = HOLD_TIME
	else:
		_hold = maxf(0.0, _hold - delta)
		if _hold > 0.0:
			want = 1.0
	var target := 1.0 if want > 0.0 else 0.0
	if is_equal_approx(_offset, target):
		return
	_offset = move_toward(_offset, target, delta * OPEN_SPEED)
	position = _closed_position + direction * (travel * _offset)
