class_name MapLoader
extends Node3D
## Builds the playable scene from a `.csmap` payload.
##
## For every material group a single `ArrayMesh` surface is created with
## albedo + baked vertex colour (lightmap × albedo), so a whole map runs in
## ~30 draw calls.  A trimesh collision is created from the same vertices with
## degenerate triangles dropped (GoldSrc maps contain a few percent of
## zero-area triangles that make the physics engine unhappy).

const COLLISION_EPSILON := 1e-9
const WORLD_SHADER := "res://shaders/world.gdshader"

var map_data: MapData
var world_root: Node3D
var collision_body: StaticBody3D
var water_root: Node3D
var door_root: Node3D
var used_materials: Array = []
var stats := {}


func build(map_name: String) -> bool:
	map_data = MapData.new()
	if not map_data.load_map(Cfg.map_payload_path(map_name)):
		push_error(map_data.error)
		return false
	_clear()
	world_root = Node3D.new()
	world_root.name = "Geometry"
	add_child(world_root)
	stats = {
		"groups": map_data.groups.size(),
		"triangles": 0,
		"collision_triangles": 0,
		"dropped_triangles": 0,
	}
	for group in map_data.groups:
		stats["triangles"] += int(group["tris"])
	_build_geometry()
	_build_collision()
	_build_water()
	_build_doors()
	return true


func _clear() -> void:
	for child in get_children():
		child.queue_free()
	used_materials.clear()


func _build_geometry() -> void:
	for index in map_data.groups.size():
		var group: Dictionary = map_data.groups[index]
		if int(group["verts"]) == 0 or int(group["tris"]) == 0:
			continue
		var info: Dictionary = map_data.materials[int(group["mat"])] if int(group["mat"]) < map_data.materials.size() else {}
		var array_mesh := ArrayMesh.new()
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = map_data.group_positions(group)
		arrays[Mesh.ARRAY_NORMAL] = _decode_vec3(group["normals"], true)
		arrays[Mesh.ARRAY_TEX_UV] = _decode_vec2(group["uv"])
		arrays[Mesh.ARRAY_TEX_UV2] = _decode_vec2(group["uv2"])
		arrays[Mesh.ARRAY_COLOR] = _decode_color(group["colors"])
		arrays[Mesh.ARRAY_INDEX] = map_data.group_indices(group)
		array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var material := _material_for(info)
		array_mesh.surface_set_material(0, material)
		var mesh_instance := MeshInstance3D.new()
		mesh_instance.name = "surface_%02d" % index
		mesh_instance.mesh = array_mesh
		mesh_instance.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
		mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		world_root.add_child(mesh_instance)


func _material_for(info: Dictionary) -> Material:
	## GoldSrc surfaces are unlit: the lightmap already contains every light,
	## so the world shader multiplies albedo by the baked vertex colour and
	## skips the engine's dynamic lighting entirely.
	var transparent := bool(info.get("transparent", false))
	var shader := load(WORLD_SHADER) as Shader
	if shader == null:
		return _fallback_material(info)
	var material := ShaderMaterial.new()
	material.shader = shader
	var path := str(info.get("file", ""))
	if not path.is_empty() and ResourceLoader.exists(path):
		var texture := load(path) as Texture2D
		if texture != null:
			material.set_shader_parameter("albedo_tex", texture)
	material.set_shader_parameter("emissive", bool(info.get("emissive", false)))
	material.set_shader_parameter("light_boost", Cfg.WORLD_LIGHT_BOOST)
	material.set_shader_parameter("alpha_scale", 0.72 if transparent else 1.0)
	material.set_shader_parameter("tint", Color(1.0, 1.0, 1.0))
	if transparent:
		material.render_priority = 1
		# masked surfaces (fences, gratings) are drawn double-sided in retail
		material.set_shader_parameter("alpha_scale", 0.72)
	return material


func _fallback_material(info: Dictionary) -> Material:
	var material := StandardMaterial3D.new()
	material.vertex_color_use_as_albedo = true
	material.vertex_color_is_srgb = false
	material.roughness = 0.92
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED if bool(info.get("transparent", false)) else BaseMaterial3D.CULL_BACK
	var path := str(info.get("file", ""))
	if not path.is_empty() and ResourceLoader.exists(path):
		material.albedo_texture = load(path) as Texture2D
	if bool(info.get("transparent", false)):
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		material.albedo_color.a = 0.75
	return material


func _build_collision() -> void:
	var faces := PackedVector3Array()
	var dropped := 0
	for group in map_data.groups:
		var positions := map_data.group_positions(group)
		var indices := map_data.group_indices(group)
		var i := 0
		while i + 2 < indices.size():
			var a := indices[i]
			var b := indices[i + 1]
			var c := indices[i + 2]
			i += 3
			if a < 0 or b < 0 or c < 0 or a >= positions.size() or b >= positions.size() or c >= positions.size():
				dropped += 1
				continue
			var pa := positions[a]
			var pb := positions[b]
			var pc := positions[c]
			# skip zero-area triangles: the physics trimesh builder aborts on them
			if (pb - pa).cross(pc - pa).length_squared() <= COLLISION_EPSILON:
				dropped += 1
				continue
			faces.append(pa)
			faces.append(pb)
			faces.append(pc)
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(faces)
	shape.backface_collision = true
	collision_body = StaticBody3D.new()
	collision_body.name = "WorldCollision"
	collision_body.collision_layer = 1
	collision_body.collision_mask = 0
	var collision := CollisionShape3D.new()
	collision.shape = shape
	collision_body.add_child(collision)
	add_child(collision_body)
	stats["collision_triangles"] = faces.size() / 3
	stats["dropped_triangles"] = dropped


