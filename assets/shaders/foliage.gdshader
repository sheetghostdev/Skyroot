shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx, cull_disabled;

// Leaves / crop foliage: vertex-colour albedo, gentle wind sway, soft
// translucency, darker interior.

uniform sampler2D noise_a : filter_linear_mipmap, repeat_enable;
uniform vec2 wind_dir = vec2(1.0, 0.3);
uniform float wind_strength = 0.35;
uniform float sway_scale = 1.0;      // how bendy (crops > tree leaves)
uniform float height_ref = 1.0;      // local height at which sway is full
uniform float translucency = 0.35;
uniform float wet = 0.0;
uniform vec4 tint : source_color = vec4(1.0);
uniform float dry = 0.0;
uniform vec3 dry_col : source_color = vec3(0.68, 0.58, 0.3);

varying vec3 wp;

void vertex() {
	wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec2 wd = normalize(wind_dir + vec2(0.0001));
	float n = texture(noise_a, wp.xz * 0.05 - wd * TIME * 0.04).r;
	float k = clamp(VERTEX.y / max(height_ref, 0.01), 0.0, 1.5);
	float flutter = sin(TIME * 4.3 + wp.x * 3.1 + wp.y * 2.7 + wp.z * 2.3) * 0.25;
	float sway = (sin(TIME * 1.6 + wp.x * 0.5 + wp.z * 0.4) * 0.4 + smoothstep(0.3, 0.9, n) * 0.9 + flutter);
	vec3 disp = vec3(wd.x, 0.0, wd.y) * sway * wind_strength * 0.05 * sway_scale * k * k;
	disp.y += flutter * 0.01 * wind_strength * sway_scale;
	VERTEX += (inverse(MODEL_MATRIX) * vec4(disp, 0.0)).xyz;
}

void fragment() {
	vec3 c = COLOR.rgb * tint.rgb;
	float n = texture(noise_a, wp.xz * 0.9 + wp.y * 0.3).r;
	c *= 0.86 + 0.28 * n;
	c = mix(c, dry_col * (0.8 + 0.3 * n), dry);
	c *= mix(1.0, 0.8, wet);
	ALBEDO = c;
	ROUGHNESS = 0.78 - wet * 0.3;
	SPECULAR = 0.35;
	BACKLIGHT = c * translucency;
}
