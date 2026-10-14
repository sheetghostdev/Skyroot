class_name ItemVisual
extends RefCounted
## Builds the 3D model for an item (stack), used in the world, in hands and for icons.

const STACK_OFFSETS := [Vector3(0, 0, 0), Vector3(0.05, 0.0, 0.04), Vector3(-0.04, 0.0, 0.05), Vector3(0.0, 0.04, -0.01)]


static func make(id: String, d: Dictionary = {}, n: int = 1) -> Node3D:
	var root := Node3D.new()
	root.name = "Item_" + id
	var copies := 1
	if n > 1:
		copies = mini(n, 4 if ItemDB.unit_volume(id) < 1.0 else 2)
	for c in copies:
		var m := single(id, d)
		if m == null:
			continue
		if c > 0:
			var aabb := Models.aabb_of(m)
			m.position = STACK_OFFSETS[c % STACK_OFFSETS.size()] * maxf(1.0, aabb.size.length() * 4.0)
			m.position.y += aabb.size.y * (0.75 if c == 3 else 0.0)
			m.rotation.y = c * 1.3
		root.add_child(m)
	return root


static func single(id: String, d: Dictionary = {}) -> Node3D:
	var def := ItemDB.def(id)
	var model := String(def.get("model", ""))
	if model.begins_with("proc:"):
		return _proc(model.substr(5), id, d)
	var inst := Models.instance(model)
	if inst:
		var moist := float(d.get("moist", def.get("moist", 0.0)))
		if def.get("mat", "") == "wood" and moist > 0.3:
			Models.set_role_param(inst, "Bark", "wet", 0.25)
		return inst
	return _fallback(id)


static func _proc(kind: String, id: String, d: Dictionary) -> Node3D:
	var mi := MeshInstance3D.new()
	match kind:
		"stone":
			mi.mesh = ProcMesh.stone(int(d.get("seed", hash(id) % 1000)))
			mi.material_override = Models.material_for("Stone")
		"log":
			mi.mesh = ProcMesh.log_mesh()
			mi.material_override = Models.material_for("Bark")
		"board":
			mi.mesh = ProcMesh.board()
			mi.material_override = Models.material_for("Wood")
		"firewood":
			mi.mesh = ProcMesh.firewood()
			mi.material_override = Models.material_for("Wood")
		"wood_piece":
			var poly := PackedVector2Array(d.get("poly", []))
			if poly.size() < 3:
				mi.mesh = ProcMesh.firewood()
			else:
				mi.mesh = ProcMesh.wood_piece(poly, float(d.get("len", 2.0)), float(d.get("r0", 0.16)), d.get("c0", Vector2.ZERO))
			mi.material_override = Models.material_for("Wood")
		"clay_lump":
			mi.mesh = ProcMesh.clay_lump(0.042, 3, Color(0.46, 0.29, 0.21))
			var m := Models.unique_material("Clay")
			m.set_shader_parameter("roughness", 0.4)
			m.set_shader_parameter("use_local", 1.0)
			mi.material_override = m
		"knapped":
			mi.mesh = Knap.build_mesh(int(d.get("seed", 1)), d.get("cuts", []))
			mi.material_override = Models.material_for("Stone")
		"tool":
			return ToolVisual.make(id, d)
		"pot":
			if d.has("ro"):
				return Pottery.make_instance(d)
			mi.mesh = ProcMesh.clay_lump(0.05, 5)
			mi.material_override = Models.material_for("Clay")
		_:
			return _fallback(id)
	return mi


static func _fallback(id: String) -> Node3D:
	var def := ItemDB.def(id)
	var vol := float(def.get("vol", 0.3)) / 1000.0
	var s := clampf(pow(vol, 1.0 / 3.0), 0.04, 0.6)
	var col := Color(0.6, 0.5, 0.35)
	match String(def.get("mat", "")):
		"wood": col = Color(0.55, 0.42, 0.3)
		"plant": col = Color(0.45, 0.6, 0.3)
		"food": col = Color(0.62, 0.32, 0.38)
		"soil": col = Color(0.32, 0.24, 0.17)
		"clay": col = Color(0.62, 0.36, 0.25)
		"stone": col = Color(0.55, 0.53, 0.5)
		"charcoal": col = Color(0.12, 0.11, 0.11)
		"ash": col = Color(0.6, 0.6, 0.58)
		"ceramic": col = Color(0.7, 0.38, 0.24)
	var long: bool = def.get("tags", []).has("handle") or id in ["pole", "stick", "twig", "branch", "limb", "torch", "spindle"]
	if long:
		var len: float = {"pole": 2.0, "limb": 2.2, "branch": 1.1, "stick": 0.6, "twig": 0.35, "torch": 0.55}.get(id, 0.5)
		var mi := Models.placeholder(Vector3(clampf(s * 0.3, 0.02, 0.09), len, 0), col, "cylinder")
		mi.rotation.z = PI * 0.5
		var r := Node3D.new()
		r.add_child(mi)
		return r
	return Models.placeholder(Vector3(s, s * 0.7, s), col, "sphere")


static func held_offset(id: String) -> Transform3D:
	## How an item sits in the right hand's grip (hand space: +Z forward).
	var hold := String(ItemDB.def(id).get("hold", "hand"))
	match hold:
		"grip":
			if id in ["axe", "digger"]:
				return Transform3D(Basis.from_euler(Vector3(0.0, PI * 0.5, 0.0)), Vector3(0, 0, 0))
			return Transform3D(Basis.from_euler(Vector3(0.0, PI * 0.5, 0.0)), Vector3(0, 0.0, 0.0))
		"two":
			return Transform3D(Basis.from_euler(Vector3(0.0, PI * 0.5, 0.0)), Vector3(0, 0.0, 0.0))
	return Transform3D.IDENTITY


static func fit_scale(node: Node3D, max_size: float) -> float:
	var aabb := Models.aabb_of(node)
	var s := aabb.get_longest_axis_size()
	return 1.0 if s <= 0.0001 else minf(1.0, max_size / s)
