class_name Atmosphere
extends WorldEnvironment
## Per-map sky, sun and fog, driven by the `.csmap` `sky` block.
##
## Maps whose retail `gfx/env` skybox could be found get a panorama `Sky`
## generated at build time (so the original sky art survives); the rest fall
## back to a procedural sky tuned to the same horizon/zenith colours.  The sun
## direction comes from the map's `light_environment`.

var sun: DirectionalLight3D
var panorama_sky: PanoramaSkyMaterial
var weather := "clear"


func setup(sky: Dictionary, quality: String) -> void:
	weather = str(sky.get("weather", "clear"))
	var env := Environment.new()
	environment = env
	env.background_mode = Environment.BG_SKY
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = _color(sky.get("zenith", [0.4, 0.5, 0.7]))
	environment.ambient_light_energy = _ambient_energy(weather)
	environment.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	environment.tonemap_exposure = 1.0

	var horizon := _color(sky.get("horizon", [0.6, 0.6, 0.6]))
	var zenith := _color(sky.get("zenith", [0.3, 0.45, 0.75]))
	var panorama_path := str(sky.get("panorama", ""))
	environment.sky = Sky.new()
	if not panorama_path.is_empty() and ResourceLoader.exists(panorama_path):
		panorama_sky = PanoramaSkyMaterial.new()
		panorama_sky.panorama = load(panorama_path) as Texture2D
		panorama_sky.filter = false
		panorama_sky.energy_multiplier = 1.0
		environment.sky.sky_material = panorama_sky
		environment.sky.radiance_size = Sky.RADIANCE_SIZE_256
		environment.sky.process_mode = Sky.PROCESS_MODE_QUALITY
	else:
		var physical := ProceduralSkyMaterial.new()
		physical.sky_top_color = zenith
		physical.sky_horizon_color = horizon
		physical.sky_curve = 0.13
		physical.ground_bottom_color = horizon.darkened(0.55)
		physical.ground_horizon_color = horizon
		physical.sun_angle_max = 24.0
		physical.sun_curve = 0.12
		environment.sky.sky_material = physical
		environment.sky.radiance_size = Sky.RADIANCE_SIZE_128
		environment.sky.process_mode = Sky.PROCESS_MODE_REALTIME

	var density := float(sky.get("fog_density", 0.05))
	environment.fog_enabled = density > 0.001
	environment.fog_mode = Environment.FOG_MODE_EXPONENTIAL
	environment.fog_light_color = horizon.lerp(zenith, 0.25)
	environment.fog_light_energy = 0.8
	environment.fog_density = maxf(0.0015, density * 0.012)
	environment.fog_sky_affect = 0.35
	environment.fog_height = 2.0
	environment.fog_height_density = 0.0

	if quality == "ultra":
		environment.ssao_enabled = true
		environment.ssao_radius = 1.4
		environment.ssao_intensity = 1.4
	if quality != "low":
		environment.glow_enabled = true
		environment.glow_intensity = 0.35
		environment.glow_bloom = 0.05
		environment.glow_blend_mode = Environment.GLOW_BLEND_MODE_SOFTLIGHT

	environment.adjustment_enabled = true
	environment.adjustment_brightness = 1.0
	environment.adjustment_contrast = 1.04
	environment.adjustment_saturation = 1.02
	self.environment = environment
	create_sun(sky)


func create_sun(sky: Dictionary) -> void:
	sun = DirectionalLight3D.new()
	sun.name = "Sun"
	sun.light_color = _color(sky.get("sun_color", [1.0, 0.95, 0.85]))
	sun.light_energy = clampf(float(sky.get("sun_energy", 1.2)), 0.1, 4.0)
	sun.light_specular = 0.4
	sun.shadow_enabled = true
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun.directional_shadow_max_distance = 160.0
	sun.directional_shadow_split_1 = 0.08
	sun.directional_shadow_split_2 = 0.2
	sun.directional_shadow_split_3 = 0.45
	sun.shadow_bias = 0.04
	sun.shadow_normal_bias = 1.6
	sun.shadow_blur = 1.2
	var direction := _vec3(sky.get("sun_direction", [0.35, -0.85, 0.4])).normalized()
	if direction.length() < 0.1:
		direction = Vector3(0.35, -0.85, 0.4).normalized()
	# A DirectionalLight3D shines down its own -Z axis.
	var target := -direction
	var up := Vector3.UP if absf(target.dot(Vector3.UP)) < 0.98 else Vector3.RIGHT
	sun.look_at_from_position(Vector3.ZERO, target, up)
	add_child(sun)


func _ambient_energy(weather_name: String) -> float:
	match weather_name:
		"rain", "storm":
			return 0.55
		"snow":
			return 0.9
		"night":
			return 0.25
		_:
			return 0.7


static func _color(values: Array) -> Color:
	if values.size() < 3:
		return Color(0.5, 0.6, 0.7)
	return Color(float(values[0]), float(values[1]), float(values[2]))


static func _vec3(values: Array) -> Vector3:
	if values.size() < 3:
		return Vector3.ZERO
	return Vector3(float(values[0]), float(values[1]), float(values[2]))
