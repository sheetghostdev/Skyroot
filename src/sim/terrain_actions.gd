class_name TerrainActions
extends RefCounted
## Digging, filling, tilling and fertilising the island's ground.

const EARTH_L := 4.0
const CLAY_L := 0.25


static func _blocked(a: Actions, pos: Vector3) -> String:
	var p2 := Vector2(pos.x, pos.z)
	if not World.terrain.is_inside(pos.x, pos.z) or World.terrain.edge_factor(p2) > 0.97:
		return "Too close to the edge - the ground would crumble away."
	if World.terrain.in_pond(p2) and pos.y < float(Game.game_world.island.water_level()) + 0.05:
		return "You can't dig underwater."
	for e in World.entities_near(pos, 1.6):
		var t := String(e["t"])
		var r: float = {"tree": 0.95, "outcrop": 1.45, "flat_stone": 0.75, "boulder": 0.75, "mossy_log": 0.7, "structure": 1.1, "bush": 0.6}.get(t, 0.0)
		if t == "tree" and bool(e["d"].get("from_seed", false)):
			r = 0.3
		if r > 0.0 and Vector2(e["xf"].origin.x, e["xf"].origin.z).distance_to(p2) < r:
			match t:
				"tree": return "The roots are too dense here."
				"structure": return "Something is built here."
				_: return "There's rock in the way."
	return ""


static func put_earth(center: Vector3, litres: float) -> void:
	## Loose earth goes down on the ground here (spreading a little further when
	## it's right at the edge); with no island under it, it falls into the abyss
	## - still on the books.
	if litres <= 1e-9:
		return
	var c := Vector2(center.x, center.z)
	for r in [0.3, 0.6, 1.0]:
		if not World.terrain.cells_in_radius(c, r).is_empty():
			World.terrain_edited(World.terrain.fill(c, r, litres))
			return
	World.pools["lost_soil"] = float(World.pools.get("lost_soil", 0.0)) + litres


static func add_nutrients(center: Vector3, amount: float, radius: float = 0.4) -> void:
	## Minerals set free here soak into the soil around it (or, with no island
	## under it - a deck out over the abyss - they're lost over the edge).
	if amount == 0.0:
		return
	var c := Vector2(center.x, center.z)
	for r in [radius, radius * 2.0 + 0.4]:
		var cells := World.terrain.cells_in_radius(c, r)
		if not cells.is_empty():
			for k in cells:
				World.terrain.nutr[k] += amount / cells.size()
			return
	World.pools["lost_nutr"] = float(World.pools.get("lost_nutr", 0.0)) + amount


static func remove_grass(cells: PackedInt32Array, amount: float) -> void:
	## Grass torn up is not lost: its carbon and nutrients go back into the soil.
	var t := World.terrain
	for k in cells:
		var g := t.grass[k]
		if g <= 0.0:
			continue
		var take := minf(g, amount)
		t.grass[k] = g - take
		World.pools["soil_organic_kg"] = float(World.pools.get("soil_organic_kg", 0.0)) + take * PlantSim.GRASS_KG
		var nu := take * PlantSim.GRASS_NUTR
		t.nutr[k] += nu
		World.pools["grass_nutr"] = float(World.pools.get("grass_nutr", 0.0)) - nu


