class_name WaterMaterial
extends RefCounted
## Small helper for the water shader so the loader and the debug views share one
## code path (and so the shader can be swapped without touching the loader).
##
## The material itself lives in `shaders/water.gdshader`; this class only picks
## the tint from the map's own water textures when they were resolved.

const SHADER_PATH := "res://shaders/water.gdshader"

const FAMILY_TINTS := {
	"water": [Color(0.18, 0.52, 0.60), Color(0.04, 0.16, 0.24)],
	"slime": [Color(0.36, 0.52, 0.24), Color(0.10, 0.18, 0.06)],
	"lava": [Color(0.86, 0.34, 0.10), Color(0.32, 0.06, 0.02)],
	"teleport": [Color(0.42, 0.30, 0.66), Color(0.12, 0.06, 0.22)],
}


static func create(family: String = "water") -> ShaderMaterial:
	var material := ShaderMaterial.new()
	var shader := load(SHADER_PATH) as Shader
	if shader == null:
		return null
	material.shader = shader
	var tint: Array = FAMILY_TINTS.get(family, FAMILY_TINTS["water"])
	material.set_shader_parameter("shallow_color", tint[0])
	material.set_shader_parameter("deep_color", tint[1])
	match family:
		"slime":
			material.set_shader_parameter("wave_speed", 0.18)
		"lava":
			material.set_shader_parameter("wave_speed", 0.12)
			material.set_shader_parameter("roughness_base", 0.4)
		_:
			material.set_shader_parameter("wave_speed", 0.35)
	return material
