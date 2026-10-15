class_name ArchipelagoGen
extends RefCounted
## Builds an archipelago: a stretch of sea with a dozen and a half islands, none
## of them big, each a different kind with different things to find - so you
## have to build a raft and go from one to the next.
##
##   home    the small island you wake on: palms, a few stones and sticks
##   atoll   a sandbar ring with palms and coconuts
##   grove   woods (oak, birch), berries, mushrooms, a fresh pond with clay banks
##   rocky   a granite knoll: loose stones, flint, gravel
##   marsh   low and wet: clay under the turf, ponds, cattails, flax
##   meadow  grass hills: wild turnips and flax, berries, a few trees
##
## Everything is seeded: the same seed gives the same sea.  The ocean floor
## shelves down from each island into deep water between them.

const W := 512
const H := 64
const D := 512
const SEA := 30                  # the top layer of sea water (its surface is at SEA + 0.875)
const DEEP := 12                 # the deep floor between islands, roughly
const SHELF := 1.3               # how far (in island radii) the shallows reach past the shore

const BIOMES := {
	"home": {"r": [9.0, 11.0], "h": [3.0, 5.0]},
	"atoll": {"r": [6.0, 10.0], "h": [1.0, 2.0]},
	"grove": {"r": [13.0, 21.0], "h": [5.0, 9.0]},
	"rocky": {"r": [9.0, 15.0], "h": [10.0, 17.0]},
	"marsh": {"r": [11.0, 18.0], "h": [1.0, 3.0]},
	"meadow": {"r": [12.0, 20.0], "h": [3.0, 7.0]},
}
# the first two are placed near home (wood and water, then stone)
const ORDER := ["grove", "rocky", "atoll", "marsh", "meadow", "grove", "rocky", "atoll", "marsh",
	"meadow", "atoll", "grove", "meadow", "rocky", "marsh", "atoll"]

# surface materials
enum Top { SAND, GRASS, STONE, GRAVEL, CLAY, DIRT }

var vd: VoxelData
var rng := RandomNumberGenerator.new()
var n_floor := FastNoiseLite.new()
var n_shape := FastNoiseLite.new()
var n_detail := FastNoiseLite.new()
var n_patch := FastNoiseLite.new()
var islands: Array = []          # [{"c": Vector2, "r": float, "b": String, "h": float}]
var floor_y := PackedInt32Array()
var top := PackedByteArray()
var owner := PackedInt32Array()  # island index per column (land and shallows), -1 for open sea
var dist := PackedFloat32Array() # distance from the owning island's middle, in its radii
var B := {}


static func new_grid() -> VoxelData:
	return VoxelData.new(W, H, D)


static func generate(data: VoxelData, seed_v: int) -> Dictionary:
	var g := ArchipelagoGen.new()
	g.vd = data
	g._setup(seed_v)
	g._place_islands()
	g._shape()
	g._fill()
	for i in g.islands.size():
		g._decorate(i)
	g._sea_floor_life()
	return g._geo()


func _setup(seed_v: int) -> void:
	rng.seed = seed_v
	for n in [n_floor, n_shape, n_detail, n_patch]:
		(n as FastNoiseLite).seed = rng.randi()
	n_floor.frequency = 0.012
	n_shape.frequency = 0.07
	n_detail.frequency = 0.11
	n_patch.frequency = 0.09
	for nm in Blocks.by_name:
		B[nm] = Blocks.id_of(nm)
	floor_y.resize(W * D)
	top.resize(W * D)
	owner.resize(W * D)
	owner.fill(-1)
	dist.resize(W * D)
	dist.fill(99.0)


func _rand_in(r: Array) -> float:
	return rng.randf_range(float(r[0]), float(r[1]))


# ---------------------------------------------------------------------------
# Where the islands go
# ---------------------------------------------------------------------------

