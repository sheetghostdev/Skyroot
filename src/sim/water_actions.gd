class_name WaterActions
extends RefCounted
## Drinking, filling and pouring.  Every litre comes from somewhere and goes somewhere.

const HAND_SIP := 0.18
const POUR := 0.25
const PORRIDGE_SEEDS := 4        # grains of seed in a portion
const PORRIDGE_WATER := 0.12     # litres of water a portion soaks up


static func _near_pond(a: Actions, pid: int) -> bool:
	var p := a.player_pos(pid)
	return World.terrain.pond_q(Vector2(p.x, p.z)) < 1.9


static func drink_pond(a: Actions, pid: int, args: Dictionary) -> void:
	if not _near_pond(a, pid):
		return
	var pond := float(World.env.get("pond_l", 0.0))
	if pond < 1.0:
		World.notify(pid, "The pond is nearly dry.", "warn")
		return
	var drunk := Survival.drink(pid, minf(HAND_SIP, pond))
	if drunk <= 0.001:
		World.notify(pid, "You're not thirsty.")
		return
	World.env["pond_l"] = pond - drunk
	World.fx("drink", a.player_pos(pid) + Vector3(0, 1.5, 0))
	World.hint_to(pid, "water_first")


static func fill_vessel(a: Actions, pid: int, args: Dictionary) -> void:
	if not _near_pond(a, pid):
		return
	var s := a.held(pid, args)
	if String(s.get("i", "")) != "pot":
		return
	var d: Dictionary = s["d"].duplicate(true)
	if String(d.get("state", "")) != "fired":
		return
	var cap := Pottery.capacity(d)
	var room := cap - float(d.get("water", 0.0))
	var pond := float(World.env.get("pond_l", 0.0))
	var take := clampf(room, 0.0, pond - 0.5)
	if take <= 0.001:
		return
	d["water"] = float(d.get("water", 0.0)) + take
	World.env["pond_l"] = pond - take
	World.inventory_of(pid).set_data(int(args["slot"]), d)
	World.mark_inventory(pid)
	World.fx("pour", a.player_pos(pid) + Vector3(0, 0.8, 0))
	World.discover("first_water_vessel", pid)


static func drink_vessel(a: Actions, pid: int, args: Dictionary) -> void:
	var s := a.held(pid, args)
	if String(s.get("i", "")) != "pot":
		return
	var d: Dictionary = s["d"].duplicate(true)
	var w := float(d.get("water", 0.0))
	var drunk := Survival.drink(pid, minf(w, 0.4))
	if drunk <= 0.001:
		World.notify(pid, "You're not thirsty.")
		return
	d["water"] = w - drunk
	World.inventory_of(pid).set_data(int(args["slot"]), d)
	World.mark_inventory(pid)
	World.fx("drink", a.player_pos(pid) + Vector3(0, 1.5, 0))


static func drink_entity(a: Actions, pid: int, args: Dictionary) -> void:
	var eid := int(args.get("eid", -1))
	var ent := World.get_entity(eid)
	if ent.is_empty() or ent["t"] != "item" or String(ent["d"].get("i", "")) != "pot":
		return
	if not a.in_reach(pid, args, ent["xf"].origin):
		return
	var x: Dictionary = ent["d"]["x"].duplicate(true)
	var w := float(x.get("water", 0.0))
	var drunk := Survival.drink(pid, minf(w, 0.4))
	if drunk <= 0.001:
		return
	x["water"] = w - drunk
	World.update(eid, {"x": x})
	World.fx("drink", ent["xf"].origin)


static func eat_vessel(a: Actions, pid: int, args: Dictionary) -> void:
	var s := a.held(pid, args)
	if String(s.get("i", "")) != "pot":
		return
	var d: Dictionary = s["d"].duplicate(true)
	var cont: Dictionary = d.get("contents", {}).duplicate()
	if int(cont.get("porridge", 0)) <= 0:
		return
	cont["porridge"] = int(cont["porridge"]) - 1
	if int(cont["porridge"]) <= 0:
		cont.erase("porridge")
	d["contents"] = cont
	World.inventory_of(pid).set_data(int(args["slot"]), d)
	World.mark_inventory(pid)
	# a portion of porridge = grain cooked in water: food plus a little water
	Survival.eat(pid, "seed_grain", {"hunger": 0.12, "raw": false}, PORRIDGE_SEEDS)
	var water := minf(PORRIDGE_WATER, float(World.pools.get("porridge_water_l", 0.0)))
	World.pools["porridge_water_l"] = float(World.pools.get("porridge_water_l", 0.0)) - water
	var drunk := Survival.drink(pid, water)
	World.pools["atmo_water_l"] = float(World.pools.get("atmo_water_l", 0.0)) + (water - drunk)
	World.fx("eat", a.player_pos(pid) + Vector3(0, 1.5, 0))


