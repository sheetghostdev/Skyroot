class_name IslandGen
extends RefCounted
## Builds the island.  The layout is hand-placed (the hill and its little cave in
## the north-east, the pond with its clay banks in the south-west, the groves,
## the islet across the gap) and the same on every new world; noise only roughens
## the outline, the ground and the underside.

const W := 64                     # the sky island's grid
const H := 80
const D := 64
const CENTER := Vector2(32, 32)
const RADIUS := 17.5
const TOP := 44                   # y of the grass at the island's middle
const HILL := Vector2(40.5, 24.5)
const POND := Vector2(24.0, 39.5)
const ISLET := Vector2(53.0, 13.0)
const SPAWN := Vector3(30.5, TOP + 1.05, 34.5)

const OAKS := [Vector2i(27, 25), Vector2i(22, 30), Vector2i(35, 37), Vector2i(41, 33), Vector2i(29, 45), Vector2i(19, 23),
	Vector2i(44, 40), Vector2i(36, 18), Vector2i(23, 47)]
const BIRCHES := [Vector2i(31, 21), Vector2i(17, 34), Vector2i(38, 44), Vector2i(46, 29), Vector2i(53, 12)]
const BUSHES := [Vector2i(25, 34), Vector2i(33, 41), Vector2i(43, 36), Vector2i(20, 28), Vector2i(51, 15)]

var vd: VoxelData
var noise := FastNoiseLite.new()
var rng := RandomNumberGenerator.new()
var top_y := PackedInt32Array()       # per column: y of the top block of the main mass, -1 = outside
var B := {}


func _init(data: VoxelData) -> void:
	vd = data
	noise.seed = 1337
	noise.frequency = 0.08
	rng.seed = 424242
	for n in Blocks.by_name:
		B[n] = Blocks.id_of(n)
	top_y.resize(W * D)
	top_y.fill(-1)


static func new_grid() -> VoxelData:
	return VoxelData.new(W, H, D)


static func generate(data: VoxelData) -> void:
	var g := IslandGen.new(data)
	g._mass(CENTER, RADIUS, TOP, 1.0)
	g._mass(ISLET, 4.3, TOP - 3, 0.35)
	g._hill()
	g._pond()
	g._cave()
	g._gravel()
	g._trees()
	g._decorate()
	g._underside()
	data.rebuild_heights()


func _n(x: float, y: float) -> float:
	return noise.get_noise_2d(x, y)


func _put(x: int, y: int, z: int, n: String, m: int = 0) -> void:
	vd.set_block(x, y, z, int(B[n]), m)


func _at(x: int, y: int, z: int) -> String:
	return Blocks.name_of(vd.get_id(x, y, z))


func _mass(c: Vector2, radius: float, top: int, depth_k: float) -> void:
	## A floating mass: an irregular disc of turf over soil over rock, tapering
	## to a jagged point underneath.
	for z in D:
		for x in W:
			var d := Vector2(x + 0.5, z + 0.5) - c
			var ang := atan2(d.y, d.x)
			var r := radius + _n(cos(ang) * 9.0 + c.x, sin(ang) * 9.0) * 2.6 + _n(cos(ang) * 23.0, sin(ang) * 23.0 + c.y) * 1.2
			var dist := d.length()
			if dist > r:
				continue
			var e := dist / r
			var h := float(top) + _n(x * 0.7, z * 0.7) * 1.1
			if e > 0.86:
				h -= 1.0
			var ty := int(round(h))
			var depth := 3.0 + (radius * 1.45 * depth_k + 4.0) * pow(maxf(0.0, 1.0 - e * e), 0.75)
			depth += absf(_n(x * 1.9 + 100.0, z * 1.9)) * 5.0 * (1.0 - e) + _n(x * 0.5 - 40.0, z * 0.5) * 2.0
			var by := int(ty - depth)
			for y in range(maxi(by, 1), ty + 1):
				var below_top := ty - y
				var nm := "stone"
				if below_top == 0:
					nm = "grass"
				elif below_top <= 2 + int(absf(_n(x * 1.3, z * 1.3)) * 2.0):
					nm = "dirt"
				_put(x, y, z, nm)
			top_y[x + z * W] = ty


