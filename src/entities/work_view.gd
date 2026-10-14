extends EntityView
## A craft in progress, visible to everyone: the knapped stone, the clay being
## kneaded, the pot taking shape on its bat, cord being twisted, a tool being
## bound.  The local crafter's session can feed predicted state for instant
## feedback (set_local_*).

var kind := ""
var root3: Node3D
var stone: MeshInstance3D
var lump: MeshInstance3D
var specks: Node3D
var bat: MeshInstance3D
var pot_mi: MeshInstance3D
var cord_mi: MeshInstance3D
var handle: Node3D
var head: MeshInstance3D
var bind_mi: MeshInstance3D
var _press := 0.0
var _turn := 0.0
var _twist := 0.0
var _local_pot: Dictionary = {}
var _pot_dirty := true
var _pot_t := 0.0
var _seat_local := false
var _seat := Vector3.ZERO
var _angle := 0.0
var _lump_mat: ShaderMaterial
var _pot_key := ""
var board: Node3D
var spindle: Node3D
var hands: Array = []
var drill_smoke: GPUParticles3D
var drill_smoke_mat: ParticleProcessMaterial
var ember_light: OmniLight3D
var ember_mi: MeshInstance3D
var drill_snd: AudioStreamPlayer3D
var _spin_angle := 0.0
var _spin_speed := 0.0
var _spin_local := false
var _t_drill := 0.0


func _build() -> void:
	kind = String(data().get("kind", ""))
	root3 = Node3D.new()
	add_child(root3)
	var box := BoxShape3D.new()
	box.size = Vector3(0.3, 0.16, 0.24)
	if kind == "haft" or kind == "cordage":
		box.size = Vector3(0.55, 0.12, 0.26)
	make_body(box, LAYER_INTERACT, "work", Transform3D(Basis(), Vector3(0.0 if kind != "haft" else 0.05, 0.06, 0)))
	match kind:
		"knap":
			stone = MeshInstance3D.new()
			stone.material_override = Models.material_for("Stone")
			root3.add_child(stone)
		"clay_prep":
			lump = MeshInstance3D.new()
			_lump_mat = Models.unique_material("Clay")
			_lump_mat.set_shader_parameter("use_local", 1.0)
			lump.material_override = _lump_mat
			root3.add_child(lump)
			specks = Node3D.new()
			lump.add_child(specks)
			var rng := RandomNumberGenerator.new()
			rng.seed = entity_id
			for i in 9:
				var s := MeshInstance3D.new()
				s.mesh = ProcMesh.blob(0.0035, Color(0.45, 0.43, 0.4), i, 0.8)
				s.material_override = Models.material_for("Stone")
				var dir := Vector3(rng.randf_range(-1, 1), rng.randf_range(0.2, 1), rng.randf_range(-1, 1)).normalized()
				s.position = dir * 0.05
				specks.add_child(s)
		"pottery":
			bat = MeshInstance3D.new()
			var cm := CylinderMesh.new()
			cm.top_radius = 0.1
			cm.bottom_radius = 0.105
			cm.height = 0.014
			cm.radial_segments = 28
			bat.mesh = ProcMesh.painted(cm, ProcMesh.WOOD * 0.9)
			bat.material_override = Models.material_for("Wood")
			bat.position.y = 0.007
			root3.add_child(bat)
			pot_mi = MeshInstance3D.new()
			pot_mi.position.y = 0.014
			root3.add_child(pot_mi)
		"cordage":
			cord_mi = MeshInstance3D.new()
			cord_mi.material_override = Models.material_for("Rope")
			root3.add_child(cord_mi)
		"fire_drill":
			_build_drill()
		"haft":
			handle = Models.instance("res://assets/models/items/handle.glb")
			if handle == null:
				var hm := MeshInstance3D.new()
				var c2 := CylinderMesh.new()
				c2.top_radius = 0.014
				c2.bottom_radius = 0.016
				c2.height = 0.46
				hm.mesh = ProcMesh.painted(c2, ProcMesh.WOOD * 0.85)
				hm.material_override = Models.material_for("Wood")
				hm.rotation.z = PI * 0.5
				handle = Node3D.new()
				handle.add_child(hm)
			root3.add_child(handle)
			handle.position = Vector3(0.0, 0.016, 0.0)
			head = MeshInstance3D.new()
			head.material_override = Models.material_for("Stone")
			root3.add_child(head)
			bind_mi = MeshInstance3D.new()
			var rm := StandardMaterial3D.new()
			rm.albedo_color = Color(0.74, 0.64, 0.44)
			rm.roughness = 0.95
			bind_mi.material_override = rm
			root3.add_child(bind_mi)


