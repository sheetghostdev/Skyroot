// The cracks spreading over a block while you break it.
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_back;

uniform sampler2DArray atlas : source_color, filter_nearest_mipmap, repeat_enable;
uniform float layer = 0.0;

void fragment() {
	vec4 t = texture(atlas, vec3(UV * vec2(3.0, 2.0), layer));
	ALBEDO = t.rgb;
	ALPHA = t.a * 0.85;
}
