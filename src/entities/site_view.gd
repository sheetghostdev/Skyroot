extends EntityView
## A fire site as everyone sees it: flames and sparks over the bed, smoke whose
## colour tells what the fire is doing (white steam, thick yellow-grey smoke,
## thin blue), the glow of embers, a blackened ash bed, and - when it has been
## covered - the packed earth dome with its vents breathing smoke.

static var _soft: Texture2D
static var _flame_tex: Texture2D

var body: Area3D
var shape: CollisionShape3D
var bed: MeshInstance3D
var dome: MeshInstance3D
var flames: GPUParticles3D
var sparks: GPUParticles3D
var smoke: GPUParticles3D
var light: OmniLight3D
var snd_small: AudioStreamPlayer3D
var snd_large: AudioStreamPlayer3D
var snd_mound: AudioStreamPlayer3D
var _smoke_mat: ParticleProcessMaterial
var _jet_mat: ParticleProcessMaterial
var _jet_mesh: QuadMesh
var _flame_mat: ParticleProcessMaterial
var _vent_nodes: Array = []
var _t := 0.0
var _flame := 0.0
var _glow := 0.0
var _smoke := 0.0
var _was_flaming := false
var _shell_key := ""


static func soft_tex() -> Texture2D:
	if _soft == null:
		var g := Gradient.new()
		g.set_color(0, Color(1, 1, 1, 1))
		g.set_color(1, Color(1, 1, 1, 0))
		g.add_point(0.45, Color(1, 1, 1, 0.55))
		var t := GradientTexture2D.new()
		t.gradient = g
		t.fill = GradientTexture2D.FILL_RADIAL
		t.fill_from = Vector2(0.5, 0.5)
		t.fill_to = Vector2(0.5, 0.0)
		t.width = 64
		t.height = 64
		_soft = t
	return _soft


static func flame_tex() -> Texture2D:
	if _flame_tex == null:
		var img := Image.create(48, 64, false, Image.FORMAT_RGBA8)
		for y in 64:
			for x in 48:
				var u := (x - 23.5) / 24.0
				var v := y / 63.0  # 0 top .. 1 bottom
				var w := lerpf(0.15, 0.95, pow(v, 0.7))
				var a := clampf(1.0 - absf(u) / maxf(w, 0.05), 0.0, 1.0)
				a *= smoothstep(0.0, 0.35, v) * smoothstep(1.0, 0.8, v)
				img.set_pixel(x, y, Color(1, 1, 1, a * a))
		_flame_tex = ImageTexture.create_from_image(img)
	return _flame_tex


static func clear_cache() -> void:
	_soft = null
	_flame_tex = null


func _build() -> void:
	body = Area3D.new()
	body.monitoring = false
	body.monitorable = false
	body.collision_layer = LAYER_INTERACT
	body.collision_mask = 0
	body.set_meta("eid", entity_id)
	body.set_meta("part", "site")
	shape = CollisionShape3D.new()
	body.add_child(shape)
	add_child(body)
	bed = MeshInstance3D.new()
	bed.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(bed)
	dome = MeshInstance3D.new()
	dome.material_override = Models.material_for("Soil")
	add_child(dome)
	light = OmniLight3D.new()
	light.light_color = Color(1.0, 0.62, 0.3)
	light.omni_range = 7.0
	light.omni_attenuation = 1.6
	light.light_energy = 0.0
	light.shadow_enabled = false
	light.position = Vector3(0, 0.45, 0)
	add_child(light)
	_make_flames()
	_make_sparks()
	_make_smoke()
	snd_small = Sfx.make_loop_player("fire_small", self, -60.0, 22.0)
	snd_large = Sfx.make_loop_player("fire_large", self, -60.0, 30.0)
	snd_mound = Sfx.make_loop_player("mound_smolder", self, -60.0, 18.0)
	for sp in [snd_small, snd_large, snd_mound]:
		if sp and sp.stream:
			sp.play()


