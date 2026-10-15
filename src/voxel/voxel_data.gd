class_name VoxelData
extends RefCounted
## A world's blocks: a grid of block ids plus one byte of per-block state
## ("meta": log axis, crop stage, farmland wetness...).  Block (x, y, z) fills
## the unit cube [x, x+1) x [y, y+1) x [z, z+1) in world space.  The size is set
## per world: the sky island is 64 x 80 x 64, an archipelago much wider.
##
## Stored column-major (y varies fastest) so a column is one contiguous run:
## the mesher copies whole columns at a time.
##
## Also keeps a height map of the highest sky-blocking block in every column
## (skylight, rain and "is this under a roof?").
##
## Outside the grid there is nothing (the sky island's abyss) - or, in an
## archipelago, open sea down to a deep floor (see set_outside()).

var sx := 64
var sy := 80
var sz := 64
var col := 80            # index stride of x (= sy)
var row := 80 * 64       # index stride of z (= sy * sx)

var ids := PackedByteArray()
var meta := PackedByteArray()
var height := PackedInt32Array()     # per column: y of the highest sky-blocking block, -1 if none
var low := PackedInt32Array()        # per column: y of the lowest sky-blocking block, sy if none
var outside := PackedByteArray()     # block id at each height outside the grid (all air by default)


func _init(w: int = 64, h: int = 80, d: int = 64, alloc := true) -> void:
	sx = w
	sy = h
	sz = d
	col = sy
	row = sy * sx
	outside.resize(sy)
	if alloc:
		ids.resize(sx * sy * sz)
		meta.resize(sx * sy * sz)
	height.resize(sx * sz)
	height.fill(-1)
	low.resize(sx * sz)
	low.fill(sy)


func set_outside(column: PackedByteArray) -> void:
	## What lies beyond the edges, by height (open sea: floor, water, air).
	outside = column.duplicate()
	outside.resize(sy)


func idx(x: int, y: int, z: int) -> int:
	return y + x * col + z * row


func in_bounds(x: int, y: int, z: int) -> bool:
	return x >= 0 and y >= 0 and z >= 0 and x < sx and y < sy and z < sz


func in_bounds_v(c: Vector3i) -> bool:
	return c.x >= 0 and c.y >= 0 and c.z >= 0 and c.x < sx and c.y < sy and c.z < sz


static func cell_of(p: Vector3) -> Vector3i:
	return Vector3i(floori(p.x), floori(p.y), floori(p.z))


static func center_of(c: Vector3i) -> Vector3:
	return Vector3(c.x + 0.5, c.y + 0.5, c.z + 0.5)


func get_id(x: int, y: int, z: int) -> int:
	if y < 0 or y >= sy:
		return 0
	if x < 0 or z < 0 or x >= sx or z >= sz:
		return outside[y]
	return ids[y + x * col + z * row]


func get_idv(c: Vector3i) -> int:
	return get_id(c.x, c.y, c.z)


func get_m(x: int, y: int, z: int) -> int:
	if x < 0 or y < 0 or z < 0 or x >= sx or y >= sy or z >= sz:
		return 0
	return meta[y + x * col + z * row]


func set_block(x: int, y: int, z: int, id: int, m: int = 0) -> void:
	if not in_bounds(x, y, z):
		return
	var i := idx(x, y, z)
	ids[i] = id
	meta[i] = m
	_update_height(x, z, y, id)


func set_m(x: int, y: int, z: int, m: int) -> void:
	if in_bounds(x, y, z):
		meta[idx(x, y, z)] = m


static func blocks_sky(id: int) -> bool:
	return Blocks.opaque[id] == 1 or Blocks.sky_cost[id] > 0 or Blocks.solid[id] == 1


func _update_height(x: int, z: int, y: int, id: int) -> void:
	var c := x + z * sx
	var h := height[c]
	var lo := low[c]
	var base := x * col + z * row
	if blocks_sky(id):
		if y > h:
			height[c] = y
		if y < lo:
			low[c] = y
	else:
		if y == h:
			var yy := y - 1
			while yy >= 0 and not blocks_sky(ids[base + yy]):
				yy -= 1
			height[c] = yy
		if y == lo:
			var yl := y + 1
			while yl < sy and not blocks_sky(ids[base + yl]):
				yl += 1
			low[c] = yl