func _place_islands() -> void:
	var home := {"c": Vector2(W * 0.5, D * 0.5) + Vector2(rng.randf_range(-20, 20), rng.randf_range(-20, 20)),
		"r": _rand_in(BIOMES["home"]["r"]), "b": "home"}
	home["h"] = _rand_in(BIOMES["home"]["h"])
	islands.append(home)
	for k in ORDER.size():
		var b: String = ORDER[k]
		var r := _rand_in(BIOMES[b]["r"])
		for attempt in 600:
			var c: Vector2
			if k == 0:
				# something to row to on the first day: a wooded island close by
				c = home["c"] + Vector2.from_angle(rng.randf() * TAU) * rng.randf_range(44.0, 58.0)
			elif k == 1:
				c = home["c"] + Vector2.from_angle(rng.randf() * TAU) * rng.randf_range(60.0, 100.0)
			else:
				c = Vector2(rng.randf_range(r + 30.0, W - r - 30.0), rng.randf_range(r + 30.0, D - r - 30.0))
			if c.x < r + 30.0 or c.y < r + 30.0 or c.x > W - r - 30.0 or c.y > D - r - 30.0:
				continue
			var ok := true
			for o in islands:
				if c.distance_to(o["c"]) < r + float(o["r"]) + 24.0:
					ok = false
					break
			if ok:
				islands.append({"c": c, "r": r, "b": b, "h": _rand_in(BIOMES[b]["h"])})
				break
			if attempt % 100 == 99:
				r *= 0.85


# ---------------------------------------------------------------------------
# Heights
# ---------------------------------------------------------------------------

func _shape() -> void:
	# the deep floor everywhere first
	for z in D:
		for x in W:
			floor_y[x + z * W] = DEEP + int(round(n_floor.get_noise_2d(x, z) * 3.0))
			top[x + z * W] = Top.SAND if n_patch.get_noise_2d(x * 0.5, z * 0.5) > -0.25 else Top.GRAVEL
	# then each island and its shallows
	for i in islands.size():
		var isl: Dictionary = islands[i]
		var c: Vector2 = isl["c"]
		var r: float = isl["r"]
		var b: String = isl["b"]
		var hmax: float = isl["h"]
		var reach := r * (1.0 + SHELF) + 6.0
		for z in range(maxi(0, int(c.y - reach)), mini(D, int(c.y + reach) + 1)):
			for x in range(maxi(0, int(c.x - reach)), mini(W, int(c.x + reach) + 1)):
				var k := x + z * W
				var d0 := Vector2(x + 0.5, z + 0.5).distance_to(c) / r
				# a ragged coastline: the radius wanders by a fifth either way
				var d := d0 * (1.0 - n_shape.get_noise_2d(x, z) * 0.2)
				var y: int
				var t: int
				if d < 1.0:
					var prof := pow(1.0 - d * d, 0.75)
					var rough := n_detail.get_noise_2d(x, z) * (2.5 if b == "rocky" else 1.2)
					y = SEA + 1 + int(round(prof * hmax + rough * prof))
					t = _land_top(b, d, x, z)
					if d > 0.8 and b != "rocky":
						# a beach all round
						y = mini(y, SEA + 1 + (1 if d < 0.9 else 0))
						t = Top.SAND
				else:
					var s := clampf((d - 1.0) / SHELF, 0.0, 1.0)
					var deep := float(floor_y[k])
					y = int(round(lerpf(float(SEA - 1), deep, smoothstep(0.0, 1.0, s)) + n_detail.get_noise_2d(x, z) * 1.2))
					t = Top.SAND
					if b == "rocky" and s < 0.4:
						t = Top.GRAVEL if n_patch.get_noise_2d(x, z) > 0.0 else Top.STONE
					elif b == "marsh" and s < 0.5 and n_patch.get_noise_2d(x, z) > 0.1:
						t = Top.CLAY
				if d < 1.0:
					# land
					floor_y[k] = y
					top[k] = t
					owner[k] = i
					dist[k] = d
				elif dist[k] >= 1.0:
					# shallows: the higher shelf wins where two meet
					if y > floor_y[k]:
						floor_y[k] = y
						top[k] = t
					if d < dist[k] and d < 1.0 + SHELF:
						owner[k] = i
						dist[k] = d


