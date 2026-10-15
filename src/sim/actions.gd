class_name Actions
extends Node
## The host's request handler.  Every client request ends up here; each action
## re-validates everything against the current state (is the block still there,
## is it within reach, does the player hold what they claim...) before changing
## anything, and requests are handled one at a time, so nothing can be
## duplicated.  Domain rules live in BlockActs, FireActs, CraftActs and FarmActs.

const REACH := 5.4                 # eye to the nearest point of the target (a little slack for lag)
const EYE := 1.62
const PICKUP_R := 1.5
const ABYSS_Y := -30.0

var no_rate := false               # tests: requests may come faster than hands could
var _pickup_t := 0.0
var _last_break: Dictionary = {}   # pid -> msec
var _last_act: Dictionary = {}     # "pid:action" -> msec

var blocks: BlockActs
var fire: FireActs
var craft: CraftActs
var farm: FarmActs
var water: WaterSim
var rafts: RaftSim
var animals: AnimalSim


func _ready() -> void:
	blocks = BlockActs.new(self)
	fire = FireActs.new(self)
	craft = CraftActs.new(self)
	farm = FarmActs.new(self)
	water = WaterSim.new(self)
	rafts = RaftSim.new(self)
	animals = AnimalSim.new(self)
	animals.populate()
	# rafts move before the players who ride them
	process_physics_priority = -10


# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

const ARG_TYPES := {
	"c": TYPE_VECTOR3I, "face": TYPE_VECTOR3I, "slot": TYPE_INT, "i": TYPE_INT, "r": TYPE_STRING,
	"sneak": TYPE_BOOL, "add": TYPE_BOOL, "cells": TYPE_PACKED_INT32_ARRAY, "button": TYPE_INT, "shift": TYPE_BOOL,
	"all": TYPE_BOOL, "amount": TYPE_FLOAT, "cause": TYPE_STRING, "state": TYPE_DICTIONARY, "eid": TYPE_INT,
	"point": TYPE_VECTOR3, "kind": TYPE_STRING, "yaw": TYPE_FLOAT, "cell": TYPE_VECTOR3I, "dir": TYPE_VECTOR3,
}


func handle(pid: int, action: String, args: Dictionary) -> void:
	for k in args:
		if ARG_TYPES.has(k) and typeof(args[k]) != ARG_TYPES[k]:
			return
	var st: Dictionary = World.stats.get(pid, {})
	if st.is_empty():
		return
	var alive := bool(st.get("alive", true))
	if not alive and action != "respawn" and action != "guide_state":
		return
	match action:
		"break": blocks.break_at(pid, args)
		"place": blocks.place(pid, args)
		"use": use(pid, args)
		"ignite": fire.ignite(pid, args)
		"knap": craft.knap(pid, args)
		"knap_choose": craft.knap_choose(pid, args)
		"clay": craft.clay(pid, args)
		"clay_choose": craft.clay_choose(pid, args)
		"take": take(pid, args)
		"satchel": take_satchel(pid, args)
		"eat": eat(pid, args)
		"drink": drink(pid, args)
		"inv_click": inv_click(pid, args)
		"inv_swap": inv_swap(pid, args)
		"raft_new": rafts.new_raft(pid, args)
		"raft_place": rafts.place(pid, args)
		"raft_break": rafts.take(pid, args)
		"raft_use": rafts.use(pid, args)
		"paddle": rafts.paddle(pid, args)
		"helm": rafts.helm(pid, args)
		"hit": animals.hit(pid, args)
		"animal_use": animals.use(pid, args)
		"inv_close": close_inventory(pid)
		"container_click": craft.container_click(pid, args)
		"drop": drop(pid, args)
		"hurt":
			if _rate(pid, "hurt", 300):
				Survival.damage(pid, clampf(float(args.get("amount", 0.0)), 0.0, 1.0), String(args.get("cause", "fall")))
		"fell": Survival.die(pid, "abyss")
		"respawn": Survival.respawn(pid)
		"bed_set": farm.bed_set(pid, args)
		"guide_state":
			World.guide_states[pid] = _clean_guide(args.get("state", {}))


