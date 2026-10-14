class_name FireActs
extends RefCounted
## Fire pits and pit kilns (host).
##
## A fire pit is built where you sneak-right-click a stick (or a handful of dry
## grass) onto the ground.  Each stick added lies across the others: the first
## two make an X, the next two a cross over it, and so on up to eight.  Dry grass
## goes underneath as tinder.  Hold a bow drill on it to light it: the tinder
## flares, catches the sticks, and the sticks catch any firewood laid on top.
## Rain on an open fire drowns it unless logs are burning.
##
## A pit kiln is raw pottery set on the ground, covered with dry grass and then
## sticks, and lit.  It burns for three hours.  In a pit (solid blocks around it)
## the heat is even; out in the open some pieces crack.

const TINDER_MAX := 3
const STICK_MAX := 8
const LOG_MAX := 4
const FOOD_MAX := 4
const TINDER_H := 0.12
const STICK_H := 0.45
const LOG_H := 1.8
const KILN_GRASS := 4
const KILN_STICKS := 6
const KILN_H := 3.0
const RAIN_OUT_S := 7.0
const STEW_S := 32.0
const CRACK := [0.45, 0.32, 0.2, 0.08, 0.0]

var a: Actions


func _init(actions: Actions) -> void:
	a = actions


# ---------------------------------------------------------------------------
# Building
# ---------------------------------------------------------------------------

func new_firepit(pid: int, c: Vector3i, slot: int, id: String) -> bool:
	var d := {"tinder": 0, "sticks": 0, "logs": 0, "tf": 0.0, "sf": 0.0, "lf": 0.0, "lit": false, "ash": false,
		"food": [], "pot": {}, "heat": 0.0, "phase": ""}
	if id == "stick":
		d["sticks"] = 1
		d["sf"] = STICK_H
	elif ItemDB.fuel(id) == "tinder":
		d["tinder"] = 1
		d["tf"] = TINDER_H
	else:
		return false
	World.inventory_of(pid).take_from(slot, 1)
	World.mark_inventory(pid)
	World.spawn_be("firepit", c, d)
	World.fx("place_fuel", Vector3(c) + Vector3(0.5, 0.1, 0.5), {"i": id})
	World.hint_to(pid, "firepit")
	a.flag_player(pid, "built_firepit")
	return true


