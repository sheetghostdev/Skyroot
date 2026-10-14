// Opaque blocks.  UV2.x = texture layer; COLOR.rgb = tint, COLOR.a = skylight x
// corner occlusion, which darkens ambient light (and some of the direct light,
// for definition) - the sun itself is shadowed by the real shadow map.
shader_type spatial;
render_mode diffuse_lambert, specular_schlick_ggx;

uniform sampler2DArray atlas : source_color, filter_nearest_mipmap_anisotropic, repeat_enable;
uniform float ao_light = 0.45;
uniform float night_floor = 0.0;
varying flat float layer;

void vertex() {
	layer = UV2.x;
}

void fragment() {
	vec4 t = texture(atlas, vec3(UV, layer));
	ALBEDO = t.rgb * COLOR.rgb;
	float a = max(COLOR.a, night_floor);
	AO = a;
	AO_LIGHT_AFFECT = ao_light;
	ROUGHNESS = 0.92;
	SPECULAR = 0.25;
}
