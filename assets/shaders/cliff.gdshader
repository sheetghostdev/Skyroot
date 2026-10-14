shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

// Island flanks and rocky underside.  Vertex COLOR: r = soil band at the lip,
// g = moss allowance, a = baked occlusion.

uniform sampler2D noise_a : filter_linear_mipmap, repeat_enable;
uniform sampler2D noise_b : filter_linear_mipmap, repeat_enable;
uniform sampler2D noise_n : hint_normal, filter_linear_mipmap, repeat_enable;
uniform vec3 rock_a : source_color = vec3(0.44, 0.41, 0.37);
uniform vec3 rock_b : source_color = vec3(0.60, 0.56, 0.50);
uniform vec3 rock_dark : source_color = vec3(0.20, 0.19, 0.22);
uniform vec3 soil_col : source_color = vec3(0.30, 0.21, 0.15);
uniform vec3 moss_col : source_color = vec3(0.33, 0.45, 0.20);

varying vec3 wpos;
varying vec3 wnrm;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wnrm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

vec3 tri(sampler2D t, vec3 p, vec3 bl, float s) {
	return texture(t, p.zy * s).rgb * bl.x + texture(t, p.xz * s).rgb * bl.y + texture(t, p.xy * s).rgb * bl.z;
}

void fragment() {
	vec3 bl = pow(abs(wnrm), vec3(4.0));
	bl /= dot(bl, vec3(1.0));
	float n = tri(noise_b, wpos, bl, 0.35).r;
	float nf = tri(noise_b, wpos, bl, 1.6).r;
	float nl = tri(noise_a, wpos, bl, 0.05).r;
	float strata = 0.5 + 0.5 * sin(wpos.y * 6.0 + n * 5.0 + nl * 6.0);
	vec3 col = mix(rock_a, rock_b, clamp(strata * 0.55 + n * 0.45, 0.0, 1.0)) * (0.82 + 0.3 * nf);
	col = mix(col, col * vec3(1.05, 0.93, 0.85), smoothstep(0.55, 0.75, nl) * 0.6);
	float depth = clamp(-wpos.y / 16.0, 0.0, 1.0);
	col = mix(col, rock_dark, depth * 0.65);
	col = mix(col, soil_col * (0.75 + 0.45 * nf), clamp(COLOR.r, 0.0, 1.0));
	float up = wnrm.y;
	float moss = smoothstep(0.25, 0.75, up + (n - 0.5) * 0.6) * COLOR.g * (1.0 - depth * 0.7);
	col = mix(col, moss_col * (0.75 + 0.45 * nf), moss);
	ALBEDO = col * mix(0.55, 1.0, COLOR.a);
	ROUGHNESS = 0.9 - moss * 0.05;
	SPECULAR = 0.3;
	NORMAL_MAP = tri(noise_n, wpos, bl, 0.6);
	NORMAL_MAP_DEPTH = 1.6;
}