func use_firepit(pid: int, be: Dictionary, slot: int, sneak: bool) -> void:
	var d: Dictionary = be["d"]
	var c: Vector3i = d["cell"]
	var s := a.held(pid, slot)
	var id := String(s.get("i", ""))
	var inv := World.inventory_of(pid)
	var at := Vector3(c) + Vector3(0.5, 0.15, 0.5)
	var pot: Dictionary = d.get("pot", {})
	if id == "":
		take_from_firepit(pid, be)
		return
	if id == "stick":
		if int(d["sticks"]) >= STICK_MAX:
			World.notify(pid, "There's no room for more sticks.")
			return
		inv.take_from(slot, 1)
		World.update(be["id"], {"sticks": int(d["sticks"]) + 1, "sf": float(d["sf"]) + STICK_H, "ash": false})
		World.fx("place_fuel", at, {"i": id})
	elif ItemDB.fuel(id) == "tinder":
		if int(d["tinder"]) >= TINDER_MAX:
			World.notify(pid, "That's plenty of tinder.")
			return
		inv.take_from(slot, 1)
		World.update(be["id"], {"tinder": int(d["tinder"]) + 1, "tf": float(d["tf"]) + TINDER_H, "ash": false})
		World.fx("place_fuel", at, {"i": id})
	elif id == "firewood":
		if int(d["logs"]) >= LOG_MAX:
			World.notify(pid, "The fire can't take more firewood.")
			return
		inv.take_from(slot, 1)
		World.update(be["id"], {"logs": int(d["logs"]) + 1, "lf": float(d["lf"]) + LOG_H, "ash": false})
		World.fx("place_fuel", at, {"i": id})
		if not bool(d["lit"]) and int(d["sticks"]) == 0:
			World.hint_to(pid, "firewood_needs_sticks")
	elif id == "torch":
		if bool(d["lit"]):
			var n := int(s["n"])
			inv.set_slot(slot, Inventory.make("torch_lit", n))
			World.fx("ignite", at)
			a.flag_player(pid, "lit_torch")
		else:
			World.notify(pid, "Light the fire first, then the torch from it.")
	elif id == "torch_lit":
		_light_firepit(pid, be)
	elif id == "pot" and pot.is_empty():
		inv.take_from(slot, 1)
		World.update(be["id"], {"pot": {"water": int(s["d"].get("w", 0)), "items": [], "stew": 0, "t": 0.0}})
		World.fx("place", at, {"b": 0})
	elif id == "bowl" and not pot.is_empty():
		_bowl_at_pot(pid, be, slot, s)
	elif String(ItemDB.food(id).get("cook", "")) != "":
		if not pot.is_empty() and int(pot.get("water", 0)) > 0 and int(pot.get("stew", 0)) == 0:
			if (pot["items"] as Array).size() >= 4:
				World.notify(pid, "The pot is full.")
				return
			inv.take_from(slot, 1)
			var p2: Dictionary = pot.duplicate(true)
			(p2["items"] as Array).append(id)
			World.update(be["id"], {"pot": p2})
			World.fx("splash", at + Vector3(0, 0.4, 0))
		else:
			var food: Array = d.get("food", []).duplicate(true)
			if food.size() >= FOOD_MAX or not pot.is_empty():
				World.notify(pid, "No room to roast anything else." if pot.is_empty() else "Take the pot off to roast things on sticks.")
				return
			inv.take_from(slot, 1)
			food.append({"i": id, "t": 0.0, "cs": float(ItemDB.food(id).get("cook_s", 25.0)), "done": false})
			World.update(be["id"], {"food": food})
			World.fx("place_fuel", at + Vector3(0, 0.3, 0), {"i": id})
			if not bool(d["lit"]):
				World.notify(pid, "It will roast once the fire is lit.")
	elif id == "firestarter":
		pass   # the bow drill is held down: the client sends "ignite" when done
	else:
		return
	World.mark_inventory(pid)


func _bowl_at_pot(pid: int, be: Dictionary, slot: int, s: Dictionary) -> void:
	var d: Dictionary = be["d"]
	var pot: Dictionary = (d["pot"] as Dictionary).duplicate(true)
	var inv := World.inventory_of(pid)
	var content := String(s["d"].get("c", ""))
	if content == "" and int(pot.get("stew", 0)) > 0:
		pot["stew"] = int(pot["stew"]) - 1
		if int(s["n"]) > 1:
			inv.take_from(slot, 1)
			a.give(pid, "bowl", 1, {"c": "stew"})
		else:
			inv.set_data(slot, {"c": "stew"})
		World.update(be["id"], {"pot": pot})
		World.fx("splash", Vector3(d["cell"]) + Vector3(0.5, 0.6, 0.5))
		a.flag_player(pid, "made_stew")
	elif content == "water" and int(pot.get("stew", 0)) == 0 and int(pot.get("water", 0)) < 3:
		pot["water"] = int(pot["water"]) + 1
		inv.set_data(slot, {})
		World.update(be["id"], {"pot": pot})
		World.fx("splash", Vector3(d["cell"]) + Vector3(0.5, 0.6, 0.5))
	World.mark_inventory(pid)


