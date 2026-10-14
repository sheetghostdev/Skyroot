// Leaves and plants: alpha-tested, two-sided, swaying in the wind.  UV2.y is how
// much a vertex sways (0 at the roots).
shader_type spatial;
render_mode diffuse_lambert, specular_schlick_ggx, cull_disabled;

uniform sampler2DArray atlas : source_color, filter_nearest_mipmap_anisotropic, repeat_enable;
uniform float ao_light = 0.35;
uniform vec2 wind = vec2(1.0, 0.3);
uniform float wind_strength = 1.0;
varying flat float layer;

void vertex() {
	layer = UV2.x;
	float w = UV2.y;
	if (w != 0.0) {
		vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
		float t = TIME * (1.3 + length(wind) * 0.25);
		float s = sin(t + wp.x * 0.7 + wp.z * 0.5) * 0.6 + sin(t * 2.3 + wp.x * 1.9 - wp.z * 1.3) * 0.25;
		vec2 d = normalize(wind + vec2(0.001)) * (0.035 + length(wind) * 0.012) * wind_strength;
		VERTEX.xz += d * s * abs(w);
		VERTEX.y += s * 0.01 * abs(w);
	}
}

void fragment() {
	vec4 t = texture(atlas, vec3(UV, layer));
	if (t.a < 0.5) {
		discard;
	}
	ALBEDO = t.rgb * COLOR.rgb;
	AO = COLOR.a;
	AO_LIGHT_AFFECT = ao_light;
	ROUGHNESS = 0.9;
	SPECULAR = 0.2;
	BACKLIGHT = vec3(0.18, 0.22, 0.1);
	if (!FRONT_FACING) {
		NORMAL = -NORMAL;
	}
}