func _hill() -> void:
	## A rocky knoll: turf on its gentle slopes, bare granite where it is steep.
	for z in D:
		for x in W:
			var ty := top_y[x + z * W]
			if ty < 0:
				continue
			var d := Vector2(x + 0.5, z + 0.5).distance_to(HILL)
			var k := exp(-d * d / (2.0 * 4.2 * 4.2))
			var add := int(round(k * 6.5 + _n(x * 1.4, z * 1.4 + 50.0) * k * 1.5))
			if add <= 0:
				continue
			var steep := k > 0.32 and k < 0.85
			for y in range(ty + 1, ty + add + 1):
				_put(x, y, z, "stone")
			var nt := ty + add
			if not steep or _n(x * 2.0, z * 2.0) > 0.25:
				_put(x, nt, z, "grass")
				_put(x, nt - 1, z, "dirt")
			elif _n(x * 1.7 + 9.0, z * 1.7) > 0.0:
				_put(x, nt, z, "stone_mossy")
			top_y[x + z * W] = nt


func _pond() -> void:
	## A small pond with clay in its banks and floor, sand and reeds at the edge.
	for z in range(int(POND.y) - 7, int(POND.y) + 8):
		for x in range(int(POND.x) - 7, int(POND.x) + 8):
			var dv := (Vector2(x + 0.5, z + 0.5) - POND) / Vector2(4.2, 3.3)
			var e := dv.length() + _n(x * 1.1, z * 1.1) * 0.18
			var ty := top_y[x + z * W]
			if ty < 0:
				continue
			if e < 1.0:
				var depth := 2 if e < 0.6 else 1
				var surface := TOP - 1
				for y in range(surface - depth + 1, ty + 1):
					_put(x, y, z, "air")
				for y in range(surface - depth + 1, surface + 1):
					_put(x, y, z, "water")
				# clay floor
				for y in range(surface - depth - 2, surface - depth + 1):
					_put(x, y, z, "clay" if _n(x * 2.0, y * 2.0 + z) > -0.45 else "dirt")
				top_y[x + z * W] = surface
			elif e < 1.55:
				# banks: clay under the turf, sand right at the water
				for y in range(ty - 3, ty):
					if _at(x, y, z) != "air":
						_put(x, y, z, "clay" if _n(x * 1.6 + 7.0, y * 1.6 + z) > -0.3 else "dirt")
				if e < 1.18:
					_put(x, ty, z, "sand" if _n(x * 2.3, z * 2.3) > -0.2 else "clay")
				elif e < 1.32 and _n(x * 3.0, z * 3.0) > 0.25:
					_put(x, ty, z, "clay")
	# a little exposed clay on the near bank so it can be found
	for p in [Vector2i(27, 41), Vector2i(28, 40), Vector2i(27, 40)]:
		var ty := top_y[p.x + p.y * W]
		if ty > 0:
			_put(p.x, ty, p.y, "clay")


func _cave() -> void:
	## A shallow cave in the knoll: shelter for a first night.
	var c := Vector3(40.5, TOP + 2.0, 24.5)
	for z in range(18, 32):
		for x in range(33, 48):
			for y in range(TOP, TOP + 5):
				var d := (Vector3(x + 0.5, y + 0.5, z + 0.5) - c) / Vector3(2.6, 1.6, 2.4)
				var tunnel := (Vector2(x + 0.5, z + 0.5) - Vector2(37.0, 28.0)).length() < 1.6 and y <= TOP + 2 and x < 40 and z > 25
				if d.length() < 1.0 + _n(x * 2.0, z * 2.0 + y) * 0.15 or tunnel:
					if y >= TOP + 1:
						_put(x, y, z, "air")
	# a floor of soil inside
	for z in range(21, 30):
		for x in range(36, 45):
			if _at(x, TOP + 1, z) == "air" and _at(x, TOP, z) == "stone":
				_put(x, TOP, z, "dirt")


func _gravel() -> void:
	for p in [Vector2i(35, 23), Vector2i(36, 23), Vector2i(35, 22), Vector2i(34, 24), Vector2i(36, 22), Vector2i(46, 22), Vector2i(47, 23)]:
		var ty := _top_solid(p.x, p.y)
		if ty > 0 and _at(p.x, ty, p.y) in ["grass", "dirt", "stone"]:
			_put(p.x, ty, p.y, "gravel")


func _top_solid(x: int, z: int) -> int:
	return vd.surface_y(x, z)


func _trees() -> void:
	for p in OAKS:
		grow_tree(vd, p.x, _top_solid(p.x, p.y) + 1, p.y, "oak", rng.randi())
	for p in BIRCHES:
		grow_tree(vd, p.x, _top_solid(p.x, p.y) + 1, p.y, "birch", rng.randi())


