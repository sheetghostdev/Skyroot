class_name DryingSim
extends RefCounted
## Things left out in the air: clay and pottery dry (their water joins the
## atmosphere), wood seasons, cut grass cures into straw.  Rain undoes it -
## unfired pottery left in the rain slumps back into clay.  Open fired vessels
## catch rain.

const SKIP_TYPES := []


static func _sheltered(pos: Vector3) -> bool:
	var gw = Game.game_world
	if gw == null:
		return false
	return Shelter.roof_above(gw.get_world_3d(), pos + Vector3(0, 0.25, 0), 6.0)


static func tick(hours: float, ctx: Dictionary) -> void:
	var temp: float = ctx.get("temp", 16.0)
	var sun: float = ctx.get("sun", 0.5)
	var wind: float = ctx.get("wind", 1.0)
	var rain := float(World.env.get("rain", 0.0))
	var humid := clampf(float(World.pools.get("atmo_water_l", 0.0)) / WaterSim.ATMO_CAPACITY, 0.0, 1.0)
	var base := clampf((temp + 2.0) / 22.0, 0.15, 1.5) * (0.6 + 0.15 * wind) * (1.0 - 0.6 * humid)
	for e in World.entities.values():
		if e["t"] != "item":
			continue
		var d: Dictionary = e["d"]
		if int(d.get("site", -1)) >= 0:
			continue  # inside a fire: the fire simulation handles it
		var id := String(d.get("i", ""))
		var x: Dictionary = d.get("x", {})
		var pos: Vector3 = e["xf"].origin
		match id:
			"pot":
				_pot(e, x, hours, base, sun, rain, pos)
			"clay", "clay_prepared":
				_clay(e, x, id, hours, base, rain, pos)
			_:
				var mat := ItemDB.material(id)
				if mat == "wood" or id == "grass" or id == "leaves":
					_organic(e, x, id, hours, base, sun, rain, pos)


static func _pot(e: Dictionary, x: Dictionary, hours: float, base: float, sun: float, rain: float, pos: Vector3) -> void:
	var st := String(x.get("state", "wet"))
	if st == "fired" or st == "cracked":
		return
	var m := float(x.get("moist", 0.24))
	var vol := float(x.get("vol", 0.25))
	var sheltered := _sheltered(pos)
	if rain > 0.05 and not sheltered:
		var wet := rain * 0.03 * hours
		var take := minf(wet * vol, float(World.pools.get("atmo_water_l", 0.0)))
		World.pools["atmo_water_l"] = float(World.pools["atmo_water_l"]) - take
		m += take / vol
		if m > 0.34:
			_slump(e, x, m)
			return
	elif m > 0.02:
		var wall := float(Pottery.stats(x).get("wall_mean", 0.007)) if x.has("ro") else 0.007
		var rate := 0.016 * base * (1.25 if not sheltered and sun > 0.3 else 1.0) * clampf(0.0065 / maxf(wall, 0.002), 0.5, 1.8)
		var dm := minf(m - 0.02, rate * hours)
		m -= dm
		World.pools["atmo_water_l"] = float(World.pools.get("atmo_water_l", 0.0)) + dm * vol
	var x2 := x.duplicate(true)
	x2["moist"] = m
	x2["state"] = Pottery.moisture_state(m)
	if absf(m - float(x.get("moist", m))) > 0.004 or x2["state"] != st:
		World.update(e["id"], {"x": x2})
	else:
		x["moist"] = m


static func _slump(e: Dictionary, x: Dictionary, m: float) -> void:
	## Rain-soaked unfired clay loses its shape and becomes lumps of clay again.
	var vol := float(x.get("vol", 0.25))
	var lumps := maxi(1, int(round(vol / Pottery.LUMP_L)))
	var a: Actions = World.actions
	var pos: Vector3 = e["xf"].origin
	World.despawn(e["id"])
	# water beyond what the lumps hold drains into the soil
	var water := vol * m
	var keep := lumps * Pottery.LUMP_L * 0.3
	if a:
		a.spawn_item("clay", lumps, {"moist": keep / (lumps * Pottery.LUMP_L)}, pos + Vector3(0, 0.1, 0))
	WaterActions.soak(pos, maxf(0.0, water - keep), 0.3)
	# clay volume drift from rounding is tracked so nothing is created or lost
	var dv := vol - lumps * Pottery.LUMP_L
	World.pools["clay_spilled_l"] = float(World.pools.get("clay_spilled_l", 0.0)) + dv
	World.fx("clay_squish", pos)
	World.notify_all("An unfired pot left in the rain has slumped back into clay.")