func _make_flames() -> void:
	flames = GPUParticles3D.new()
	flames.amount = 48
	flames.lifetime = 0.7
	flames.local_coords = false
	flames.emitting = false
	_flame_mat = ParticleProcessMaterial.new()
	_flame_mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	_flame_mat.emission_sphere_radius = 0.15
	_flame_mat.direction = Vector3(0, 1, 0)
	_flame_mat.spread = 12.0
	_flame_mat.initial_velocity_min = 0.35
	_flame_mat.initial_velocity_max = 0.8
	_flame_mat.gravity = Vector3(0, 0.6, 0)
	_flame_mat.damping_min = 0.4
	_flame_mat.damping_max = 0.9
	_flame_mat.scale_min = 0.7
	_flame_mat.scale_max = 1.3
	var sc := Curve.new()
	sc.add_point(Vector2(0.0, 0.5))
	sc.add_point(Vector2(0.25, 1.0))
	sc.add_point(Vector2(1.0, 0.15))
	var sct := CurveTexture.new()
	sct.curve = sc
	_flame_mat.scale_curve = sct
	var g := Gradient.new()
	g.set_color(0, Color(1.0, 0.95, 0.75, 1.0))
	g.add_point(0.25, Color(1.0, 0.65, 0.2, 0.9))
	g.add_point(0.65, Color(0.9, 0.25, 0.05, 0.5))
	g.set_color(g.get_point_count() - 1, Color(0.3, 0.05, 0.02, 0.0))
	var gt := GradientTexture1D.new()
	gt.gradient = g
	_flame_mat.color_ramp = gt
	flames.process_material = _flame_mat
	var q := QuadMesh.new()
	q.size = Vector2(0.22, 0.32)
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	m.vertex_color_use_as_albedo = true
	m.albedo_texture = flame_tex()
	m.albedo_color = Color(1.6, 1.25, 1.0)
	m.disable_receive_shadows = true
	q.material = m
	flames.draw_pass_1 = q
	flames.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	flames.position = Vector3(0, 0.08, 0)
	add_child(flames)


func _make_sparks() -> void:
	sparks = GPUParticles3D.new()
	sparks.amount = 16
	sparks.lifetime = 1.6
	sparks.local_coords = false
	sparks.emitting = false
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = 0.12
	pm.direction = Vector3(0, 1, 0)
	pm.spread = 25.0
	pm.initial_velocity_min = 0.8
	pm.initial_velocity_max = 2.0
	pm.gravity = Vector3(0, 0.3, 0)
	pm.turbulence_enabled = true
	pm.turbulence_noise_strength = 0.6
	pm.scale_min = 0.5
	pm.scale_max = 1.0
	var g := Gradient.new()
	g.set_color(0, Color(1.0, 0.8, 0.4, 1.0))
	g.set_color(1, Color(1.0, 0.3, 0.05, 0.0))
	var gt := GradientTexture1D.new()
	gt.gradient = g
	pm.color_ramp = gt
	sparks.process_material = pm
	var q := QuadMesh.new()
	q.size = Vector2(0.018, 0.018)
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	m.vertex_color_use_as_albedo = true
	m.albedo_texture = soft_tex()
	m.albedo_color = Color(2.0, 1.4, 0.8)
	q.material = m
	sparks.draw_pass_1 = q
	sparks.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	sparks.position = Vector3(0, 0.15, 0)
	add_child(sparks)


