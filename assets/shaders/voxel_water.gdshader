// Still water: the water tile drifting slowly, darker with depth, a little
// fresnel reflection of the sky.
shader_type spatial;
render_mode blend_mix, depth_draw_always, cull_back, diffuse_lambert, specular_schlick_ggx;

uniform sampler2DArray atlas : source_color, filter_nearest_mipmap_anisotropic, repeat_enable;
uniform sampler2D depth_tex : hint_depth_texture, filter_linear;
uniform vec3 deep = vec3(0.05, 0.16, 0.24);
uniform vec3 sky_glow = vec3(0.0);
varying flat float layer;
varying vec3 wpos;

void vertex() {
	layer = UV2.x;
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 uv = wpos.xz * 0.5 + vec2(TIME * 0.02, TIME * 0.013);
	vec2 uv2 = wpos.xz * 0.37 - vec2(TIME * 0.017, -TIME * 0.011);
	vec3 a = texture(atlas, vec3(fract(uv), layer)).rgb;
	vec3 b = texture(atlas, vec3(fract(uv2), layer)).rgb;
	vec3 col = mix(a, b, 0.5);
	float depth = texture(depth_tex, SCREEN_UV).r;
	vec4 world = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth, 1.0);
	world.xyz /= world.w;
	float thick = clamp((-world.z) - (-VERTEX.z), 0.0, 6.0);
	float k = clamp(thick / 2.5, 0.0, 1.0);
	ALBEDO = mix(col * 1.05, deep, k * 0.6) * COLOR.a + sky_glow;
	float fres = pow(1.0 - clamp(dot(normalize(VIEW), NORMAL), 0.0, 1.0), 3.0);
	ALPHA = clamp(0.55 + k * 0.35 + fres * 0.25, 0.0, 0.94);
	ROUGHNESS = 0.08;
	METALLIC = 0.0;
	SPECULAR = 0.6;
}