func _refresh(keys: Array) -> void:
	var d := data()
	match kind:
		"knap":
			var p := Knap.params(int(d.get("seed", 1)))
			stone.mesh = Knap.build_mesh(int(d.get("seed", 1)), d.get("cuts", []))
			var c := float(p["c"])
			var flipped := bool(d.get("flipped", false))
			stone.transform = Transform3D(Basis(Vector3.RIGHT, PI) if flipped else Basis(), Vector3(0, c, 0))
		"clay_prep":
			var vol := float(d.get("vol", 0.25))
			var r := pow(vol / 1000.0 * 3.0 / (4.0 * PI), 1.0 / 3.0) * 1.15
			lump.mesh = ProcMesh.clay_lump(r, entity_id % 7 + 1, Color(0.52, 0.32, 0.23))
			var m := float(d.get("moist", 0.17))
			var homog := float(d.get("homog", 0.0))
			var wet := clampf((m - 0.15) / 0.14, 0.0, 1.0)
			_lump_mat.set_shader_parameter("tint", Color(1.0, 1.0, 1.0).lerp(Color(0.78, 0.74, 0.72), wet))
			_lump_mat.set_shader_parameter("roughness", lerpf(0.95, 0.38, wet))
			_lump_mat.set_shader_parameter("detail_strength", lerpf(0.35, 0.06, homog))
			_lump_mat.set_shader_parameter("normal_strength", lerpf(1.4, 0.25, homog))
			specks.visible = float(d.get("grit", 1.0)) > 0.15
			specks.scale = Vector3.ONE * clampf(float(d.get("grit", 1.0)), 0.3, 1.0)
			if String(d.get("note", "")) == "dry" and keys.has("kneads"):
				Game.game_world.fx.play("dust", global_position + Vector3(0, 0.05, 0), {"sound": "", "amount": 6, "color": Color(0.6, 0.45, 0.35)})
		"pottery":
			_pot_dirty = true
		"cordage":
			_build_cord()
		"fire_drill":
			if not _spin_local:
				_spin_speed = float(d.get("spin", 0.0))
			var heat := float(d.get("heat", 0.0))
			drill_smoke.emitting = heat > 0.3
			drill_smoke.amount_ratio = clampf((heat - 0.25) * 1.4, 0.1, 1.0)
			var ember := float(d.get("ember", 0.0)) > 0.0
			ember_light.visible = ember or heat > 0.9
			ember_light.light_energy = 0.6 if ember else 0.15
			var em: StandardMaterial3D = ember_mi.material_override
			em.emission_energy_multiplier = 3.0 if ember else clampf((heat - 0.6) * 2.0, 0.0, 0.6)
			ember_mi.scale = Vector3.ONE * (0.6 + 0.8 * clampf(float(d.get("dust", 0.0)) * 2.0, 0.0, 1.0))
		"haft":
			if not _seat_local:
				_seat = d.get("seat", Vector3(0.12, 0, 0))
				_angle = float(d.get("angle", 0.6))
			_place_head()
			_build_binding()


func set_press(p: float) -> void:
	_press = p
	if lump:
		lump.scale = Vector3(1.0 + p * 0.28, 1.0 - p * 0.42, 1.0 + p * 0.28)


func set_local_pot(pot: Dictionary) -> void:
	_local_pot = pot
	_pot_dirty = true


func set_turn(a: float) -> void:
	_turn = a


func set_twist(t: float) -> void:
	_twist = t
	if cord_mi:
		_build_cord()


func set_spin(angle: float, speed: float) -> void:
	_spin_local = true
	_spin_angle = angle
	_spin_speed = speed


