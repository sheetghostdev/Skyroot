extends EntityView
## The great tree (and any tree grown from its seeds).  Each branch is its own
## node so it can be cut, and regrows by scaling back up from its attachment
## point.  Felled trees show a stump, then a sapling, then a young tree.

const MODEL := "res://assets/models/nature/skyroot_tree.glb"
const SAPLING := "res://assets/models/nature/sapling.glb"
const YOUNG := "res://assets/models/nature/young_tree.glb"

var model: Node3D
var trunk: Node3D
var stump: Node3D
var crown: Node3D
var roots: Node3D
var small: Array = []
var large: Array = []
var sapling: Node3D
var young: Node3D
var trunk_body: StaticBody3D
var stump_body: StaticBody3D
var areas: Dictionary = {}
var _was_felled := false
var _shake := 0.0


func _build() -> void:
	model = Models.instance(MODEL)
	if model == null:
		model = _procedural_tree()
	add_child(model)
	trunk = model.find_child("Trunk", true, false)
	stump = model.find_child("Stump", true, false)
	crown = model.find_child("CrownLeaves", true, false)
	roots = model.find_child("Roots", true, false)
	for i in TreeSim.SMALL:
		small.append(model.find_child("BranchS_%d" % i, true, false))
	for i in TreeSim.LARGE:
		large.append(model.find_child("BranchL_%d" % i, true, false))
	var cyl := CylinderShape3D.new()
	cyl.radius = 0.3
	cyl.height = 5.0
	trunk_body = make_body(cyl, LAYER_STRUCT, "trunk", Transform3D(Basis(), Vector3(0, 2.5, 0)), true)
	var scyl := CylinderShape3D.new()
	scyl.radius = 0.3
	scyl.height = 0.6
	stump_body = make_body(scyl, LAYER_STRUCT, "stump", Transform3D(Basis(), Vector3(0, 0.3, 0)), true)
	_make_branch_areas()
	sapling = Models.instance(SAPLING)
	if sapling == null:
		sapling = _proc_small_tree(0.9)
	add_child(sapling)
	young = Models.instance(YOUNG)
	if young == null:
		young = _proc_small_tree(3.0)
	add_child(young)
	_was_felled = bool(data().get("felled", false))


func _make_branch_areas() -> void:
	for group in [["sb", small], ["lb", large]]:
		var arr: Array = group[1]
		for i in arr.size():
			var b: Node3D = arr[i]
			if b == null:
				continue
			var aabb := _subtree_aabb(b)
			var origin := _rel_pos(b)
			var mid := (origin + aabb.get_center()) * 0.5
			var length := origin.distance_to(aabb.get_center()) * 1.25 + 0.2
			var cap := CapsuleShape3D.new()
			cap.radius = 0.16 if group[0] == "sb" else 0.22
			cap.height = maxf(length, cap.radius * 2.0 + 0.05)
			var dir := (aabb.get_center() - origin).normalized()
			var basis := Basis()
			if dir.length() > 0.01:
				var axis := Vector3.UP.cross(dir)
				if axis.length() > 0.001:
					basis = Basis(axis.normalized(), Vector3.UP.angle_to(dir))
			areas["%s:%d" % [group[0], i]] = make_body(cap, LAYER_INTERACT, "%s:%d" % [group[0], i], Transform3D(basis, mid))


func _subtree_aabb(n: Node3D) -> AABB:
	## AABB of a branch (and its leaves) in this view's local space.
	var out := AABB()
	var first := true
	for mi in Models.mesh_instances(n):
		if mi.mesh == null:
			continue
		var xf: Transform3D = model.transform * Models._rel_xf(model, mi)
		var b: AABB = xf * mi.mesh.get_aabb()
		if first:
			out = b
			first = false
		else:
			out = out.merge(b)
	return out


func _rel_pos(n: Node3D) -> Vector3:
	return model.transform * Models._rel_xf(model, n).origin


func branch_tip(part: String) -> Vector3:
	var a = areas.get(part)
	if a:
		return a.global_position
	return global_position + Vector3(0, 2.0, 0)


func interaction_point(part: String) -> Vector3:
	if part.begins_with("sb") or part.begins_with("lb"):
		return branch_tip(part)
	return global_position + Vector3(0, 1.2, 0)


var _hp := {}    # what the last blows left: "trunk", "lhp", "shp", "sb", "lb"