func _rate(pid: int, key: String, ms: int) -> bool:
	if no_rate:
		return true
	var k := "%d:%s" % [pid, key]
	var now := Time.get_ticks_msec()
	if now - int(_last_act.get(k, -100000)) < ms:
		return false
	_last_act[k] = now
	return true


func _clean_guide(st: Dictionary) -> Dictionary:
	var out := {}
	for k in ["read", "seen", "done", "flags"]:
		var src = st.get(k, {})
		var d := {}
		if src is Dictionary:
			for key in src:
				if d.size() < 400:
					d[String(key).left(48)] = true
		out[k] = d
	return out


# ---------------------------------------------------------------------------
# Players
# ---------------------------------------------------------------------------

func player_pos(pid: int) -> Vector3:
	var pose: Dictionary = Net.poses.get(pid, {})
	return pose.get("p", World.spawn_point(pid))


func eye_pos(pid: int) -> Vector3:
	var pose: Dictionary = Net.poses.get(pid, {})
	var crouch := bool(pose.get("c", false))
	if bool(pose.get("st", false)):
		return player_pos(pid) + Vector3(0, 0.92, 0)
	return player_pos(pid) + Vector3(0, 1.3 if crouch else EYE, 0)


func in_reach(pid: int, c: Vector3i) -> bool:
	var box := AABB(Vector3(c), Vector3.ONE)
	var e := eye_pos(pid)
	var nearest := e.clamp(box.position, box.end)
	return e.distance_to(nearest) <= REACH


func held(pid: int, slot: int) -> Dictionary:
	if slot < 0 or slot >= Inventory.HOTBAR:
		return {}
	return World.inventory_of(pid).get_slot(slot)


func held_kind(pid: int, slot: int) -> String:
	var s := held(pid, slot)
	return ItemDB.tool_kind(String(s.get("i", ""))) if not s.is_empty() else ""


func wear_tool(pid: int, slot: int, uses: int = 1) -> void:
	## A tool loses a use; worn out, it breaks.
	var inv := World.inventory_of(pid)
	var s := inv.get_slot(slot)
	if s.is_empty() or ItemDB.tool_info(String(s["i"])).is_empty():
		return
	var d: Dictionary = s["d"]
	var dur := int(d.get("dur", ItemDB.max_durability(String(s["i"]), d))) - uses
	if dur <= 0:
		inv.set_slot(slot, {})
		World.notify(pid, "Your %s broke." % ItemDB.label(String(s["i"]), d).to_lower(), "warn")
		World.fx("tool_break", player_pos(pid) + Vector3(0, 1.2, 0))
	else:
		d["dur"] = dur
	World.mark_inventory(pid)


func give(pid: int, id: String, n: int = 1, d: Dictionary = {}, at := Vector3.INF) -> void:
	## Into the player's inventory; what doesn't fit drops at their feet (or at `at`).
	var inv := World.inventory_of(pid)
	var left := inv.add(id, n, d)
	World.mark_inventory(pid)
	if left > 0:
		var p := player_pos(pid) + Vector3(0, 0.6, 0) if at == Vector3.INF else at
		if World.vox.rest_height(p) == -INF:
			p = player_pos(pid) + Vector3(0, 0.6, 0)
		drop_item(id, left, d, p, Vector3.ZERO, pid)


func give_stack(pid: int, s: Dictionary, at := Vector3.INF) -> void:
	give(pid, String(s["i"]), int(s["n"]), s.get("d", {}), at)


# ---------------------------------------------------------------------------
# Dropped items
# ---------------------------------------------------------------------------

