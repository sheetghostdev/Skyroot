shader_type spatial;
render_mode blend_mix, depth_draw_always, cull_back, diffuse_burley, specular_schlick_ggx;

uniform sampler2D depth_tex : hint_depth_texture, filter_linear;
uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform sampler2D wave_a : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D wave_b : hint_normal, filter_linear_mipmap, repeat_enable;
uniform vec3 shallow_col : source_color = vec3(0.36, 0.52, 0.46);
uniform vec3 deep_col : source_color = vec3(0.08, 0.20, 0.24);
uniform float clarity = 1.6;
uniform float rain = 0.0;
uniform float wind = 0.3;

varying vec3 wpos;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 uv = wpos.xz;
	float t = TIME * (0.6 + wind);
	vec3 na = texture(wave_a, uv * 0.35 + vec2(t * 0.013, t * 0.008)).rgb;
	vec3 nb = texture(wave_b, uv * 0.8 - vec2(t * 0.009, -t * 0.015)).rgb;
	vec3 nr = texture(wave_b, uv * 3.0 + vec2(t * 0.11, t * 0.07)).rgb;
	vec3 nmap = normalize(mix(na + nb - 1.0, nr, rain * 0.5));
	NORMAL_MAP = nmap * 0.5 + 0.5;
	NORMAL_MAP_DEPTH = 0.35 + rain * 0.6;

	float d = texture(depth_tex, SCREEN_UV).r;
	vec4 v = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, d, 1.0);
	v.xyz /= v.w;
	float thick = clamp(VERTEX.z - v.z, 0.0, 10.0);
	float a = 1.0 - exp(-thick * clarity);
	vec2 off = (nmap.xy - 0.5) * 0.02 * clamp(thick * 4.0, 0.0, 1.0);
	vec3 refr = textureLod(screen_tex, SCREEN_UV + off, 1.5).rgb;
	vec3 tint = mix(shallow_col, deep_col, clamp(thick * 1.4, 0.0, 1.0));
	float fres = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 4.0);
	vec3 col = mix(refr * mix(vec3(1.0), shallow_col * 1.4, 0.55), tint, a * 0.85);
	float edge = 1.0 - smoothstep(0.0, 0.05, thick);
	ALBEDO = mix(col, vec3(0.85, 0.9, 0.88), edge * 0.35);
	ROUGHNESS = 0.06 + rain * 0.12;
	METALLIC = 0.0;
	SPECULAR = 0.6;
	ALPHA = clamp(0.55 + fres * 0.4 + a * 0.2, 0.0, 1.0) * smoothstep(0.0, 0.025, thick);
}