static func _dropped(was, now) -> bool:
	## Did any part of it go down (a blow landed, or a branch came off)?
	if was == null or now == null:
		return false
	if was is Array and now is Array:
		for i in mini((was as Array).size(), (now as Array).size()):
			if float(now[i]) < float(was[i]) - 1e-6:
				return true
		return false
	return float(now) < float(was) - 1e-6


func _refresh(keys: Array) -> void:
	var d := data()
	var felled := bool(d.get("felled", false))
	# a blow at a branch, a limb or the trunk - every cut changes these, and they
	# reach every screen reliably - shakes the tree (growing doesn't)
	if _dropped(_hp.get("trunk"), d.get("trunk")):
		shake(0.8)
	elif _dropped(_hp.get("lhp"), d.get("lhp")) or _dropped(_hp.get("lb"), d.get("lb")):
		shake(0.5)
	elif _dropped(_hp.get("shp"), d.get("shp")) or _dropped(_hp.get("sb"), d.get("sb")):
		shake(0.3)
	for k in ["trunk", "lhp", "shp", "sb", "lb"]:
		var v = d.get(k)
		_hp[k] = v.duplicate() if v is Array else v
	var g := TreeSim.growth(d)
	var st := TreeSim.stage(d)
	if felled and not _was_felled:
		_play_fall()
	_was_felled = felled
	model.visible = true
	if trunk:
		trunk.visible = not felled
	if crown:
		crown.visible = not felled
	if stump:
		stump.visible = felled and not bool(d.get("from_seed", false))
	if roots:
		roots.visible = not bool(d.get("from_seed", false)) or not felled
	model.scale = Vector3.ONE * (0.82 + 0.18 * g if not felled else 1.0)
	for i in small.size():
		var b: Node3D = small[i]
		if b:
			var gg := float(d["sb"][i])
			b.visible = not felled and gg > 0.02
			b.scale = Vector3.ONE * maxf(0.05, gg)
		_set_area("sb:%d" % i, not felled and float(d["sb"][i]) > 0.02)
	for i in large.size():
		var b: Node3D = large[i]
		if b:
			var gg := float(d["lb"][i])
			b.visible = not felled and gg > 0.02
			b.scale = Vector3.ONE * maxf(0.05, gg)
		_set_area("lb:%d" % i, not felled and float(d["lb"][i]) > 0.02)
	trunk_body.process_mode = Node.PROCESS_MODE_INHERIT
	_set_body(trunk_body, not felled)
	_set_body(stump_body, felled and not bool(d.get("from_seed", false)))
	var tb := float(d.get("tb", 0.0))
	sapling.visible = felled and st == "sapling"
	young.visible = felled and st == "young"
	if sapling.visible:
		sapling.scale = Vector3.ONE * clampf(0.25 + tb / 18.0 * 0.75, 0.25, 1.0)
	if young.visible:
		young.scale = Vector3.ONE * clampf(0.55 + (tb - 18.0) / 42.0 * 0.45, 0.55, 1.0)


func _set_area(part: String, on: bool) -> void:
	var a = areas.get(part)
	if a:
		a.collision_layer = LAYER_INTERACT if on else 0


func _set_body(b: CollisionObject3D, on: bool) -> void:
	b.collision_layer = LAYER_STRUCT if on else 0


func shake(strength: float = 1.0) -> void:
	_shake = maxf(_shake, strength)


func _process(delta: float) -> void:
	if _shake > 0.0:
		_shake = maxf(0.0, _shake - delta * 2.5)
		var t := Time.get_ticks_msec() / 1000.0
		model.rotation = Vector3(sin(t * 31.0) * 0.006 * _shake, 0.0, cos(t * 27.0) * 0.006 * _shake)
	elif model.rotation != Vector3.ZERO:
		model.rotation = Vector3.ZERO


func _play_fall() -> void:
	## A visual copy of the trunk and crown topples over.
	if trunk == null:
		return
	var ghost := Node3D.new()
	add_child(ghost)
	var tcopy := trunk.duplicate() as Node3D
	tcopy.visible = true
	ghost.add_child(tcopy)
	if crown and crown.get_parent() != trunk:
		var ccopy := crown.duplicate() as Node3D
		ccopy.visible = true
		ghost.add_child(ccopy)
	var dir := randf() * TAU
	ghost.rotation.y = dir
	var tw := create_tween()
	tw.tween_property(ghost, "rotation:x", PI * 0.47, 2.2).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tw.tween_callback(func(): Sfx.play("tree_fall", global_position + Vector3(0, 1, 0), 2.0))
	tw.tween_interval(0.6)
	tw.tween_property(ghost, "scale", Vector3(0.001, 0.001, 0.001), 0.5)
	tw.tween_callback(ghost.queue_free)
	Sfx.play("tree_creak", global_position + Vector3(0, 3, 0), 2.0)