func take_from_firepit(pid: int, be: Dictionary) -> void:
	## Empty hand: take what has roasted (or whatever is on the sticks), else the pot.
	var d: Dictionary = be["d"]
	var food: Array = d.get("food", []).duplicate(true)
	if not food.is_empty():
		var pick := 0
		for i in food.size():
			if bool(food[i].get("done", false)):
				pick = i
				break
		var f: Dictionary = food[pick]
		food.remove_at(pick)
		World.update(be["id"], {"food": food})
		a.give(pid, String(f["i"]), 1)
		if bool(f.get("done", false)) and String(f["i"]) != "charred_food":
			a.flag_player(pid, "cooked_food")
		return
	var pot: Dictionary = d.get("pot", {})
	if not pot.is_empty():
		if int(pot.get("stew", 0)) > 0:
			World.notify(pid, "Ladle the stew out with a bowl first.")
			return
		World.update(be["id"], {"pot": {}})
		a.give(pid, "pot", 1, {"w": int(pot.get("water", 0))} if int(pot.get("water", 0)) > 0 else {})


func firepit_contents(be: Dictionary) -> Array:
	var d: Dictionary = be["d"]
	var out: Array = []
	if not bool(d["lit"]):
		if int(d["tinder"]) > 0:
			out.append(Inventory.make("dry_grass", int(d["tinder"])))
		if int(d["sticks"]) > 0:
			out.append(Inventory.make("stick", int(d["sticks"])))
	if int(d["logs"]) > 0:
		out.append(Inventory.make("firewood", int(d["logs"])))
	for f in d.get("food", []):
		out.append(Inventory.make(String(f["i"]), 1))
	var pot: Dictionary = d.get("pot", {})
	if not pot.is_empty():
		out.append(Inventory.make("pot", 1))
		for it in pot.get("items", []):
			out.append(Inventory.make(String(it), 1))
	return out


# ---------------------------------------------------------------------------
# Lighting
# ---------------------------------------------------------------------------

func ignite(pid: int, args: Dictionary) -> void:
	var c: Vector3i = args.get("c", Vector3i(-1, -1, -1))
	var slot := int(args.get("slot", -1))
	if not a.in_reach(pid, c) or not a._rate(pid, "ignite", 800):
		return
	var s := a.held(pid, slot)
	var id := String(s.get("i", ""))
	if id != "firestarter" and id != "torch_lit":
		return
	var be := World.be(c)
	if be.is_empty():
		return
	var ok := false
	if be["t"] == "firepit":
		ok = _light_firepit(pid, be)
	elif be["t"] == "kiln":
		ok = _light_kiln(pid, be)
	if ok and id == "firestarter":
		a.wear_tool(pid, slot)


func _raining_on(c: Vector3i) -> bool:
	return float(World.env.get("rain", 0.0)) > 0.3 and World.vox.open_to_sky(c)


func _light_firepit(pid: int, be: Dictionary) -> bool:
	var d: Dictionary = be["d"]
	var c: Vector3i = d["cell"]
	if bool(d["lit"]):
		return false
	if int(d["tinder"]) <= 0:
		World.notify(pid, "It needs tinder underneath: right-click it with dry grass.", "warn")
		return false
	if int(d["sticks"]) <= 0:
		World.notify(pid, "Tinder alone burns out in seconds. Add some sticks.", "warn")
		return false
	if _raining_on(c):
		World.notify(pid, "Everything's soaked. Build it under cover, or wait for the rain to pass.", "warn")
		return false
	World.update(be["id"], {"lit": true, "ash": false, "phase": "tinder", "heat": 0.35, "rain_t": 0.0})
	World.fx("ignite", Vector3(c) + Vector3(0.5, 0.2, 0.5))
	a.flag_player(pid, "lit_fire")
	World.discover("first_fire", pid)
	return true