func drop_item(id: String, n: int, d: Dictionary, p: Vector3, vel := Vector3.ZERO, by := 0, wait_ms := 0) -> int:
	## A stack lying in the world.  It lands on whatever is below; over the abyss
	## it is gone.  wait_ms: it only shows up (and can be picked up) after that
	## long - for things still falling in an effect, like a toppling tree.
	if n <= 0:
		return -1
	var land := p + Vector3(vel.x, 0, vel.z) * 0.35
	var y := World.vox.rest_height(land)
	# on a raft's deck it stays on the deck (and goes where the raft goes)
	var deck: Dictionary = rafts.deck_under(land) if rafts else {}
	if not deck.is_empty() and float((deck["world"] as Vector3).y) > y:
		var t0 := Time.get_ticks_msec()
		return World.spawn("item", Transform3D(Basis(Vector3.UP, randf() * TAU), deck["world"]),
			{"i": id, "n": n, "d": d, "t": t0 + wait_ms, "by": by, "raft": deck["eid"], "rp": deck["rp"]})
	if y == -INF:
		World.fx("lost", land, {"i": id})
		return -1
	land.y = y
	# things float: on water they rest at the surface
	var wc := VoxelData.cell_of(Vector3(land.x, y + 0.05, land.z))
	if Blocks.is_water(World.block(wc)):
		while Blocks.is_water(World.block(wc + Vector3i.UP)):
			wc += Vector3i.UP
		land.y = wc.y + 0.8
	var t := Time.get_ticks_msec()
	var ed := {"i": id, "n": n, "d": d, "t": t + wait_ms, "by": by, "from": p}
	if wait_ms > 0:
		ed["w"] = wait_ms
	return World.spawn("item", Transform3D(Basis(Vector3.UP, randf() * TAU), land), ed)


func drop_stacks(stacks: Array, p: Vector3) -> void:
	for s in stacks:
		if s is Dictionary and not s.is_empty():
			var j := Vector3(randf_range(-0.3, 0.3), 0, randf_range(-0.3, 0.3))
			drop_item(String(s["i"]), int(s["n"]), s.get("d", {}), p + j)


func resettle_items(c: Vector3i) -> void:
	## A block went away: whatever lay on it (in this column) falls.
	for e in World.entities_of("item"):
		var p: Vector3 = (e["xf"] as Transform3D).origin
		if floori(p.x) != c.x or floori(p.z) != c.z or p.y < c.y or int(e["d"].get("raft", -1)) >= 0:
			continue
		var y := World.vox.rest_height(p + Vector3(0, 0.05, 0))
		if y == -INF:
			World.fx("lost", p, {"i": e["d"]["i"]})
			World.despawn(e["id"])
		elif absf(y - p.y) > 0.01:
			var xf: Transform3D = e["xf"]
			xf.origin.y = y
			World.update(e["id"], {"from": p})
			World.set_xf(e["id"], xf)


func _physics_process(delta: float) -> void:
	if not World.running:
		return
	water.step(delta)
	rafts.step(delta)
	animals.step(delta)
	_pickup_t -= delta
	if _pickup_t > 0.0:
		return
	_pickup_t = 0.12
	var now := Time.get_ticks_msec()
	for pid in Net.players:
		var st: Dictionary = World.stats.get(pid, {})
		if st.is_empty() or not bool(st.get("alive", true)):
			continue
		var p := player_pos(pid) + Vector3(0, 0.4, 0)
		# where you last stood on firm ground (a fall into the abyss leaves your bag there)
		var pose: Dictionary = Net.poses.get(pid, {})
		if bool(pose.get("g", false)) and not bool(pose.get("w", false)) and World.vox.rest_height(p) != -INF:
			st["safe"] = player_pos(pid)
		for e in World.entities_near(p, PICKUP_R + 0.5, "item"):
			var d: Dictionary = e["d"]
			# what you just threw can't jump straight back into your hands
			var age := now - int(d.get("t", 0))
			if age < 0 and d.has("w"):
				continue   # still falling
			if not no_rate:
				if int(d.get("by", 0)) == pid and age < 1600:
					continue
				if age < 350:
					continue
			if (e["xf"].origin as Vector3).distance_to(p) > PICKUP_R:
				continue
			var inv := World.inventory_of(pid)
			var n := int(d["n"])
			var left := inv.add(String(d["i"]), n, d.get("d", {}))
			if left == n:
				continue
			World.mark_inventory(pid)
			if left > 0:
				World.update(e["id"], {"n": left})
			else:
				World.despawn(e["id"])
			World.fx("pickup", e["xf"].origin, {"pid": pid})
	# items that fell off into the abyss (pushed off an edge by a broken block)
	for e in World.entities_of("item"):
		if (e["xf"].origin as Vector3).y < ABYSS_Y:
			World.despawn(e["id"])


