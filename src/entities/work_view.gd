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


func set_local_seat(seat: Vector3, angle: float) -> void:
	_seat_local = true
	_seat = seat
	_angle = angle
	_place_head()


func _process(delta: float) -> void:
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