func use_kiln(pid: int, be: Dictionary, slot: int, sneak: bool) -> void:
	var d: Dictionary = be["d"]
	var c: Vector3i = d["cell"]
	var s := a.held(pid, slot)
	var id := String(s.get("i", ""))
	var inv := World.inventory_of(pid)
	var at := Vector3(c) + Vector3(0.5, 0.2, 0.5)
	if bool(d.get("lit", false)):
		World.notify(pid, "The kiln is burning. Leave it be.")
		return
	if ItemDB.fuel(id) == "tinder":
		if int(d["grass"]) >= KILN_GRASS:
			World.notify(pid, "The pottery is covered: now lay sticks over it.")
			return
		inv.take_from(slot, 1)
		World.update(be["id"], {"grass": int(d["grass"]) + 1})
		World.fx("place_fuel", at, {"i": id})
	elif id == "stick" or id == "firewood":
		if int(d["grass"]) < KILN_GRASS:
			World.notify(pid, "Cover the pottery with dry grass first (%d/%d)." % [int(d["grass"]), KILN_GRASS], "warn")
			return
		if int(d["sticks"]) >= KILN_STICKS:
			World.notify(pid, "Ready to fire: light it with a bow drill or a torch.")
			return
		inv.take_from(slot, 1)
		World.update(be["id"], {"sticks": int(d["sticks"]) + 1})
		World.fx("place_fuel", at, {"i": "stick"})
		if int(d["sticks"]) + 1 >= KILN_STICKS:
			World.hint_to(pid, "kiln_ready")
	elif id == "torch_lit":
		_light_kiln(pid, be)
	World.mark_inventory(pid)


static func enclosure(c: Vector3i) -> int:
	## How many of the four sides are walled by solid ground (a pit).
	var n := 0
	for o in [Vector3i.LEFT, Vector3i.RIGHT, Vector3i.FORWARD, Vector3i.BACK]:
		if Blocks.is_opaque(World.block(c + o)):
			n += 1
	return n


func _light_kiln(pid: int, be: Dictionary) -> bool:
	var d: Dictionary = be["d"]
	var c: Vector3i = d["cell"]
	if bool(d.get("lit", false)):
		return false
	if int(d["grass"]) < KILN_GRASS or int(d["sticks"]) < KILN_STICKS:
		World.notify(pid, "The kiln needs %d dry grass and then %d sticks over the pottery (%d/%d, %d/%d)." % [
			KILN_GRASS, KILN_STICKS, int(d["grass"]), KILN_GRASS, int(d["sticks"]), KILN_STICKS], "warn")
		return false
	if _raining_on(c):
		World.notify(pid, "It's too wet to light.", "warn")
		return false
	var enc := enclosure(c)
	World.update(be["id"], {"lit": true, "t": 0.0, "enc": enc, "rain_t": 0.0})
	World.fx("ignite", Vector3(c) + Vector3(0.5, 0.3, 0.5))
	if enc < 3:
		World.hint_to(pid, "kiln_open")
	a.flag_player(pid, "lit_kiln")
	return true


func kiln_contents(be: Dictionary) -> Array:
	var d: Dictionary = be["d"]
	var out: Array = (d.get("items", []) as Array).duplicate(true)
	if not bool(d.get("lit", false)):
		if int(d["grass"]) > 0:
			out.append(Inventory.make("dry_grass", int(d["grass"])))
		if int(d["sticks"]) > 0:
			out.append(Inventory.make("stick", int(d["sticks"])))
	return out


# ---------------------------------------------------------------------------
# Simulation (host, twice a second)
# ---------------------------------------------------------------------------

func tick(hours: float, real_dt: float) -> void:
	for e in World.entities_of("firepit"):
		if bool(e["d"]["lit"]):
			_burn(e, hours, real_dt)
	for e in World.entities_of("kiln"):
		if bool(e["d"].get("lit", false)):
			_fire_kiln(e, hours, real_dt)