func drop(pid: int, args: Dictionary) -> void:
	var slot := int(args.get("slot", -1))
	if slot < 0 or slot >= Inventory.MAIN:
		return
	var inv := World.inventory_of(pid)
	var s := inv.get_slot(slot)
	if s.is_empty():
		return
	var n := int(s["n"]) if bool(args.get("all", false)) else 1
	var out := inv.take_from(slot, n)
	World.mark_inventory(pid)
	var yaw := float(args.get("yaw", 0.0))
	var fwd := Vector3(-sin(yaw), 0, -cos(yaw))
	var from := eye_pos(pid) - Vector3(0, 0.3, 0)
	# thrown about a block and a half ahead (never through a wall)
	var to := from + fwd * 1.4
	var hit := World.vox.raycast(from, fwd, 1.4)
	if not hit.is_empty():
		to = from + fwd * maxf(0.0, float(hit["dist"]) - 0.3)
	drop_item(String(out["i"]), int(out["n"]), out["d"], to, Vector3.ZERO, pid)


# ---------------------------------------------------------------------------
# Using things (right click)
# ---------------------------------------------------------------------------

func use(pid: int, args: Dictionary) -> void:
	var c: Vector3i = args.get("c", Vector3i(-1, -1, -1))
	var slot := int(args.get("slot", -1))
	var sneak := bool(args.get("sneak", false))
	var face: Vector3i = args.get("face", Vector3i.UP)
	if not in_reach(pid, c):
		return
	if not _rate(pid, "use", 90):
		return
	var s := held(pid, slot)
	var id := String(s.get("i", ""))
	# a block entity in the cell
	var be := World.be(c)
	if not be.is_empty():
		match String(be["t"]):
			"firepit": fire.use_firepit(pid, be, slot, sneak)
			"kiln": fire.use_kiln(pid, be, slot, sneak)
			"ground": craft.use_ground(pid, be, slot, sneak)
			"knap": craft.use_knap(pid, be, slot, sneak)
			"clay": craft.use_clay(pid, be, slot, sneak)
			"jar": craft.use_jar(pid, be, slot, sneak)
		return
	var target := World.block(c)
	# things done to the block itself
	if farm.use_block(pid, c, target, slot, s, face, sneak):
		return
	# set something down on top of the block
	if face == Vector3i.UP and Blocks.is_solid(target):
		var above := c + Vector3i.UP
		# (blocks are always placed, sneaking or not - you sneak to build at an edge)
		if World.cell_free(above) and ItemDB.block_of(id) < 0:
			if craft.set_down(pid, above, slot, s, sneak):
				return
	# place a block
	if ItemDB.block_of(id) >= 0:
		blocks.place(pid, {"c": c + face, "slot": slot, "face": face})


func take(pid: int, args: Dictionary) -> void:
	var c: Vector3i = args.get("c", Vector3i(-1, -1, -1))
	if not in_reach(pid, c):
		return
	var be := World.be(c)
	if be.is_empty():
		return
	match String(be["t"]):
		"ground": craft.take_ground(pid, be)
		"firepit": fire.take_from_firepit(pid, be)