func _land_top(b: String, d: float, x: int, z: int) -> int:
	var p := n_patch.get_noise_2d(x, z)
	match b:
		"atoll":
			return Top.SAND if p < 0.35 else Top.GRASS
		"rocky":
			if d < 0.55 or p > 0.2:
				return Top.STONE
			return Top.GRAVEL if p < -0.35 else Top.GRASS
		"marsh":
			return Top.CLAY if p > 0.45 else Top.GRASS
	return Top.GRASS


# ---------------------------------------------------------------------------
# Blocks: every column built from a cached template, then the details
# ---------------------------------------------------------------------------

func _column(fy: int, t: int) -> PackedByteArray:
	var col := PackedByteArray()
	col.resize(H)
	var top_id: int
	var sub_id: int
	var under_sea := fy <= SEA
	match t:
		Top.SAND:
			top_id = B["sand"]
			sub_id = B["sand"]
		Top.GRASS:
			top_id = B["dirt"] if under_sea else B["grass"]
			sub_id = B["dirt"]
		Top.STONE:
			top_id = B["stone"]
			sub_id = B["stone"]
		Top.GRAVEL:
			top_id = B["gravel"]
			sub_id = B["stone"]
		Top.CLAY:
			top_id = B["clay"]
			sub_id = B["clay"]
		_:
			top_id = B["dirt"]
			sub_id = B["dirt"]
	for y in H:
		var id := 0
		if y < fy - 3:
			id = B["stone"]
		elif y < fy:
			id = sub_id
		elif y == fy:
			id = top_id
		elif y <= SEA:
			id = Blocks.sea
		col[y] = id
	return col


func _fill() -> void:
	var cache := {}
	var ids := PackedByteArray()
	for z in D:
		for x in W:
			var k := x + z * W
			var fy := clampi(floor_y[k], 2, H - 8)
			var key := fy * 8 + top[k]
			if not cache.has(key):
				cache[key] = _column(fy, top[k])
			ids.append_array(cache[key])
			vd.height[k] = fy
			vd.low[k] = 0
	vd.ids = ids
	vd.meta = PackedByteArray()
	vd.meta.resize(ids.size())
	# what lies past the edge: deep floor and open sea
	vd.set_outside(_column(DEEP, Top.SAND))


func _put(x: int, y: int, z: int, nm: String, m: int = 0) -> void:
	vd.set_block(x, y, z, int(B[nm]), m)


func _ground(x: int, z: int) -> int:
	return floor_y[x + z * W]


func _free(x: int, y: int, z: int) -> bool:
	return vd.get_id(x, y, z) == 0


func _land_spots(i: int, dmin: float, dmax: float) -> Array:
	## Dry land columns of island i whose distance (in radii) is in [dmin, dmax).
	var out: Array = []
	var isl: Dictionary = islands[i]
	var c: Vector2 = isl["c"]
	var r: float = isl["r"]
	for z in range(maxi(0, int(c.y - r * 1.3)), mini(D, int(c.y + r * 1.3) + 1)):
		for x in range(maxi(0, int(c.x - r * 1.3)), mini(W, int(c.x + r * 1.3) + 1)):
			var k := x + z * W
			if owner[k] == i and floor_y[k] > SEA and dist[k] >= dmin and dist[k] < dmax:
				out.append(Vector2i(x, z))
	return out


func _scatter(spots: Array, n: int, nm: String, on: Array = [], m: int = 0) -> int:
	## Put n of a plant/loose thing on top of random spots (on: allowed ground).
	var placed := 0
	var tries := 0
	while placed < n and tries < n * 12 and not spots.is_empty():
		tries += 1
		var p: Vector2i = spots[rng.randi_range(0, spots.size() - 1)]
		var y := _ground(p.x, p.y)
		if vd.get_id(p.x, y, p.y) == 0 or not _free(p.x, y + 1, p.y):
			continue
		if not on.is_empty() and not (Blocks.name_of(vd.get_id(p.x, y, p.y)) in on):
			continue
		_put(p.x, y + 1, p.y, nm, m)
		placed += 1
	return placed


