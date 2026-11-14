class_name MapData
extends RefCounted
## Parsed `.csmap` payload: geometry streams, materials and gameplay markers.
##
## File layout (little endian):
##   "CS15MAP\x01" | u32 header_len | UTF-8 JSON header
##   per group: i32 verts, i32 tris, i32 material
##              f32 vec3 positions | f32 vec3 normals | f32 vec2 uv | f32 vec2 uv2
##              u8 vec3 colours   | i32 vec3 indices
##   per water face: i32 verts, i32 tris | f32 vec3 positions | i32 vec3 indices

const MAGIC := "CS15MAP"
const FORMAT_VERSION := 1

var map_name := ""
var header: Dictionary = {}
var materials: Array = []
var groups: Array = []
var water_faces: Array = []
var bounds_min := Vector3.ZERO
var bounds_max := Vector3.ZERO
var spawns: Array = []
var bomb_sites: Array = []
var buy_zones: Array = []
var lights: Array = []
var water_volumes: Array = []
var sky: Dictionary = {}
var error := ""


func load_map(path: String) -> bool:
	var slug := path.get_file().get_basename()
	if not FileAccess.file_exists(path):
		error = "missing map payload: %s" % path
		return false
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		error = "cannot open %s" % path
		return false
	var magic := file.get_buffer(8)
	if magic.size() < 8 or magic.slice(0, 7).get_string_from_ascii() != MAGIC or magic[7] != FORMAT_VERSION:
		error = "%s is not a csmap payload" % path
		return false
	var header_len := file.get_32()
	var header_text := file.get_buffer(header_len).get_string_from_utf8()
	var parsed: Variant = JSON.parse_string(header_text)
	if typeof(parsed) != TYPE_DICTIONARY:
		error = "%s has a corrupt header" % path
		return false
	header = parsed
	map_name = str(header.get("map", slug))
	materials = header.get("materials", []) as Array
	sky = header.get("sky", {}) as Dictionary
	var raw_spawns: Array = header.get("spawns", []) as Array
	spawns.clear()
	for entry in raw_spawns:
		var e: Dictionary = entry
		spawns.append({
			"pos": _vec3(e.get("pos", [0, 0, 0])),
			"yaw": float(e.get("yaw", 0.0)),
			"team": str(e.get("team", "any")),
		})
	bomb_sites = _convert_sites(header.get("bomb_sites", []) as Array)
	buy_zones = header.get("buy_zones", []) as Array
	lights = header.get("lights", []) as Array
	water_volumes = header.get("water_volumes", []) as Array
	var min_raw: Array = header.get("bounds", {}).get("min", [0, 0, 0])
	var max_raw: Array = header.get("bounds", {}).get("max", [0, 0, 0])
	bounds_min = _vec3(min_raw)
	bounds_max = _vec3(max_raw)

	groups.clear()
	var group_info: Array = header.get("groups", []) as Array
	for info_entry in group_info:
		var info: Dictionary = info_entry
		var verts := file.get_32()
		var tris := file.get_32()
		var mat := file.get_32()
		if verts < 0 or tris < 0 or verts > 4_000_000:
			error = "corrupt group in %s" % path
			return false
		var group := {
			"verts": verts,
			"tris": tris,
			"mat": mat,
			"positions": file.get_buffer(verts * 12),
			"normals": file.get_buffer(verts * 12),
			"uv": file.get_buffer(verts * 8),
			"uv2": file.get_buffer(verts * 8),
			"colors": file.get_buffer(verts * 3),
			"indices": file.get_buffer(tris * 12),
		}
		groups.append(group)

	water_faces.clear()
	while file.get_position() + 8 <= file.get_length():
		var wverts := file.get_32()
		var wtris := file.get_32()
		if wverts <= 0 or wtris <= 0:
			break
		water_faces.append({
			"verts": wverts,
			"positions": file.get_buffer(wverts * 12),
			"indices": file.get_buffer(wtris * 12),
		})
	file.close()
	return true


func _convert_sites(raw: Array) -> Array:
	var out: Array = []
	for entry in raw:
		var e: Dictionary = entry
		var bmin: Array = e.get("bounds", {}).get("min", [0, 0, 0])
		var bmax: Array = e.get("bounds", {}).get("max", [0, 0, 0])
		out.append({
			"name": str(e.get("name", "A")),
			"pos": _vec3(e.get("pos", [0, 0, 0])),
			"min": _vec3(bmin),
			"max": _vec3(bmax),
		})
	return out


static func _vec3(values: Array) -> Vector3:
	if values.size() < 3:
		return Vector3.ZERO
	return Vector3(float(values[0]), float(values[1]), float(values[2]))


## Decode a group's interleaved-free index buffer into a PackedInt32Array.
func group_indices(group: Dictionary) -> PackedInt32Array:
	var raw: PackedByteArray = group["indices"]
	var out := PackedInt32Array()
	out.resize(raw.size() / 4)
	var i := 0
	while i + 4 <= raw.size():
		out[i / 4] = raw.decode_s32(i)
		i += 4
	return out


func group_positions(group: Dictionary) -> PackedVector3Array:
	var raw: PackedByteArray = group["positions"]
	var out := PackedVector3Array()
	out.resize(raw.size() / 12)
	var i := 0
	while i + 12 <= raw.size():
		out[i / 12] = _vec3([raw.decode_float(i), raw.decode_float(i + 4), raw.decode_float(i + 8)])
		i += 12
	return out


func material_name(index: int) -> String:
	if index < 0 or index >= materials.size():
		return "?"
	return str((materials[index] as Dictionary).get("name", "?"))


func site_named(site_name: String) -> Dictionary:
	for site in bomb_sites:
		if str(site["name"]).to_upper() == site_name.to_upper():
			return site
	return {}


func spawn_points(team: String) -> Array:
	var out: Array = []
	for spawn in spawns:
		var tag := str(spawn["team"])
		if tag == "any" or tag == team:
			out.append(spawn)
	if out.is_empty():
		return spawns
	return out


func centre() -> Vector3:
	return (bounds_min + bounds_max) * 0.5