func take_satchel(pid: int, args: Dictionary) -> void:
	## Your things back from the bag you left when you died (anyone may open it).
	var eid := int(args.get("eid", -1))
	var e := World.get_entity(eid)
	if e.is_empty() or e["t"] != "satchel":
		return
	var p: Vector3 = (e["xf"] as Transform3D).origin
	if eye_pos(pid).distance_to(p) > REACH + 0.5:
		return
	var inv := World.inventory_of(pid)
	var left: Array = []
	for s in e["d"].get("items", []):
		var n := inv.add(String(s["i"]), int(s["n"]), s.get("d", {}))
		if n > 0:
			left.append(Inventory.make(String(s["i"]), n, s.get("d", {})))
	World.mark_inventory(pid)
	if left.is_empty():
		World.despawn(eid)
		World.fx("pickup", p, {"pid": pid})
	else:
		World.update(eid, {"items": left})
		World.notify(pid, "You couldn't carry everything; the rest is still in the bag.")


func eat(pid: int, args: Dictionary) -> void:
	var slot := int(args.get("slot", -1))
	if not _rate(pid, "eat", 700):
		return
	var inv := World.inventory_of(pid)
	var s := held(pid, slot)
	if s.is_empty():
		return
	var id := String(s["i"])
	var d: Dictionary = s["d"]
	# a bowl of stew or water
	if id == "bowl" and d.get("c", "") != "":
		var what := String(d["c"])
		if what == "water":
			Survival.drink(pid, 0.35)
		elif what == "sea":
			Survival.drink(pid, -0.08)
			World.notify(pid, "Salt water! It only makes you thirstier. (Boil it in a pot over a fire.)", "warn")
		elif what == "stew":
			Survival.eat(pid, {"hunger": 0.32, "thirst": 0.05}, true)
		inv.set_data(slot, {})
		World.mark_inventory(pid)
		World.fx("drink" if what == "water" else "eat", player_pos(pid) + Vector3(0, 1.5, 0), {"pid": pid})
		return
	# a pot of water, a waterskin
	if id == "pot" and int(d.get("w", 0)) > 0:
		if bool(d.get("salt", false)):
			Survival.drink(pid, -0.08)
			World.notify(pid, "Salt water! Boil it over a fire first.", "warn")
		else:
			Survival.drink(pid, 0.35)
		var left := int(d["w"]) - 1
		inv.set_data(slot, {"w": left, "salt": d.get("salt", false)} if left > 0 else {})
		World.mark_inventory(pid)
		World.fx("drink", player_pos(pid) + Vector3(0, 1.5, 0), {"pid": pid})
		return
	if id == "waterskin" and String(d.get("c", "")) == "water" and int(d.get("n", 0)) > 0:
		Survival.drink(pid, 0.35)
		var n := int(d["n"]) - 1
		inv.set_data(slot, {"c": "water", "n": n} if n > 0 else {})
		World.mark_inventory(pid)
		World.fx("drink", player_pos(pid) + Vector3(0, 1.5, 0), {"pid": pid})
		return
	var f := ItemDB.food(id)
	if f.is_empty():
		return
	var st: Dictionary = World.stats.get(pid, {})
	if float(st.get("hunger", 0.0)) >= 0.995 and float(f.get("thirst", 0.0)) <= 0.0:
		World.notify(pid, "You're full.")
		return
	inv.take_from(slot, 1)
	World.mark_inventory(pid)
	Survival.eat(pid, f, not f.has("cook"))
	flag_player(pid, "ate:" + id)
	World.fx("eat", player_pos(pid) + Vector3(0, 1.5, 0), {"pid": pid})


func drink(pid: int, args: Dictionary) -> void:
	## Drinking straight from the pond (hold right click on water with an empty hand).
	var c: Vector3i = args.get("c", Vector3i(-1, -1, -1))
	if not in_reach(pid, c) or not Blocks.is_water(World.block(c)):
		return
	if not _rate(pid, "drink", 450):
		return
	if World.block(c) != Blocks.id_of("water"):
		# the sea: salt, and only makes it worse
		Survival.drink(pid, -0.06)
		World.notify(pid, "Salt water! It only makes you thirstier.", "warn")
		World.fx("drink", Vector3(c) + Vector3(0.5, 0.9, 0.5), {"pid": pid})
		return
	Survival.drink(pid, 0.12)
	World.fx("drink", Vector3(c) + Vector3(0.5, 0.9, 0.5), {"pid": pid})


