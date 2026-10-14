class_name Ledger
extends RefCounted
## Material accounting for the closed island.  compute() walks every store and
## sums each conserved quantity.  Totals must stay constant over time except for
## what is recorded as lost to the abyss (which is itself part of the total, so
## the grand totals are exactly invariant).  Tests assert this.
##
## Units: water litres, carbon kg of dry biomass-equivalent, nutrients abstract
## units, clay litres, soil litres, stone kg.

const KEYS := ["water", "carbon", "nutr", "clay", "soil", "stone"]
const SHERD_L := 0.05


static func empty() -> Dictionary:
	var d := {}
	for k in KEYS:
		d[k] = 0.0
	return d


static func _add(a: Dictionary, b: Dictionary) -> void:
	for k in b:
		a[k] = float(a.get(k, 0.0)) + float(b[k])


static func item_contrib(id: String, n: int, x: Dictionary) -> Dictionary:
	var out := empty()
	if n <= 0 or not ItemDB.exists(id):
		return out
	if x.has("fm"):
		# fuel that has been in a fire carries its own wood, charcoal and minerals
		out["carbon"] = float(x["fm"]) + float(x.get("ch", 0.0))
		out["nutr"] = float(x.get("nu", 0.0))
		return out
	match id:
		"clay", "clay_prepared":
			out["clay"] = n * Pottery.LUMP_L
			out["water"] = n * Pottery.LUMP_L * float(x.get("moist", ItemDB.default_moist(id)))
		"pot":
			out["clay"] = float(x.get("vol", 0.25))
			var st := String(x.get("state", "wet"))
			if st != "fired" and st != "cracked":
				out["water"] = float(x.get("vol", 0.25)) * float(x.get("moist", 0.0))
			out["water"] += float(x.get("water", 0.0))
			var cont: Dictionary = x.get("contents", {})
			for cid in cont:
				if cid == "porridge":
					# grain cooked in water: the water is in the porridge pool
					_add(out, item_contrib("seed_grain", int(cont[cid]) * WaterActions.PORRIDGE_SEEDS, {}))
				else:
					_add(out, item_contrib(cid, int(cont[cid]), {}))
		"potsherds":
			out["clay"] = n * SHERD_L
		"earth":
			out["soil"] = n * 4.0
		"stone":
			out["stone"] = n * ItemDB.unit_mass("stone")
		"stone_head", "blade":
			out["stone"] = float(x.get("stone_kg", ItemDB.unit_mass(id))) * n
		"axe", "digger":
			out["stone"] = float(x.get("head", {}).get("stone_kg", 0.25))
			out["carbon"] = ItemDB.unit_mass("stick") + ItemDB.unit_mass("cordage") * float(x.get("cords", 1))
			out["nutr"] = ItemDB.nutrients("stick") + ItemDB.nutrients("cordage") * float(x.get("cords", 1))
		"wood_piece":
			out["carbon"] = float(x.get("mass", 10.0))
			out["nutr"] = ItemDB.nutrients("log") * float(x.get("mass", 10.0)) / ItemDB.unit_mass("log")
		"torch":
			out["carbon"] = float(x.get("mass", ItemDB.unit_mass("stick")))
			out["nutr"] = ItemDB.nutrients("stick")
		_:
			if ItemDB.is_organic(id) or ItemDB.material(id) in ["charcoal", "ash"] or id == "compost":
				out["carbon"] = n * ItemDB.unit_mass(id)
			out["nutr"] = n * ItemDB.nutrients(id)
	return out


static func record_loss(id: String, n: int, x: Dictionary) -> void:
	## Something went over the edge: it stays in the books as lost.
	var c := item_contrib(id, n, x)
	for k in c:
		if float(c[k]) != 0.0:
			var pool: String = "lost_water_l" if k == "water" else "lost_" + String(k)
			World.pools[pool] = float(World.pools.get(pool, 0.0)) + float(c[k])


