class_name VoxelView
extends Node3D
## Renders a VoxelData as 16^3 chunk meshes.  Chunks are rebuilt on worker
## threads when blocks change (and their neighbours when the change can alter
## their light), and swapped in on the main thread.  Torches get a light each.

const CS := ChunkMesher.CS
const NCX := VoxelData.SX / CS
const NCY := VoxelData.SY / CS
const NCZ := VoxelData.SZ / CS
const MAX_JOBS := 3

var vd: VoxelData
var mat_solid: ShaderMaterial
var mat_cutout: ShaderMaterial
var mat_water: ShaderMaterial
var chunks: Dictionary = {}          # Vector3i -> MeshInstance3D
var _lights: Dictionary = {}         # Vector3i -> Array[OmniLight3D]
var _fixtures: Dictionary = {}       # Vector3i -> [key, Array[Node3D]]
var _dirty: Dictionary = {}          # Vector3i -> true
var _jobs: Dictionary = {}           # task id -> Vector3i
var _results: Array = []
var _mutex := Mutex.new()
var _rebuild_again: Dictionary = {}  # chunk changed while its job ran
var _flicker_t := 0.0


func _ready() -> void:
	add_to_group("voxel_view")
	var arr := BlockTex.array()
	mat_solid = ShaderMaterial.new()
	mat_solid.shader = load("res://assets/shaders/voxel_solid.gdshader")
	mat_solid.set_shader_parameter("atlas", arr)
	mat_cutout = ShaderMaterial.new()
	mat_cutout.shader = load("res://assets/shaders/voxel_cutout.gdshader")
	mat_cutout.set_shader_parameter("atlas", arr)
	mat_water = ShaderMaterial.new()
	mat_water.shader = load("res://assets/shaders/voxel_water.gdshader")
	mat_water.set_shader_parameter("atlas", arr)
	mat_water.render_priority = 1


func build(data: VoxelData, sync := false) -> void:
	## Mesh everything.  `sync` builds on this thread (menu backdrop, screenshots).
	vd = data
	for c in chunks.values():
		(c as Node).queue_free()
	chunks.clear()
	for cz in NCZ:
		for cx in NCX:
			for cy in NCY:
				var k := Vector3i(cx, cy, cz)
				if sync:
					_apply(k, ChunkMesher.build(vd.ids, vd.meta, vd.height, vd.low, cx, cy, cz))
				else:
					_dirty[k] = true


func block_changed(c: Vector3i, old_height: int) -> void:
	## A block changed at c (old_height: the column's sky height before).  The
	## chunks within light range of it are rebuilt - and if the change opened or
	## closed the column to the sky, everything down that column too.
	if vd == null:
		return
	var m := ChunkMesher.MARGIN
	var h := vd.column_height(c.x, c.z)
	var lo_y := c.y - m
	var hi_y := c.y + m
	if old_height != h:
		lo_y = mini(lo_y, vd.column_low(c.x, c.z) - m)
	var a := Vector3i((c.x - m) / CS, maxi(lo_y, 0) / CS, (c.z - m) / CS)
	var b := Vector3i((c.x + m) / CS, mini(hi_y, VoxelData.SY - 1) / CS, (c.z + m) / CS)
	# the chunk itself first, then the ones whose light may have changed
	_mark(Vector3i(c.x / CS, c.y / CS, c.z / CS))
	for cz in range(maxi(a.z, 0), mini(b.z, NCZ - 1) + 1):
		for cy in range(maxi(a.y, 0), mini(b.y, NCY - 1) + 1):
			for cx in range(maxi(a.x, 0), mini(b.x, NCX - 1) + 1):
				_mark(Vector3i(cx, cy, cz))


func _mark(k: Vector3i) -> void:
	if k.x < 0 or k.y < 0 or k.z < 0 or k.x >= NCX or k.y >= NCY or k.z >= NCZ:
		return
	if _jobs.values().has(k):
		_rebuild_again[k] = true
	else:
		_dirty[k] = true