# ---------------------------------------------------------------------------
# Inventory screen (host keeps the cursor and crafting grid)
# ---------------------------------------------------------------------------

const OUTPUT := 46


func inv_swap(pid: int, args: Dictionary) -> void:
	## A number key over a slot: swap that slot with the hotbar slot.
	var slot := int(args.get("slot", -1))
	var hb := int(args.get("i", -1))
	if slot < 0 or slot >= Inventory.CURSOR or hb < 0 or hb >= Inventory.HOTBAR or slot == hb:
		return
	var inv := World.inventory_of(pid)
	var s := inv.get_slot(slot)
	inv.set_slot(slot, inv.get_slot(hb))
	inv.set_slot(hb, s)
	World.mark_inventory(pid)


func inv_click(pid: int, args: Dictionary) -> void:
	## Minecraft-style slot clicks.  button 0: pick up / put down / swap the whole
	## stack; button 1: pick up half / put down one.  shift: move straight across
	## (backpack <-> hotbar, grid -> backpack).  Slot 46 is the crafting result.
	var inv := World.inventory_of(pid)
	var slot := int(args.get("slot", -1))
	var button := int(args.get("button", 0))
	var shift := bool(args.get("shift", false))
	if slot == OUTPUT:
		_craft_click(pid, inv, shift)
		World.mark_inventory(pid)
		return
	if slot < 0 or slot >= Inventory.CURSOR:
		return
	var cur := inv.get_slot(Inventory.CURSOR)
	var s := inv.get_slot(slot)
	if shift:
		if s.is_empty():
			return
		var dest := range(Inventory.HOTBAR, Inventory.MAIN) if slot < Inventory.HOTBAR else range(0, Inventory.HOTBAR)
		if slot >= Inventory.GRID:
			dest = range(0, Inventory.MAIN)
		var moving: Dictionary = s.duplicate(true)
		inv.set_slot(slot, {})
		var left := _merge_into(inv, moving, dest)
		if left > 0:
			moving["n"] = left
			inv.set_slot(slot, moving)
		World.mark_inventory(pid)
		return
	if button == 0:
		if cur.is_empty():
			inv.set_slot(Inventory.CURSOR, s)
			inv.set_slot(slot, {})
		elif s.is_empty():
			inv.set_slot(slot, cur)
			inv.set_slot(Inventory.CURSOR, {})
		elif _same(cur, s):
			var mx := ItemDB.stack_max(String(s["i"]))
			var take := mini(int(cur["n"]), mx - int(s["n"]))
			s["n"] = int(s["n"]) + take
			cur["n"] = int(cur["n"]) - take
			if int(cur["n"]) <= 0:
				inv.set_slot(Inventory.CURSOR, {})
		else:
			inv.set_slot(slot, cur)
			inv.set_slot(Inventory.CURSOR, s)
	else:
		if cur.is_empty():
			if s.is_empty():
				return
			var half := int(ceil(int(s["n"]) / 2.0))
			inv.set_slot(Inventory.CURSOR, inv.take_from(slot, half))
		elif s.is_empty():
			inv.set_slot(slot, inv.take_from(Inventory.CURSOR, 1))
		elif _same(cur, s) and int(s["n"]) < ItemDB.stack_max(String(s["i"])):
			s["n"] = int(s["n"]) + 1
			inv.take_from(Inventory.CURSOR, 1)
		else:
			inv.set_slot(slot, cur)
			inv.set_slot(Inventory.CURSOR, s)
	World.mark_inventory(pid)


func _same(a: Dictionary, b: Dictionary) -> bool:
	return String(a["i"]) == String(b["i"]) and ItemDB.can_stack(String(a["i"]), a["d"]) and ItemDB.can_stack(String(b["i"]), b["d"])


