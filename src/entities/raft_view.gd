class_name RaftView
extends EntityView
## A raft: its lashed logs and whatever is built on it, drawn from its cells,
## with sails up or furled and torches burning.  On the host it is wherever the
## simulation put it; elsewhere it eases toward the host's position, carried on
## by its speed between updates.  The logs bob a little on the swell (only the
## picture: you stand on the steady raft).

const SAIL_UP := AABB(Vector3(-0.78, 0.72, 0.47), Vector3(2.56, 1.82, 0.06))
const SAIL_FURLED := AABB(Vector3(-0.82, 2.42, 0.42), Vector3(2.64, 0.17, 0.16))

var body: Node3D
var mi: MeshInstance3D
var _target := Transform3D.IDENTITY
var _target_t := 0.0
var _vis := Transform3D.IDENTITY
var _t := 0.0
var _extras: Array = []


func _build() -> void:
	add_to_group("rafts")
	# move before the players who ride it, so they're carried this same frame
	process_physics_priority = -5
	body = Node3D.new()
	add_child(body)
	mi = MeshInstance3D.new()
	body.add_child(mi)
	_target = transform
	_vis = transform
	_t = randf() * 10.0


func _refresh(keys: Array) -> void:
	if keys.has("cells"):
		_rebuild()


func _moved(xf: Transform3D) -> void:
	_target = xf
	_target_t = Time.get_ticks_msec() / 1000.0
	if World.is_host():
		_vis = xf
		transform = xf


func view_xf() -> Transform3D:
	## Where the raft is drawn - and so where people on it stand.
	return _vis


func cells() -> Dictionary:
	return data().get("cells", {})


func _physics_process(delta: float) -> void:
	if not World.is_host():
		# carry on at the raft's speed since the last update, and ease there
		var d := data()
		var v: Vector3 = d.get("v", Vector3.ZERO)
		var dt := clampf(Time.get_ticks_msec() / 1000.0 - _target_t, 0.0, 0.5)
		var pred := _target
		pred.origin += v * dt
		var k := 1.0 - exp(-12.0 * delta)
		var q := Quaternion(_vis.basis).slerp(Quaternion(pred.basis), k)
		_vis = Transform3D(Basis(q), _vis.origin.lerp(pred.origin, k))
		if _vis.origin.distance_to(pred.origin) > 6.0:
			_vis = pred
		transform = _vis


func _process(delta: float) -> void:
	_t += delta
	# the swell (picture only)
	var n := float(Raft.floor_count(cells()))
	var amp := 1.0 / sqrt(maxf(1.0, n))
	body.position.y = sin(_t * 1.3) * 0.025 * amp
	body.rotation = Vector3(sin(_t * 0.9) * 0.012 * amp, 0.0, sin(_t * 1.1 + 1.0) * 0.015 * amp)


func _rebuild() -> void:
	for x in _extras:
		(x as Node).queue_free()
	_extras.clear()
	var cs := cells()
	var s := ChunkMesher.Surf.new()
	var opaque := Blocks.opaque
	for c in cs:
		var v: Vector2i = cs[c]
		var id := v.x
		var m := v.y
		var at := Vector3(c)
		if Blocks.fixture[id] == 1:
			var t := TorchModel.make(true)
			body.add_child(t)
			t.place_block(at, m)
			_extras.append(t)
			continue
		match Blocks.shape[id]:
			Blocks.Shape.CUBE:
				var cell: Vector3i = c
				var cull := func(f: int, _a: Vector3, _b: Vector3) -> bool:
					var nb = cs.get(cell + (ChunkMesher.FACES[f]["n"] as Vector3i))
					return nb != null and opaque[(nb as Vector2i).x] == 1
				ChunkMesher.box_faces(s, Vector3.ZERO, Vector3.ONE, 0.0, at, Blocks.face_tex[id * 6 + 2], Blocks.face_tex[id * 6], Color.WHITE, cull)
			Blocks.Shape.BOXES:
				for bx in Blocks.boxes.get(id, []):
					var a: Vector3 = bx["a"]
					var b: Vector3 = bx["b"]
					if Blocks.facing[id] == 1:
						var tb := Blocks.turn_box(a, b, m)
						a = tb.position
						b = tb.end
					ChunkMesher.box_faces(s, a, b, 0.0, at, bx["tex"], bx["tex"], Color.WHITE)
				if Blocks.has_flag(id, "sail"):
					var sb := SAIL_UP if (m & 4) != 0 else SAIL_FURLED
					var tb2 := Blocks.turn_box(sb.position, sb.end, m)
					ChunkMesher.box_faces(s, tb2.position, tb2.end, 0.0, at, BlockTex.layer("thatch"), BlockTex.layer("thatch"), Color(1.0, 0.97, 0.9))
	var mesh := ArrayMesh.new()
	var arr := s.arrays()
	if not arr.is_empty():
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
		mesh.surface_set_material(0, block_mat())
	mi.mesh = mesh


static func find(eid: int) -> RaftView:
	var em := (Engine.get_main_loop() as SceneTree).get_first_node_in_group("entities") as EntityManager
	if em == null:
		return null
	return em.view(eid) as RaftView


static func all() -> Array:
	var out: Array = []
	for v in (Engine.get_main_loop() as SceneTree).get_nodes_in_group("rafts"):
		if v is RaftView and not (v as RaftView).is_queued_for_deletion():
			out.append(v)
	return out