static func dig(a: Actions, pid: int, args: Dictionary) -> void:
	var pos: Vector3 = args.get("pos", Vector3.ZERO)
	if not a.in_reach(pid, args, pos):
		return
	var why := _blocked(a, pos)
	if why != "":
		World.notify(pid, why)
		return
	var hands := ItemDB.tool_kind(a.held_id(pid, args)) != "dig"
	var layer := World.terrain.layer_at(pos.x, pos.z)
	if layer == "rock":
		World.notify(pid, "Bedrock. Nothing to dig.")
		return
	var power := 1.0 if hands else Tools.power(a.held(pid, args))
	var vol := (1.0 if layer == "soil" else 0.45) if hands else (3.2 if layer == "soil" else 1.3) * power
	var st := a.stats(pid)
	var cells := World.terrain.cells_in_radius(Vector2(pos.x, pos.z), 0.3)
	remove_grass(cells, 0.5)
	var res := World.terrain.dig(Vector2(pos.x, pos.z), 0.3, vol, "clay")
	var torn: Dictionary = res["torn"]
	for k in torn:
		remove_grass(PackedInt32Array([int(k)]), float(torn[k]))
	if float(res["soil"]) + float(res["clay"]) <= 0.001:
		World.notify(pid, "Nothing more comes up here - you've hit rock.")
		return
	st["dig_soil"] = float(st.get("dig_soil", 0.0)) + float(res["soil"])
	st["dig_clay"] = float(st.get("dig_clay", 0.0)) + float(res["clay"])
	var earth := int(floor(float(st["dig_soil"]) / EARTH_L))
	if earth > 0:
		st["dig_soil"] = float(st["dig_soil"]) - earth * EARTH_L
		a.give(pid, "earth", earth)
	var clay := int(floor(float(st["dig_clay"]) / CLAY_L))
	if clay > 0:
		st["dig_clay"] = float(st["dig_clay"]) - clay * CLAY_L
		# raw clay carries water drawn from the ground it came from
		var want := clay * CLAY_L * 0.17
		var got := _take_soil_water(cells, want)
		var moist := got / maxf(0.0001, clay * CLAY_L)
		a.give(pid, "clay", clay, {"moist": moist})
		World.hint_to(pid, "clay_found")
	World.terrain_edited(res["rect"])
	World.fx("clay_dig" if float(res["clay"]) > float(res["soil"]) else "dust", pos)
	a.exert(pid, 0.035 if hands else 0.025)
	if not hands:
		Tools.wear(pid, args, 0.004)
	World.mark_stats(pid)
	ActionsFire.on_terrain_dug(pos)


static func _take_soil_water(cells: PackedInt32Array, litres: float) -> float:
	var t := World.terrain
	var cl := WaterSim.cell_l()
	var got := 0.0
	for k in cells:
		if got >= litres:
			break
		var avail := maxf(0.0, t.moist[k] - 0.05) * cl
		var take := minf(avail, litres - got)
		t.moist[k] -= take / cl
		got += take
	return got


static func fill(a: Actions, pid: int, args: Dictionary) -> void:
	var pos: Vector3 = args.get("pos", Vector3.ZERO)
	if not a.in_reach(pid, args, pos) or a.held_id(pid, args) != "earth":
		return
	if World.terrain.in_pond(Vector2(pos.x, pos.z)):
		World.notify(pid, "It would just turn to mud in the water.")
		return
	if not World.terrain.is_inside(pos.x, pos.z):
		return
	a.take_held(pid, args, 1)
	put_earth(pos, EARTH_L)
	World.fx("soil_place", pos)


static func till(a: Actions, pid: int, args: Dictionary) -> void:
	var pos: Vector3 = args.get("pos", Vector3.ZERO)
	if not a.in_reach(pid, args, pos) or ItemDB.tool_kind(a.held_id(pid, args)) != "dig":
		return
	var why := _blocked(a, pos)
	if why != "":
		World.notify(pid, why)
		return
	var cells := World.terrain.cells_in_radius(Vector2(pos.x, pos.z), 0.36)
	var any := false
	for k in cells:
		if World.terrain.soil[k] >= 0.06 and World.terrain.tilled[k] == 0:
			World.terrain.tilled[k] = 1
			any = true
	if not any:
		World.notify(pid, "The soil here is too thin or already tilled.")
		return
	remove_grass(cells, 1.0)
	World.terrain_edited(Rect2i(TerrainData.cell_at(Vector2(pos.x, pos.z)) - Vector2i(3, 3), Vector2i(7, 7)))
	World.fx("dust", pos)
	a.exert(pid, 0.03)
	Tools.wear(pid, args, 0.004)
	World.hint_to(pid, "tilled")


static func fertilize(a: Actions, pid: int, args: Dictionary) -> void:
	var pos: Vector3 = args.get("pos", Vector3.ZERO)
	var id := a.held_id(pid, args)
	if not a.in_reach(pid, args, pos) or not (id == "compost" or id == "ash"):
		return
	var cells := World.terrain.cells_in_radius(Vector2(pos.x, pos.z), 0.55)
	if cells.is_empty():
		return
	a.take_held(pid, args, 1)
	var nutr := ItemDB.nutrients(id)
	for k in cells:
		World.terrain.nutr[k] += nutr / cells.size()
	if id == "compost":
		World.pools["soil_organic_kg"] = float(World.pools.get("soil_organic_kg", 0.0)) + ItemDB.unit_mass("compost")
	else:
		World.pools["soil_mineral_kg"] = float(World.pools.get("soil_mineral_kg", 0.0)) + ItemDB.unit_mass("ash")
	World.terrain_edited(Rect2i(TerrainData.cell_at(Vector2(pos.x, pos.z)) - Vector2i(3, 3), Vector2i(7, 7)))
	World.fx("soil_place", pos)
