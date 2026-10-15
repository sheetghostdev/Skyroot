class_name AnimalView
extends EntityView
## An animal, built from boxes like everything else: a crab scuttling sideways,
## a junglefowl bobbing its head, a goat on its four legs.  The host moves it a
## few times a second and this eases it along between, legs going at the pace it
## walks.  On a raft it stands on the deck as this machine draws the raft.  A
## lead of twine runs from its neck to whoever leads it.

const TINTS := {
	"crab": [Color(0.46, 0.29, 0.2), Color(0.52, 0.33, 0.21), Color(0.42, 0.3, 0.24)],
	"fowl": [Color(0.62, 0.3, 0.14), Color(0.55, 0.36, 0.2), Color(0.7, 0.42, 0.2)],
	"goat": [Color(0.62, 0.48, 0.34), Color(0.9, 0.87, 0.8), Color(0.52, 0.44, 0.38), Color(0.76, 0.62, 0.44)],
}

var model: Node3D
var legs: Array[Node3D] = []
var head: Node3D
var _target := Transform3D.IDENTITY
var _vis := Transform3D.IDENTITY
var _speed := 0.0
var _walk := 0.0
var _peck := 0.0
var _hurt := 0.0
var _rope: Array[MeshInstance3D] = []
var _mat: ShaderMaterial
var _surfs: Dictionary = {}      # model part -> the boxes merged into its mesh
var _neck := Vector3(0, 0.5, -0.3)


func _build() -> void:
	add_to_group("animals")
	_target = transform
	_vis = transform
	_mat = EntityView.block_mat()
	model = Node3D.new()
	add_child(model)
	var s := String(data().get("s", ""))
	var tints: Array = TINTS.get(s, [Color.WHITE])
	var tint: Color = tints[entity_id % tints.size()]
	match s:
		"crab":
			_crab(tint)
		"fowl":
			_fowl(tint)
		"goat":
			_goat(tint)
	_finish_meshes()
	_scale()


func species() -> String:
	return String(data().get("s", ""))


func size() -> Vector2:
	var sz: Array = ItemDB.animals.get(species(), {}).get("size", [0.5, 0.5])
	var k := _grown_scale()
	return Vector2(float(sz[0]), float(sz[1])) * k


func _grown_scale() -> float:
	return lerpf(0.55, 1.0, AnimalSim.grown(data()))


func _scale() -> void:
	model.scale = Vector3.ONE * _grown_scale()


func _refresh(keys: Array) -> void:
	if keys.has("hp"):
		_hurt = 0.35
	if keys.has("born"):
		_scale()


func _moved(xf: Transform3D) -> void:
	_target = xf


func view_xf() -> Transform3D:
	return _vis


func _process(delta: float) -> void:
	var d := data()
	var target := _target
	var raft := RaftView.find(int(d.get("raft", -1))) if int(d.get("raft", -1)) >= 0 else null
	if raft != null:
		target = raft.view_xf() * Transform3D(Basis(Vector3.UP, float(d.get("ry", 0.0))), d.get("rp", Vector3.ZERO))
	var k := 1.0 - exp(-10.0 * delta)
	var q := Quaternion(_vis.basis).slerp(Quaternion(target.basis), k)
	_vis = Transform3D(Basis(q), _vis.origin.lerp(target.origin, k))
	if _vis.origin.distance_to(target.origin) > 4.0:
		_vis = target
	transform = _vis
	# how fast it walks (on a raft: about the deck, not carried by it)
	var rel := raft.view_xf().affine_inverse() * _vis.origin if raft != null else _vis.origin
	var moved := 0.0 if _last_rel == Vector3.INF else rel.distance_to(_last_rel)
	_last_rel = rel
	_speed = lerpf(_speed, minf(moved / maxf(delta, 0.001), 6.0), 1.0 - exp(-6.0 * delta))
	_animate(delta)
	_call(delta)
	_frames += 1
	if _frames % 30 == 0:
		_scale()
	_draw_rope(int(d.get("lead", -1)))


var _frames := 0
var _last_rel := Vector3.INF
var _call_t := randf_range(4.0, 30.0)


func _call(delta: float) -> void:
	## Now and then a bleat, a cluck or a click - if you're near enough to hear.
	_call_t -= delta
	if _call_t > 0.0:
		return
	_call_t = randf_range(14.0, 45.0)
	var cam := get_viewport().get_camera_3d()
	if cam and cam.global_position.distance_to(global_position) < 22.0:
		var fxn := get_tree().get_first_node_in_group("fx")
		if fxn:
			fxn.play("animal_call", global_position + Vector3(0, 0.4, 0), {"s": species()})


