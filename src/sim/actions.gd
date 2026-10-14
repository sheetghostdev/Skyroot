class_name Actions
extends Node
## Host-only: validates and executes every request from every player
## (including the host's own).  Because only this code mutates the world and
## each request re-checks the current state (does the item still exist? is it
## in the slot the client claims? is it within reach?), simultaneous requests
## can't duplicate anything: the second one simply fails.

const REACH := 3.0          # generous server-side reach (client uses 2.6)
const PICKUP_STACK := true

var handlers: Dictionary = {}
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	_rng.randomize()
	for nm in ["pickup", "drop", "place", "outcrop_take", "pick_mushroom", "pick_berries", "eat", "drink_pond",
			"drink_vessel", "drink_entity", "fill_vessel", "eat_vessel", "hurt", "fell", "exert", "guide_state", "dig", "fill",
			"till", "cut_grass", "tree_cut", "tree_chop_limb", "tree_fell", "process", "process_held", "harvest", "plant",
			"fertilize", "pour", "inv_move", "inv_split", "inv_drop_slot", "respawn", "satchel_take", "split", "chat_cmd"]:
		handlers[nm] = Callable(self, "_a_" + nm)
	ActionsCraft.register(self)
	ActionsFire.register(self)
	ActionsBuild.register(self)


func register(nm: String, cb: Callable) -> void:
	handlers[nm] = cb


func handle(pid: int, action: String, args: Dictionary) -> void:
	if not handlers.has(action):
		push_warning("Unknown action " + action)
		return
	if not Net.players.has(pid):
		return
	var alive: bool = World.stats.get(pid, {}).get("alive", true)
	if not alive and not action in ["respawn", "guide_state", "fell", "inv_move", "inv_split"]:
		return
	handlers[action].call(pid, args)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func player_pos(pid: int) -> Vector3:
	var gw = Game.game_world
	if gw and gw.players:
		return gw.players.player_pos(pid)
	return Net.poses.get(pid, {}).get("p", Vector3.ZERO)


func eye(pid: int, args: Dictionary) -> Vector3:
	var p := player_pos(pid)
	var e: Vector3 = args.get("eye", p + Vector3(0, 1.6, 0))
	if e.distance_to(p + Vector3(0, 1.3, 0)) > 1.2:
		e = p + Vector3(0, 1.55, 0)
	return e


func in_reach(pid: int, args: Dictionary, point: Vector3, extra: float = 0.0) -> bool:
	return eye(pid, args).distance_to(point) <= REACH + extra


func inv(pid: int) -> Inventory:
	return World.inventory_of(pid)


func held(pid: int, args: Dictionary) -> Dictionary:
	return inv(pid).get_slot(int(args.get("slot", -1)))


func held_id(pid: int, args: Dictionary) -> String:
	return String(held(pid, args).get("i", ""))


func give(pid: int, id: String, n: int, d: Dictionary = {}, near: Vector3 = Vector3.INF) -> void:
	## Add to inventory; anything that doesn't fit is dropped at the player's feet.
	var left := inv(pid).add(id, n, d)
	World.mark_inventory(pid)
	if left > 0:
		var p := near if near != Vector3.INF else player_pos(pid)
		spawn_item(id, left, d, p + Vector3(0, 0.4, 0))
		World.notify(pid, "Your hands are full - dropped %s." % ItemDB.display_name(id, d).to_lower())
	_first_touch(pid, id)


func _first_touch(pid: int, id: String) -> void:
	World.hint_to(pid, "item:" + id)


func take_held(pid: int, args: Dictionary, n: int = 1) -> Dictionary:
	var slot := int(args.get("slot", -1))
	var s := inv(pid).take_from(slot, n)
	World.mark_inventory(pid)
	return s


func spawn_item(id: String, n: int, d: Dictionary, pos: Vector3, yaw: float = -1.0) -> int:
	## Drop an item into the world; it settles on whatever is beneath it.
	var rest := settle_point(pos)
	if rest == Vector3.INF:
		lose_to_abyss(id, n, d)
		World.fx("drop", pos)
		return -1
	if yaw < 0.0:
		yaw = _rng.randf() * TAU
	var lift := item_lift(id, d)
	return World.spawn("item", Transform3D(Basis(Vector3.UP, yaw), rest + Vector3(0, lift, 0)), {"i": id, "n": n, "x": d})


func item_lift(id: String, d: Dictionary) -> float:
	return float(InteractionRules._lift_cache.get(id + str(hash(d)), _compute_lift(id, d)))


func _compute_lift(id: String, d: Dictionary) -> float:
	var vis := ItemVisual.single(id, d)
	var lift := 0.02
	if vis:
		lift = -Models.aabb_of(vis).position.y + 0.004
		vis.free()
	InteractionRules._lift_cache[id + str(hash(d))] = lift
	return lift


