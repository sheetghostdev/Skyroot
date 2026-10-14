class_name TerrainData
extends RefCounted
## Authoritative description of the island's ground: a regular height grid with
## material layers (bedrock / clay / soil) plus per-cell soil state (moisture,
## nutrients, grass cover, tillage).  Pure data - no nodes - so the host
## simulation, clients and tests all share it.
##
## Surface height of a cell = rock + clay + soil.  Digging removes soil first,
## then clay, and stops at bedrock: every litre removed becomes an item.

const N := 81                 # vertices per side
const H := 0.25               # metres between grid vertices
const ORIGIN := Vector2(-10.0, -10.0)
const CELL_AREA := H * H      # m^2 represented by one grid vertex
const FIELD_CAPACITY := 0.035 # m of water held by 1.0 moisture in the root zone (35 L/m^2)

# Hand-authored layout (island-local metres, x east, z south).
const TREE_POS := Vector2(1.1, -1.7)
const POND_CENTER := Vector2(-3.7, 0.7)
const POND_RADII := Vector2(1.75, 1.3)
const POND_DEPTH := 0.78
const CLAY_CENTER := Vector2(-2.0, 2.15)
const CLAY_RADII := Vector2(1.7, 1.15)
const OUTCROP_POS := Vector2(4.3, 1.4)
const FLAT_STONE_POS := Vector2(2.9, 3.1)
const SPAWN_POS := Vector2(0.4, 1.2)

var rock := PackedFloat32Array()
var clay := PackedFloat32Array()
var soil := PackedFloat32Array()
var moist := PackedFloat32Array()   # 0..1 of field capacity
var nutr := PackedFloat32Array()    # nutrient units per cell
var grass := PackedFloat32Array()   # 0..1 grass cover
var tilled := PackedByteArray()     # 0 untilled, 1 tilled
var base := PackedFloat32Array()    # original surface (for reference / pit depth)

var inside := PackedByteArray()     # derived: vertex lies inside the island outline
var outline := PackedVector2Array() # derived: island boundary polygon (CCW)
var pond_cells := PackedInt32Array()
var pond_mask := PackedByteArray()        # 1 where the pond basin is (q < 1.05)
var pond_levels := PackedFloat32Array()   # water level samples
var pond_volumes := PackedFloat32Array()  # litres at each level sample
var pond_rim := 0.0
var pond_bottom := 0.0

var _noise := FastNoiseLite.new()


func _init() -> void:
	_noise.seed = 1337
	_noise.frequency = 0.35
	_noise.fractal_octaves = 3


static func outline_radius(theta: float) -> float:
	## Authored, irregular island silhouette: ~16 x 13.5 m.
	var r := 7.15
	r *= 1.0 + 0.085 * sin(2.0 * theta + 0.6) + 0.055 * sin(3.0 * theta + 2.1) \
		+ 0.035 * sin(5.0 * theta + 0.4) + 0.022 * sin(7.0 * theta + 4.0) + 0.012 * sin(11.0 * theta + 1.3)
	return r


static func outline_point(theta: float) -> Vector2:
	var r := outline_radius(theta)
	return Vector2(cos(theta) * r * 1.1, sin(theta) * r * 0.93)


func generate() -> void:
	var count := N * N
	for arr in [rock, clay, soil, moist, nutr, grass, base]:
		arr.resize(count)
	tilled.resize(count)
	tilled.fill(0)
	_build_outline()
	for j in N:
		for i in N:
			var k := j * N + i
			var p := cell_pos(k)
			var surf := _base_surface(p)
			var s := _soil_depth(p)
			var c := _clay_depth(p)
			# bedrock outcrop pokes through the soil
			var od := p.distance_to(OUTCROP_POS)
			var outcrop := 0.55 * exp(-pow(od / 1.25, 2.0))
			if od < 1.7:
				var t := clampf((od - 0.7) / 1.0, 0.0, 1.0)
				s *= t
				c *= t
			surf += outcrop * (1.0 - clampf((od - 0.6) / 1.2, 0.0, 1.0))
			soil[k] = s
			clay[k] = c
			rock[k] = surf - s - c
			base[k] = surf
			var pq := _pond_q(p)
			moist[k] = clampf(0.55 + 0.4 * (1.0 - clampf(pq - 1.0, 0.0, 1.0)), 0.0, 1.0)
			if pq < 1.05 or not inside[k]:
				moist[k] = 0.0  # pond bed is underwater; outside the island there is no soil
			nutr[k] = 0.012 + 0.006 * maxf(0.0, 1.0 - p.distance_to(TREE_POS) / 4.0)
			var g := 1.0
			if pq < 1.08:
				g = 0.0
			elif pq < 1.3:
				g = (pq - 1.08) / 0.22 * 0.7
			if _clay_q(p) < 1.0:
				g = minf(g, 0.25 + 0.6 * _clay_q(p))
			if od < 1.9:
				g = minf(g, clampf((od - 1.0) / 0.9, 0.0, 1.0))
			if p.distance_to(TREE_POS) < 0.75:
				g = 0.3
			if p.distance_to(FLAT_STONE_POS) < 0.75:
				g = 0.2
			grass[k] = g if inside[k] else 0.0
	_build_pond_table()