func _burn(e: Dictionary, hours: float, real_dt: float) -> void:
	var d: Dictionary = e["d"]
	var c: Vector3i = d["cell"]
	var tf := float(d["tf"])
	var sf := float(d["sf"])
	var lf := float(d["lf"])
	var phase := String(d.get("phase", "tinder"))
	var rain := _raining_on(c)
	var burn := hours * (1.5 if rain else 1.0)
	var out_reason := ""
	# tinder, then sticks, then firewood: what's left of this step carries on to the next
	while burn > 1e-6 and out_reason == "":
		if tf > 0.0:
			var use_t := minf(burn, tf / 1.6)
			tf = maxf(0.0, tf - use_t * 1.6)
			burn -= use_t
			phase = "tinder"
			if tf <= 0.0 and sf <= 0.0:
				out_reason = "The tinder burned out without catching anything."
		elif sf > 0.0:
			var use_s := minf(burn, sf)
			sf -= use_s
			burn -= use_s
			phase = "sticks"
			d["caught"] = true
		elif lf > 0.0 and bool(d.get("caught", false)):
			var use_l := minf(burn, lf)
			lf -= use_l
			burn -= use_l
			phase = "logs"
		else:
			out_reason = "The fire has burned down." if phase != "tinder" else "Firewood won't catch from tinder alone. Add sticks."
	if out_reason == "" and tf <= 0.0 and sf <= 0.0 and (lf <= 0.0 or not bool(d.get("caught", false))):
		out_reason = "The fire has burned down." if phase != "tinder" else "Firewood won't catch from tinder alone. Add sticks."
	var rain_t := float(d.get("rain_t", 0.0))
	if rain and phase != "logs":
		rain_t += real_dt
		if rain_t > RAIN_OUT_S:
			out_reason = "The rain put the fire out."
	else:
		rain_t = 0.0
	d["tf"] = tf
	d["sf"] = sf
	d["lf"] = lf
	d["rain_t"] = rain_t
	var heat := {"tinder": 0.35, "sticks": 0.65, "logs": 1.0}.get(phase, 0.3) as float
	if rain:
		heat *= 0.7
	var changes := {}
	var tinder := int(ceil(tf / TINDER_H - 0.001))
	var sticks := int(ceil(sf / STICK_H - 0.001))
	var logs := int(ceil(lf / LOG_H - 0.001))
	if tinder != int(d["tinder"]):
		changes["tinder"] = tinder
	if sticks != int(d["sticks"]):
		changes["sticks"] = sticks
	if logs != int(d["logs"]):
		changes["logs"] = logs
	if phase != String(d.get("phase", "")):
		changes["phase"] = phase
	if absf(heat - float(d.get("heat", 0.0))) > 0.05:
		changes["heat"] = heat
	# roasting
	var food: Array = d.get("food", [])
	var food_changed := false
	var rate := 1.0 if heat >= 0.6 else 0.5
	for f in food:
		f["t"] = float(f["t"]) + real_dt * rate
		var cs := float(f.get("cs", 25.0))
		if not bool(f["done"]) and float(f["t"]) >= cs:
			f["i"] = String(ItemDB.food(String(f["i"])).get("cook", "charred_food"))
			f["done"] = true
			f["t"] = 0.0
			food_changed = true
		elif bool(f["done"]) and String(f["i"]) != "charred_food" and float(f["t"]) >= cs * 1.6:
			f["i"] = "charred_food"
			food_changed = true
	if food_changed:
		changes["food"] = food.duplicate(true)
		World.fx("sizzle", Vector3(c) + Vector3(0.5, 0.4, 0.5))
	# stew
	var pot: Dictionary = d.get("pot", {})
	if not pot.is_empty() and int(pot.get("water", 0)) > 0 and int(pot.get("stew", 0)) == 0 and not (pot.get("items", []) as Array).is_empty():
		pot["t"] = float(pot.get("t", 0.0)) + real_dt * rate
		if float(pot["t"]) >= STEW_S:
			var portions := mini((pot["items"] as Array).size() + 1, int(pot["water"]) * 2)
			changes["pot"] = {"water": 0, "items": [], "stew": maxi(1, portions), "t": 0.0}
			World.fx("sizzle", Vector3(c) + Vector3(0.5, 0.6, 0.5))
	if out_reason != "":
		changes["lit"] = false
		changes["ash"] = true
		changes["phase"] = ""
		changes["heat"] = 0.0
		changes["tinder"] = 0
		d["tf"] = 0.0
		d["caught"] = false
		World.fx("fire_out", Vector3(c) + Vector3(0.5, 0.3, 0.5))
		for pid in Net.players:
			if a.player_pos(pid).distance_to(Vector3(c)) < 12.0:
				World.notify(pid, out_reason)
	if not changes.is_empty():
		World.update(e["id"], changes)