func settle_point(pos: Vector3) -> Vector3:
	## Where something dropped at `pos` comes to rest, or INF if it falls off the island.
	var space := get_viewport().world_3d.direct_space_state
	var q := PhysicsRayQueryParameters3D.create(pos + Vector3(0, 0.3, 0), pos + Vector3(0, -60, 0),
		EntityView.LAYER_TERRAIN | EntityView.LAYER_STRUCT | EntityView.LAYER_ITEMS)
	var hit := space.intersect_ray(q)
	if hit.is_empty():
		return Vector3.INF
	var p: Vector3 = hit["position"]
	if p.y < -6.0:
		return Vector3.INF  # caught on the underside: tumbles off into the abyss
	return p


func lose_to_abyss(id: String, n: int, d: Dictionary) -> void:
	var lost: Dictionary = World.pools.get("lost_mass", {})
	lost[id] = int(lost.get(id, 0)) + n
	World.pools["lost_mass"] = lost
	if id == "pot":
		World.pools["lost_water_l"] = float(World.pools.get("lost_water_l", 0.0)) + float(d.get("water", 0.0))
	Ledger.record_loss(id, n, d)


func cell_index_at(p: Vector3) -> int:
	var c := TerrainData.cell_at(Vector2(p.x, p.z))
	return TerrainData.cell_index(c.x, c.y)


func entity_view(eid: int) -> EntityView:
	var gw = Game.game_world
	return gw.entities.view(eid) if gw and gw.entities else null


func stats(pid: int) -> Dictionary:
	return World.stats.get(pid, {})


func exert(pid: int, amount: float) -> void:
	var st := stats(pid)
	if st.is_empty():
		return
	st["stamina"] = clampf(float(st["stamina"]) - amount, 0.0, 1.0)
	World.mark_stats(pid)


# ---------------------------------------------------------------------------
# Items
# ---------------------------------------------------------------------------

func _a_pickup(pid: int, args: Dictionary) -> void:
	var eid := int(args.get("eid", -1))
	var ent := World.get_entity(eid)
	if ent.is_empty() or ent["t"] != "item":
		return
	if not in_reach(pid, args, ent["xf"].origin):
		return
	if int(ent["d"].get("site", -1)) >= 0 or ent["d"].get("x", {}).has("fm"):
		ActionsFire.prepare_pickup(eid)
		ent = World.get_entity(eid)
		if ent.is_empty():
			return
	var d: Dictionary = ent["d"]
	var id := String(d["i"])
	var n := int(d["n"])
	var x: Dictionary = d.get("x", {})
	var hot := float(d.get("heat", 20.0))
	var space := inv(pid).space_for(id, x)
	if space <= 0:
		World.notify(pid, "No room to carry that.")
		return
	var take := mini(n, space)
	if hot > 70.0:
		Survival.damage(pid, clampf((hot - 70.0) / 400.0, 0.02, 0.15), "burn")
		World.notify(pid, "Ouch - it's hot!", "warn")
	inv(pid).add(id, take, x)
	World.mark_inventory(pid)
	if take >= n:
		World.despawn(eid)
	else:
		World.update(eid, {"n": n - take})
	World.fx("pickup", ent["xf"].origin)
	_first_touch(pid, id)


func _a_drop(pid: int, args: Dictionary) -> void:
	var stack := held(pid, args)
	if stack.is_empty():
		return
	var n := clampi(int(args.get("n", 1)), 1, int(stack["n"]))
	var from: Vector3 = eye(pid, args)
	var dir: Vector3 = (args.get("dir", Vector3.FORWARD) as Vector3).normalized()
	var s := take_held(pid, args, n)
	if s.is_empty():
		return
	# a short throw: arc forward, then settle
	var land := from + Vector3(dir.x, 0, dir.z).normalized() * 1.3 + Vector3(0, -0.5, 0)
	var space := get_viewport().world_3d.direct_space_state
	var q := PhysicsRayQueryParameters3D.create(from, land, EntityView.LAYER_TERRAIN | EntityView.LAYER_STRUCT)
	var hit := space.intersect_ray(q)
	if not hit.is_empty():
		land = hit["position"] + (hit["normal"] as Vector3) * 0.05
	spawn_item(String(s["i"]), int(s["n"]), s["d"], land)