func _build_outline() -> void:
	outline.clear()
	var segs := 220
	for s in segs:
		var th := float(s) / segs * TAU
		outline.append(outline_point(th))
	inside.resize(N * N)
	for k in N * N:
		inside[k] = 1 if Geometry2D.is_point_in_polygon(cell_pos(k), outline) else 0


func _pond_q(p: Vector2) -> float:
	var d := p - POND_CENTER
	return sqrt(pow(d.x / POND_RADII.x, 2.0) + pow(d.y / POND_RADII.y, 2.0))


func _clay_q(p: Vector2) -> float:
	var d := p - CLAY_CENTER
	return sqrt(pow(d.x / CLAY_RADII.x, 2.0) + pow(d.y / CLAY_RADII.y, 2.0))


func edge_factor(p: Vector2) -> float:
	## 0 at the centre .. 1 at the outline.
	var th := atan2(p.y / 0.93, p.x / 1.1)
	var r := outline_radius(th)
	return Vector2(p.x / 1.1, p.y / 0.93).length() / r


func _base_surface(p: Vector2) -> float:
	var e := edge_factor(p)
	var h := 0.32 * (1.0 - e * e)
	h += 0.42 * exp(-p.distance_squared_to(TREE_POS) / (2.4 * 2.4))
	h += 0.05 * _noise.get_noise_2d(p.x, p.y)
	h -= 0.16 * smoothstep(0.8, 1.02, e)
	h += 0.08 * exp(-p.distance_squared_to(Vector2(-1.0, -4.2)) / 4.0)
	# pond basin with a gentle lip so it holds water
	var q := _pond_q(p)
	if q < 1.0:
		h -= POND_DEPTH * pow(1.0 - q * q, 1.6)
	h += 0.05 * exp(-pow((q - 1.12) / 0.16, 2.0))
	# clay bank sits a little low and flat
	var cq := _clay_q(p)
	if cq < 1.3:
		h -= 0.06 * (1.0 - cq / 1.3)
	return h


func _soil_depth(p: Vector2) -> float:
	var d := 0.42 + 0.18 * exp(-p.distance_squared_to(TREE_POS) / 5.0)
	var q := _pond_q(p)
	if q < 1.15:
		d = lerpf(0.0, d, clampf((q - 0.85) / 0.3, 0.0, 1.0))
	var cq := _clay_q(p)
	if cq < 1.25:
		d = lerpf(0.06, d, clampf((cq - 0.6) / 0.65, 0.0, 1.0))
	return d


func _clay_depth(p: Vector2) -> float:
	var c := 0.03
	var cq := _clay_q(p)
	c += 0.38 * clampf(1.0 - cq * cq * 0.75, 0.0, 1.0)
	var q := _pond_q(p)
	if q < 1.2:
		c = maxf(c, 0.22 * clampf(1.2 - q, 0.0, 1.0) + 0.04)
	return c


# ---------------------------------------------------------------------------
# Queries
# ---------------------------------------------------------------------------

static func cell_pos(k: int) -> Vector2:
	return ORIGIN + Vector2(k % N, k / N) * H


static func cell_xy(k: int) -> Vector2i:
	return Vector2i(k % N, k / N)


static func cell_index(x: int, y: int) -> int:
	return y * N + x


static func cell_at(p: Vector2) -> Vector2i:
	var f := (p - ORIGIN) / H
	return Vector2i(clampi(int(round(f.x)), 0, N - 1), clampi(int(round(f.y)), 0, N - 1))


func surface(k: int) -> float:
	return rock[k] + clay[k] + soil[k]


func height(x: float, z: float) -> float:
	var f := (Vector2(x, z) - ORIGIN) / H
	var i := clampi(int(floor(f.x)), 0, N - 2)
	var j := clampi(int(floor(f.y)), 0, N - 2)
	var tx := clampf(f.x - i, 0.0, 1.0)
	var tz := clampf(f.y - j, 0.0, 1.0)
	var k := j * N + i
	var h00 := surface(k)
	var h10 := surface(k + 1)
	var h01 := surface(k + N)
	var h11 := surface(k + N + 1)
	return lerpf(lerpf(h00, h10, tx), lerpf(h01, h11, tx), tz)


