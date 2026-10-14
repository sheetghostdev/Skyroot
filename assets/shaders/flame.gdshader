// Flames: the flame tile on crossed quads, licking upward, added onto the scene.
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled;

uniform sampler2DArray atlas : source_color, filter_linear_mipmap, repeat_disable;
uniform float layer = 0.0;

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1, 0)), f.x), mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), f.x), f.y);
}

void fragment() {
	vec2 uv = UV;
	float n = noise(vec2(uv.x * 5.0, uv.y * 3.0 + TIME * 3.2));
	float n2 = noise(vec2(uv.x * 9.0 + 3.0, uv.y * 6.0 + TIME * 5.0));
	uv.x += (n - 0.5) * 0.22 * (1.0 - uv.y);
	uv.y += (n2 - 0.5) * 0.1;
	vec4 t = texture(atlas, vec3(clamp(uv, 0.0, 1.0), layer));
	float fade = smoothstep(0.0, 0.25, uv.y) * smoothstep(1.0, 0.85, uv.y);
	ALBEDO = t.rgb * 1.6;
	ALPHA = t.a * fade * (0.75 + n2 * 0.4);
}
