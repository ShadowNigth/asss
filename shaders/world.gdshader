shader_type spatial;
render_mode unshaded, cull_back, depth_prepass_alpha;

// GoldSrc baked lighting: the lightmap sample is stored in the mesh's vertex
// colour and multiplied with the albedo.  Retail lightmaps are overbright
// (final = texture × light × 2), so the boost restores the original contrast
// instead of rendering everything at ~60 % brightness.

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform vec3 tint : source_color = vec3(1.0);
uniform float light_boost = 1.9;
uniform float exposure = 1.0;
uniform bool use_vertex_light = true;
uniform vec4 albedo_color : source_color = vec4(1.0);
uniform bool emissive = false;
uniform float alpha_scale = 1.0;

void fragment() {
	vec4 texel = texture(albedo_tex, UV) * albedo_color;
	vec3 light = use_vertex_light ? (COLOR.rgb * light_boost * exposure) : vec3(1.0);
	vec3 color = texel.rgb * tint * light;
	if (emissive) {
		// light fixtures stay readable when the lightmap says "dark"
		color = max(color, texel.rgb * 0.85);
	}
	ALBEDO = min(color, vec3(1.0));
	ALPHA = texel.a * alpha_scale;
}