func _a_place(pid: int, args: Dictionary) -> void:
	var stack := held(pid, args)
	if stack.is_empty():
		return
	var xf: Transform3D = args.get("xf", Transform3D())
	if not in_reach(pid, args, xf.origin, 0.3):
		return
	var id := String(stack["i"])
	# placed things must rest on something solid
	var below := settle_point(xf.origin + Vector3(0, 0.05, 0))
	if below == Vector3.INF or below.y < xf.origin.y - 0.6:
		World.notify(pid, "There's nothing there to put it on.")
		return
	var s := take_held(pid, args, 1)
	if s.is_empty():
		return
	var eid := World.spawn("item", xf, {"i": id, "n": 1, "x": s["d"]})
	World.fx("drop", xf.origin, {"vol": -6.0})
	ActionsFire.on_item_placed(eid)
	if id == "pot":
		World.hint_to(pid, "drying")


func _a_inv_move(pid: int, args: Dictionary) -> void:
	inv(pid).move(int(args.get("from", -1)), int(args.get("to", -1)))
	World.mark_inventory(pid)


func _a_inv_split(pid: int, args: Dictionary) -> void:
	inv(pid).split(int(args.get("from", -1)), int(args.get("to", -1)))
	World.mark_inventory(pid)


func _a_inv_drop_slot(pid: int, args: Dictionary) -> void:
	var slot := int(args.get("slot", -1))
	var s := inv(pid).take_from(slot, int(args.get("n", 999)))
	World.mark_inventory(pid)
	if s.is_empty():
		return
	var p := player_pos(pid)
	spawn_item(String(s["i"]), int(s["n"]), s["d"], p + Vector3(0, 0.5, 0))


func _a_satchel_take(pid: int, args: Dictionary) -> void:
	var eid := int(args.get("eid", -1))
	var ent := World.get_entity(eid)
	if ent.is_empty() or ent["t"] != "satchel" or not in_reach(pid, args, ent["xf"].origin):
		return
	var items: Array = ent["d"].get("items", [])
	var rest: Array = []
	for s in items:
		var left := inv(pid).add(String(s["i"]), int(s["n"]), s["d"])
		if left > 0:
			rest.append(Inventory.make(s["i"], left, s["d"]))
	World.mark_inventory(pid)
	if rest.is_empty():
		World.despawn(eid)
	else:
		World.update(eid, {"items": rest})
		World.notify(pid, "You couldn't carry everything.")
	World.fx("pickup", ent["xf"].origin)


# ---------------------------------------------------------------------------
# Gathering
# ---------------------------------------------------------------------------

func _a_outcrop_take(pid: int, args: Dictionary) -> void:
	var eid := int(args.get("eid", -1))
	var ent := World.get_entity(eid)
	if ent.is_empty() or ent["t"] != "outcrop":
		return
	var idx := int(args.get("idx", -1))
	var loose: Array = ent["d"].get("loose", []).duplicate()
	if idx < 0 or idx >= loose.size() or int(loose[idx]) <= 0:
		return
	var v := entity_view(eid)
	var at: Vector3 = v.interaction_point("loose:%d" % idx) if v else ent["xf"].origin
	if not in_reach(pid, args, at, 0.5):
		return
	if inv(pid).space_for("stone") <= 0:
		World.notify(pid, "No room to carry a stone.")
		return
	loose[idx] = 0
	World.update(eid, {"loose": loose})
	give(pid, "stone", 1)
	World.fx("stone_break", at, {"sound": "stone_drop", "amount": 6})


func _a_pick_mushroom(pid: int, args: Dictionary) -> void:
	var eid := int(args.get("eid", -1))
	var ent := World.get_entity(eid)
	if ent.is_empty() or ent["t"] != "mushrooms" or not in_reach(pid, args, ent["xf"].origin, 0.5):
		return
	var caps: Array = ent["d"].get("caps", []).duplicate()
	var idx := int(args.get("idx", -1))
	if idx < 0 or idx >= caps.size() or float(caps[idx]) < 0.6:
		World.notify(pid, "That one is too small yet.")
		return
	caps[idx] = 0.0
	World.update(eid, {"caps": caps})
	give(pid, "mushroom", 1)
	World.fx("harvest", ent["xf"].origin, {"amount": 3})


func _a_pick_berries(pid: int, args: Dictionary) -> void:
	var eid := int(args.get("eid", -1))
	var ent := World.get_entity(eid)
	if ent.is_empty() or ent["t"] != "bush" or not in_reach(pid, args, ent["xf"].origin + Vector3(0, 0.4, 0), 0.6):
		return
	var b := float(ent["d"].get("berries", 0.0))
	if b < 0.25:
		return
	var n := int(round(b * 6.0))
	World.update(eid, {"berries": 0.0})
	give(pid, "berries", n)
	World.fx("berries", ent["xf"].origin + Vector3(0, 0.5, 0))


