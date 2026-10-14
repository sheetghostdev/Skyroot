shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_disabled;

// Grass tufts drawn with a MultiMesh.  UV.y = 0 at blade base, 1 at tip.
// INSTANCE_CUSTOM.rgb = tint, .a = dryness.

uniform sampler2D noise_a : filter_linear_mipmap, repeat_enable;
uniform vec3 base_col : source_color = vec3(0.20, 0.33, 0.11);
uniform vec3 mid_col : source_color = vec3(0.36, 0.52, 0.19);
uniform vec3 tip_col : source_color = vec3(0.62, 0.72, 0.33);
uniform vec3 dry_col : source_color = vec3(0.70, 0.62, 0.36);
uniform vec2 wind_dir = vec2(1.0, 0.3);
uniform float wind_strength = 0.35;
uniform float wetness = 0.0;
uniform vec4 clear_zone = vec4(0.0);   // (x, z, radius): grass lies flat here (around close-up work)

varying float h;
varying vec4 inst;
varying vec3 wp;

void vertex() {
	h = UV.y;
	inst = INSTANCE_CUSTOM;
	wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	if (clear_zone.z > 0.0) {
		float cz = 1.0 - smoothstep(clear_zone.z * 0.6, clear_zone.z, distance(wp.xz, clear_zone.xy));
		VERTEX.y *= 1.0 - 0.9 * cz;
	}
	vec2 wd = normalize(wind_dir + vec2(0.0001));
	float n = texture(noise_a, wp.xz * 0.045 - wd * TIME * 0.05).r;
	float gust = smoothstep(0.35, 0.85, n);
	float sway = sin(TIME * 2.1 + wp.x * 0.9 + wp.z * 0.7) * 0.35 + gust * 1.2;
	vec3 disp = vec3(wd.x, 0.0, wd.y) * sway * wind_strength * 0.16 * h * h;
	disp.y = -length(disp) * 0.4;
	VERTEX += (inverse(MODEL_MATRIX) * vec4(disp, 0.0)).xyz;
	vec3 up_local = normalize((inverse(MODEL_MATRIX) * vec4(0.0, 1.0, 0.0, 0.0)).xyz);
	NORMAL = normalize(mix(NORMAL, up_local, 0.75));
}

void fragment() {
	vec3 c = mix(base_col, mid_col, smoothstep(0.0, 0.45, h));
	c = mix(c, tip_col, smoothstep(0.45, 1.0, h));
	c *= inst.rgb;
	c = mix(c, dry_col * mix(0.8, 1.0, h), clamp(inst.a, 0.0, 1.0) * smoothstep(0.1, 0.9, h));
	c *= mix(1.0, 0.8, wetness);
	ALBEDO = c * mix(0.55, 1.0, smoothstep(0.0, 0.35, h));
	ROUGHNESS = 0.85 - wetness * 0.3;
	BACKLIGHT = c * 0.35;
}