func _animate(delta: float) -> void:
	var moving := clampf(_speed / 1.2, 0.0, 1.6)
	_walk += delta * (4.0 + _speed * 6.0) * (1.0 if moving > 0.05 else 0.0)
	var sw := sin(_walk) * 0.55 * minf(moving, 1.0)
	match species():
		"crab":
			for i in legs.size():
				var side := 1.0 if i % 2 == 0 else -1.0
				legs[i].rotation.z = side * (0.5 + sin(_walk * 1.6 + i * 1.3) * 0.35 * minf(moving, 1.0))
		"fowl":
			if legs.size() == 2:
				legs[0].rotation.x = sw
				legs[1].rotation.x = -sw
			_peck -= delta
			if moving < 0.05 and _peck < -3.0 and randf() < delta * 0.5:
				_peck = 0.6
			var peck := maxf(0.0, sin(clampf(_peck, 0.0, 0.6) / 0.6 * PI)) if _peck > 0.0 else 0.0
			if head:
				head.rotation.x = -peck * 1.1
				head.position.z = _neck.z + sin(_walk * 2.0) * 0.03 * minf(moving, 1.0)
		"goat":
			if legs.size() == 4:
				legs[0].rotation.x = sw
				legs[3].rotation.x = sw
				legs[1].rotation.x = -sw
				legs[2].rotation.x = -sw
			if head:
				_peck -= delta
				if moving < 0.05 and _peck < -4.0 and randf() < delta * 0.3:
					_peck = 2.5
				head.rotation.x = -0.8 if _peck > 0.0 else lerpf(head.rotation.x, 0.0, 1.0 - exp(-4.0 * delta))
	_hurt = maxf(0.0, _hurt - delta)
	model.position.y = _hurt * 0.4


# ---------------------------------------------------------------------------
# The lead
# ---------------------------------------------------------------------------

func _draw_rope(lead: int) -> void:
	if lead < 0:
		for r in _rope:
			r.visible = false
		return
	var pr := get_tree().get_first_node_in_group("players_root") as PlayersRoot
	if pr == null:
		return
	var who := pr.player_node(lead)
	if who == null:
		return
	if _rope.is_empty():
		var lin := Color(0.78, 0.68, 0.45).srgb_to_linear()
		for i in 8:
			var mi := MeshInstance3D.new()
			var bm := BoxMesh.new()
			bm.size = Vector3(0.025, 0.025, 1.0)
			mi.mesh = bm
			var m := StandardMaterial3D.new()
			m.albedo_color = lin
			mi.material_override = m
			mi.top_level = true
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			add_child(mi)
			_rope.append(mi)
	var a := global_transform * (_neck * _grown_scale())
	var b := (who as Node3D).global_position + Vector3(0, 0.95, 0)
	if who is LocalPlayer:
		var lp := who as LocalPlayer
		b = lp.global_position + Basis(Vector3.UP, lp.yaw) * Vector3(0.25, 0.9, -0.3)
	var span := a.distance_to(b)
	var sag := clampf(1.6 - span * 0.25, 0.05, 0.6)
	var n := _rope.size()
	for i in n:
		var t0 := float(i) / n
		var t1 := float(i + 1) / n
		var p0 := a.lerp(b, t0) - Vector3(0, sag * 4.0 * t0 * (1.0 - t0), 0)
		var p1 := a.lerp(b, t1) - Vector3(0, sag * 4.0 * t1 * (1.0 - t1), 0)
		var seg := _rope[i]
		seg.visible = true
		var ln := maxf(0.001, p0.distance_to(p1))
		var xf := Transform3D(Basis(), (p0 + p1) * 0.5)
		if ln > 0.001:
			xf = xf.looking_at(p1, Vector3.UP if absf((p1 - p0).normalized().y) < 0.99 else Vector3.RIGHT)
		xf.basis = xf.basis.scaled(Vector3(1, 1, ln))
		seg.global_transform = xf


# ---------------------------------------------------------------------------
# Models (block units, origin at the feet, facing -Z)
# ---------------------------------------------------------------------------

