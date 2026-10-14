extends EntityView
## A compost heap: a mottled mound whose colour follows what's in it (fresh
## green, straw yellow, finished dark brown), growing with what's added and
## settling as it rots.  Wet heaps glisten; a working heap steams.

const GREEN := Color(0.30, 0.42, 0.16)
const BROWN := Color(0.66, 0.55, 0.30)
const HUMUS := Color(0.19, 0.13, 0.09)
const SOUR := Color(0.22, 0.24, 0.16)

var mound: MeshInstance3D
var mat: ShaderMaterial
var bits: Node3D
var steam: GPUParticles3D
var area_shape: CollisionShape3D
var _key := ""
var _bits_key := ""
var _t := 0.0


func _build() -> void:
	mound = MeshInstance3D.new()
	mat = Models.unique_material("Soil")
	mound.material_override = mat
	add_child(mound)
	bits = Node3D.new()
	add_child(bits)
	var cyl := CylinderShape3D.new()
	cyl.radius = 0.4
	cyl.height = 0.6
	var body := make_body(cyl, LAYER_INTERACT, "heap", Transform3D(Basis(), Vector3(0, 0.25, 0)))
	area_shape = body.get_child(0)
	steam = GPUParticles3D.new()
	steam.amount = 14
	steam.lifetime = 3.5
	steam.emitting = false
	steam.local_coords = false
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = 0.25
	pm.direction = Vector3(0, 1, 0)
	pm.spread = 12.0
	pm.initial_velocity_min = 0.08
	pm.initial_velocity_max = 0.18
	pm.gravity = Vector3(0, 0.05, 0)
	pm.scale_min = 0.5
	pm.scale_max = 1.1
	var curve := Curve.new()
	curve.add_point(Vector2(0, 0.4))
	curve.add_point(Vector2(1, 1.6))
	var ct := CurveTexture.new()
	ct.curve = curve
	pm.scale_curve = ct
	var grad := Gradient.new()
	grad.set_color(0, Color(1, 1, 1, 0.0))
	grad.set_color(1, Color(1, 1, 1, 0.0))
	grad.add_point(0.25, Color(1, 1, 1, 1.0))
	var gt := GradientTexture1D.new()
	gt.gradient = grad
	pm.color_ramp = gt
	steam.process_material = pm
	var quad := QuadMesh.new()
	quad.size = Vector2(0.35, 0.35)
	var sm := StandardMaterial3D.new()
	sm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	sm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	sm.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	sm.vertex_color_use_as_albedo = true
	sm.albedo_color = Color(0.92, 0.92, 0.9, 0.22)
	var soft := GradientTexture2D.new()
	soft.fill = GradientTexture2D.FILL_RADIAL
	soft.fill_from = Vector2(0.5, 0.5)
	soft.fill_to = Vector2(1.0, 0.5)
	var sg := Gradient.new()
	sg.set_color(0, Color(1, 1, 1, 1))
	sg.set_color(1, Color(1, 1, 1, 0))
	soft.gradient = sg
	soft.width = 64
	soft.height = 64
	sm.albedo_texture = soft
	quad.material = sm
	steam.draw_pass_1 = quad
	steam.position = Vector3(0, 0.3, 0)
	add_child(steam)


func _refresh(_keys: Array) -> void:
	var d := data()
	var r := CompostSim.radius(d)
	var m := maxf(0.001, CompostSim.mass(d))
	var fg := float(d.get("g", 0.0)) / m
	var fb := float(d.get("b", 0.0)) / m
	var air := float(d.get("air", 1.0))
	var key := "%.2f|%.1f|%.1f|%d" % [r, fg, fb, 1 if air < 0.15 else 0]
	if key != _key:
		_key = key
		mound.mesh = _mound_mesh(r, fg, fb, air < 0.15)
		(area_shape.shape as CylinderShape3D).radius = r
		area_shape.position = Vector3(0, r * 0.3, 0)
		_place_bits(d, r)
	var W := CompostSim.wetness(d)
	mat.set_shader_parameter("wet", clampf((W - 0.35) * 1.8, 0.0, 0.9))
	var T := float(d.get("T", 15.0))
	var hot := clampf((T - 34.0) / 22.0, 0.0, 1.0)
	steam.emitting = hot > 0.05
	steam.amount_ratio = clampf(0.25 + hot, 0.0, 1.0)
	(steam.process_material as ParticleProcessMaterial).emission_sphere_radius = r * 0.6
	steam.position = Vector3(0, r * 0.45, 0)


func _process(delta: float) -> void:
	_t += delta
	# the steam shows best in cool, still air
	if steam.emitting:
		var cool := clampf((22.0 - Climate.base_temp()) / 12.0, 0.25, 1.0)
		var sm: StandardMaterial3D = (steam.draw_pass_1 as QuadMesh).material
		sm.albedo_color.a = 0.12 + 0.18 * cool