func _fire_kiln(e: Dictionary, hours: float, real_dt: float) -> void:
	var d: Dictionary = e["d"]
	var c: Vector3i = d["cell"]
	var t := float(d.get("t", 0.0)) + hours
	d["t"] = t
	var rain_t := float(d.get("rain_t", 0.0))
	if _raining_on(c):
		rain_t += real_dt
		if rain_t > RAIN_OUT_S * 1.5:
			World.update(e["id"], {"lit": false, "grass": 0, "sticks": 0, "t": 0.0, "rain_t": 0.0})
			World.fx("fire_out", Vector3(c) + Vector3(0.5, 0.3, 0.5))
			for pid in Net.players:
				if a.player_pos(pid).distance_to(Vector3(c)) < 16.0:
					World.notify(pid, "The rain put out the pit kiln. The pottery is still raw.")
			return
	else:
		rain_t = 0.0
	d["rain_t"] = rain_t
	var stage := int(t / KILN_H * 4.0)
	if stage != int(d.get("stage", 0)):
		World.update(e["id"], {"stage": stage})
	if t < KILN_H:
		return
	# done: crack or fire every piece
	var enc := mini(int(d.get("enc", 0)), enclosure(c))
	var chance: float = CRACK[clampi(enc, 0, 4)]
	var results: Array = []
	var cracked := 0
	var fired := 0
	for s in d.get("items", []):
		var kind := ItemDB.fired_of(String(s["i"]))
		for i in int(s["n"]):
			if randf() < chance:
				cracked += 1
			else:
				fired += 1
				_add_stack(results, kind, 1)
	if cracked > 0:
		_add_stack(results, "potsherd", cracked)
	World.despawn(e["id"])
	World.spawn_be("ground", c, {"items": results, "ash": true})
	World.fx("kiln_done", Vector3(c) + Vector3(0.5, 0.3, 0.5))
	var msg := "The pit kiln has burned down: %d fired" % fired + (", %d cracked." % cracked if cracked > 0 else ".")
	if cracked > 0 and enc < 3:
		msg += " Pottery fired in a pit, walled in by earth, heats evenly and cracks less."
	for pid in Net.players:
		if a.player_pos(pid).distance_to(Vector3(c)) < 24.0:
			World.notify(pid, msg)
	if fired > 0:
		World.discover("first_pottery", 1)


func _add_stack(arr: Array, id: String, n: int) -> void:
	for s in arr:
		if String(s["i"]) == id and ItemDB.stack_max(id) >= int(s["n"]) + n:
			s["n"] = int(s["n"]) + n
			return
	arr.append(Inventory.make(id, n))


func heat_sources() -> Array:
	var out: Array = []
	for e in World.entities_of("firepit"):
		if bool(e["d"]["lit"]):
			out.append({"pos": Vector3(e["d"]["cell"]) + Vector3(0.5, 0.3, 0.5), "kw": float(e["d"].get("heat", 0.5))})
	for e in World.entities_of("kiln"):
		if bool(e["d"].get("lit", false)):
			out.append({"pos": Vector3(e["d"]["cell"]) + Vector3(0.5, 0.3, 0.5), "kw": 0.6})
	return out


func burning_at(p: Vector3) -> float:
	## Standing in a fire hurts.
	var c := VoxelData.cell_of(p + Vector3(0, 0.1, 0))
	var be := World.be(c)
	if be.is_empty() or be["t"] != "firepit" or not bool(be["d"]["lit"]):
		return 0.0
	return 0.06 * float(be["d"].get("heat", 0.5))