func _build_drill() -> void:
	board = Models.instance("res://assets/models/items/hearth_board.glb")
	if board == null:
		board = Node3D.new()
		var bm := MeshInstance3D.new()
		var bx := BoxMesh.new()
		bx.size = Vector3(0.28, 0.022, 0.07)
		bm.mesh = ProcMesh.painted(bx, ProcMesh.WOOD)
		bm.material_override = Models.material_for("Wood")
		board.add_child(bm)
	var aabb := Models.aabb_of(board)
	board.position = Vector3(0, -aabb.position.y, 0)
	root3.add_child(board)
	var top := aabb.size.y
	spindle = Node3D.new()
	var stick := ItemVisual.single("stick", {})
	if stick:
		# the stick's long axis is X: stand it up, tip in the notch
		var holder := Node3D.new()
		holder.rotation = Vector3(0, 0, PI * 0.5)
		holder.add_child(stick)
		var sa := Models.aabb_of(stick)
		stick.position = Vector3(-sa.position.x, 0, 0)
		spindle.add_child(holder)
	spindle.position = Vector3(0.06, top, 0.0)
	root3.add_child(spindle)
	var skin := Color(0.78, 0.58, 0.45)
	for side in [-1.0, 1.0]:
		var h := MeshInstance3D.new()
		var cap := CapsuleMesh.new()
		cap.radius = 0.028
		cap.height = 0.11
		h.mesh = ProcMesh.painted(cap, skin)
		h.material_override = Models.material_for("Skin")
		h.scale = Vector3(1.0, 1.0, 0.55)
		root3.add_child(h)
		hands.append([h, side])
	ember_mi = MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.012
	sm.height = 0.012
	ember_mi.mesh = sm
	var emat := StandardMaterial3D.new()
	emat.albedo_color = Color(0.08, 0.06, 0.05)
	emat.emission_enabled = true
	emat.emission = Color(1.0, 0.4, 0.08)
	emat.emission_energy_multiplier = 0.0
	ember_mi.material_override = emat
	ember_mi.position = Vector3(0.06, top + 0.004, 0.03)
	root3.add_child(ember_mi)
	ember_light = OmniLight3D.new()
	ember_light.light_color = Color(1.0, 0.45, 0.15)
	ember_light.omni_range = 1.2
	ember_light.visible = false
	ember_light.position = ember_mi.position + Vector3(0, 0.03, 0)
	root3.add_child(ember_light)
	drill_smoke = GPUParticles3D.new()
	drill_smoke.amount = 24
	drill_smoke.lifetime = 2.5
	drill_smoke.local_coords = false
	drill_smoke.emitting = false
	drill_smoke_mat = ParticleProcessMaterial.new()
	drill_smoke_mat.direction = Vector3(0, 1, 0)
	drill_smoke_mat.spread = 20.0
	drill_smoke_mat.initial_velocity_min = 0.05
	drill_smoke_mat.initial_velocity_max = 0.12
	drill_smoke_mat.gravity = Vector3(0, 0.05, 0)
	drill_smoke_mat.turbulence_enabled = true
	drill_smoke_mat.turbulence_noise_strength = 0.2
	var sc := Curve.new()
	sc.add_point(Vector2(0.0, 0.2))
	sc.add_point(Vector2(1.0, 1.0))
	var sct := CurveTexture.new()
	sct.curve = sc
	drill_smoke_mat.scale_curve = sct
	var g := Gradient.new()
	g.set_color(0, Color(0.9, 0.9, 0.88, 0.0))
	g.add_point(0.15, Color(0.85, 0.85, 0.83, 0.45))
	g.set_color(g.get_point_count() - 1, Color(0.8, 0.8, 0.8, 0.0))
	var gt := GradientTexture1D.new()
	gt.gradient = g
	drill_smoke_mat.color_ramp = gt
	drill_smoke.process_material = drill_smoke_mat
	var q := QuadMesh.new()
	q.size = Vector2(0.12, 0.12)
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	m.vertex_color_use_as_albedo = true
	m.albedo_texture = preload("res://src/entities/site_view.gd").soft_tex()
	q.material = m
	drill_smoke.draw_pass_1 = q
	drill_smoke.position = ember_mi.position
	root3.add_child(drill_smoke)
	drill_snd = Sfx.make_loop_player("drill_spin", self, -60.0, 14.0)
	if drill_snd and drill_snd.stream:
		drill_snd.play()


func _drill_process(delta: float) -> void:
	if not _spin_local:
		_spin_angle += _spin_speed * delta * 40.0
	spindle.rotation.y = _spin_angle
	# palms rub back and forth on either side of the stick, sliding down as they go
	var rub := sin(_spin_angle * 0.5) * 0.035
	var slide := fmod(_t_drill, 2.0) / 2.0
	for hh in hands:
		var h: MeshInstance3D = hh[0]
		var side: float = hh[1]
		h.position = spindle.position + Vector3(side * 0.035, 0.36 - slide * 0.16, rub * side)
		h.rotation = Vector3(0.0, 0.0, side * 0.25)
	if drill_snd:
		var target := linear_to_db(maxf(_spin_speed, 0.0001)) - 2.0
		drill_snd.volume_db = move_toward(drill_snd.volume_db, target, 60.0 * delta)
	_t_drill += delta * (0.3 + _spin_speed)


func set_local_seat(seat: Vector3, angle: float) -> void:
	_seat_local = true
	_seat = seat
	_angle = angle
	_place_head()


