shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

// Generic material for Blender-made models: colour from vertex COLOR, plus
// world-space triplanar detail so surfaces don't look plasticky.

uniform sampler2D detail : filter_linear_mipmap, repeat_enable;
uniform sampler2D detail_n : hint_normal, filter_linear_mipmap, repeat_enable;
uniform vec4 tint : source_color = vec4(1.0);
uniform float detail_scale = 3.0;
uniform float detail_strength = 0.22;
uniform float normal_strength = 0.6;
uniform float roughness = 0.85;
uniform float specular = 0.4;
uniform float wet = 0.0;
uniform float emission_strength = 0.0;
uniform vec3 emission_col : source_color = vec3(1.0, 0.4, 0.1);
uniform float char_amount = 0.0;
uniform float use_local = 0.0;

varying vec3 tpos;
varying vec3 tnrm;

void vertex() {
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 wn = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	tpos = mix(wp, VERTEX, use_local);
	tnrm = mix(wn, NORMAL, use_local);
}

void fragment() {
	vec3 bl = pow(abs(tnrm), vec3(4.0));
	bl /= dot(bl, vec3(1.0));
	vec3 p = tpos * detail_scale;
	float d = texture(detail, p.zy).r * bl.x + texture(detail, p.xz).r * bl.y + texture(detail, p.xy).r * bl.z;
	vec3 nm = texture(detail_n, p.zy).rgb * bl.x + texture(detail_n, p.xz).rgb * bl.y + texture(detail_n, p.xy).rgb * bl.z;
	vec3 base = COLOR.rgb * tint.rgb;
	base *= 1.0 + (d - 0.5) * 2.0 * detail_strength;
	base = mix(base, vec3(0.06, 0.05, 0.05), char_amount * (0.7 + 0.3 * d));
	base *= mix(1.0, 0.7, wet);
	ALBEDO = base;
	ROUGHNESS = clamp(roughness - wet * 0.35, 0.05, 1.0);
	SPECULAR = specular;
	NORMAL_MAP = nm;
	NORMAL_MAP_DEPTH = normal_strength;
	EMISSION = emission_col * emission_strength * (0.6 + 0.8 * d);
}
