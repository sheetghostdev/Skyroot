class_name WaterSim
extends RefCounted
## The island's closed water cycle.  Every transfer moves litres between pools:
## pond <-> atmosphere <-> soil, soil -> plants -> atmosphere, rain -> pond /
## soil / open vessels / items.  Only water spilled over the edge leaves the
## system (World.pools.lost_water_l).

const ATMO_CAPACITY := 1600.0     # litres of vapour the local air can hold before it must rain
const POND_EVAP_MM_H := 0.22      # mm per hour at 20 C, sun, light wind
const SOIL_EVAP_MM_H := 0.09
const DRAIN_ABOVE := 0.6          # soil wetter than this (of field capacity) drains toward the pond
const DRAIN_RATE := 0.03          # share of that excess draining away per hour


static func cell_l() -> float:
	return TerrainData.FIELD_CAPACITY * TerrainData.CELL_AREA * 1000.0


static func tick(hours: float, ctx: Dictionary) -> void:
	var t: TerrainData = World.terrain
	var pools := World.pools
	var temp: float = ctx.get("temp", 18.0)
	var sun: float = ctx.get("sun", 0.5)
	var wind: float = ctx.get("wind", 1.0)
	var humid := clampf(float(pools.get("atmo_water_l", 0.0)) / ATMO_CAPACITY, 0.0, 1.0)
	var evap_k := clampf((temp + 5.0) / 25.0, 0.1, 1.6) * (0.35 + 0.65 * sun) * (0.7 + 0.15 * wind) * (1.0 - humid * 0.8)
	# --- pond evaporation
	var pond := float(World.env.get("pond_l", 0.0))
	var area := _pond_area(t, pond)
	var pe := minf(pond, area * POND_EVAP_MM_H * evap_k * hours)
	pond -= pe
	pools["atmo_water_l"] = float(pools["atmo_water_l"]) + pe
	# --- soil evaporation (grass shades the soil a little)
	var cl := cell_l()
	var soil_evap := 0.0
	for k in t.moist.size():
		var m := t.moist[k]
		if m <= 0.02 or not t.inside[k] or t.is_pond_cell(k):
			continue
		var shade := 1.0 - t.grass[k] * 0.35
		var loss := minf(m - 0.02, SOIL_EVAP_MM_H / 35.0 * evap_k * shade * m * 1.6 * hours)
		if loss > 0.0:
			t.moist[k] = m - loss
			soil_evap += loss * cl
	pools["atmo_water_l"] = float(pools["atmo_water_l"]) + soil_evap
	# --- pond seepage keeps the banks damp
	var seep_total := 0.0
	var bank_cells := _bank_cells(t)
	for k in bank_cells:
		if pond <= 1.0:
			break
		var want := maxf(0.0, 0.85 - t.moist[k]) * 0.06 * hours
		var l := minf(want * cl, pond * 0.001)
		t.moist[k] += l / cl
		pond -= l
		seep_total += l
	# --- diffusion between neighbouring soil cells (conservative)
	_diffuse(t, hours)
	# --- soil wetter than it can hold against gravity seeps down and through the
	# ground to the pond: rain on the island keeps the pond filled
	var drained := 0.0
	var dk := minf(1.0, DRAIN_RATE * hours)
	for k in t.moist.size():
		if not t.inside[k] or t.is_pond_cell(k):
			continue
		var m := t.moist[k]
		if m > DRAIN_ABOVE:
			var dm := (m - DRAIN_ABOVE) * dk
			t.moist[k] = m - dm
			drained += dm * cl
	pond += drained
	# --- rain
	var rain := float(World.env.get("rain", 0.0))
	if rain > 0.0:
		var mm := rain * 1.8 * hours       # mm of rain this tick
		var want := mm * _island_area(t)   # litres requested
		var avail := maxf(0.0, float(pools["atmo_water_l"]) - 40.0)
		var fall := minf(want, avail)
		if fall > 0.0:
			pools["atmo_water_l"] = float(pools["atmo_water_l"]) - fall
			var f := fall / want  # fraction of the requested depth that actually fell
			var depth_mm := mm * f
			# direct rain into the pond
			var to_pond := area * depth_mm
			pond += to_pond
			var left := fall - to_pond
			# open vessels and exposed items catch their share
			if ctx.has("rain_catch"):
				var caught: float = (ctx["rain_catch"] as Callable).call(depth_mm)
				left -= caught
			# the rest soaks into the soil; what can't soak in runs off to the pond
			var cells := 0
			for k in t.moist.size():
				if t.inside[k] and not t.is_pond_cell(k):
					cells += 1
			var per := left / maxf(1.0, cells)
			var runoff := 0.0
			for k in t.moist.size():
				if not t.inside[k] or t.is_pond_cell(k):
					continue
				var room := (1.0 - t.moist[k]) * cl
				var soak := minf(per, room)
				t.moist[k] += soak / cl
				runoff += per - soak
			pond += runoff
	# --- pond overflow soaks into the banks (never vanishes)
	var cap := t.pond_capacity()
	if pond > cap:
		var extra := pond - cap
		pond = cap
		var banks := bank_cells
		var per2 := extra / maxf(1.0, banks.size())
		var spill := 0.0
		for k in banks:
			var room2 := (1.0 - t.moist[k]) * cl
			var s := minf(per2, room2)
			t.moist[k] += s / cl
			spill += per2 - s
		pools["atmo_water_l"] = float(pools["atmo_water_l"]) + spill  # puddles evaporate
	World.env["pond_l"] = pond


static func _pond_area(t: TerrainData, litres: float) -> float:
	var lvl := t.pond_level_for(litres)
	var a := 0.0
	for k in t.pond_cells:
		if t.surface(k) < lvl:
			a += TerrainData.CELL_AREA
	return a


static var _banks: PackedInt32Array = PackedInt32Array()


static func _bank_cells(t: TerrainData) -> PackedInt32Array:
	if _banks.size() > 0:
		return _banks
	for k in t.moist.size():
		var q := t.pond_q(TerrainData.cell_pos(k))
		if q >= 1.05 and q < 1.45 and t.inside[k] and not t.is_pond_cell(k):
			_banks.append(k)
	return _banks


static var _island_area_cache := -1.0


static func _island_area(t: TerrainData) -> float:
	if _island_area_cache < 0.0:
		var n := 0
		for k in t.inside.size():
			if t.inside[k]:
				n += 1
		_island_area_cache = n * TerrainData.CELL_AREA
	return _island_area_cache


static func _diffuse(t: TerrainData, hours: float) -> void:
	var n := TerrainData.N
	var k_d := clampf(0.08 * hours, 0.0, 0.2)
	var src := t.moist.duplicate()
	for j in range(1, n - 1):
		for i in range(1, n - 1):
			var k := j * n + i
			if not t.inside[k] or t.is_pond_cell(k):
				continue
			var flow := 0.0
			for nb in [k - 1, k + 1, k - n, k + n]:
				if t.inside[nb] and not t.is_pond_cell(nb):
					flow += (src[nb] - src[k])
			t.moist[k] += flow * k_d * 0.25