func _tree(spots: Array, n: int, kind: String) -> void:
	var placed := 0
	var tries := 0
	while placed < n and tries < n * 10 and not spots.is_empty():
		tries += 1
		var p: Vector2i = spots[rng.randi_range(0, spots.size() - 1)]
		var y := _ground(p.x, p.y)
		var g := Blocks.name_of(vd.get_id(p.x, y, p.y))
		if not (g in ["grass", "dirt", "sand"]):
			continue
		if kind != "palm" and g == "sand":
			continue
		# keep trunks apart
		var crowded := false
		for dz in range(-2, 3):
			for dx in range(-2, 3):
				if Blocks.has_flag(vd.get_id(p.x + dx, y + 1, p.y + dz), "tree"):
					crowded = true
		if crowded:
			continue
		if IslandGen.grow_tree(vd, p.x, y + 1, p.y, kind, rng.randi()):
			placed += 1


func _pond(i: int, at: Vector2i, rad: float, banks_clay: bool) -> void:
	## A little fresh pond sunk into the island, with clay in its banks.
	var gy := _ground(at.x, at.y)
	if gy <= SEA + 1:
		return
	var surface := gy - 1
	for z in range(at.y - int(rad) - 3, at.y + int(rad) + 4):
		for x in range(at.x - int(rad) - 3, at.x + int(rad) + 4):
			if x < 0 or z < 0 or x >= W or z >= D:
				continue
			var e := Vector2(x + 0.5, z + 0.5).distance_to(Vector2(at) + Vector2(0.5, 0.5)) / rad + n_detail.get_noise_2d(x * 2.0, z * 2.0) * 0.15
			var k := x + z * W
			if owner[k] != i or floor_y[k] <= SEA + 1:
				continue
			if e < 1.0:
				var depth := 2 if e < 0.55 else 1
				for y in range(surface - depth + 1, floor_y[k] + 1):
					vd.set_block(x, y, z, 0)
				for y in range(surface - depth + 1, surface + 1):
					_put(x, y, z, "water")
				for y in range(surface - depth - 1, surface - depth + 1):
					_put(x, y, z, "clay" if banks_clay else "dirt")
				floor_y[k] = surface
			elif e < 1.5 and banks_clay:
				for y in range(floor_y[k] - 3, floor_y[k]):
					if vd.get_id(x, y, z) != 0:
						_put(x, y, z, "clay")
				if e < 1.2 and rng.randf() < 0.5:
					_put(x, floor_y[k], z, "sand")