func _box(parent: Node3D, center: Vector3, sz: Vector3, tile: String, tint: Color, rot := Vector3.ZERO) -> void:
	## One box of the model, merged into its part's mesh (one draw per moving
	## part, not one per box).
	var tmp := ChunkMesher.Surf.new()
	var lin := tint.srgb_to_linear()
	var tex := BlockTex.layer(tile)
	ChunkMesher.box_faces(tmp, -sz * 0.5, sz * 0.5, 0.0, Vector3.ZERO, tex, tex, Color(lin.r, lin.g, lin.b, 1.0))
	var xf := Transform3D(Basis.from_euler(rot), center)
	if not _surfs.has(parent):
		_surfs[parent] = ChunkMesher.Surf.new()
	var s: ChunkMesher.Surf = _surfs[parent]
	var base := s.v.size()
	for k in tmp.v.size():
		s.v.append(xf * tmp.v[k])
		s.n.append(xf.basis * tmp.n[k])
	s.c.append_array(tmp.c)
	s.uv.append_array(tmp.uv)
	s.uv2.append_array(tmp.uv2)
	for idx in tmp.i:
		s.i.append(base + idx)


func _finish_meshes() -> void:
	for parent in _surfs:
		var arr := (_surfs[parent] as ChunkMesher.Surf).arrays()
		if arr.is_empty():
			continue
		var m := ArrayMesh.new()
		m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
		m.surface_set_material(0, _mat)
		var mi := MeshInstance3D.new()
		mi.mesh = m
		mi.visibility_range_end = 72.0      # too small to see further off
		(parent as Node3D).add_child(mi)
	_surfs.clear()


func _pivot(parent: Node3D, at: Vector3) -> Node3D:
	var n := Node3D.new()
	n.position = at
	parent.add_child(n)
	return n


func _crab(tint: Color) -> void:
	_neck = Vector3(0, 0.15, -0.14)
	var dark := tint.darkened(0.35)
	_box(model, Vector3(0, 0.13, 0), Vector3(0.34, 0.11, 0.26), "shell", tint)
	_box(model, Vector3(0, 0.2, 0.0), Vector3(0.26, 0.04, 0.2), "shell", tint.lightened(0.08))
	for sx in [-1.0, 1.0]:
		# eyes on stalks
		_box(model, Vector3(sx * 0.05, 0.22, -0.12), Vector3(0.025, 0.07, 0.025), "shell", dark)
		_box(model, Vector3(sx * 0.05, 0.265, -0.12), Vector3(0.035, 0.035, 0.035), "hair", Color(0.1, 0.1, 0.1))
		# claws
		var arm := _pivot(model, Vector3(sx * 0.15, 0.12, -0.12))
		_box(arm, Vector3(sx * 0.05, 0.0, -0.05), Vector3(0.06, 0.05, 0.12), "shell", tint)
		_box(arm, Vector3(sx * 0.07, 0.02, -0.14), Vector3(0.1, 0.08, 0.1), "shell", tint.lightened(0.05))
		# three legs a side
		for k in 3:
			var leg := _pivot(model, Vector3(sx * 0.16, 0.12, -0.04 + k * 0.08))
			_box(leg, Vector3(sx * 0.08, 0.0, 0), Vector3(0.16, 0.025, 0.025), "shell", dark)
			_box(leg, Vector3(sx * 0.17, -0.06, 0), Vector3(0.025, 0.12, 0.025), "shell", dark)
			leg.rotation.z = sx * 0.5
			legs.append(leg)


func _fowl(tint: Color) -> void:
	_neck = Vector3(0, 0.45, -0.12)
	_box(model, Vector3(0, 0.3, 0.02), Vector3(0.22, 0.2, 0.32), "feathers", tint)
	_box(model, Vector3(0, 0.36, 0.06), Vector3(0.24, 0.1, 0.22), "feathers", tint.darkened(0.12))
	# a dark sickle tail
	_box(model, Vector3(0, 0.44, 0.2), Vector3(0.05, 0.22, 0.1), "feathers", Color(0.12, 0.2, 0.16), Vector3(-0.5, 0, 0))
	_box(model, Vector3(0, 0.5, 0.25), Vector3(0.04, 0.16, 0.08), "feathers", Color(0.1, 0.16, 0.13), Vector3(-0.9, 0, 0))
	head = _pivot(model, Vector3(0, 0.38, -0.12))
	_box(head, Vector3(0, 0.08, -0.02), Vector3(0.1, 0.16, 0.1), "feathers", Color(0.78, 0.48, 0.2))
	_box(head, Vector3(0, 0.18, -0.03), Vector3(0.025, 0.06, 0.09), "shell", Color(0.78, 0.12, 0.1))
	_box(head, Vector3(0, 0.08, -0.09), Vector3(0.03, 0.05, 0.03), "shell", Color(0.78, 0.12, 0.1))
	_box(head, Vector3(0, 0.12, -0.09), Vector3(0.035, 0.025, 0.05), "shell", Color(0.85, 0.68, 0.3))
	for sx in [-1.0, 1.0]:
		_box(head, Vector3(sx * 0.051, 0.13, -0.04), Vector3(0.005, 0.02, 0.02), "hair", Color(0.1, 0.08, 0.05))
		var leg := _pivot(model, Vector3(sx * 0.05, 0.21, 0.03))
		_box(leg, Vector3(0, -0.1, 0), Vector3(0.025, 0.2, 0.025), "shell", Color(0.8, 0.66, 0.32))
		_box(leg, Vector3(0, -0.2, -0.03), Vector3(0.06, 0.01, 0.08), "shell", Color(0.8, 0.66, 0.32))
		legs.append(leg)