static func _clay(e: Dictionary, x: Dictionary, id: String, hours: float, base: float, rain: float, pos: Vector3) -> void:
	var n := int(e["d"].get("n", 1))
	var vol := n * Pottery.LUMP_L
	var m := float(x.get("moist", ItemDB.default_moist(id)))
	var nm := m
	if rain > 0.05 and not _sheltered(pos):
		var take := minf(rain * 0.02 * hours * vol, float(World.pools.get("atmo_water_l", 0.0)))
		World.pools["atmo_water_l"] = float(World.pools["atmo_water_l"]) - take
		nm = minf(0.32, m + take / vol)
		World.pools["atmo_water_l"] = float(World.pools["atmo_water_l"]) + maxf(0.0, (m + take / vol - nm) * vol)
	elif m > 0.05:
		var dm := minf(m - 0.05, 0.006 * base * hours)
		nm = m - dm
		World.pools["atmo_water_l"] = float(World.pools.get("atmo_water_l", 0.0)) + dm * vol
	if absf(nm - m) > 0.0:
		var x2 := x.duplicate()
		x2["moist"] = nm
		if absf(nm - m) > 0.005:
			World.update(e["id"], {"x": x2})
		else:
			e["d"]["x"] = x2


static func _organic(e: Dictionary, x: Dictionary, id: String, hours: float, base: float, sun: float, rain: float, pos: Vector3) -> void:
	## Seasoning wood and curing grass.  (Water bound in living tissue is outside the
	## water ledger - see docs/ECONOMY.md - so this only changes the material's state.)
	var m := float(x.get("moist", ItemDB.default_moist(id)))
	var floor_m := 0.1 if id == "grass" else 0.12
	var nm := m
	if rain > 0.1 and not _sheltered(pos):
		nm = minf(0.6, m + rain * 0.02 * hours)
	elif m > floor_m:
		var rate := (0.03 if id == "grass" else (0.02 if id == "leaves" else 0.009)) * base * (1.3 if sun > 0.3 else 0.8)
		nm = maxf(floor_m, m - rate * hours)
	if id == "grass" and nm <= 0.16:
		var n := int(e["d"].get("n", 1))
		World.update(e["id"], {"i": "straw", "x": {"moist": 0.1}})
		World.pools["soil_organic_kg"] = float(World.pools.get("soil_organic_kg", 0.0)) + n * maxf(0.0, ItemDB.unit_mass("grass") - ItemDB.unit_mass("straw"))
		return
	if absf(nm - m) > 0.02:
		var x2 := x.duplicate()
		x2["moist"] = nm
		World.update(e["id"], {"x": x2})
	elif nm != m:
		var x3 := x.duplicate()
		x3["moist"] = nm
		e["d"]["x"] = x3


static func rain_catch(depth_mm: float) -> float:
	## Open fired vessels standing outdoors fill with rain.  Returns litres caught.
	var caught := 0.0
	for e in World.entities.values():
		if e["t"] != "item" or String(e["d"].get("i", "")) != "pot":
			continue
		var x: Dictionary = e["d"].get("x", {})
		if String(x.get("state", "")) != "fired" or not x.has("ri"):
			continue
		if _sheltered(e["xf"].origin):
			continue
		var r: float = x["ri"][Pottery.N - 1]
		var area := PI * r * r
		var cap := Pottery.capacity(x)
		var room := cap - float(x.get("water", 0.0))
		var c := clampf(area * depth_mm, 0.0, room)
		if c > 0.0:
			var x2 := x.duplicate(true)
			x2["water"] = float(x.get("water", 0.0)) + c
			World.update(e["id"], {"x": x2})
			caught += c
	return caught