func _decorate(i: int) -> void:
	var isl: Dictionary = islands[i]
	var b: String = isl["b"]
	var c := Vector2i(isl["c"])
	var inland := _land_spots(i, 0.0, 0.78)
	var coast := _land_spots(i, 0.7, 1.0)
	var all := _land_spots(i, 0.0, 1.0)
	var r: float = isl["r"]
	var area := r * r
	match b:
		"home":
			_tree(coast, 4, "palm")
			_tree(inland, 1, "oak")
			_scatter(all, 5, "loose_sticks")
			_scatter(all, 4, "loose_stones")
			_scatter(inland, 18, "tallgrass", ["grass"])
			_scatter(inland, 4, "fern", ["grass"])
			_scatter(inland, 1, "berry_bush", ["grass"], 1)
			_scatter(inland, 3, "flower_yellow", ["grass"])
		"atoll":
			_tree(all, int(2 + area / 20.0), "palm")
			_scatter(all, 2, "loose_sticks")
			_scatter(all, 6, "tallgrass", ["grass"])
		"grove":
			_pond(i, c + Vector2i(rng.randi_range(-3, 3), rng.randi_range(-3, 3)), rng.randf_range(2.5, 3.6), true)
			_tree(inland, int(area / 18.0), "oak")
			_tree(inland, int(area / 40.0), "birch")
			_tree(coast, 2, "palm")
			_scatter(inland, int(area / 30.0), "berry_bush", ["grass"], 1)
			_scatter(inland, int(area / 25.0), "mushroom", ["grass", "dirt"])
			_scatter(all, int(area / 18.0), "loose_sticks")
			_scatter(all, 3, "loose_stones")
			_scatter(inland, int(area / 4.0), "tallgrass", ["grass"])
			_scatter(inland, int(area / 10.0), "fern", ["grass"])
			_scatter(inland, int(area / 25.0), "flower_blue", ["grass"])
			_scatter(_land_spots(i, 0.0, 0.5), 6, "reeds", ["grass", "sand", "clay", "dirt"])
		"rocky":
			_scatter(all, int(6 + area / 14.0), "loose_stones")
			_scatter(all, int(3 + area / 45.0), "loose_flint")
			_tree(coast, 1, "birch")
			_scatter(all, int(area / 10.0), "tallgrass", ["grass"])
			_scatter(all, 3, "loose_sticks")
			_scatter(all, 4, "flower_red", ["grass"])
		"marsh":
			for k in rng.randi_range(2, 4):
				var p: Vector2i = inland[rng.randi_range(0, inland.size() - 1)] if not inland.is_empty() else c
				_pond(i, p, rng.randf_range(1.6, 2.6), true)
			# clay a block or two under the turf, all over
			for p in all:
				var y := _ground(p.x, p.y)
				for yy in range(y - 3, y):
					if Blocks.name_of(vd.get_id(p.x, yy, p.y)) == "dirt":
						_put(p.x, yy, p.y, "clay")
			_scatter(all, int(area / 6.0), "reeds", ["grass", "clay", "dirt", "sand"])
			_scatter(inland, int(3 + area / 50.0), "wild_flax", ["grass"])
			_scatter(inland, int(area / 6.0), "tallgrass", ["grass"])
			_tree(inland, 2, "birch")
			_scatter(all, 3, "loose_sticks")
		"meadow":
			_tree(inland, int(1 + area / 70.0), "oak")
			_scatter(inland, int(3 + area / 45.0), "wild_turnip", ["grass"])
			_scatter(inland, int(2 + area / 60.0), "wild_flax", ["grass"])
			_scatter(inland, int(area / 40.0), "berry_bush", ["grass"], 1)
			_scatter(inland, int(area / 3.0), "tallgrass", ["grass"])
			for f in ["flower_red", "flower_yellow", "flower_blue"]:
				_scatter(inland, int(area / 25.0), f, ["grass"])
			_scatter(all, 4, "loose_sticks")
			_scatter(all, 2, "loose_stones")


func _sea_floor_life() -> void:
	## Seaweed in the sunlit shallows round every island.
	for z in range(0, D, 1):
		for x in range(0, W, 1):
			var k := x + z * W
			if owner[k] < 0:
				continue
			var fy := floor_y[k]
			var depth := SEA - fy
			if depth < 2 or depth > 9:
				continue
			if Blocks.name_of(vd.get_id(x, fy, z)) != "sand":
				continue
			if n_patch.get_noise_2d(x * 1.7, z * 1.7) > 0.25 and rng.randf() < 0.35:
				_put(x, fy + 1, z, "seaweed")
				if depth > 4 and rng.randf() < 0.4:
					_put(x, fy + 2, z, "seaweed")


func _geo() -> Dictionary:
	var home: Dictionary = islands[0]
	var hc: Vector2 = home["c"]
	var sx := int(hc.x)
	var sz := int(hc.y)
	# wake on open ground near the middle of the home island
	var best := Vector2i(sx, sz)
	for rr in range(0, 6):
		var found := false
		for dz in range(-rr, rr + 1):
			for dx in range(-rr, rr + 1):
				var x := sx + dx
				var z := sz + dz
				var y := vd.surface_y(x, z)
				if y > SEA and _free(x, y + 1, z) and _free(x, y + 2, z) and Blocks.is_solid(vd.get_id(x, y, z)):
					best = Vector2i(x, z)
					found = true
					break
			if found:
				break
		if found:
			break
	var spawn := Vector3(best.x + 0.5, vd.surface_y(best.x, best.y) + 1.05, best.y + 0.5)
	var list: Array = []
	for isl in islands:
		list.append({"c": isl["c"], "r": isl["r"], "b": isl["b"]})
	return {"sea": SEA, "islands": list, "spawn": spawn, "size": Vector2i(W, D)}
