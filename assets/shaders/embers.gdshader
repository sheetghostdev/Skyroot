// Glowing embers: bright in the dark, pulsing gently.
shader_type spatial;
render_mode unshaded, cull_back;

uniform sampler2DArray atlas : source_color, filter_nearest_mipmap, repeat_enable;
uniform float layer = 0.0;

void fragment() {
	vec4 t = texture(atlas, vec3(UV, layer));
	float pulse = 0.85 + 0.25 * sin(TIME * 2.3 + UV.x * 9.0) * sin(TIME * 1.7 + UV.y * 7.0);
	ALBEDO = t.rgb * pulse * 1.4;
}