func rebuild_heights() -> void:
	# a table of which ids block the sky, then one pass per column
	var bs := PackedByteArray()
	bs.resize(256)
	for i in Blocks.MAX:
		bs[i] = 1 if blocks_sky(i) else 0
	for z in sz:
		for x in sx:
			var h := -1
			var base := x * col + z * row
			for y in range(sy - 1, -1, -1):
				if bs[ids[base + y]] == 1:
					h = y
					break
			height[x + z * sx] = h
			var l := sy
			for y in sy:
				if bs[ids[base + y]] == 1:
					l = y
					break
			low[x + z * sx] = l


func column_low(x: int, z: int) -> int:
	if x < 0 or z < 0 or x >= sx or z >= sz:
		return sy
	return low[x + z * sx]


func column_height(x: int, z: int) -> int:
	if x < 0 or z < 0 or x >= sx or z >= sz:
		return -1
	return height[x + z * sx]


func open_to_sky(c: Vector3i) -> bool:
	## Nothing above this cell stops the rain.
	return c.y > column_height(c.x, c.z)


func surface_y(x: int, z: int) -> int:
	## The highest solid block in a column, or -1.
	if x < 0 or z < 0 or x >= sx or z >= sz:
		for y in range(sy - 1, -1, -1):
			if Blocks.solid[outside[y]] == 1:
				return y
		return -1
	var base := x * col + z * row
	for y in range(sy - 1, -1, -1):
		if Blocks.solid[ids[base + y]] == 1:
			return y
	return -1


func rest_height(p: Vector3) -> float:
	## Where something dropped at p comes to rest: the top of the first solid
	## surface at or below p, or -INF over the abyss.
	var c := cell_of(p)
	var y := mini(c.y, sy - 1)
	while y >= 0:
		var id := get_id(c.x, y, c.z)
		if Blocks.solid[id] == 1:
			var top := 1.0
			for b in Blocks.collide.get(id, []):
				top = (b as AABB).end.y
			return y + top
		y -= 1
	return -INF


# ---------------------------------------------------------------------------
# Collision
# ---------------------------------------------------------------------------

func solid_boxes(region: AABB) -> Array[AABB]:
	## World-space collision boxes of every solid block touching region.
	var out: Array[AABB] = []
	var a := cell_of(region.position)
	var b := cell_of(region.end)
	for y in range(maxi(a.y, 0), mini(b.y, sy - 1) + 1):
		for z in range(a.z, b.z + 1):
			for x in range(a.x, b.x + 1):
				var id := get_id(x, y, z)
				if Blocks.solid[id] == 0:
					continue
				for box in Blocks.collide.get(id, []):
					out.append(AABB((box as AABB).position + Vector3(x, y, z), (box as AABB).size))
	return out


func box_free(box: AABB) -> bool:
	for b in solid_boxes(box.grow(-0.001)):
		if b.intersects(box.grow(-0.001)):
			return false
	return true


func liquid_at(p: Vector3) -> bool:
	var c := cell_of(p)
	var id := get_idv(c)
	if Blocks.waterlog[id] == 1:
		return true
	if Blocks.shape[id] != Blocks.Shape.LIQUID:
		return false
	return p.y - c.y < ChunkMesher.liquid_h(get_m(c.x, c.y, c.z), get_id(c.x, c.y + 1, c.z) == id)


# ---------------------------------------------------------------------------
# Raycast
# ---------------------------------------------------------------------------

func raycast(origin: Vector3, dir: Vector3, max_dist: float, extra: Callable = Callable(), liquids := false) -> Dictionary:
	## Voxel DDA.  Returns {} or {"cell", "normal", "point", "dist", "id", "be"}.
	## `extra(cell) -> AABB` (block-local, or an empty AABB) adds selectable
	## volumes for cells that hold block entities.
	dir = dir.normalized()
	var c := cell_of(origin)
	var step := Vector3i(signi(int(signf(dir.x))), signi(int(signf(dir.y))), signi(int(signf(dir.z))))
	var t_max := Vector3.ZERO
	var t_delta := Vector3.ZERO
	for i in 3:
		if absf(dir[i]) < 1e-9:
			t_max[i] = INF
			t_delta[i] = INF
		else:
			var nb := float(c[i] + (1 if step[i] > 0 else 0))
			t_max[i] = (nb - origin[i]) / dir[i]
			t_delta[i] = absf(1.0 / dir[i])
	var t := 0.0
	var last_n := Vector3i.ZERO
	var guard := 0
	while t <= max_dist and guard < 512:
		guard += 1
		var hit := _test_cell(c, origin, dir, max_dist, extra, liquids)
		if not hit.is_empty():
			if hit.get("normal") == null:
				hit["normal"] = last_n
			return hit
		if t_max.x < t_max.y and t_max.x < t_max.z:
			c.x += step.x
			t = t_max.x
			t_max.x += t_delta.x
			last_n = Vector3i(-step.x, 0, 0)
		elif t_max.y < t_max.z:
			c.y += step.y
			t = t_max.y
			t_max.y += t_delta.y
			last_n = Vector3i(0, -step.y, 0)
		else:
			c.z += step.z
			t = t_max.z
			t_max.z += t_delta.z
			last_n = Vector3i(0, 0, -step.z)
		if c.y < -2 or c.y > sy + 2:
			break
	return {}


