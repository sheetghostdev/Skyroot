shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

// Island ground.  Vertex COLOR carries material weights (r grass, g soil,
// b clay, a rock).  UV2 carries (soil moisture 0..1, tilled 0/1).

uniform sampler2D noise_a : filter_linear_mipmap, repeat_enable;
uniform sampler2D noise_b : filter_linear_mipmap, repeat_enable;
uniform sampler2D noise_n : hint_normal, filter_linear_mipmap, repeat_enable;

uniform vec3 grass_a : source_color = vec3(0.32, 0.46, 0.18);
uniform vec3 grass_b : source_color = vec3(0.47, 0.58, 0.24);
uniform vec3 soil_a : source_color = vec3(0.27, 0.19, 0.13);
uniform vec3 soil_b : source_color = vec3(0.40, 0.29, 0.20);
uniform vec3 clay_a : source_color = vec3(0.55, 0.31, 0.21);
uniform vec3 clay_b : source_color = vec3(0.69, 0.43, 0.30);
uniform vec3 rock_a : source_color = vec3(0.42, 0.40, 0.37);
uniform vec3 rock_b : source_color = vec3(0.60, 0.58, 0.54);
uniform float rain_wet = 0.0;

varying vec3 wpos;
varying vec2 extra;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	extra = UV2;
}

void fragment() {
	vec2 p = wpos.xz;
	float n1 = texture(noise_a, p * 0.06).r;
	float n2 = texture(noise_b, p * 0.45).r;
	float n3 = texture(noise_b, p * 1.9 + vec2(0.37, 0.71)).r;
	float n4 = texture(noise_a, p * 0.9).r;

	vec4 w = max(COLOR, vec4(0.0));
	vec4 jitter = (vec4(n3, n2, n4, n2 * 0.5 + n3 * 0.5) - 0.5) * 0.9;
	vec4 ww = max(w + jitter * w * (1.0 - w) * 2.0, vec4(0.0));
	ww = ww * ww;
	ww /= max(dot(ww, vec4(1.0)), 1e-4);

	float moist = clamp(smoothstep(0.5, 1.0, extra.x) + rain_wet * 0.6, 0.0, 1.0);
	float tilled = clamp(extra.y, 0.0, 1.0);

	vec3 grass = mix(grass_a, grass_b, smoothstep(0.25, 0.75, n1)) * (0.82 + 0.32 * n3);
	grass = mix(grass, grass * vec3(1.08, 1.02, 0.78), smoothstep(0.62, 0.8, n4) * 0.5);

	vec3 soil = mix(soil_a, soil_b, smoothstep(0.2, 0.8, n2)) * (0.78 + 0.35 * n3);
	float furrow = 0.5 + 0.5 * sin(p.y * 24.0 + n2 * 3.0);
	soil = mix(soil, soil * (0.62 + 0.5 * furrow), tilled);

	vec3 clay = mix(clay_a, clay_b, smoothstep(0.2, 0.85, n1 * 0.6 + n2 * 0.5)) * (0.9 + 0.16 * n3);
	float streak = smoothstep(0.45, 0.55, fract(p.x * 2.1 + n2 * 2.5));
	clay *= 0.94 + 0.08 * streak;

	vec3 rock = mix(rock_a, rock_b, smoothstep(0.25, 0.8, n2)) * (0.78 + 0.32 * n3);

	vec3 col = grass * ww.x + soil * ww.y + clay * ww.z + rock * ww.w;
	float porous = ww.y + ww.z + ww.x * 0.35;
	col *= mix(1.0, 0.6, moist * porous);

	ALBEDO = col;
	// (bare rock is matte: in shade it mustn't mirror the blue sky like a puddle)
	ROUGHNESS = clamp(mix(0.93, 0.5, moist * porous) - ww.z * 0.1 + ww.w * 0.07, 0.3, 1.0);
	SPECULAR = 0.35 - 0.22 * ww.w;
	NORMAL_MAP = texture(noise_n, p * 0.8).rgb;
	NORMAL_MAP_DEPTH = 0.55 + ww.w * 0.4 + tilled * 0.5;
}