func _make_smoke() -> void:
	smoke = GPUParticles3D.new()
	smoke.amount = 40
	smoke.lifetime = 6.0
	smoke.local_coords = false
	smoke.emitting = false
	smoke.visibility_aabb = AABB(Vector3(-6, -1, -6), Vector3(12, 14, 12))
	_smoke_mat = ParticleProcessMaterial.new()
	_smoke_mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	_smoke_mat.emission_sphere_radius = 0.15
	_smoke_mat.direction = Vector3(0, 1, 0)
	_smoke_mat.spread = 15.0
	_smoke_mat.initial_velocity_min = 0.25
	_smoke_mat.initial_velocity_max = 0.5
	_smoke_mat.gravity = Vector3(0, 0.12, 0)
	_smoke_mat.damping_min = 0.05
	_smoke_mat.damping_max = 0.15
	_smoke_mat.turbulence_enabled = true
	_smoke_mat.turbulence_noise_strength = 0.35
	_smoke_mat.turbulence_noise_scale = 3.0
	_smoke_mat.angle_min = -180.0
	_smoke_mat.angle_max = 180.0
	_smoke_mat.angular_velocity_min = -20.0
	_smoke_mat.angular_velocity_max = 20.0
	var sc := Curve.new()
	sc.add_point(Vector2(0.0, 0.25))
	sc.add_point(Vector2(1.0, 1.0))
	var sct := CurveTexture.new()
	sct.curve = sc
	_smoke_mat.scale_curve = sct
	_smoke_mat.scale_min = 0.8
	_smoke_mat.scale_max = 1.4
	_set_smoke_colour(0.0, 0.5)
	smoke.process_material = _smoke_mat
	var q := QuadMesh.new()
	q.size = Vector2(0.9, 0.9)
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	m.vertex_color_use_as_albedo = true
	m.albedo_texture = soft_tex()
	m.disable_receive_shadows = true
	q.material = m
	smoke.draw_pass_1 = q
	smoke.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	smoke.position = Vector3(0, 0.25, 0)
	add_child(smoke)
	# small jets for vents and gaps in an earth mound
	_jet_mat = ParticleProcessMaterial.new()
	_jet_mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	_jet_mat.emission_sphere_radius = 0.015
	_jet_mat.direction = Vector3(0, 1, 0)
	_jet_mat.spread = 20.0
	_jet_mat.initial_velocity_min = 0.15
	_jet_mat.initial_velocity_max = 0.3
	_jet_mat.gravity = Vector3(0, 0.15, 0)
	_jet_mat.turbulence_enabled = true
	_jet_mat.turbulence_noise_strength = 0.3
	_jet_mat.angle_min = -180.0
	_jet_mat.angle_max = 180.0
	_jet_mat.scale_curve = sct
	_jet_mat.scale_min = 0.5
	_jet_mat.scale_max = 0.9
	_jet_mat.color_ramp = _smoke_mat.color_ramp
	_jet_mesh = QuadMesh.new()
	_jet_mesh.size = Vector2(0.45, 0.45)
	_jet_mesh.material = m


func _set_smoke_colour(sc: float, density: float) -> void:
	## 0 white steam, 1 thick yellow-grey smoke, 2 thin blue.
	var c := Color(0.92, 0.92, 0.9)
	if sc <= 1.0:
		c = Color(0.93, 0.93, 0.92).lerp(Color(0.62, 0.58, 0.48), sc)
	else:
		c = Color(0.55, 0.62, 0.78)
	var a := clampf(0.08 + density * 0.3, 0.04, 0.38) * (0.55 if sc > 1.5 else 1.0)
	var g := Gradient.new()
	g.set_color(0, Color(c, 0.0))
	g.add_point(0.12, Color(c, a))
	g.add_point(0.5, Color(c.lerp(Color(0.8, 0.8, 0.82), 0.4), a * 0.6))
	g.set_color(g.get_point_count() - 1, Color(c, 0.0))
	var gt := GradientTexture1D.new()
	gt.gradient = g
	_smoke_mat.color_ramp = gt
	if _jet_mat:
		_jet_mat.color_ramp = gt


func _refresh(keys: Array) -> void:
	var d := data()
	var r := float(d.get("r", 0.25))
	var covered := FireSim.shell_coverage(d) > 0.3
	var shk := "%s|%s|%.2f|%.2f" % [str(hash(d.get("shell", []))), str(d.get("vents", [])), r, float(d.get("h", 0.1))]
	if shk != _shell_key:
		_shell_key = shk
		_build_dome(d)
	# collider: the dome when covered, otherwise a low disc over the bed
	if covered:
		var rr := FireSim.dome_radii(d)
		var pts := PackedVector3Array()
		for k in FireSim.CELLS:
			pts.append(FireSim.cell_point(k, d, Vector3.ZERO) * 1.04)
		for j in 12:
			var a := j * TAU / 12.0
			pts.append(Vector3(cos(a) * rr.x * 1.04, 0.0, sin(a) * rr.x * 1.04))
		var hull := ConvexPolygonShape3D.new()
		hull.points = pts
		shape.shape = hull
		shape.transform = Transform3D.IDENTITY
	else:
		var cyl := CylinderShape3D.new()
		cyl.radius = r + 0.05
		cyl.height = 0.08
		shape.shape = cyl
		shape.transform = Transform3D(Basis(), Vector3(0, 0.02, 0))
	if keys.has("r") or keys.has("ash_n") or keys.has("peak") or bed.mesh == null:
		_build_bed(d)
	var sc := float(d.get("sc", 0.0))
	_set_smoke_colour(sc, float(d.get("smoke", 0.0)))
	var flaming := float(d.get("flame", 0.0)) > 0.1
	if _was_flaming and not flaming and not bool(d.get("lit", false)):
		Sfx.play("fire_out", global_position + Vector3(0, 0.3, 0), -8.0)
	_was_flaming = flaming
	# emitters follow the shape of the fire
	_flame_mat.emission_sphere_radius = clampf(r * 0.6, 0.06, 0.5)
	_smoke_mat.emission_sphere_radius = clampf(r * 0.5, 0.08, 0.4)
	if covered:
		var rr2 := FireSim.dome_radii(d)
		smoke.position = Vector3(0, rr2.y * 0.9, 0)
		_smoke_mat.emission_sphere_radius = rr2.x * 0.5
	else:
		smoke.position = Vector3(0, 0.25 + float(d.get("h", 0.1)) * 0.6, 0)