static func pot_add(a: Actions, pid: int, args: Dictionary) -> void:
	## Put grain into a fired pot that's standing somewhere.
	var eid := int(args.get("eid", -1))
	var ent := World.get_entity(eid)
	if ent.is_empty() or ent["t"] != "item" or String(ent["d"].get("i", "")) != "pot":
		return
	if not a.in_reach(pid, args, ent["xf"].origin):
		return
	var s := a.held(pid, args)
	if String(s.get("i", "")) != "seed_grain":
		return
	var x: Dictionary = ent["d"]["x"].duplicate(true)
	if String(x.get("state", "")) != "fired":
		World.notify(pid, "Only a fired pot can hold food and water.")
		return
	var cont: Dictionary = x.get("contents", {})
	var have := int(cont.get("seed_grain", 0))
	var room := int(Pottery.capacity(x) / 0.03) - have - int(cont.get("porridge", 0)) * PORRIDGE_SEEDS
	var n := mini(mini(int(s["n"]), PORRIDGE_SEEDS), room)
	if n <= 0:
		World.notify(pid, "The pot is full.")
		return
	a.take_held(pid, args, n)
	cont["seed_grain"] = have + n
	x["contents"] = cont
	World.update(eid, {"x": x})
	World.fx("pickup", ent["xf"].origin)


static func pour(a: Actions, pid: int, args: Dictionary) -> void:
	var s := a.held(pid, args)
	if String(s.get("i", "")) != "pot":
		return
	var pos: Vector3 = args.get("pos", Vector3.ZERO)
	if not a.in_reach(pid, args, pos, 0.5):
		return
	var d: Dictionary = s["d"].duplicate(true)
	var w := float(d.get("water", 0.0))
	var amount := minf(w, POUR)
	if amount <= 0.0:
		return
	d["water"] = w - amount
	World.inventory_of(pid).set_data(int(args["slot"]), d)
	World.mark_inventory(pid)
	var eid := int(args.get("eid", -1))
	if eid >= 0 and World.has_entity(eid) and World.get_entity(eid)["t"] == "site":
		ActionsFire.douse(eid, amount)
	elif not World.terrain.is_inside(pos.x, pos.z):
		World.pools["lost_water_l"] = float(World.pools.get("lost_water_l", 0.0)) + amount
		World.notify(pid, "The water drips away into the abyss.")
	else:
		soak(pos, amount, 0.45)
	World.fx("pour", pos)
	World.hint_to(pid, "watering")


static func soak(pos: Vector3, litres: float, radius: float) -> void:
	## Put water into the soil around pos; whatever can't soak in spreads wider,
	## and anything left over trickles into the pond.
	var t := World.terrain
	var cl := WaterSim.cell_l()
	var left := litres
	var r := radius
	for ring in 4:
		var cells := t.cells_in_radius(Vector2(pos.x, pos.z), r)
		var land: Array = []
		for k in cells:
			if not t.is_pond_cell(k):
				land.append(k)
		if land.is_empty():
			break
		var per := left / land.size()
		var used := 0.0
		for k in land:
			var room := (1.0 - t.moist[k]) * cl
			var add := minf(per, room)
			t.moist[k] += add / cl
			used += add
		left -= used
		if left <= 0.0001:
			left = 0.0
			break
		r *= 1.8
	if left > 0.0:
		World.env["pond_l"] = float(World.env.get("pond_l", 0.0)) + left
	World.terrain_edited(Rect2i(TerrainData.cell_at(Vector2(pos.x, pos.z)) - Vector2i(4, 4), Vector2i(9, 9)))