func sample(arr: PackedFloat32Array, x: float, z: float) -> float:
	var f := (Vector2(x, z) - ORIGIN) / H
	var i := clampi(int(floor(f.x)), 0, N - 2)
	var j := clampi(int(floor(f.y)), 0, N - 2)
	var tx := clampf(f.x - i, 0.0, 1.0)
	var tz := clampf(f.y - j, 0.0, 1.0)
	var k := j * N + i
	return lerpf(lerpf(arr[k], arr[k + 1], tx), lerpf(arr[k + N], arr[k + N + 1], tx), tz)


func normal_at(x: float, z: float) -> Vector3:
	var e := 0.12
	var hx := height(x + e, z) - height(x - e, z)
	var hz := height(x, z + e) - height(x, z - e)
	return Vector3(-hx, 2.0 * e, -hz).normalized()


func is_inside(x: float, z: float) -> bool:
	return Geometry2D.is_point_in_polygon(Vector2(x, z), outline)


func layer_at(x: float, z: float) -> String:
	var k := cell_index(cell_at(Vector2(x, z)).x, cell_at(Vector2(x, z)).y)
	if in_pond(Vector2(x, z)):
		return "water"
	if soil[k] > 0.015:
		return "soil"
	if clay[k] > 0.015:
		return "clay"
	return "rock"


func in_pond(p: Vector2) -> bool:
	return _pond_q(p) < 1.05


func is_pond_cell(k: int) -> bool:
	return pond_mask.size() > k and pond_mask[k] == 1


func pond_q(p: Vector2) -> float:
	return _pond_q(p)


func depth_below_base(x: float, z: float) -> float:
	return sample(base, x, z) - height(x, z)


func cells_in_radius(center: Vector2, radius: float) -> PackedInt32Array:
	var out := PackedInt32Array()
	var c0 := cell_at(center - Vector2(radius, radius))
	var c1 := cell_at(center + Vector2(radius, radius))
	for j in range(c0.y, c1.y + 1):
		for i in range(c0.x, c1.x + 1):
			var k := j * N + i
			if inside[k] and cell_pos(k).distance_to(center) <= radius:
				out.append(k)
	return out


# ---------------------------------------------------------------------------
# Edits (host applies, then broadcasts the touched rect)
# ---------------------------------------------------------------------------

func dig(center: Vector2, radius: float, volume_l: float, max_layer: String = "clay") -> Dictionary:
	## Removes up to `volume_l` litres with a smooth brush.  Soil comes off first,
	## then clay (if max_layer == "clay"); bedrock never.  Returns the litres of
	## each material actually removed and the touched cell rect.
	var cells := cells_in_radius(center, radius)
	var out := {"soil": 0.0, "clay": 0.0, "rect": Rect2i(), "torn": {}}
	if cells.is_empty():
		return out
	var weights := PackedFloat32Array()
	var wsum := 0.0
	for k in cells:
		var d := cell_pos(k).distance_to(center) / radius
		var w := pow(1.0 - d * d, 2.0)
		weights.append(w)
		wsum += w
	if wsum <= 0.0:
		return out
	var depth := (volume_l / 1000.0) / (wsum * CELL_AREA)
	var rect := Rect2i(cell_xy(cells[0]), Vector2i.ONE)
	for n in cells.size():
		var k := cells[n]
		var want := depth * weights[n]
		var from_soil := minf(want, soil[k])
		soil[k] -= from_soil
		want -= from_soil
		out["soil"] += from_soil * CELL_AREA * 1000.0
		if want > 0.0 and max_layer == "clay":
			var from_clay := minf(want, clay[k])
			clay[k] -= from_clay
			out["clay"] += from_clay * CELL_AREA * 1000.0
		if from_soil > 0.0:
			# the grass on it is torn up too (the caller settles where it goes)
			out["torn"][k] = 0.8 * weights[n] + 0.2
		rect = rect.expand(cell_xy(k))
	out["rect"] = rect.grow(1)
	return out


func fill(center: Vector2, radius: float, volume_l: float) -> Rect2i:
	var cells := cells_in_radius(center, radius)
	if cells.is_empty():
		return Rect2i()
	var weights := PackedFloat32Array()
	var wsum := 0.0
	for k in cells:
		var d := cell_pos(k).distance_to(center) / radius
		var w := pow(1.0 - d * d, 2.0)
		weights.append(w)
		wsum += w
	var depth := (volume_l / 1000.0) / (wsum * CELL_AREA)
	var rect := Rect2i(cell_xy(cells[0]), Vector2i.ONE)
	for n in cells.size():
		var k := cells[n]
		soil[k] += depth * weights[n]
		rect = rect.expand(cell_xy(k))
	return rect.grow(1)


func soil_volume_l(center: Vector2, radius: float) -> float:
	var v := 0.0
	for k in cells_in_radius(center, radius):
		v += soil[k] * CELL_AREA * 1000.0
	return v


