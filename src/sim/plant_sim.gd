class_name PlantSim
extends RefCounted
## Growth of everything green on the island.  Growth is paid for: carbon from
## the atmosphere pool, water and nutrients from the soil cells under the
## plant.  Stressed plants show it (wilting, yellowing).

const GRASS_KG := 0.04        # biomass of a fully grassed cell
const GRASS_NUTR := 0.0005
const CROP_WATER_L_PER_KG := 8.0
const ROOT_R := 0.32
const DAY_LIGHT := 0.42       # average daylight over a whole clear day (Weather.light_factor)

static var _grass_cursor := 0


static func tick(hours: float, ctx: Dictionary) -> void:
	var light: float = ctx.get("light", 0.5)
	var temp: float = ctx.get("temp", 16.0)
	var temp_f := clampf((temp - 4.0) / 12.0, 0.15, 1.15)
	# crops are tuned so a plant's "days" holds for a watered, fed crop in ordinary island weather
	var crop_tf := clampf((temp - 2.0) / 12.0, 0.15, 1.2)
	for e in World.entities.values():
		match String(e["t"]):
			"plant":
				_crop(e, hours, light, crop_tf)
			"tree":
				var res := TreeSim.tick(e["d"], hours, light * temp_f, e["xf"].origin, World.terrain, World.pools)
				for drop in res["drops"]:
					_drop_near_tree(e, String(drop[0]), int(drop[1]))
				if res["changed"]:
					World.update(e["id"], e["d"].duplicate())
			"bush":
				_bush(e, hours, light, temp_f)
			"mushrooms":
				_mushrooms(e, hours)
	_grass(hours, light, temp_f)


static func _cells(p: Vector3, r: float = ROOT_R) -> PackedInt32Array:
	return World.terrain.cells_in_radius(Vector2(p.x, p.z), r)


static func _avg_moist(cells: PackedInt32Array) -> float:
	if cells.is_empty():
		return 0.0
	var m := 0.0
	for k in cells:
		m += World.terrain.moist[k]
	return m / cells.size()


static func _avail_nutr(cells: PackedInt32Array) -> float:
	var n := 0.0
	for k in cells:
		n += World.terrain.nutr[k]
	return n


static func _crop(e: Dictionary, hours: float, light: float, temp_f: float) -> void:
	var d: Dictionary = e["d"]
	var g := float(d.get("g", 0.0))
	var info := ItemDB.plant(String(d.get("sp", "")))
	if info.is_empty():
		return
	var cells := _cells(e["xf"].origin)
	var moist := _avg_moist(cells)
	var need := float(info.get("water_need", 0.3))
	var water_f := clampf((moist - 0.1) / maxf(0.05, need - 0.1), 0.0, 1.0)
	var changes := {}
	var thirst := 1.0 - water_f
	if absf(thirst - float(d.get("thirst", 0.0))) > 0.08:
		changes["thirst"] = snappedf(thirst, 0.01)
	if g < 1.0:
		var rate := 1.0 / (float(info.get("days", 3.0)) * 24.0) * (light / DAY_LIGHT)
		var nutr_total := float(info.get("nutr_total", 0.01))
		var nutr_avail := _avail_nutr(cells)
		var dg := rate * water_f * temp_f * hours
		var dn := dg * nutr_total
		var nutr_f := 1.0
		if dn > nutr_avail * 0.5:
			nutr_f = clampf(nutr_avail * 0.5 / maxf(dn, 1e-9), 0.0, 1.0)
		dg *= 0.25 + 0.75 * nutr_f
		var hunger := 1.0 - nutr_f
		if absf(hunger - float(d.get("hunger", 0.0))) > 0.08:
			changes["hunger"] = snappedf(hunger, 0.01)
		var bio_total := float(info.get("biomass", 1.0))
		var db := dg * bio_total
		dg = minf(dg, 1.0 - g)
		db = minf(db, float(World.pools.get("atmo_carbon_kg", 0.0)))
		if dg > 0.0 and db > 0.0:
			dn = dg * nutr_total
			var dw := db * CROP_WATER_L_PER_KG
			var got := TreeSim.draw_from_cells(World.terrain, cells, dw, dn)
			World.pools["atmo_carbon_kg"] = float(World.pools["atmo_carbon_kg"]) - db
			World.pools["atmo_water_l"] = float(World.pools.get("atmo_water_l", 0.0)) + got.x
			d["g"] = g + dg
			d["nutr"] = float(d.get("nutr", 0.0)) + got.y
			d["bio"] = float(d.get("bio", 0.0)) + db
			# vigour remembers stress (affects yield)
			d["vig"] = lerpf(float(d.get("vig", 1.0)), water_f * (0.4 + 0.6 * nutr_f), clampf(hours * 0.1, 0.0, 1.0))
			if int(float(d["g"]) * 20.0) != int(g * 20.0) or float(d["g"]) >= 1.0:
				changes["g"] = minf(1.0, float(d["g"]))
				changes["nutr"] = d["nutr"]
				changes["bio"] = d["bio"]
				changes["vig"] = d["vig"]
	if not changes.is_empty():
		World.update(e["id"], changes)


