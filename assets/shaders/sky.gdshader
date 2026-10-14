shader_type sky;
render_mode use_debanding;

// Open sky above, endless hazy abyss below.

uniform vec3 zenith_day : source_color = vec3(0.24, 0.45, 0.78);
uniform vec3 horizon_day : source_color = vec3(0.70, 0.80, 0.90);
uniform vec3 abyss_day : source_color = vec3(0.30, 0.42, 0.62);
uniform vec3 zenith_night : source_color = vec3(0.01, 0.02, 0.05);
uniform vec3 horizon_night : source_color = vec3(0.05, 0.07, 0.13);
uniform vec3 abyss_night : source_color = vec3(0.01, 0.015, 0.04);
uniform vec3 sunset_col : source_color = vec3(1.0, 0.45, 0.18);
uniform vec3 overcast_col : source_color = vec3(0.62, 0.65, 0.70);
uniform float day = 1.0;
uniform float sunset = 0.0;
uniform float overcast = 0.0;
uniform float cloud_cover = 0.35;
uniform vec2 cloud_drift = vec2(0.0, 0.0);
uniform vec3 moon_dir = vec3(0.0, 1.0, 0.0);
uniform sampler2D cloud_noise : filter_linear_mipmap, repeat_enable;
uniform sampler2D cloud_detail : filter_linear_mipmap, repeat_enable;

float hash(vec3 p) {
	p = fract(p * 0.3183099 + 0.1);
	p *= 17.0;
	return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

void sky() {
	vec3 d = normalize(EYEDIR);
	float y = d.y;
	vec3 zen = mix(zenith_night, zenith_day, day);
	vec3 hor = mix(horizon_night, horizon_day, day);
	vec3 aby = mix(abyss_night, abyss_day, day);
	zen = mix(zen, overcast_col * mix(0.15, 0.85, day), overcast * 0.85);
	hor = mix(hor, overcast_col * mix(0.18, 1.0, day), overcast * 0.75);
	vec3 col;
	if (y >= 0.0) {
		col = mix(hor, zen, pow(clamp(y, 0.0, 1.0), 0.5));
	} else {
		col = mix(hor, aby, pow(clamp(-y, 0.0, 1.0), 0.38));
	}
	vec3 sdir = LIGHT0_DIRECTION;
	float sd = clamp(dot(d, sdir), 0.0, 1.0);
	float horizon_band = 1.0 - clamp(abs(y) * 1.6, 0.0, 1.0);
	col += sunset_col * sunset * (pow(sd, 6.0) * 0.9 + pow(sd, 1.5) * 0.25) * horizon_band * (1.0 - overcast * 0.7);
	col += mix(vec3(1.0, 0.9, 0.7), sunset_col, sunset) * pow(sd, 64.0) * 0.6 * day * (1.0 - overcast);
	if (LIGHT0_ENABLED && day > 0.02) {
		float disk = smoothstep(0.99955, 0.99975, sd);
		col += LIGHT0_COLOR * disk * 18.0 * (1.0 - overcast * 0.9);
	}
	// moon
	float md = dot(d, normalize(moon_dir));
	float moon = smoothstep(0.99925, 0.9995, md);
	col += vec3(0.85, 0.9, 1.0) * moon * (1.0 - day) * 1.6 * (1.0 - overcast);
	col += vec3(0.3, 0.38, 0.55) * pow(clamp(md, 0.0, 1.0), 80.0) * 0.25 * (1.0 - day);
	// stars
	if (y > -0.05) {
		vec3 sp = d * 220.0;
		vec3 cell = floor(sp);
		float h = hash(cell);
		float star = step(0.9965, h) * smoothstep(0.6, 0.0, length(fract(sp) - 0.5));
		float tw = 0.6 + 0.4 * sin(TIME * 3.0 + h * 50.0);
		col += vec3(0.9, 0.92, 1.0) * star * tw * (1.0 - day) * (1.0 - overcast) * smoothstep(-0.05, 0.25, y) * 1.4;
	}
	// clouds above
	if (y > 0.0) {
		vec2 uv = d.xz / (y + 0.12) * 0.22 + cloud_drift;
		float c = texture(cloud_noise, uv).r * 0.75 + texture(cloud_detail, uv * 3.1 + cloud_drift * 1.7).r * 0.35;
		float cov = clamp(cloud_cover + overcast * 0.5, 0.0, 1.0);
		float m = smoothstep(1.05 - cov, 1.35 - cov * 0.6, c);
		vec3 lit = mix(vec3(0.2, 0.22, 0.3), vec3(1.0, 0.98, 0.95), day);
		lit = mix(lit, overcast_col * mix(0.3, 0.95, day), overcast);
		lit += sunset_col * sunset * 0.55 * (0.5 + 0.5 * sd);
		vec3 shade = lit * mix(0.7, 0.92, c);
		col = mix(col, shade, m * smoothstep(0.0, 0.18, y) * 0.92);
	}
	COLOR = col;
}