func _build_bed(d: Dictionary) -> void:
	## Scorched ground under a fire that has burnt, pale ash in the middle.
	var r := float(d.get("r", 0.25))
	var burnt := int(d.get("peak", 0)) > 250
	var ash := clampf(float(d.get("ash_c", 0.0)) / 0.2 + float(d.get("ash_n", 0.0)) / 0.06, 0.0, 1.0)
	if not burnt and ash <= 0.0:
		bed.mesh = null
		return
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var seg := 28
	var rings := 4
	var rng := RandomNumberGenerator.new()
	rng.seed = entity_id
	var R := r + 0.18
	var verts: Array = []
	for i in rings + 1:
		var row: Array = []
		var f := float(i) / rings
		for j in seg:
			var a := float(j) / seg * TAU
			var wob := 1.0 + rng.randf_range(-0.12, 0.12) * f
			var p := Vector3(cos(a) * R * f * wob, 0.012 + (1.0 - f) * 0.02 * ash, sin(a) * R * f * wob)
			var col := Color(0.09, 0.08, 0.07).lerp(Color(0.62, 0.61, 0.58), clampf((1.0 - f * 1.4) * ash * 1.5, 0.0, 1.0))
			col.a = 1.0 - smoothstep(0.7, 1.0, f)
			row.append([p, col])
		verts.append(row)
	for i in rings:
		for j in seg:
			var j2 := (j + 1) % seg
			for v in [verts[i][j], verts[i + 1][j], verts[i][j2], verts[i][j2], verts[i + 1][j], verts[i + 1][j2]]:
				st.set_color((v[1] as Color).srgb_to_linear())
				st.set_normal(Vector3.UP)
				st.add_vertex(v[0])
	bed.mesh = st.commit()
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.roughness = 1.0
	m.albedo_color = Color(1, 1, 1, 1)
	bed.material_override = m