static func _bush(e: Dictionary, hours: float, light: float, temp_f: float) -> void:
	var d: Dictionary = e["d"]
	var b := float(d.get("berries", 0.0))
	if b >= 1.0:
		return
	var cells := _cells(e["xf"].origin, 0.8)
	var water_f := clampf((_avg_moist(cells) - 0.12) / 0.3, 0.0, 1.0)
	var db := hours / 32.0 * water_f * temp_f * (light / 0.5)
	db = minf(db, 1.0 - b)
	var kg := db * 6.0 * ItemDB.unit_mass("berries")
	var nutr := db * 6.0 * ItemDB.nutrients("berries")
	var water := db * 6.0 * 0.03 * Survival.BODY_WATER_L  # juice that drinking berries returns
	if db <= 0.0 or kg > float(World.pools.get("atmo_carbon_kg", 0.0)) or nutr > _avail_nutr(cells) * 0.5:
		return
	var cl := WaterSim.cell_l()
	var soil_w := 0.0
	for k in cells:
		soil_w += maxf(0.0, World.terrain.moist[k] - 0.06) * cl
	if water > soil_w * 0.3:
		return
	var got := TreeSim.draw_from_cells(World.terrain, cells, water, nutr)
	if got.y < nutr - 1e-9 or got.x < water - 1e-7:
		# the soil couldn't spare it after all: give it back and wait
		WaterActions.soak(e["xf"].origin, got.x, 0.8)
		var back := _cells(e["xf"].origin, 0.8)
		for k in back:
			World.terrain.nutr[k] += got.y / maxf(1.0, back.size())
		return
	World.pools["atmo_carbon_kg"] = float(World.pools["atmo_carbon_kg"]) - kg
	World.pools["plant_water_l"] = float(World.pools.get("plant_water_l", 0.0)) + water
	d["berries"] = b + db
	if int(float(d["berries"]) * 8.0) != int(b * 8.0):
		World.update(e["id"], {"berries": d["berries"]})


static func _mushrooms(e: Dictionary, hours: float) -> void:
	var d: Dictionary = e["d"]
	var caps: Array = d.get("caps", [])
	var sub := float(d.get("substrate", 0.0))
	if sub <= 0.0:
		return
	var cells := _cells(e["xf"].origin, 0.6)
	var moist := _avg_moist(cells)
	var f := clampf((moist - 0.15) / 0.3, 0.0, 1.0)
	var changed := false
	var nu := float(d.get("nutr", 0.0))
	for i in caps.size():
		var c := float(caps[i])
		if c >= 1.0:
			continue
		var dc := minf(1.0 - c, hours / 16.0 * f)
		var kg := dc * ItemDB.unit_mass("mushroom")
		if kg > sub:
			break
		# a cap is built from the rotting wood and the minerals in it (or the soil beneath)
		var dn := dc * ItemDB.nutrients("mushroom")
		var from_wood := minf(dn, nu)
		var from_soil := dn - from_wood
		if from_soil > 0.0:
			if _avail_nutr(cells) < from_soil * 4.0:
				break
			var got := TreeSim.draw_from_cells(World.terrain, cells, 0.0, from_soil)
			if got.y < from_soil - 1e-9:
				for k in cells:
					World.terrain.nutr[k] += got.y / maxf(1.0, cells.size())
				break
		nu -= from_wood
		sub -= kg
		caps[i] = c + dc
		if int(float(caps[i]) * 5.0) != int(c * 5.0):
			changed = true
	d["substrate"] = sub
	d["nutr"] = nu
	if changed:
		World.update(e["id"], {"caps": caps.duplicate(), "substrate": sub, "nutr": nu})


static func _grass(hours: float, light: float, temp_f: float) -> void:
	## Lawn grass slowly recovers on undisturbed soil (a slice of the island per tick).
	var t: TerrainData = World.terrain
	var count := t.grass.size()
	var slice := 900
	var any := false
	var carbon := float(World.pools.get("atmo_carbon_kg", 0.0))
	var hours_eff := hours * float(count) / slice
	for n in slice:
		var k := (_grass_cursor + n) % count
		if not t.inside[k] or t.tilled[k] == 1 or t.soil[k] < 0.05 or t.is_pond_cell(k):
			continue
		var g := t.grass[k]
		if g >= 1.0 or t.moist[k] < 0.18:
			continue
		var dg := minf(1.0 - g, 0.01 * hours_eff * light / 0.5 * temp_f * clampf((t.moist[k] - 0.18) / 0.3, 0.0, 1.0) * (0.3 + g))
		var kg := dg * GRASS_KG
		var nu := dg * GRASS_NUTR
		if dg <= 0.0 or kg > carbon or nu > t.nutr[k]:
			continue
		t.grass[k] = g + dg
		t.nutr[k] -= nu
		carbon -= kg
		World.pools["grass_nutr"] = float(World.pools.get("grass_nutr", 0.0)) + nu
		any = true
	World.pools["atmo_carbon_kg"] = carbon
	_grass_cursor = (_grass_cursor + slice) % count


static func _drop_near_tree(e: Dictionary, id: String, n: int) -> void:
	var a: Actions = World.actions
	if a == null:
		return
	var o: Vector3 = e["xf"].origin
	var ang := randf() * TAU
	var r := randf_range(0.6, 2.6)
	var p := o + Vector3(cos(ang) * r, 4.0, sin(ang) * r)
	a.spawn_item(id, n, {"moist": 0.12} if ItemDB.material(id) == "wood" else {}, p)