static func grow_tree(data: VoxelData, x: int, y: int, z: int, kind: String, seed_v: int, setter: Callable = Callable()) -> bool:
	## Places a tree with its trunk base at (x, y, z).  Used by the generator and
	## when a sapling grows up (then `setter(cell, id, meta)` puts the blocks in
	## through World so they replicate).  Returns false if there is no room.
	var put := func(px: int, py: int, pz: int, id: int, m: int) -> void:
		if setter.is_valid():
			setter.call(Vector3i(px, py, pz), id, m)
		else:
			data.set_block(px, py, pz, id, m)
	var r := RandomNumberGenerator.new()
	r.seed = seed_v
	if kind == "palm":
		return _grow_palm(data, x, y, z, r, put)
	var log_id := Blocks.id_of("log_oak" if kind == "oak" else "log_birch")
	var leaf_id := Blocks.id_of("leaves_oak" if kind == "oak" else "leaves_birch")
	var h := r.randi_range(4, 6) if kind == "oak" else r.randi_range(5, 7)
	for i in h + 1:
		var id := data.get_id(x, y + i, z)
		if id != 0 and not Blocks.is_replaceable(id) and Blocks.shape[id] != Blocks.Shape.CROSS:
			return false
	if y + h + 3 >= data.sy:
		return false
	var top := y + h
	var rad := 2.4 if kind == "oak" else 1.8
	for dy in range(-2 if kind == "oak" else -3, 3):
		var ry := rad - (0.6 if dy >= 1 else 0.0) - (0.8 if dy == 2 else 0.0)
		for dz in range(-3, 4):
			for dx in range(-3, 4):
				var d := sqrt(dx * dx + dz * dz)
				if d > ry + r.randf_range(-0.35, 0.35):
					continue
				if dy == 2 and d > 1.1:
					continue
				var px := x + dx
				var py := top + dy
				var pz := z + dz
				if data.in_bounds(px, py, pz) and data.get_id(px, py, pz) == 0:
					put.call(px, py, pz, leaf_id, 0)
	for i in h:
		put.call(x, y + i, z, log_id, BlockActs.NATURAL)
	# the soil under a trunk
	if Blocks.name_of(data.get_id(x, y - 1, z)) == "grass":
		put.call(x, y - 1, z, Blocks.id_of("dirt"), 0)
	return true


static func _grow_palm(data: VoxelData, x: int, y: int, z: int, r: RandomNumberGenerator, put: Callable) -> bool:
	## A palm: a tall trunk that leans as it rises, a crown of drooping fronds,
	## and coconuts hanging under it.
	var log_id := Blocks.id_of("palm_log")
	var leaf_id := Blocks.id_of("palm_leaves")
	var nut_id := Blocks.id_of("coconut")
	var h := r.randi_range(5, 8)
	var lean: Vector2i = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)][r.randi_range(0, 3)]
	var bend := r.randi_range(h / 2, h - 1)
	var cells: Array[Vector3i] = []
	var px := x
	var pz := z
	for i in h:
		if i == bend:
			px += lean.x
			pz += lean.y
		cells.append(Vector3i(px, y + i, pz))
	if y + h + 3 >= data.sy:
		return false
	for c in cells:
		var id := data.get_id(c.x, c.y, c.z)
		if id != 0 and not Blocks.is_replaceable(id) and Blocks.shape[id] != Blocks.Shape.CROSS:
			return false
	for c in cells:
		put.call(c.x, c.y, c.z, log_id, BlockActs.NATURAL)
	var top: Vector3i = cells[cells.size() - 1]
	var leaf := func(c: Vector3i) -> void:
		if data.in_bounds(c.x, c.y, c.z) and data.get_id(c.x, c.y, c.z) == 0:
			put.call(c.x, c.y, c.z, leaf_id, 0)
	leaf.call(top + Vector3i.UP)
	for d in [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]:
		# each frond runs out and droops at the end
		leaf.call(top + Vector3i.UP + d)
		leaf.call(top + Vector3i.UP + d * 2)
		leaf.call(top + d * 3)
	for d in [Vector3i(1, 0, 1), Vector3i(-1, 0, 1), Vector3i(1, 0, -1), Vector3i(-1, 0, -1)]:
		leaf.call(top + Vector3i.UP + d)
		if r.randf() < 0.6:
			leaf.call(top + d * 2)
	# coconuts under the crown, against the trunk
	for d in [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]:
		var c: Vector3i = top + d
		if r.randf() < 0.55 and data.get_id(c.x, c.y, c.z) == 0 and data.get_id(c.x, c.y + 1, c.z) == leaf_id:
			put.call(c.x, c.y, c.z, nut_id, 0)
	if Blocks.name_of(data.get_id(x, y - 1, z)) == "grass":
		put.call(x, y - 1, z, Blocks.id_of("dirt"), 0)
	return true