func _process(delta: float) -> void:
	if kind == "fire_drill":
		_drill_process(delta)
		return
	if kind == "pottery":
		_pot_t -= delta
		if _pot_dirty and _pot_t <= 0.0:
			_pot_t = 0.03
			_pot_dirty = false
			var pot: Dictionary = _local_pot if not _local_pot.is_empty() else data().get("pot", {})
			if pot.has("ro"):
				var old_mat := pot_mi.material_override
				pot_mi.mesh = Pottery.build_mesh(pot)
				if old_mat == null:
					var inst := Pottery.make_instance(pot)
					pot_mi.material_override = inst.material_override
					inst.free()
				(pot_mi.material_override as ShaderMaterial).set_shader_parameter("roughness", Pottery.roughness_for(pot))
		if int(data().get("by", 0)) != 0:
			if _local_pot.is_empty():
				_turn += delta * 0.4
		pot_mi.rotation.y = _turn


func _build_cord() -> void:
	var d := data()
	var prog := float(d.get("prog", 0.0))
	var length := 0.04 + 0.3 * prog
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var x0 := -0.16
	var twist := _twist
	# twisted section: two strands spiralling around each other
	for strand in 2:
		var pts: Array[Vector3] = []
		var steps := maxi(6, int(length * 140.0))
		for i in steps + 1:
			var f := float(i) / steps
			var x := x0 + f * length
			var a := f * length * 220.0 + strand * PI + twist
			pts.append(Vector3(x, 0.012 + sin(a) * 0.0028, cos(a) * 0.0028))
		_tube(st, pts, 0.0026, Color(0.78, 0.68, 0.46) * (1.0 - strand * 0.08))
	# loose fibres fanning out beyond the twist
	var rng := RandomNumberGenerator.new()
	rng.seed = entity_id
	for f in 10:
		var side := 1.0 if f % 2 == 0 else -1.0
		var start := Vector3(x0 + length, 0.012, 0.0)
		var end := start + Vector3(0.18 - prog * 0.1, rng.randf_range(-0.004, 0.006), side * rng.randf_range(0.004, 0.035))
		_tube(st, [start, start.lerp(end, 0.5) + Vector3(0, 0.003, 0), end], 0.0009, Color(0.74, 0.7, 0.45))
	st.generate_normals()
	cord_mi.mesh = st.commit()


func _tube(st: SurfaceTool, pts: Array, r: float, col: Color) -> void:
	var seg := 5
	var rings: Array = []
	for i in pts.size():
		var p: Vector3 = pts[i]
		var t: Vector3 = (pts[mini(i + 1, pts.size() - 1)] - pts[maxi(i - 1, 0)]).normalized()
		var n := t.cross(Vector3.UP)
		if n.length() < 0.01:
			n = t.cross(Vector3.FORWARD)
		n = n.normalized()
		var b := t.cross(n).normalized()
		var ring: Array = []
		for s in seg:
			var a := float(s) / seg * TAU
			ring.append(p + (n * cos(a) + b * sin(a)) * r)
		rings.append(ring)
	for i in rings.size() - 1:
		for s in seg:
			var s2 := (s + 1) % seg
			for v in [rings[i][s], rings[i + 1][s], rings[i][s2], rings[i][s2], rings[i + 1][s], rings[i + 1][s2]]:
				st.set_color(col.srgb_to_linear())
				st.add_vertex(v)


func _place_head() -> void:
	if head == null:
		return
	var d := data()
	var hd: Dictionary = d.get("head", {})
	if head.mesh == null:
		head.mesh = Knap.build_mesh(int(hd.get("seed", 1)), hd.get("cuts", []))
	var c := float(Knap.params(int(hd.get("seed", 1)))["c"])
	head.transform = Transform3D(Basis(Vector3.UP, _angle), _seat + Vector3(0, c, 0))


func _build_binding() -> void:
	var d := data()
	var wraps := float(d.get("wraps", 0.0))
	if wraps <= 0.05:
		bind_mi.mesh = null
		return
	var tight := float(d.get("tight", 0.0))
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var pts: Array = []
	var turns := wraps
	var steps := int(turns * 14.0) + 2
	var rr := lerpf(0.026, 0.019, tight)
	for i in steps:
		var f := float(i) / (steps - 1)
		var a := f * turns * TAU
		var x := 0.19 + f * turns * 0.0045
		pts.append(Vector3(x, 0.02 + sin(a) * rr, cos(a) * rr))
	_tube(st, pts, 0.0022, Color(0.76, 0.66, 0.45))
	st.generate_normals()
	bind_mi.mesh = st.commit()