func _mound_mesh(r: float, fg: float, fb: float, sour: bool) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var noise := FastNoiseLite.new()
	noise.seed = entity_id
	noise.frequency = 2.4
	var rings := 12
	var segs := 32
	var h := r * 0.62
	var fh := clampf(1.0 - fg - fb, 0.0, 1.0)
	var base := HUMUS
	if sour:
		base = SOUR
	var verts: Array = []
	var fine := FastNoiseLite.new()
	fine.seed = entity_id + 17
	fine.frequency = 1.0
	for i in rings + 1:
		var row: Array = []
		var v := float(i) / rings          # 0 at the rim, 1 at the top
		var ang := v * PI * 0.5
		for j in segs:
			var a := float(j) / segs * TAU
			var dir := Vector3(cos(a), 0, sin(a))
			# an irregular outline and a lumpy top, not a dome
			var lobe := 1.0 + 0.2 * noise.get_noise_2d(cos(a) * 1.3, sin(a) * 1.3)
			var rr := r * cos(ang) * lobe
			var y := h * sin(ang) * (1.0 + 0.15 * noise.get_noise_2d(cos(a) * 2.0 + 5.0, sin(a) * 2.0))
			var p := dir * rr + Vector3(0, y, 0)
			var n1 := noise.get_noise_3dv(p * 2.2)
			var n2 := fine.get_noise_3dv(p * 14.0)
			var bump := (n1 * 0.12 + n2 * 0.05) * r * (0.25 + 0.75 * v)
			p += (dir * cos(ang) + Vector3(0, sin(ang) + 0.3, 0)).normalized() * bump
			if i == 0:
				p.y = -0.02
			# patches of what's in it: straw flecks, fresh greens, dark finished compost
			var k := fine.get_noise_3dv(p * 30.0) * 0.5 + 0.5
			var col := base
			if k < fg:
				col = GREEN.lerp(Color(0.42, 0.52, 0.2), fine.get_noise_3dv(p * 50.0) * 0.5 + 0.5)
			elif k < fg + fb:
				col = BROWN.lerp(Color(0.8, 0.7, 0.42), fine.get_noise_3dv(p * 47.0) * 0.5 + 0.5)
			col = col.lerp(base, clampf(fh * 0.55 + (1.0 - v) * 0.2, 0.0, 0.8) * (0.6 if k < fg + fb else 1.0))
			# hollows are darker and damper
			col *= 0.72 + 0.5 * clampf(0.5 + n2 * 1.2, 0.0, 1.0)
			row.append([p, col.srgb_to_linear()])
		verts.append(row)
	for i in rings:
		for j in segs:
			var j2 := (j + 1) % segs
			var a: Array = verts[i][j]
			var b: Array = verts[i][j2]
			var c: Array = verts[i + 1][j]
			var dd: Array = verts[i + 1][j2]
			for tri in [[a, c, b], [b, c, dd]]:
				var p0: Vector3 = tri[0][0]
				var p1: Vector3 = tri[1][0]
				var p2: Vector3 = tri[2][0]
				# front faces wind clockwise seen from outside
				if (p1 - p0).cross(p2 - p0).dot((p0 + p1 + p2) / 3.0 + Vector3(0, 0.05, 0)) > 0.0:
					tri = [tri[0], tri[2], tri[1]]
				for vv in tri:
					st.set_color(vv[1])
					st.add_vertex(vv[0])
	st.generate_normals()
	return st.commit()


func _place_bits(d: Dictionary, r: float) -> void:
	## A few recognisable pieces on top: leaves and grass for greens, straw for browns.
	var g := float(d.get("g", 0.0))
	var b := float(d.get("b", 0.0))
	var ng := clampi(int(ceil(g / 0.3)), 0, 8)
	var nb := clampi(int(ceil(b / 0.15)), 0, 7)
	var key := "%d|%d|%.1f" % [ng, nb, r]
	if key == _bits_key:
		return
	_bits_key = key
	for c in bits.get_children():
		c.queue_free()
	var rng := RandomNumberGenerator.new()
	rng.seed = entity_id * 7 + 1
	var paths: Array = []
	for i in ng:
		paths.append("res://assets/models/items/leaves.glb" if i % 2 == 0 else "res://assets/models/items/grass.glb")
	for i in nb:
		paths.append("res://assets/models/items/straw.glb")
	var h := r * 0.62
	for p in paths:
		var inst := Models.instance(String(p))
		if inst == null:
			continue
		var a := rng.randf() * TAU
		var rr := rng.randf_range(0.0, r * 0.7)
		var y := h * sqrt(maxf(0.0, 1.0 - (rr / r) * (rr / r))) + 0.01
		inst.position = Vector3(cos(a) * rr, y, sin(a) * rr)
		# lying on the slope where it was tossed
		var tilt := (rr / r) * 0.7
		inst.rotation = Vector3(-sin(a) * tilt + rng.randf_range(-0.2, 0.2), rng.randf() * TAU, cos(a) * tilt + rng.randf_range(-0.2, 0.2))
		inst.scale = Vector3.ONE * rng.randf_range(0.9, 1.3)
		bits.add_child(inst)


func interaction_point(_part: String) -> Vector3:
	return global_position + Vector3(0, 0.3, 0)