func _process(delta: float) -> void:
	if vd == null:
		return
	# finished jobs
	for tid in _jobs.keys():
		if WorkerThreadPool.is_task_completed(tid):
			WorkerThreadPool.wait_for_task_completion(tid)
			var k: Vector3i = _jobs[tid]
			_jobs.erase(tid)
			if _rebuild_again.has(k):
				_rebuild_again.erase(k)
				_dirty[k] = true
	_mutex.lock()
	var res := _results
	_results = []
	_mutex.unlock()
	for r in res:
		_apply(r[0], r[1])
	# start new ones, nearest to the camera first
	if not _dirty.is_empty() and _jobs.size() < MAX_JOBS:
		var cam := get_viewport().get_camera_3d()
		var focus := cam.global_position if cam else Vector3(32, 44, 32)
		var keys := _dirty.keys()
		keys.sort_custom(func(p, q): return _dist(p, focus) < _dist(q, focus))
		for k in keys:
			if _jobs.size() >= MAX_JOBS:
				break
			_dirty.erase(k)
			var ids := vd.ids
			var meta := vd.meta
			var hts := vd.height
			var lows := vd.low
			var kk: Vector3i = k
			var tid := WorkerThreadPool.add_task(func(): _job(kk, ids, meta, hts, lows), false, "chunk")
			_jobs[tid] = kk
	_flicker(delta)


func _dist(k: Vector3i, p: Vector3) -> float:
	return (Vector3(k) * CS + Vector3.ONE * CS * 0.5).distance_squared_to(p)


func _job(k: Vector3i, ids: PackedByteArray, meta: PackedByteArray, hts: PackedInt32Array, lows: PackedInt32Array) -> void:
	var r := ChunkMesher.build(ids, meta, hts, lows, k.x, k.y, k.z)
	_mutex.lock()
	_results.append([k, r])
	_mutex.unlock()


func pending() -> int:
	return _dirty.size() + _jobs.size() + _results.size()


func _apply(k: Vector3i, r: Dictionary) -> void:
	var mi: MeshInstance3D = chunks.get(k)
	if r.is_empty():
		if mi:
			mi.queue_free()
			chunks.erase(k)
		_set_lights(k, PackedVector3Array())
		_set_fixtures(k, [])
		return
	var mesh := ArrayMesh.new()
	for key in ["solid", "cutout", "water"]:
		if r.has(key):
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, r[key])
			var m: Material = mat_solid if key == "solid" else (mat_cutout if key == "cutout" else mat_water)
			mesh.surface_set_material(mesh.get_surface_count() - 1, m)
	if mi == null:
		mi = MeshInstance3D.new()
		mi.name = "Chunk_%d_%d_%d" % [k.x, k.y, k.z]
		mi.position = Vector3(k) * CS
		add_child(mi)
		chunks[k] = mi
	mi.mesh = mesh
	_set_lights(k, r.get("lights", PackedVector3Array()))
	_set_fixtures(k, r.get("fixtures", []))


func _set_lights(k: Vector3i, pts: PackedVector3Array) -> void:
	var have: Array = _lights.get(k, [])
	while have.size() > pts.size():
		(have.pop_back() as Node).queue_free()
	while have.size() < pts.size():
		var l := OmniLight3D.new()
		l.light_color = Color(1.0, 0.68, 0.36)
		l.light_energy = 1.4
		l.omni_range = 7.5
		l.omni_attenuation = 1.3
		l.shadow_enabled = false
		add_child(l)
		have.append(l)
	for i in pts.size():
		(have[i] as OmniLight3D).position = Vector3(k) * CS + pts[i]
	_lights[k] = have


func _set_fixtures(k: Vector3i, list: Array) -> void:
	## Torches in this chunk: kept as they are unless they changed.
	var key := str(list)
	var have: Array = _fixtures.get(k, ["", []])
	if have[0] == key:
		return
	for n in have[1]:
		(n as Node).queue_free()
	var nodes: Array = []
	for f in list:
		var t := TorchModel.make(true)
		add_child(t)
		t.place_block(Vector3(k) * CS + (f[0] as Vector3), int(f[2]))
		nodes.append(t)
	if nodes.is_empty():
		_fixtures.erase(k)
	else:
		_fixtures[k] = [key, nodes]


func _flicker(delta: float) -> void:
	_flicker_t += delta
	var i := 0
	for arr in _lights.values():
		for l in arr:
			(l as OmniLight3D).light_energy = 1.35 + sin(_flicker_t * 9.0 + i * 1.7) * 0.08 + sin(_flicker_t * 23.0 + i) * 0.05
			i += 1


func set_wind(w: Vector2, rain: float) -> void:
	if mat_cutout:
		mat_cutout.set_shader_parameter("wind", w)
		mat_cutout.set_shader_parameter("wind_strength", 1.0 + rain * 0.8)


func _exit_tree() -> void:
	for tid in _jobs.keys():
		WorkerThreadPool.wait_for_task_completion(tid)
	_jobs.clear()