# ---------------------------------------------------------------------------
# Pond
# ---------------------------------------------------------------------------

func _build_pond_table() -> void:
	pond_mask.resize(N * N)
	for k in N * N:
		pond_mask[k] = 1 if _pond_q(cell_pos(k)) < 1.05 else 0
	pond_cells.clear()
	pond_bottom = 1e9
	pond_rim = 1e9
	for k in N * N:
		var q := _pond_q(cell_pos(k))
		if q < 1.18:
			pond_cells.append(k)
			pond_bottom = minf(pond_bottom, surface(k))
		if q > 1.0 and q < 1.25:
			pond_rim = minf(pond_rim, surface(k))
	pond_levels.clear()
	pond_volumes.clear()
	var steps := 64
	for s in steps + 1:
		var lvl := lerpf(pond_bottom, pond_rim, float(s) / steps)
		var v := 0.0
		for k in pond_cells:
			v += maxf(0.0, lvl - surface(k)) * CELL_AREA * 1000.0
		pond_levels.append(lvl)
		pond_volumes.append(v)


func pond_capacity() -> float:
	return pond_volumes[pond_volumes.size() - 1] if pond_volumes.size() > 0 else 0.0


func pond_level_for(volume_l: float) -> float:
	if pond_volumes.is_empty():
		return 0.0
	if volume_l <= 0.0:
		return pond_bottom - 0.01
	for s in range(1, pond_volumes.size()):
		if pond_volumes[s] >= volume_l:
			var t := (volume_l - pond_volumes[s - 1]) / maxf(0.0001, pond_volumes[s] - pond_volumes[s - 1])
			return lerpf(pond_levels[s - 1], pond_levels[s], t)
	return pond_rim


# ---------------------------------------------------------------------------
# Serialisation
# ---------------------------------------------------------------------------

func to_dict() -> Dictionary:
	return {
		"rock": rock, "clay": clay, "soil": soil, "moist": moist, "nutr": nutr,
		"grass": grass, "tilled": tilled,
	}


func from_dict(d: Dictionary) -> void:
	generate()  # rebuild derived data (outline, inside, base) deterministically
	for key in ["rock", "clay", "soil", "moist", "nutr", "grass"]:
		if d.has(key) and d[key] is PackedFloat32Array and d[key].size() == N * N:
			set(key, d[key])
	if d.has("tilled") and d["tilled"] is PackedByteArray and d["tilled"].size() == N * N:
		tilled = d["tilled"]
	_build_pond_table()


func patch(rect: Rect2i) -> Dictionary:
	rect = rect.intersection(Rect2i(0, 0, N, N))
	var out := {"r": rect, "rock": PackedFloat32Array(), "clay": PackedFloat32Array(), "soil": PackedFloat32Array(),
		"grass": PackedFloat32Array(), "tilled": PackedByteArray(), "moist": PackedFloat32Array(), "nutr": PackedFloat32Array()}
	for j in range(rect.position.y, rect.end.y):
		for i in range(rect.position.x, rect.end.x):
			var k := j * N + i
			out["rock"].append(rock[k])
			out["clay"].append(clay[k])
			out["soil"].append(soil[k])
			out["grass"].append(grass[k])
			out["tilled"].append(tilled[k])
			out["moist"].append(moist[k])
			out["nutr"].append(nutr[k])
	return out


func apply_patch(p: Dictionary) -> Rect2i:
	var rect: Rect2i = p["r"]
	var n := 0
	for j in range(rect.position.y, rect.end.y):
		for i in range(rect.position.x, rect.end.x):
			var k := j * N + i
			rock[k] = p["rock"][n]
			clay[k] = p["clay"][n]
			soil[k] = p["soil"][n]
			grass[k] = p["grass"][n]
			tilled[k] = p["tilled"][n]
			moist[k] = p["moist"][n]
			nutr[k] = p["nutr"][n]
			n += 1
	return rect


# ---------------------------------------------------------------------------
# Ledger helpers
# ---------------------------------------------------------------------------

func total_soil_l() -> float:
	var v := 0.0
	for k in N * N:
		if inside[k]:
			v += soil[k]
	return v * CELL_AREA * 1000.0


func total_clay_l() -> float:
	var v := 0.0
	for k in N * N:
		if inside[k]:
			v += clay[k]
	return v * CELL_AREA * 1000.0


func total_soil_water_l() -> float:
	var v := 0.0
	for k in N * N:
		if inside[k] and not is_pond_cell(k):
			v += moist[k]
	return v * FIELD_CAPACITY * CELL_AREA * 1000.0


func total_nutrients() -> float:
	var v := 0.0
	for k in N * N:
		if inside[k]:
			v += nutr[k]
	return v