func _a_cut_grass(pid: int, args: Dictionary) -> void:
	var pos: Vector3 = args.get("pos", Vector3.ZERO)
	if not in_reach(pid, args, pos):
		return
	var blade := ItemDB.tool_kind(held_id(pid, args)) == "cut"
	var radius := 0.32 if blade else 0.2
	var cells := World.terrain.cells_in_radius(Vector2(pos.x, pos.z), radius)
	var removed := 0.0
	for k in cells:
		var g := World.terrain.grass[k]
		if g <= 0.05:
			continue
		var take := minf(g, 0.6 if blade else 0.35)
		World.terrain.grass[k] = g - take
		removed += take
	# grass cover is biomass: ~0.04 kg per cell of full cover
	var kg := removed * 0.04
	var units := int(floor(kg / ItemDB.unit_mass("grass") + _rng.randf()))
	if removed <= 0.0:
		World.notify(pid, "No grass left to cut here.")
		return
	var rest_kg := kg - units * ItemDB.unit_mass("grass")
	World.pools["soil_organic_kg"] = float(World.pools.get("soil_organic_kg", 0.0)) + maxf(0.0, rest_kg)
	if units < 0 and rest_kg < 0.0:
		pass
	if units > 0:
		give(pid, "grass", units, {"moist": 0.65})
	World.terrain_edited(Rect2i(TerrainData.cell_at(Vector2(pos.x, pos.z)) - Vector2i(3, 3), Vector2i(7, 7)))
	World.fx("grass", pos)
	if blade:
		Tools.wear(pid, args, 0.002)
	exert(pid, 0.01)


func _a_dig(pid: int, args: Dictionary) -> void:
	TerrainActions.dig(self, pid, args)


func _a_fill(pid: int, args: Dictionary) -> void:
	TerrainActions.fill(self, pid, args)


func _a_till(pid: int, args: Dictionary) -> void:
	TerrainActions.till(self, pid, args)


func _a_fertilize(pid: int, args: Dictionary) -> void:
	TerrainActions.fertilize(self, pid, args)


func _a_plant(pid: int, args: Dictionary) -> void:
	FarmActions.plant(self, pid, args)


func _a_harvest(pid: int, args: Dictionary) -> void:
	FarmActions.harvest(self, pid, args)


func _a_pour(pid: int, args: Dictionary) -> void:
	WaterActions.pour(self, pid, args)


func _a_drink_pond(pid: int, args: Dictionary) -> void:
	WaterActions.drink_pond(self, pid, args)


func _a_drink_vessel(pid: int, args: Dictionary) -> void:
	WaterActions.drink_vessel(self, pid, args)


func _a_drink_entity(pid: int, args: Dictionary) -> void:
	WaterActions.drink_entity(self, pid, args)


func _a_fill_vessel(pid: int, args: Dictionary) -> void:
	WaterActions.fill_vessel(self, pid, args)


func _a_eat_vessel(pid: int, args: Dictionary) -> void:
	WaterActions.eat_vessel(self, pid, args)


func _a_tree_cut(pid: int, args: Dictionary) -> void:
	TreeActions.cut_small(self, pid, args)


func _a_tree_chop_limb(pid: int, args: Dictionary) -> void:
	TreeActions.chop_limb(self, pid, args)


func _a_tree_fell(pid: int, args: Dictionary) -> void:
	TreeActions.fell(self, pid, args)


func _a_process(pid: int, args: Dictionary) -> void:
	TreeActions.process_item(self, pid, args)


func _a_process_held(pid: int, args: Dictionary) -> void:
	TreeActions.process_held(self, pid, args)


func _a_split(pid: int, args: Dictionary) -> void:
	TreeActions.split(self, pid, args)


# ---------------------------------------------------------------------------
# Survival
# ---------------------------------------------------------------------------

func _a_eat(pid: int, args: Dictionary) -> void:
	var stack := held(pid, args)
	var id := String(stack.get("i", ""))
	var food := ItemDB.food(id)
	if food.is_empty():
		return
	take_held(pid, args, 1)
	Survival.eat(pid, id, food)
	World.fx("eat", player_pos(pid) + Vector3(0, 1.5, 0))


func _a_hurt(pid: int, args: Dictionary) -> void:
	Survival.damage(pid, clampf(float(args.get("amount", 0.0)), 0.0, 1.0), String(args.get("cause", "")))


func _a_fell(pid: int, args: Dictionary) -> void:
	Survival.die(pid, "abyss")


func _a_respawn(pid: int, args: Dictionary) -> void:
	Survival.respawn(pid)


func _a_exert(pid: int, args: Dictionary) -> void:
	match String(args.get("kind", "")):
		"jump":
			exert(pid, 0.02)


func _a_guide_state(pid: int, args: Dictionary) -> void:
	World.guide_states[pid] = args.get("state", {})


func _a_chat_cmd(_pid: int, _args: Dictionary) -> void:
	pass