# ---------------------------------------------------------------------------
# Procedural fallback (used until/unless the Blender model is present)
# ---------------------------------------------------------------------------

func _procedural_tree() -> Node3D:
	var root := Node3D.new()
	var bark := Models.material_for("Bark")
	var leaves := Models.material_for("Leaves")
	var tr := MeshInstance3D.new()
	tr.name = "Trunk"
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.16
	cyl.bottom_radius = 0.3
	cyl.height = 5.6
	tr.mesh = ProcMesh.painted(cyl, ProcMesh.BARK)
	tr.material_override = bark
	tr.position.y = 2.8
	root.add_child(tr)
	var cr := MeshInstance3D.new()
	cr.name = "CrownLeaves"
	cr.mesh = ProcMesh.blob(1.9, Color(0.3, 0.5, 0.2), 11, 0.75)
	cr.material_override = leaves
	cr.position = Vector3(0, 4.6, 0)
	root.add_child(cr)
	var st := MeshInstance3D.new()
	st.name = "Stump"
	var sc := CylinderMesh.new()
	sc.top_radius = 0.27
	sc.bottom_radius = 0.33
	sc.height = 0.55
	st.mesh = ProcMesh.painted(sc, ProcMesh.BARK)
	st.material_override = bark
	st.position.y = 0.27
	root.add_child(st)
	for i in TreeSim.SMALL:
		var a := float(i) / TreeSim.SMALL * TAU + 0.3
		var h := 1.5 + fmod(i * 0.37, 1.0)
		root.add_child(_proc_branch("BranchS_%d" % i, Vector3(cos(a) * 0.22, h, sin(a) * 0.22), Vector3(cos(a), 0.25, sin(a)), 1.1, 0.03, bark, leaves, 0.35))
	for i in TreeSim.LARGE:
		var a := float(i) / TreeSim.LARGE * TAU + 1.0
		var h := 2.5 + fmod(i * 0.23, 0.9)
		root.add_child(_proc_branch("BranchL_%d" % i, Vector3(cos(a) * 0.2, h, sin(a) * 0.2), Vector3(cos(a), 0.6, sin(a)), 2.6, 0.08, bark, leaves, 0.85))
	return root


func _proc_branch(nm: String, attach: Vector3, dir: Vector3, length: float, radius: float, bark: Material, leaves: Material, leaf_r: float) -> Node3D:
	var b := Node3D.new()
	b.name = nm
	b.position = attach
	dir = dir.normalized()
	var stick := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = radius * 0.4
	cm.bottom_radius = radius
	cm.height = length
	stick.mesh = ProcMesh.painted(cm, ProcMesh.BARK)
	stick.material_override = bark
	var axis := Vector3.UP.cross(dir)
	var basis := Basis(axis.normalized(), Vector3.UP.angle_to(dir)) if axis.length() > 0.001 else Basis()
	stick.transform = Transform3D(basis, dir * length * 0.5)
	b.add_child(stick)
	var lv := MeshInstance3D.new()
	lv.name = nm + "_Leaves"
	lv.mesh = ProcMesh.blob(leaf_r, Color(0.33, 0.52, 0.22), nm.hash() % 50, 0.8)
	lv.material_override = leaves
	lv.position = dir * length * 0.95
	b.add_child(lv)
	return b


func _proc_small_tree(height: float) -> Node3D:
	var root := Node3D.new()
	var t := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = height * 0.015
	cm.bottom_radius = height * 0.035
	cm.height = height * 0.75
	t.mesh = ProcMesh.painted(cm, ProcMesh.BARK)
	t.material_override = Models.material_for("Bark")
	t.position.y = height * 0.375
	root.add_child(t)
	var l := MeshInstance3D.new()
	l.mesh = ProcMesh.blob(height * 0.3, Color(0.35, 0.55, 0.22), int(height * 10), 0.85)
	l.material_override = Models.material_for("Leaves")
	l.position.y = height * 0.72
	root.add_child(l)
	return root
