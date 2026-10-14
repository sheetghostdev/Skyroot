class_name ActionsCompost
extends RefCounted
## Host handlers for compost heaps: start one, add to it, turn it, water it
## (see WaterActions.pour), take finished compost, or spread the lot.


static func register(a: Actions) -> void:
	for nm in ["compost_start", "compost_add", "compost_turn", "compost_take", "compost_spread"]:
		a.register(nm, Callable(ActionsCompost, "_" + nm).bind(a))


static func _heap(a: Actions, pid: int, args: Dictionary) -> Dictionary:
	var e := World.get_entity(int(args.get("eid", -1)))
	if e.is_empty() or e["t"] != "compost" or not a.in_reach(pid, args, e["xf"].origin + Vector3(0, 0.3, 0), 0.5):
		return {}
	return e


static func _put(d: Dictionary, id: String, x: Dictionary) -> Dictionary:
	## The heap's data with one unit of `id` mixed in.
	var kind := CompostSim.kind_of(id)
	var m := ItemDB.unit_mass(id)
	var moist := float(x.get("moist", ItemDB.default_moist(id)))
	if not x.has("moist") and ItemDB.default_moist(id) <= 0.0:
		moist = CompostSim.GREEN_MOIST if kind == "green" else CompostSim.BROWN_MOIST
	var key := "g" if kind == "green" else "b"
	var out := {}
	out[key] = float(d.get(key, 0.0)) + m
	out[key + "w"] = float(d.get(key + "w", 0.0)) + m * clampf(moist, 0.0, 0.9)
	out["nu"] = float(d.get("nu", 0.0)) + ItemDB.nutrients(id)
	return out


static func _compost_start(pid: int, args: Dictionary, a: Actions) -> void:
	var pos: Vector3 = args.get("pos", Vector3.ZERO)
	var s := a.held(pid, args)
	var id := String(s.get("i", ""))
	if not CompostSim.is_compostable(id) or s["d"].has("fm") or not a.in_reach(pid, args, pos):
		return
	var t := World.terrain
	if not t.is_inside(pos.x, pos.z) or t.layer_at(pos.x, pos.z) in ["rock", "water"]:
		World.notify(pid, "A heap needs bare earth beneath it.")
		return
	for e in World.entities_near(pos, 2.0):
		var et := String(e["t"])
		var dd: float = e["xf"].origin.distance_to(pos)
		if et == "compost" and dd < CompostSim.SPACING:
			World.notify(pid, "There's a heap right here - add to that one.")
			return
		if et in ["tree", "outcrop", "boulder", "flat_stone", "site", "plant"] and dd < 0.9:
			World.notify(pid, "Not enough room for a heap here.")
			return
	var taken := a.take_held(pid, args, 1)
	if taken.is_empty():
		return
	var d := {"g": 0.0, "b": 0.0, "gw": 0.0, "bw": 0.0, "hu": 0.0, "nu": 0.0, "w": 0.0, "air": 1.0,
		"T": snappedf(Climate.base_temp(), 0.01), "act": 0.0, "by": Net.player_name(pid)}
	d.merge(_put(d, id, taken["d"]), true)
	var y := t.height(pos.x, pos.z)
	World.spawn("compost", Transform3D(Basis(Vector3.UP, randf() * TAU), Vector3(pos.x, y, pos.z)), d)
	World.fx("leaves", pos, {"amount": 6})
	World.hint_to(pid, "compost_started")


static func _compost_add(pid: int, args: Dictionary, a: Actions) -> void:
	var e := _heap(a, pid, args)
	if e.is_empty():
		return
	var s := a.held(pid, args)
	var id := String(s.get("i", ""))
	if not CompostSim.is_compostable(id) or s["d"].has("fm"):
		return
	var taken := a.take_held(pid, args, 1)
	if taken.is_empty():
		return
	World.update(int(e["id"]), _put(e["d"], id, taken["d"]))
	World.fx("leaves", e["xf"].origin + Vector3(0, 0.35, 0), {"amount": 4, "vol": -8.0})


