class_name TreeFall
extends Node3D
## A felled tree coming down: a short-lived copy of its logs and leaves that
## swings over about the stump, slowly and then fast, and bursts into leaves
## where it lands.  Only for show - the host has already taken the blocks away
## and dropped what the tree gives (those items appear as it lands).

var _axis := Vector3.RIGHT
var _stop := PI * 0.5
var _fall := 1.2
var _life := 1.5
var _t := 0.0
var _landed := false
var _crown := Vector3.ZERO
var _leaf := 0
var _log := 0


static func make(c: Vector3i, p: Dictionary) -> TreeFall:
	var tf := TreeFall.new()
	tf.top_level = true
	var dir: Vector3i = p.get("dir", Vector3i(1, 0, 0))
	tf._leaf = int(p.get("b", 0))
	tf._log = int(p.get("log", 0))
	tf._life = float(p.get("ms", 1500)) / 1000.0
	tf._fall = tf._life * 0.8
	var logs: PackedInt32Array = p.get("logs", PackedInt32Array())
	var leaves: PackedInt32Array = p.get("leaves", PackedInt32Array())
	# it pivots on the edge of the stump it falls toward
	var pivot := Vector3(c) + Vector3(0.5, 0.0, 0.5) + Vector3(dir) * 0.5
	tf.position = pivot
	tf._axis = Vector3.UP.cross(Vector3(dir)).normalized()
	var height := 1.0
	for i in range(0, logs.size(), 3):
		height = maxf(height, float(logs[i + 1]) + 1.0)
	# something in the way (a bank, a wall) stops it leaning short of the ground
	var reach := float(p.get("reach", 16.0))
	if height > sqrt(reach * reach + 4.0):
		tf._stop = atan2(reach, 2.0)
	tf._crown = Vector3(dir) * minf(height * 0.8, reach)
	var mi := MeshInstance3D.new()
	mi.mesh = tf._mesh(c, logs, leaves)
	mi.position = Vector3(c) - pivot
	tf.add_child(mi)
	return tf


func _mesh(c: Vector3i, logs: PackedInt32Array, leaves: PackedInt32Array) -> ArrayMesh:
	var log_set := {}
	for i in range(0, logs.size(), 3):
		log_set[Vector3i(logs[i], logs[i + 1], logs[i + 2])] = true
	var m := ArrayMesh.new()
	var sl := ChunkMesher.Surf.new()
	for k in log_set:
		var at: Vector3i = k
		var cull := func(f: int, _a: Vector3, _b: Vector3) -> bool:
			return log_set.has(at + (ChunkMesher.FACES[f]["n"] as Vector3i))
		ChunkMesher.box_faces(sl, Vector3.ZERO, Vector3.ONE, 0.0, Vector3(at), Blocks.face_tex[_log * 6 + 2], Blocks.face_tex[_log * 6 + 0], Color.WHITE, cull)
	var sv := ChunkMesher.Surf.new()
	for i in range(0, leaves.size(), 3):
		var at := Vector3i(leaves[i], leaves[i + 1], leaves[i + 2])
		var w := c + at
		var tint := ChunkMesher._tint(_leaf, w.x, w.y, w.z)
		ChunkMesher.box_faces(sv, Vector3.ZERO, Vector3.ONE, 0.0, Vector3(at), Blocks.face_tex[_leaf * 6 + 2], Blocks.face_tex[_leaf * 6 + 0], tint)
	var arr := sl.arrays()
	if not arr.is_empty():
		m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
		m.surface_set_material(m.get_surface_count() - 1, EntityView.block_mat())
	arr = sv.arrays()
	if not arr.is_empty():
		m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
		m.surface_set_material(m.get_surface_count() - 1, _leaf_mat())
	return m


static func _leaf_mat() -> ShaderMaterial:
	return EntityModels.get_or_build("mat:leaves", func():
		var mat := ShaderMaterial.new()
		mat.shader = load("res://assets/shaders/voxel_cutout.gdshader")
		mat.set_shader_parameter("atlas", BlockTex.array())
		mat.set_shader_parameter("ao_light", 0.2)
		return mat)


func _process(delta: float) -> void:
	_t += delta
	var a := 0.0
	if _t < _fall:
		# a toppling trunk: barely moving at first, then faster and faster
		a = _stop * pow(_t / _fall, 2.4)
	else:
		if not _landed:
			_landed = true
			_land()
		# a little bounce as it hits
		var u := (_t - _fall) / maxf(0.01, _life - _fall)
		a = _stop - sin(clampf(u, 0.0, 1.0) * PI) * 0.06
	basis = Basis(_axis, a)
	if _t >= _life:
		queue_free()


func _land() -> void:
	var at := position + _crown + Vector3(0, 0.6, 0)
	Sfx.play("tree_fall", at, 0.0)
	var fx := get_tree().get_first_node_in_group("fx") as FX
	if fx:
		var col := BlockTex.avg_color(Blocks.face_tex[_leaf * 6 + 2]) if _leaf > 0 else Color(0.3, 0.45, 0.2)
		fx.burst(at, col, 36, 0.09, 2.6, 4.0, 1.8, 1.4)
		fx.burst(position + _crown * 0.4 + Vector3(0, 0.3, 0), Color(0.5, 0.42, 0.3), 14, 0.06, 2.0, 10.0, 0.8, 0.8)