func _build_dome(d: Dictionary) -> void:
	## The earth shell: one patch per cell, as thick as the earth packed there.
	## Vents are small dark holes with smoke curling out; uncovered gaps in an
	## otherwise covered mound leak smoke too, so players can find them.
	for v in _vent_nodes:
		v.queue_free()
	_vent_nodes.clear()
	var shell: Array = d.get("shell", [])
	if float(d.get("shell_l", 0.0)) <= 0.0 or shell.is_empty():
		dome.mesh = null
		return
	var rr := FireSim.dome_radii(d)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var rng := RandomNumberGenerator.new()
	rng.seed = entity_id
	var vents: Array = d.get("vents", [])
	var bands: Array = FireSim.BANDS
	var mostly := FireSim.shell_coverage(d) > 0.5
	var leaks := 0
	for k in FireSim.CELLS:
		var cov := FireSim.coverage(d, k)
		if cov < 0.04:
			if mostly and leaks < 6:
				_add_leak(_dp(rr, _cell_el(k, bands), _cell_az(k), 0.0), false)
				leaks += 1
			continue
		var thick := 0.012 + 0.05 * cov
		var col := Color(0.42, 0.31, 0.2) * (0.86 + 0.24 * rng.randf())
		col.a = 1.0
		if k == FireSim.CELLS - 1:
			var top := Vector3(0, rr.y + thick, 0)
			var e0 := deg_to_rad(80.0)
			for jj in FireSim.AZ:
				var a0 := float(jj) / FireSim.AZ * TAU
				var a1 := float(jj + 1) / FireSim.AZ * TAU
				_tri(st, top, _dp(rr, e0, a0, thick), _dp(rr, e0, a1, thick), col)
			continue
		var band := k / FireSim.AZ
		var az := k % FireSim.AZ
		var el0 := deg_to_rad(float(bands[band]))
		var el1 := deg_to_rad(float(bands[band + 1]))
		var a0b := float(az) / FireSim.AZ * TAU
		var a1b := float(az + 1) / FireSim.AZ * TAU
		# patches shrink toward their centre when only partly covered
		var shrink := lerpf(0.55, 1.04, cov)
		var mid_el := (el0 + el1) * 0.5
		var mid_a := (a0b + a1b) * 0.5
		var e0b := lerpf(mid_el, el0, shrink) if band > 0 else el0 - 0.03
		var e1b := lerpf(mid_el, el1, shrink)
		var b0 := lerpf(mid_a, a0b, shrink)
		var b1 := lerpf(mid_a, a1b, shrink)
		var subs := 2
		for si in subs:
			for sj in subs:
				var ea := lerpf(e0b, e1b, float(si) / subs)
				var eb := lerpf(e0b, e1b, float(si + 1) / subs)
				var aa := lerpf(b0, b1, float(sj) / subs)
				var ab := lerpf(b0, b1, float(sj + 1) / subs)
				var q0 := _dp(rr, ea, aa, _bump(thick, ea, aa, k))
				var q1 := _dp(rr, ea, ab, _bump(thick, ea, ab, k))
				var q2 := _dp(rr, eb, ab, _bump(thick, eb, ab, k))
				var q3 := _dp(rr, eb, aa, _bump(thick, eb, aa, k))
				_tri(st, q0, q1, q2, col)
				_tri(st, q0, q2, q3, col)
		if k in vents:
			_add_vent(_dp(rr, mid_el, mid_a, thick + 0.003), Vector3(cos(mid_el) * cos(mid_a), sin(mid_el), cos(mid_el) * sin(mid_a)))
		elif cov < 0.6 and mostly and leaks < 6:
			_add_leak(_dp(rr, mid_el, mid_a, thick * 0.5), true)
			leaks += 1
	st.generate_normals()
	dome.mesh = st.commit()


func _cell_el(k: int, bands: Array) -> float:
	if k >= FireSim.CELLS - 1:
		return PI * 0.5
	var band := k / FireSim.AZ
	return deg_to_rad((float(bands[band]) + float(bands[band + 1])) * 0.5)


func _cell_az(k: int) -> float:
	return (float(k % FireSim.AZ) + 0.5) / FireSim.AZ * TAU


func _bump(thick: float, e: float, a: float, k: int) -> float:
	return thick * (0.85 + 0.3 * sin(e * 13.0 + a * 7.0 + k))


func _add_vent(pos: Vector3, nrm: Vector3) -> void:
	var holder := Node3D.new()
	holder.position = pos
	var up := nrm.normalized()
	var side := up.cross(Vector3.UP)
	if side.length() < 0.01:
		side = Vector3.RIGHT
	side = side.normalized()
	holder.basis = Basis(side, up, side.cross(up))
	var vn := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 0.028
	cm.bottom_radius = 0.02
	cm.height = 0.012
	cm.radial_segments = 10
	vn.mesh = cm
	var vm := StandardMaterial3D.new()
	vm.albedo_color = Color(0.035, 0.03, 0.028)
	vm.roughness = 1.0
	vm.emission_enabled = true
	vm.emission = Color(1.0, 0.35, 0.08)
	vm.emission_energy_multiplier = 0.0
	vn.material_override = vm
	vn.set_meta("vent", true)
	holder.add_child(vn)
	add_child(holder)
	_vent_nodes.append(holder)
	_add_smoke_jet(holder, Vector3(0, 0.01, 0), 1.0)


func _add_leak(pos: Vector3, partial: bool) -> void:
	var holder := Node3D.new()
	holder.position = pos
	add_child(holder)
	_vent_nodes.append(holder)
	_add_smoke_jet(holder, Vector3.ZERO, 1.6 if not partial else 1.1)


func _add_smoke_jet(parent: Node3D, at: Vector3, strength: float) -> void:
	var gp := GPUParticles3D.new()
	gp.amount = 10
	gp.lifetime = 4.0
	gp.local_coords = false
	gp.emitting = false
	gp.visibility_aabb = AABB(Vector3(-3, -1, -3), Vector3(6, 8, 6))
	gp.process_material = _jet_mat
	gp.draw_pass_1 = _jet_mesh
	gp.position = at
	gp.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	gp.set_meta("jet", strength)
	parent.add_child(gp)