static func _compost_turn(pid: int, args: Dictionary, a: Actions) -> void:
	## One forkful: air back in, a little of the heat out.
	var e := _heap(a, pid, args)
	if e.is_empty():
		return
	var s := a.held(pid, args)
	var id := String(s.get("i", ""))
	var tool := ItemDB.tool_kind(id)
	if not (id == "" or id == "stick" or tool == "dig"):
		return
	var d: Dictionary = e["d"]
	var gain := CompostSim.TURN_AIR_TOOL if tool == "dig" else CompostSim.TURN_AIR_HANDS
	World.update(int(e["id"]), {"air": minf(1.0, float(d.get("air", 1.0)) + gain),
		"T": snappedf(float(d.get("T", 15.0)) - 2.0, 0.01), "turned": int(d.get("turned", 0)) + 1})
	World.fx("dust", e["xf"].origin + Vector3(0, 0.3, 0), {"sound": "compost_turn", "amount": 8})
	if float(d.get("T", 0.0)) > 38.0:
		World.fx("smoke_puff", e["xf"].origin + Vector3(0, 0.5, 0), {"amount": 5})
	a.exert(pid, 0.02)
	if tool == "dig":
		Tools.wear(pid, args, 0.002)


static func _compost_take(pid: int, args: Dictionary, a: Actions) -> void:
	var e := _heap(a, pid, args)
	if e.is_empty():
		return
	var d: Dictionary = e["d"]
	if CompostSim.ready_count(d) < 1:
		World.notify(pid, "No finished compost yet.")
		return
	var eid := int(e["id"])
	World.update(eid, {"hu": float(d["hu"]) - CompostSim.unit_kg(), "nu": float(d["nu"]) - CompostSim.unit_nutr()})
	a.give(pid, "compost", 1, {}, e["xf"].origin)
	World.fx("dust", e["xf"].origin + Vector3(0, 0.3, 0), {"sound": "dig_soil", "amount": 5})
	World.discover("first_compost", pid)
	var left: Dictionary = World.get_entity(eid)["d"]
	if CompostSim.mass(left) < 0.02:
		_spread(eid)


static func _compost_spread(pid: int, args: Dictionary, a: Actions) -> void:
	var e := _heap(a, pid, args)
	if e.is_empty() or a.held_id(pid, args) != "":
		return
	World.fx("dust", e["xf"].origin + Vector3(0, 0.2, 0), {"sound": "dig_soil", "amount": 10})
	a.exert(pid, 0.03)
	_spread(int(e["id"]))


static func _spread(eid: int) -> void:
	## Everything left goes into the soil beneath: organic matter, nutrients and water.
	var e := World.get_entity(eid)
	if e.is_empty():
		return
	var d: Dictionary = e["d"]
	var pos: Vector3 = e["xf"].origin
	World.pools["soil_organic_kg"] = float(World.pools.get("soil_organic_kg", 0.0)) + CompostSim.mass(d)
	var cells := World.terrain.cells_in_radius(Vector2(pos.x, pos.z), 0.6)
	if cells.is_empty():
		cells = PackedInt32Array([TerrainData.cell_index(TerrainData.cell_at(Vector2(pos.x, pos.z)).x, TerrainData.cell_at(Vector2(pos.x, pos.z)).y)])
	var nu := float(d.get("nu", 0.0))
	for k in cells:
		World.terrain.nutr[k] += nu / cells.size()
	var w := float(d.get("w", 0.0))
	World.despawn(eid)
	if w > 0.0:
		WaterActions.soak(pos, w, 0.5)
	World.terrain_edited(Rect2i(TerrainData.cell_at(Vector2(pos.x, pos.z)) - Vector2i(3, 3), Vector2i(7, 7)))