func _build_doors() -> void:
	## Brush doors are absent from the world model, so without this the map has
	## a hole (and a missing wall) exactly where each door belongs.
	door_root = null
	if map_data.doors.is_empty():
		return
	door_root = Node3D.new()
	door_root.name = "Doors"
	add_child(door_root)
	for entry in map_data.doors:
		var door := SlidingDoor.new()
		door.setup(entry["min"], entry["max"])
		door_root.add_child(door)


func _build_water() -> void:
	water_root = Node3D.new()
	water_root.name = "Water"
	add_child(water_root)
	var shader := load("res://shaders/water.gdshader") as Shader
	var material := ShaderMaterial.new()
	if shader != null:
		material.shader = shader
	else:
		var fallback := StandardMaterial3D.new()
		fallback.albedo_color = Color(0.12, 0.32, 0.42, 0.72)
		fallback.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		material = null
	for index in map_data.water_faces.size():
		var face: Dictionary = map_data.water_faces[index]
		var mesh := ArrayMesh.new()
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		var positions := PackedVector3Array()
		var raw: PackedByteArray = face["positions"]
		var i := 0
		while i + 12 <= raw.size():
			positions.append(Vector3(raw.decode_float(i), raw.decode_float(i + 4), raw.decode_float(i + 8)))
			i += 12
		var indices := PackedInt32Array()
		raw = face["indices"]
		i = 0
		while i + 4 <= raw.size():
			indices.append(raw.decode_s32(i))
			i += 4
		arrays[Mesh.ARRAY_VERTEX] = positions
		arrays[Mesh.ARRAY_INDEX] = indices
		arrays[Mesh.ARRAY_TEX_UV] = _planar_uv(positions)
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		if material != null:
			mesh.surface_set_material(0, material)
		var instance := MeshInstance3D.new()
		instance.name = "water_%02d" % index
		instance.mesh = mesh
		instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		water_root.add_child(instance)


func _planar_uv(positions: PackedVector3Array) -> PackedVector2Array:
	var uvs := PackedVector2Array()
	uvs.resize(positions.size())
	for i in positions.size():
		uvs[i] = Vector2(positions[i].x, positions[i].z) * 0.25
	return uvs


func _decode_vec3(raw: PackedByteArray, normalize: bool) -> PackedVector3Array:
	var out := PackedVector3Array()
	out.resize(raw.size() / 12)
	var i := 0
	while i + 12 <= raw.size():
		var v := Vector3(raw.decode_float(i), raw.decode_float(i + 4), raw.decode_float(i + 8))
		out[i / 12] = v.normalized() if normalize else v
		i += 12
	return out


func _decode_vec2(raw: PackedByteArray) -> PackedVector2Array:
	var out := PackedVector2Array()
	out.resize(raw.size() / 8)
	var i := 0
	while i + 8 <= raw.size():
		out[i / 8] = Vector2(raw.decode_float(i), raw.decode_float(i + 4))
		i += 8
	return out


func _decode_color(raw: PackedByteArray) -> PackedColorArray:
	var out := PackedColorArray()
	out.resize(raw.size() / 3)
	var i := 0
	while i + 3 <= raw.size():
		out[i / 3] = Color8(raw[i], raw[i + 1], raw[i + 2])
		i += 3
	return out


## Highest solid-ish water surface under `position`, or NAN when dry.
func water_surface_at(position: Vector3) -> float:
	for volume in map_data.water_volumes:
		var v: Dictionary = volume
		var mn := MapData._vec3(v.get("min", [0, 0, 0]))
		var mx := MapData._vec3(v.get("max", [0, 0, 0]))
		if position.x < mn.x - 0.5 or position.x > mx.x + 0.5:
			continue
		if position.z < mn.z - 0.5 or position.z > mx.z + 0.5:
			continue
		var level := float(v.get("level", mx.y))
		if position.y - level < 2.5:
			return level
	return NAN


func inside_water(position: Vector3) -> bool:
	for volume in map_data.water_volumes:
		var v: Dictionary = volume
		var mn := MapData._vec3(v.get("min", [0, 0, 0]))
		var mx := MapData._vec3(v.get("max", [0, 0, 0]))
		if position.x < mn.x or position.x > mx.x or position.z < mn.z or position.z > mx.z:
			continue
		if position.y < mx.y and position.y > mn.y - 2.0:
			return true
	return false


func random_spawn(team: String) -> Dictionary:
	var pool := map_data.spawn_points(team)
	if pool.is_empty():
		return {"pos": map_data.centre() + Vector3.UP * 2.0, "yaw": 0.0, "team": team, "index": 0}
	return pool[randi() % pool.size()]


func spawn_pool(team: String) -> Array:
	## Every spawn a team may use, in map order (so callers can hand them out
	## one per actor instead of letting everyone draw the same one).
	var pool := map_data.spawn_points(team)
	if pool.is_empty():
		pool = [{"pos": map_data.centre() + Vector3.UP * 2.0, "yaw": 0.0, "team": team}]
	return pool


func spawn_for_index(team: String, index: int) -> Dictionary:
	## Deterministic, collision-free assignment: actors of one team spread over
	## the spawn entities instead of being stacked on top of each other.
	var pool := spawn_pool(team)
	return pool[posmod(index, pool.size())]