func _goat(tint: Color) -> void:
	# stocky: a deep body on short legs, a bearded head, horns swept back
	_neck = Vector3(0, 0.82, -0.42)
	var belly := tint.lerp(Color(0.92, 0.88, 0.8), 0.45)
	var dark := tint.darkened(0.25)
	_box(model, Vector3(0, 0.6, 0.04), Vector3(0.38, 0.38, 0.8), "fur", tint)
	_box(model, Vector3(0, 0.44, 0.04), Vector3(0.34, 0.06, 0.62), "fur", belly)
	_box(model, Vector3(0, 0.62, -0.3), Vector3(0.4, 0.34, 0.22), "fur", tint.lightened(0.05))
	_box(model, Vector3(0, 0.8, 0.45), Vector3(0.07, 0.13, 0.06), "fur", dark, Vector3(-0.6, 0, 0))
	_box(model, Vector3(0, 0.8, -0.38), Vector3(0.17, 0.26, 0.17), "fur", tint, Vector3(0.5, 0, 0))
	head = _pivot(model, Vector3(0, 0.88, -0.46))
	_box(head, Vector3(0, 0.06, -0.12), Vector3(0.19, 0.2, 0.3), "fur", tint)
	_box(head, Vector3(0, 0.02, -0.28), Vector3(0.13, 0.12, 0.07), "fur", tint.darkened(0.15))
	_box(head, Vector3(0, -0.1, -0.22), Vector3(0.06, 0.15, 0.06), "fur", belly.darkened(0.2))
	for sx in [-1.0, 1.0]:
		_box(head, Vector3(sx * 0.13, 0.08, -0.04), Vector3(0.11, 0.04, 0.06), "fur", tint.darkened(0.08), Vector3(0, 0, sx * -0.35))
		var horn := _pivot(head, Vector3(sx * 0.05, 0.16, -0.06))
		horn.rotation = Vector3(-1.0, 0, sx * 0.12)
		_box(horn, Vector3(0, 0.08, 0), Vector3(0.045, 0.16, 0.045), "shell", Color(0.42, 0.36, 0.28))
		_box(horn, Vector3(0, 0.17, 0.02), Vector3(0.035, 0.06, 0.035), "shell", Color(0.36, 0.3, 0.24))
		_box(head, Vector3(sx * 0.096, 0.1, -0.18), Vector3(0.005, 0.03, 0.03), "hair", Color(0.08, 0.06, 0.04))
	for at in [Vector3(-0.12, 0.42, -0.26), Vector3(0.12, 0.42, -0.26), Vector3(-0.12, 0.42, 0.32), Vector3(0.12, 0.42, 0.32)]:
		var leg := _pivot(model, at)
		_box(leg, Vector3(0, -0.12, 0), Vector3(0.1, 0.24, 0.1), "fur", tint)
		_box(leg, Vector3(0, -0.3, 0), Vector3(0.08, 0.14, 0.08), "fur", dark)
		_box(leg, Vector3(0, -0.4, -0.005), Vector3(0.085, 0.05, 0.095), "shell", Color(0.2, 0.17, 0.13))
		legs.append(leg)


static func find(eid: int) -> AnimalView:
	var em := (Engine.get_main_loop() as SceneTree).get_first_node_in_group("entities") as EntityManager
	if em == null:
		return null
	return em.view(eid) as AnimalView


static func all() -> Array:
	var out: Array = []
	for v in (Engine.get_main_loop() as SceneTree).get_nodes_in_group("animals"):
		if v is AnimalView and not (v as AnimalView).is_queued_for_deletion():
			out.append(v)
	return out
