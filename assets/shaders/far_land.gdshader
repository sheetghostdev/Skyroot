// Islands seen from far off: a coarse heightfield in the colours of their top
// blocks.  Inside the square of loaded chunks it steps aside for the real thing.
shader_type spatial;
render_mode cull_back, diffuse_lambert;

uniform vec2 near_min = vec2(0.0);
uniform vec2 near_max = vec2(0.0);
varying vec3 wpos;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	if (wpos.x > near_min.x && wpos.x < near_max.x && wpos.z > near_min.y && wpos.z < near_max.y) {
		discard;
	}
	ALBEDO = COLOR.rgb;
	ROUGHNESS = 0.95;
}