static func compute() -> Dictionary:
	var L := empty()
	var t := World.terrain
	var pools := World.pools
	L["water"] += t.total_soil_water_l() + float(World.env.get("pond_l", 0.0)) + float(pools.get("atmo_water_l", 0.0)) \
		+ float(pools.get("plant_water_l", 0.0)) + float(pools.get("porridge_water_l", 0.0)) + float(pools.get("lost_water_l", 0.0))
	L["clay"] += t.total_clay_l() + float(pools.get("clay_spilled_l", 0.0)) + float(pools.get("lost_clay", 0.0))
	L["soil"] += t.total_soil_l() + float(pools.get("lost_soil", 0.0))
	L["nutr"] += t.total_nutrients() + float(pools.get("grass_nutr", 0.0)) + float(pools.get("tree_nutr", 0.0)) + float(pools.get("lost_nutr", 0.0))
	var grass_kg := 0.0
	for k in t.grass.size():
		if t.inside[k]:
			grass_kg += t.grass[k]
	L["carbon"] += float(pools.get("atmo_carbon_kg", 0.0)) + float(pools.get("soil_organic_kg", 0.0)) \
		+ float(pools.get("soil_mineral_kg", 0.0)) + float(pools.get("lost_carbon", 0.0)) + grass_kg * PlantSim.GRASS_KG
	L["stone"] += float(pools.get("debris_stone_kg", 0.0)) + float(pools.get("lost_stone", 0.0))
	for e in World.entities.values():
		_add(L, entity_contrib(e))
	for pid in World.inventories:
		for s in World.inventories[pid].slots:
			if not s.is_empty():
				_add(L, item_contrib(String(s["i"]), int(s["n"]), s["d"]))
	for pid in World.stats:
		_add(L, body_contrib(World.stats[pid]))
	for nm in World.player_saves:
		var online := false
		for pid in Net.players:
			if Net.player_name(pid) == nm:
				online = true
		if online:
			continue
		var rec: Dictionary = World.player_saves[nm]
		for s in rec.get("inv", []):
			if s is Dictionary and not s.is_empty():
				_add(L, item_contrib(String(s["i"]), int(s["n"]), s["d"]))
		_add(L, body_contrib(rec.get("stats", {})))
	return L


static func body_contrib(st: Dictionary) -> Dictionary:
	var out := empty()
	out["water"] = float(st.get("body_water_l", 0.0))
	out["nutr"] = float(st.get("waste_nutr", 0.0))
	out["carbon"] = float(st.get("scrap_carbon", 0.0))
	out["soil"] = float(st.get("dig_soil", 0.0))
	out["clay"] = float(st.get("dig_clay", 0.0))
	return out


static func entity_contrib(e: Dictionary) -> Dictionary:
	var out := empty()
	var d: Dictionary = e["d"]
	match String(e["t"]):
		"item":
			out = item_contrib(String(d.get("i", "")), int(d.get("n", 1)), d.get("x", {}))
		"tree":
			out["carbon"] = TreeSim.biomass(d)
		"plant":
			out["carbon"] = float(d.get("bio", 0.0))
			out["nutr"] = float(d.get("nutr", 0.0))
		"bush":
			out["carbon"] = float(d.get("berries", 0.0)) * 6.0 * ItemDB.unit_mass("berries")
			out["nutr"] = float(d.get("berries", 0.0)) * 6.0 * ItemDB.nutrients("berries")
		"mushrooms":
			var caps := 0.0
			for c in d.get("caps", []):
				caps += float(c)
			out["carbon"] = float(d.get("substrate", 0.0)) + caps * ItemDB.unit_mass("mushroom")
			out["nutr"] = float(d.get("nutr", 0.0)) + caps * ItemDB.nutrients("mushroom")
		"outcrop":
			var n := 0
			for l in d.get("loose", []):
				n += int(l)
			out["stone"] = n * ItemDB.unit_mass("stone")
		"satchel":
			for s in d.get("items", []):
				_add(out, item_contrib(String(s["i"]), int(s["n"]), s["d"]))
		"work":
			out = WorkLedger.contrib(d)
		"site":
			out["soil"] = float(d.get("shell_l", 0.0))
			out["nutr"] = float(d.get("ash_n", 0.0))
			out["carbon"] = float(d.get("ash_c", 0.0))
		"structure":
			var parts: Array = ItemDB.blueprint(String(d.get("bp", ""))).get("parts", [])
			var used_arr: Array = d.get("used", [])
			for i in int(d.get("installed", 0)):
				if i < parts.size():
					var used := String(used_arr[i]) if i < used_arr.size() else String(parts[i]).get_slice("|", 0)
					_add(out, item_contrib(used, 1, {}))
			for s in d.get("store", []):
				if s is Dictionary and not s.is_empty():
					_add(out, item_contrib(String(s["i"]), int(s["n"]), s["d"]))
		"compost":
			out["carbon"] = CompostSim.mass(d)
			out["nutr"] = float(d.get("nu", 0.0))
			out["water"] = float(d.get("w", 0.0))
	return out


static func format(L: Dictionary) -> String:
	return "water %.1f L | carbon %.2f kg | nutrients %.4f | clay %.2f L | soil %.1f L | stone %.2f kg" % [
		L["water"], L["carbon"], L["nutr"], L["clay"], L["soil"], L["stone"]]
