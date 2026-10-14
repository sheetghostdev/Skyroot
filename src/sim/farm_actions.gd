class_name FarmActions
extends RefCounted
## Planting and harvesting.  Harvests are budgeted against what the plant
## actually absorbed: items can never contain more biomass or nutrients than
## grew; the remainder returns to the soil.


static func plant(a: Actions, pid: int, args: Dictionary) -> void:
	var pos: Vector3 = args.get("pos", Vector3.ZERO)
	var id := a.held_id(pid, args)
	var sp := String(ItemDB.def(id).get("plant", ""))
	if sp == "" or not a.in_reach(pid, args, pos):
		return
	var k := a.cell_index_at(pos)
	if sp != "tree" and World.terrain.tilled[k] != 1:
		World.notify(pid, "Till the soil first.")
		return
	if World.terrain.soil[k] < 0.05:
		World.notify(pid, "The soil is too thin here.")
		return
	var spacing := 0.38 if sp != "tree" else 2.5
	for e in World.entities_near(pos, spacing):
		if e["t"] == "plant" or (e["t"] == "tree"):
			World.notify(pid, "Too close to another plant - give it room to grow.")
			return
	a.take_held(pid, args, 1)
	var y := World.terrain.height(pos.x, pos.z)
	if sp == "tree":
		var d := TreeSim.seedling_state()
		World.spawn("tree", Transform3D(Basis(Vector3.UP, randf() * TAU), Vector3(pos.x, y, pos.z)), d)
		World.hint_to(pid, "tree_planted")
	else:
		World.spawn("plant", Transform3D(Basis(Vector3.UP, randf() * TAU), Vector3(pos.x, y - 0.01, pos.z)),
			{"sp": sp, "g": 0.0, "nutr": ItemDB.nutrients(id), "bio": ItemDB.unit_mass(id), "vig": 1.0})
	World.fx("soil_place", pos, {"amount": 4, "vol": -6.0})
	World.discover("first_planting", pid)


static func budget_yields(spec: Dictionary, vigor: float, bio: float, nutr: float, rng: RandomNumberGenerator) -> Dictionary:
	## Choose counts for each output within [min,max], scaled by vigour, then
	## trim until mass and nutrients fit what the plant actually holds.
	var out := {}
	for id in spec:
		var r: Array = spec[id]
		var lo := int(r[0])
		var hi := int(r[1])
		var n := int(round(lerpf(lo, hi, clampf(vigor, 0.0, 1.0) * 0.8 + rng.randf() * 0.2)))
		out[id] = clampi(n, 0, hi)
	for guard in 40:
		var m := 0.0
		var nu := 0.0
		for id in out:
			m += ItemDB.unit_mass(id) * int(out[id])
			nu += ItemDB.nutrients(id) * int(out[id])
		if m <= bio + 1e-6 and nu <= nutr + 1e-7:
			break
		# drop one of the most expensive item
		var best := ""
		var best_v := -1.0
		for id in out:
			if int(out[id]) > 0:
				var v := ItemDB.unit_mass(id) / maxf(bio, 1e-6) + ItemDB.nutrients(id) / maxf(nutr, 1e-9)
				if v > best_v:
					best_v = v
					best = id
		if best == "":
			break
		out[best] = int(out[best]) - 1
	return out


static func harvest(a: Actions, pid: int, args: Dictionary) -> void:
	var eid := int(args.get("eid", -1))
	var ent := World.get_entity(eid)
	if ent.is_empty() or ent["t"] != "plant":
		return
	if not a.in_reach(pid, args, ent["xf"].origin + Vector3(0, 0.3, 0), 0.4):
		return
	var d: Dictionary = ent["d"]
	if float(d.get("g", 0.0)) < 1.0:
		World.notify(pid, "Not ready yet.")
		return
	var sp := String(d["sp"])
	var info := ItemDB.plant(sp)
	var rng := RandomNumberGenerator.new()
	rng.seed = eid * 31 + int(World.hours() * 10.0)
	var bio := float(d.get("bio", 0.0))
	var nutr := float(d.get("nutr", 0.0))
	var perennial := bool(d.get("perennial", false))
	# a perennial keeps a share of itself (roots) to regrow from
	var keep := 0.3 if perennial else 0.0
	var spec: Dictionary = info.get("harvest", {}).duplicate()
	for rid in info.get("residue", {}):
		spec[rid] = [int(info["residue"][rid]), int(info["residue"][rid])]
	var yields := budget_yields(spec, float(d.get("vig", 1.0)), bio * (1.0 - keep), nutr * (1.0 - keep), rng)
	var used_m := 0.0
	var used_n := 0.0
	var pos: Vector3 = ent["xf"].origin
	for id in yields:
		var n := int(yields[id])
		if n <= 0:
			continue
		used_m += ItemDB.unit_mass(id) * n
		used_n += ItemDB.nutrients(id) * n
		var dd := {}
		if ItemDB.default_moist(id) > 0.0:
			dd = {"moist": ItemDB.default_moist(id)}
		a.give(pid, id, n, dd, pos)
	var cells := World.terrain.cells_in_radius(Vector2(pos.x, pos.z), 0.35)
	if perennial:
		World.update(eid, {"g": 0.3, "bio": bio - used_m, "nutr": nutr - used_n, "vig": 1.0})
	else:
		# roots and stubble rot back into the soil
		World.pools["soil_organic_kg"] = float(World.pools.get("soil_organic_kg", 0.0)) + maxf(0.0, bio - used_m)
		var left := maxf(0.0, nutr - used_n)
		for k in cells:
			World.terrain.nutr[k] += left / maxf(1.0, cells.size())
		World.despawn(eid)
	World.fx("harvest", pos + Vector3(0, 0.2, 0))
	World.discover("harvest_" + sp, pid)