func _decorate() -> void:
	for p in BUSHES:
		var ty := _top_solid(p.x, p.y)
		if ty > 0 and _at(p.x, ty + 1, p.y) == "air":
			_put(p.x, ty + 1, p.y, "berry_bush", 1)
	var loose := {"loose_stones": 30, "loose_flint": 6, "loose_sticks": 16, "mushroom": 7, "wild_turnip": 5, "wild_flax": 6}
	# flint lies near the knoll and the gravel; stones everywhere; sticks and
	# mushrooms under the trees
	for kind in loose:
		var placed := 0
		var tries := 0
		while placed < int(loose[kind]) and tries < 4000:
			tries += 1
			var x := rng.randi_range(8, 56)
			var z := rng.randi_range(6, 56)
			var ty := _top_solid(x, z)
			if ty < 0 or _at(x, ty + 1, z) != "air":
				continue
			var ground := _at(x, ty, z)
			if not ground in ["grass", "dirt", "gravel", "stone", "stone_mossy", "sand"]:
				continue
			var near_tree := _near(x, ty + 3, z, 3, ["leaves_oak", "leaves_birch"])
			var near_hill := Vector2(x, z).distance_to(HILL) < 9.0
			match kind:
				"loose_flint":
					if not near_hill and ground != "gravel" and Vector2(x, z).distance_to(ISLET) > 5.0:
						continue
				"loose_sticks", "mushroom":
					if not near_tree:
						continue
				"wild_turnip", "wild_flax":
					if ground != "grass" or near_tree:
						continue
			_put(x, ty + 1, z, kind)
			placed += 1
	# reeds at the pond's edge
	for z in range(int(POND.y) - 7, int(POND.y) + 8):
		for x in range(int(POND.x) - 7, int(POND.x) + 8):
			var ty := _top_solid(x, z)
			if ty < 0 or _at(x, ty + 1, z) != "air" or not _at(x, ty, z) in ["sand", "grass", "dirt", "clay"]:
				continue
			if _near(x, ty, z, 1, ["water"]) and rng.randf() < 0.5:
				_put(x, ty + 1, z, "reeds")
	# grass and flowers
	for z in D:
		for x in W:
			var ty := _top_solid(x, z)
			if ty < 0 or _at(x, ty, z) != "grass" or _at(x, ty + 1, z) != "air":
				continue
			var shade := _near(x, ty + 3, z, 2, ["leaves_oak", "leaves_birch"])
			var v := rng.randf()
			var meadow := _n(x * 0.9 + 300.0, z * 0.9) * 0.5 + 0.5
			if shade and v < 0.18:
				_put(x, ty + 1, z, "fern")
			elif v < 0.12 + meadow * 0.38:
				_put(x, ty + 1, z, "tallgrass")
			elif v < 0.52 + meadow * 0.05:
				var f := rng.randf()
				_put(x, ty + 1, z, "flower_red" if f < 0.3 else ("flower_yellow" if f < 0.7 else "flower_blue"))


func _near(x: int, y: int, z: int, r: int, kinds: Array) -> bool:
	for dz in range(-r, r + 1):
		for dx in range(-r, r + 1):
			for dy in range(-r, r + 1):
				if _at(x + dx, y + dy, z + dz) in kinds:
					return true
	return false


func _underside() -> void:
	## Roots and vines hang from the island's belly; soil patches on the rock.
	for z in D:
		for x in W:
			# lowest block of the column
			var low := -1
			for y in range(1, H):
				if vd.get_id(x, y, z) != 0:
					low = y
					break
			if low <= 1:
				continue
			var top := _top_solid(x, z)
			var edge := top - low < 6
			var v := rng.randf()
			if edge and v < 0.07:
				_put(x, low - 1, z, "vines" if rng.randf() < 0.6 else "roots")
			elif v < 0.012:
				_put(x, low - 1, z, "roots")
			if _at(x, low, z) == "stone" and _n(x * 1.2 + 70.0, z * 1.2) > 0.35:
				_put(x, low, z, "dirt")