func _test_cell(c: Vector3i, origin: Vector3, dir: Vector3, max_dist: float, extra: Callable, liquids: bool) -> Dictionary:
	var box := AABB()
	var is_be := false
	if extra.is_valid():
		var eb = extra.call(c)
		if eb is AABB and (eb as AABB).has_volume():
			box = eb
			is_be = true
	var id := get_idv(c)
	if not is_be:
		if id == 0:
			return {}
		if Blocks.shape[id] == Blocks.Shape.LIQUID and not liquids:
			return {}
		box = Blocks.select_box(id, get_m(c.x, c.y, c.z))
		if Blocks.shape[id] == Blocks.Shape.LIQUID:
			box = AABB(Vector3.ZERO, Vector3(1, ChunkMesher.liquid_h(get_m(c.x, c.y, c.z), get_id(c.x, c.y + 1, c.z) == id), 1))
		if not box.has_volume():
			return {}
	var world_box := AABB(box.position + Vector3(c), box.size)
	var r := _ray_box(origin, dir, world_box)
	if r.is_empty() or float(r["t"]) > max_dist:
		return {}
	return {"cell": c, "normal": r["n"], "point": origin + dir * float(r["t"]), "dist": r["t"], "id": id, "be": is_be}


static func _ray_box(o: Vector3, d: Vector3, b: AABB) -> Dictionary:
	var tmin := -INF
	var tmax := INF
	var n := Vector3i.ZERO
	for i in 3:
		if absf(d[i]) < 1e-9:
			if o[i] < b.position[i] or o[i] > b.end[i]:
				return {}
			continue
		var t1 := (b.position[i] - o[i]) / d[i]
		var t2 := (b.end[i] - o[i]) / d[i]
		var sgn := -1
		if t1 > t2:
			var tmp := t1
			t1 = t2
			t2 = tmp
			sgn = 1
		if t1 > tmin:
			tmin = t1
			n = Vector3i.ZERO
			n[i] = sgn
		tmax = minf(tmax, t2)
		if tmin > tmax:
			return {}
	if tmax < 0.0:
		return {}
	return {"t": maxf(tmin, 0.0), "n": n}


# ---------------------------------------------------------------------------
# Persistence / replication
# ---------------------------------------------------------------------------

func to_dict() -> Dictionary:
	return {
		"sx": sx, "sy": sy, "sz": sz, "outside": outside,
		"ids": ids.compress(FileAccess.COMPRESSION_ZSTD), "meta": meta.compress(FileAccess.COMPRESSION_ZSTD),
		"n": ids.size(),
		"hl": (height.to_byte_array() + low.to_byte_array()).compress(FileAccess.COMPRESSION_ZSTD),
	}


static func from_saved(d: Dictionary) -> VoxelData:
	## A grid of the saved size, filled from the save (null if it doesn't fit).
	var v := VoxelData.new(int(d.get("sx", 0)), int(d.get("sy", 0)), int(d.get("sz", 0)), false)
	if v.sx <= 0 or v.sy <= 0 or v.sz <= 0 or not v.from_dict(d):
		return null
	return v


func from_dict(d: Dictionary) -> bool:
	if int(d.get("sx", 0)) != sx or int(d.get("sy", 0)) != sy or int(d.get("sz", 0)) != sz:
		return false
	if d.has("outside"):
		set_outside(d["outside"])
	var n := int(d["n"])
	ids = (d["ids"] as PackedByteArray).decompress(n, FileAccess.COMPRESSION_ZSTD)
	meta = (d["meta"] as PackedByteArray).decompress(n, FileAccess.COMPRESSION_ZSTD)
	if ids.size() != n or meta.size() != n:
		return false
	var cols := sx * sz
	if d.has("hl"):
		var hl := (d["hl"] as PackedByteArray).decompress(cols * 8, FileAccess.COMPRESSION_ZSTD)
		if hl.size() == cols * 8:
			height = hl.slice(0, cols * 4).to_int32_array()
			low = hl.slice(cols * 4).to_int32_array()
			return true
	rebuild_heights()
	return true
