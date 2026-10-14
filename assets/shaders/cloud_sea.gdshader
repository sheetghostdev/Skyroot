shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;

// A vast layer of soft, broken cloud far beneath the island: the top of the abyss.

uniform sampler2D noise_a : filter_linear_mipmap, repeat_enable;
uniform sampler2D noise_b : filter_linear_mipmap, repeat_enable;
uniform vec3 lit_col : source_color = vec3(0.97, 0.97, 1.0);
uniform vec3 shade_col : source_color = vec3(0.62, 0.68, 0.8);
uniform vec3 fade_col : source_color = vec3(0.30, 0.42, 0.62);
uniform float day = 1.0;
uniform vec2 drift = vec2(0.0);
uniform float density = 0.6;

varying vec3 wpos;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 p = wpos.xz;
	float big = texture(noise_a, p * 0.0011 + drift).r;
	float mid = texture(noise_b, p * 0.0052 - drift * 1.7).r;
	float fine = texture(noise_b, p * 0.021 + drift * 3.1).r;
	float c = big * 0.62 + mid * 0.3 + fine * 0.14;
	float cover = smoothstep(1.02 - density, 1.16 - density * 0.6, c);
	// puffy tops are brighter, thin edges darker and bluer
	float puff = smoothstep(0.0, 1.0, (c - (1.0 - density)) * 3.0);
	vec3 col = mix(shade_col, lit_col, clamp(puff * 0.8 + fine * 0.35, 0.0, 1.0)) * mix(0.1, 1.0, day);
	float dist = length(p - CAMERA_POSITION_WORLD.xz);
	float fade = smoothstep(90.0, 700.0, dist);
	ALBEDO = mix(col, fade_col * mix(0.1, 1.0, day), fade * 0.85);
	ALPHA = cover * (1.0 - fade * 0.45);
}