func _merge_into(inv: Inventory, s: Dictionary, dest: Array) -> int:
	var n := int(s["n"])
	var id := String(s["i"])
	var mx := ItemDB.stack_max(id)
	if ItemDB.can_stack(id, s["d"]):
		for i in dest:
			var t := inv.get_slot(i)
			if not t.is_empty() and _same(t, s) and int(t["n"]) < mx:
				var take := mini(n, mx - int(t["n"]))
				t["n"] = int(t["n"]) + take
				n -= take
				if n <= 0:
					return 0
	for i in dest:
		if inv.is_empty_slot(i):
			var take := mini(n, mx)
			inv.set_slot(i, Inventory.make(id, take, s["d"].duplicate(true)))
			n -= take
			if n <= 0:
				return 0
	return n


func craft_preview(inv: Inventory) -> Dictionary:
	var grid := inv.grid()
	var m := ItemDB.match_recipe(grid)
	if m.is_empty():
		return {}
	return ItemDB.recipe_output(m, grid)


func _craft_click(pid: int, inv: Inventory, shift: bool) -> void:
	var times := 64 if shift else 1
	var made := 0
	var last := ""
	while times > 0:
		times -= 1
		var grid := inv.grid()
		var m := ItemDB.match_recipe(grid)
		if m.is_empty():
			break
		var out := ItemDB.recipe_output(m, grid)
		var cur := inv.get_slot(Inventory.CURSOR)
		if shift:
			if inv.space_for(String(out["i"]), out["d"]) < int(out["n"]):
				break
		elif not cur.is_empty():
			if not (_same(cur, out) and int(cur["n"]) + int(out["n"]) <= ItemDB.stack_max(String(out["i"]))):
				break
		# consume: one of each ingredient; tools lose a use and stay
		var r: Dictionary = m["recipe"]
		for gi in range(Inventory.GRID, Inventory.GRID + 9):
			var g := inv.get_slot(gi)
			if g.is_empty():
				continue
			if not ItemDB.tool_info(String(g["i"])).is_empty() and _is_tool_ing(r, String(g["i"])):
				wear_tool(pid, gi)
			else:
				inv.take_from(gi, 1)
		if shift:
			inv.add(String(out["i"]), int(out["n"]), out["d"])
		elif cur.is_empty():
			inv.set_slot(Inventory.CURSOR, out)
		else:
			cur["n"] = int(cur["n"]) + int(out["n"])
		made += 1
		last = String(out["i"])
		flag_player(pid, "craft:" + last)
	if made > 0:
		World.fx("craft", player_pos(pid) + Vector3(0, 1.2, 0), {"pid": pid, "i": last})


func _is_tool_ing(r: Dictionary, id: String) -> bool:
	for spec in r.get("shapeless", []):
		if String(spec).begins_with("tool:") and ItemDB.tool_kind(id) == String(spec).substr(5):
			return true
	return false


func flag_player(pid: int, f: String) -> void:
	## Tell a player's goal tracker they did something.
	if pid == multiplayer.get_unique_id():
		Guide.flag(f)
	elif Net.is_online():
		# through the World autoload: clients have no Actions node to receive it
		World.rpc_flag.rpc_id(pid, f)


func close_inventory(pid: int) -> void:
	## Grid and cursor go back into the inventory; what doesn't fit drops.
	if not World.inventories.has(pid):
		return
	var inv := World.inventory_of(pid)
	var spill: Array = []
	for i in range(Inventory.GRID, Inventory.SIZE):
		var s := inv.get_slot(i)
		if s.is_empty():
			continue
		inv.set_slot(i, {})
		var left := inv.add(String(s["i"]), int(s["n"]), s["d"])
		if left > 0:
			spill.append(Inventory.make(String(s["i"]), left, s["d"]))
	World.mark_inventory(pid)
	if not spill.is_empty():
		drop_stacks(spill, player_pos(pid) + Vector3(0, 0.6, 0))
