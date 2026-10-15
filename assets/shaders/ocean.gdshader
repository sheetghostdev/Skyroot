// The open sea beyond the blocks near you: a plane at the water's surface with
// slow swells of light, fresnel and sun glints.  Inside the square of loaded
// chunks it steps aside (the block water is drawn there).
shader_type spatial;
render_mode blend_mix, depth_draw_always, cull_back, diffuse_lambert, specular_schlick_ggx;

uniform vec3 water_col = vec3(0.10, 0.40, 0.46);
uniform vec3 deep_col = vec3(0.03, 0.15, 0.22);
uniform vec2 near_min = vec2(0.0);
uniform vec2 near_max = vec2(0.0);
varying vec3 wpos;

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1, 0)), f.x), mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), f.x), f.y);
}

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	if (wpos.x > near_min.x && wpos.x < near_max.x && wpos.z > near_min.y && wpos.z < near_max.y) {
		discard;
	}
	vec2 p = wpos.xz * 0.08;
	float n1 = noise(p + vec2(TIME * 0.05, TIME * 0.03));
	float n2 = noise(p * 2.7 - vec2(TIME * 0.04, -TIME * 0.06));
	vec3 nrm = normalize(vec3((n1 - 0.5) * 0.35 + (n2 - 0.5) * 0.2, 1.0, (n2 - 0.5) * 0.35 - (n1 - 0.5) * 0.2));
	NORMAL = (VIEW_MATRIX * vec4(nrm, 0.0)).xyz;
	float fres = pow(1.0 - clamp(dot(normalize(VIEW), NORMAL), 0.0, 1.0), 3.0);
	ALBEDO = mix(water_col, deep_col, 0.35 + n1 * 0.25);
	ALPHA = clamp(0.88 + fres * 0.1, 0.0, 1.0);
	ROUGHNESS = 0.06;
	METALLIC = 0.0;
	SPECULAR = 0.7;
}
