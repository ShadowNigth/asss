shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_disabled, specular_schlick_ggx;

// GoldSrc water (`*water`, `!slime`): opaque-ish teal with a scrolling caustic
// pattern and a fresnel rim so pools read as liquid without a reflection pass.

uniform vec4 shallow_color : source_color = vec4(0.18, 0.52, 0.60, 1.0);
uniform vec4 deep_color : source_color = vec4(0.04, 0.16, 0.24, 1.0);
uniform float wave_scale = 0.35;
uniform float wave_speed = 0.35;
uniform float roughness_base = 0.12;
uniform float fresnel_power = 3.0;

varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

float wave(vec2 p, float t) {
	return sin(p.x * 1.7 + t) * 0.5 + sin(p.y * 2.3 - t * 1.3) * 0.5
		+ sin((p.x + p.y) * 3.1 + t * 0.7) * 0.25;
}

void fragment() {
	vec2 p = world_pos.xz * wave_scale;
	float t = TIME * wave_speed;
	float ripple = wave(p, t) * 0.5 + wave(p * 2.1, t * 1.6) * 0.25;

	vec3 n = normalize(vec3(
		cos(p.x * 1.7 + t) * 0.06 + cos((p.x + p.y) * 3.1 + t * 0.7) * 0.03,
		1.0,
		cos(p.y * 2.3 - t * 1.3) * 0.06 + cos((p.x + p.y) * 3.1 + t * 0.7) * 0.03));
	NORMAL = normalize((VIEW_MATRIX * vec4(n, 0.0)).xyz);

	float depth_mix = clamp(ripple * 0.5 + 0.5, 0.0, 1.0);
	ALBEDO = mix(deep_color.rgb, shallow_color.rgb, depth_mix);
	ROUGHNESS = roughness_base;
	METALLIC = 0.0;
	SPECULAR = 0.65;

	float fres = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), fresnel_power);
	EMISSION = shallow_color.rgb * (0.05 + fres * 0.35);
	ALPHA = clamp(0.88 + fres * 0.12, 0.0, 1.0);
}