func _dp(rr: Vector2, el: float, az: float, off: float) -> Vector3:
	var dir := Vector3(cos(el) * cos(az), sin(el), cos(el) * sin(az))
	return Vector3(dir.x * (rr.x + off), dir.y * (rr.y + off), dir.z * (rr.x + off))


func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, col: Color) -> void:
	# keep every face pointing out of the dome (front faces wind clockwise seen from outside)
	var n := (b - a).cross(c - a)
	if n.dot((a + b + c) / 3.0) > 0.0:
		var t := b
		b = c
		c = t
	for v in [a, b, c]:
		st.set_color(col.srgb_to_linear())
		st.add_vertex(v)


func _process(delta: float) -> void:
	_t += delta
	var d := data()
	var covered := FireSim.shell_coverage(d) > 0.6
	var tf := float(d.get("flame", 0.0))
	var tg := float(d.get("glow", 0.0))
	var ts := float(d.get("smoke", 0.0))
	_flame = move_toward(_flame, tf, delta * 0.8)
	_glow = move_toward(_glow, tg, delta * 0.5)
	_smoke = move_toward(_smoke, ts, delta * 0.4)
	flames.emitting = _flame > 0.03
	flames.amount_ratio = clampf(_flame * 1.1 + 0.08, 0.0, 1.0)
	flames.speed_scale = 0.8 + _flame * 0.5
	flames.scale = Vector3.ONE * clampf(0.55 + _flame * 1.1, 0.4, 1.8)
	sparks.emitting = _flame > 0.35 or (_glow > 0.5 and not covered)
	sparks.amount_ratio = clampf(_flame, 0.15, 1.0)
	var wind: Vector2 = World.env.get("wind", Vector2.ZERO)
	var lit := bool(d.get("lit", false))
	smoke.emitting = not covered and _smoke > 0.04
	smoke.amount_ratio = clampf(_smoke * 1.2 + 0.1, 0.1, 1.0)
	var hot := clampf((float(d.get("T", 15)) - 250.0) / 400.0, 0.0, 1.0)
	for holder in _vent_nodes:
		if not is_instance_valid(holder):
			continue
		for ch in holder.get_children():
			if ch is GPUParticles3D:
				var strength: float = ch.get_meta("jet", 1.0)
				ch.emitting = covered and lit and (_smoke > 0.03 or hot > 0.2)
				ch.amount_ratio = clampf((_smoke * 0.9 + hot * 0.3) * strength, 0.15, 1.0)
			elif ch is MeshInstance3D and ch.has_meta("vent"):
				(ch.material_override as StandardMaterial3D).emission_energy_multiplier = hot * 2.5 if lit else 0.0
	_smoke_mat.gravity = Vector3(wind.x * 0.12, 0.14 + _smoke * 0.05, wind.y * 0.12)
	# firelight flickers; a covered mound only glows dully through its vents
	var flick := 0.82 + 0.18 * sin(_t * 13.0) * sin(_t * 7.3 + 1.0) + 0.08 * sin(_t * 23.0)
	var energy := _flame * 2.4 * flick + _glow * (0.15 if covered else 0.7)
	light.light_energy = energy
	light.visible = energy > 0.02
	light.light_color = Color(1.0, 0.55 + 0.1 * _flame, 0.25)
	# sound
	_vol(snd_small, clampf(_flame * 3.0, 0.0, 1.0) * (1.0 - clampf((_flame - 0.5) * 2.0, 0.0, 0.6)) + _glow * 0.25 * (0.0 if covered else 1.0))
	_vol(snd_large, clampf((_flame - 0.35) * 1.6, 0.0, 1.0))
	_vol(snd_mound, (0.7 if covered and bool(d.get("lit", false)) else 0.0) * clampf(_smoke + 0.3, 0.0, 1.0))


func _vol(p: AudioStreamPlayer3D, v: float) -> void:
	if p == null:
		return
	var target := linear_to_db(maxf(v, 0.0001)) - 4.0
	p.volume_db = move_toward(p.volume_db, target, 40.0 * get_process_delta_time())
