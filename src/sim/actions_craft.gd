class_name ActionsCraft
extends RefCounted
## Host side of physical crafting.  A craft is a "work" entity sitting on a real
## surface that holds the materials taken from the crafter's inventory.  The
## crafter's close-up session sends small operations; the host applies them
## deterministically and replicates the result, so everyone sees the same stone
## chip or the same pot rise.

const KINDS := ["knap", "clay_prep", "pottery", "cordage", "haft", "fire_drill"]
const OP_RATE := 40  # most operations a second accepted from one crafter


static func register(a: Actions) -> void:
	for nm in ["work_start", "work_op", "work_finish", "work_cancel", "work_open", "work_close", "work_take"]:
		a.register(nm, Callable(ActionsCraft, "_" + nm).bind(a))


static func _surface_ok(a: Actions, pid: int, args: Dictionary, kind: String) -> Dictionary:
	var pos: Vector3 = args.get("pos", Vector3.ZERO)
	if not a.in_reach(pid, args, pos, 0.3):
		return {}
	var sid := int(args.get("surface", -1))
	var hard := false
	if sid >= 0:
		var s := World.get_entity(sid)
		if s.is_empty():
			return {}
		hard = String(s["t"]) in ["flat_stone", "boulder", "outcrop"]
	if kind == "knap" and not hard:
		World.notify(pid, "Knapping needs a hard anvil stone.")
		return {}
	var below := a.settle_point(pos + Vector3(0, 0.05, 0))
	if below == Vector3.INF or below.y < pos.y - 0.25:
		World.notify(pid, "There's nothing there to work on.")
		return {}
	for e in World.entities_near(pos, 0.24, "work"):
		World.notify(pid, "There's already work in progress right there.")
		return {}
	for e in World.entities_near(pos, 0.3, "work"):
		if int(e["d"].get("by", 0)) == pid:
			World.notify(pid, "Finish or gather up your other work first.")
			return {}
	return {"pos": pos, "hard": hard}


static func _work_start(pid: int, args: Dictionary, a: Actions) -> void:
	var kind := String(args.get("kind", ""))
	if not kind in KINDS:
		return
	var ok := _surface_ok(a, pid, args, kind)
	if ok.is_empty():
		return
	var inv := a.inv(pid)
	var held := a.held(pid, args)
	var hid := String(held.get("i", ""))
	var d := {"kind": kind, "by": pid, "t0": World.hours()}
	match kind:
		"knap":
			if hid == "stone":
				if inv.count("stone") < 2:
					World.notify(pid, "You need a second stone to strike with.")
					return
				a.take_held(pid, args, 1)
				var seed_value := randi() % 1000000 + 1
				d.merge({"seed": seed_value, "cuts": [], "flipped": false, "target": "blade", "strikes": 0, "kg": ItemDB.unit_mass("stone")})
			elif hid == "stone_head" or hid == "blade":
				if inv.count("stone") < 1:
					World.notify(pid, "You need a stone to strike with.")
					return
				var hd: Dictionary = held["d"]
				a.take_held(pid, args, 1)
				d.merge({"seed": int(hd.get("seed", 1)), "cuts": hd.get("cuts", []).duplicate(), "flipped": false,
					"target": String(hd.get("shape", "blade")) if String(hd.get("shape", "")) != "" else "blade",
					"strikes": int(hd.get("strikes", 0)), "kg": float(hd.get("stone_kg", 0.4))})
			else:
				return
		"clay_prep":
			if hid != "clay":
				return
			var n := mini(int(held["n"]), 4)
			var m := float(held["d"].get("moist", ItemDB.default_moist("clay")))
			a.take_held(pid, args, n)
			d.merge({"vol": n * Pottery.LUMP_L, "moist": m, "homog": 0.0, "grit": 1.0, "kneads": 0})
		"pottery":
			if hid != "clay_prepared":
				return
			var n2 := mini(int(held["n"]), 4)
			var m2 := float(held["d"].get("moist", ItemDB.default_moist("clay_prepared")))
			a.take_held(pid, args, n2)
			var pot := Pottery.new_lump(n2 * Pottery.LUMP_L, m2, randi() % 100000 + 1)
			d.merge({"pot": pot})
			World.hint_to(pid, "pottery_start")
		"cordage":
			if hid != "fiber" or inv.count("fiber") < 2:
				return
			inv.remove("fiber", 2)
			World.mark_inventory(pid)
			d.merge({"fibers": 2, "prog": 0.0, "even": 1.0, "kinks": 0})
		"fire_drill":
			if not ActionsFire.drill_start(a, pid, args, d):
				return
		"haft":
			if hid != "stone_head":
				return
			var hd2: Dictionary = held["d"]
			var shape := String(hd2.get("shape", ""))
			if shape != "axe" and shape != "digger":
				World.notify(pid, "That stone isn't shaped for a handle. Knap it into an axe head or digging blade first.")
				return
			if inv.count("stick") < 1 or inv.count("cordage") < 1:
				World.notify(pid, "Hafting needs a stick and cordage.")
				return
			a.take_held(pid, args, 1)
			inv.remove("stick", 1)
			inv.remove("cordage", 1)
			World.mark_inventory(pid)
			d.merge({"head": hd2.duplicate(true), "stage": "seat", "seat": Vector3(0.12, 0.0, 0.0), "angle": 0.6, "align": 0.0,
				"wraps": 0.0, "tight": 0.0, "cords": 1})
	var yaw := atan2(-(ok["pos"] - a.eye(pid, args)).x, -(ok["pos"] - a.eye(pid, args)).z)
	var xf := Transform3D(Basis(Vector3.UP, yaw), ok["pos"] + Vector3(0, 0.005, 0))
	var eid := World.spawn("work", xf, d)
	World.fx("drop", ok["pos"], {"vol": -8.0})
	open_session_for(pid, eid)


static func open_session_for(pid: int, eid: int) -> void:
	if pid == World.multiplayer.get_unique_id():
		var cc := World.get_tree().get_first_node_in_group("crafting")
		if cc:
			cc.open.call_deferred(eid)
	else:
		World.open_craft(pid, eid)


static func _work_open(pid: int, args: Dictionary, a: Actions) -> void:
	var eid := int(args.get("eid", -1))
	var e := World.get_entity(eid)
	if e.is_empty() or e["t"] != "work" or not a.in_reach(pid, args, e["xf"].origin, 0.4):
		return
	var by := int(e["d"].get("by", 0))
	if by != 0 and by != pid and Net.players.has(by):
		World.notify(pid, "%s is working on that." % Net.player_name(by))
		return
	World.update(eid, {"by": pid})
	open_session_for(pid, eid)


static func _work_close(pid: int, args: Dictionary, a: Actions) -> void:
	var eid := int(args.get("eid", -1))
	var e := World.get_entity(eid)
	if e.is_empty() or int(e["d"].get("by", 0)) != pid:
		return
	World.update(eid, {"by": 0})


static func _owner_ok(pid: int, eid: int) -> Dictionary:
	var e := World.get_entity(eid)
	if e.is_empty() or e["t"] != "work" or int(e["d"].get("by", 0)) != pid:
		return {}
	return e


# ---------------------------------------------------------------------------
# Operations
# ---------------------------------------------------------------------------

static var _op_budget: Dictionary = {}   # pid -> [ops it may still send, msec]


static func _rate_ok(pid: int) -> bool:
	## A visitor can't flood a workpiece with operations: OP_RATE a second, in
	## bursts of up to as many (the close-ups send 7-25 a second).
	if pid == Net.my_id():
		return true
	var now := Time.get_ticks_msec()
	var b: Array = _op_budget.get(pid, [float(OP_RATE), now])
	var left := minf(float(OP_RATE), float(b[0]) + (now - int(b[1])) * 0.001 * OP_RATE)
	_op_budget[pid] = [maxf(0.0, left - 1.0), now]
	return left >= 1.0


static func _work_op(pid: int, args: Dictionary, a: Actions) -> void:
	var eid := int(args.get("eid", -1))
	var e := _owner_ok(pid, eid)
	if e.is_empty() or not _rate_ok(pid):
		return
	var op: Array = args.get("op", [])
	if op.is_empty():
		return
	var d: Dictionary = e["d"]
	match String(d["kind"]):
		"knap":
			_knap_op(a, pid, e, op)
		"clay_prep":
			_clay_op(a, pid, e, op)
		"pottery":
			_pot_op(a, pid, e, op, args)
		"cordage":
			_cord_op(a, pid, e, op)
		"haft":
			_haft_op(a, pid, e, op)
		"fire_drill":
			ActionsFire.drill_op(a, pid, e, op)


static func _world_point(e: Dictionary, local: Vector3) -> Vector3:
	return (e["xf"] as Transform3D) * local


static func _knap_op(a: Actions, pid: int, e: Dictionary, op: Array) -> void:
	var d: Dictionary = e["d"]
	match String(op[0]):
		"target":
			var t := String(op[1])
			if Knap.TARGETS.has(t):
				World.update(e["id"], {"target": t})
		"flip":
			World.update(e["id"], {"flipped": not bool(d.get("flipped", false))})
			World.fx("stone_drop", _world_point(e, Vector3(0, 0.02, 0)), {"sound": "stone_drop", "amount": 0, "vol": -10.0})
		"strike":
			if a.inv(pid).count("stone") < 1:
				World.notify(pid, "You need a stone in hand to strike with.")
				return
			var power := clampf(float(op[3]), 0.0, 1.0)
			var click := Vector2(float(op[1]), float(op[2]))
			var cuts: Array = d.get("cuts", [])
			var res := Knap.strike(int(d["seed"]), cuts, bool(d.get("flipped", false)), click, power, int(d["seed"]) * 131 + int(d.get("strikes", 0)))
			if res["miss"]:
				return
			var new_cuts := cuts.duplicate()
			new_cuts.append(res["cut"])
			var removed_kg := float(res["removed_l"]) * Knap.DENSITY
			World.pools["debris_stone_kg"] = float(World.pools.get("debris_stone_kg", 0.0)) + removed_kg
			var changes := {"cuts": new_cuts, "strikes": int(d.get("strikes", 0)) + 1, "kg": float(d.get("kg", 0.9)) - removed_kg}
			var c: Vector2 = res["contact"]
			var wp := _world_point(e, Vector3(c.x, 0.02, c.y))
			if res["broke"]:
				changes["broke"] = true
				World.fx("stone_break", wp)
				World.notify(pid, "Crack! The stone snapped - a heavy blow across a narrow part. Work what's left, or start over.", "warn")
			else:
				World.fx("chips", wp, {"pitch": lerpf(1.25, 0.8, power), "vol": lerpf(-6.0, 1.0, power), "amount": int(lerpf(5, 16, power))})
			World.update(e["id"], changes)
			a.exert(pid, 0.004 + power * 0.01)


static func _clay_op(a: Actions, pid: int, e: Dictionary, op: Array) -> void:
	var d: Dictionary = e["d"]
	var vol := float(d["vol"])
	var m := float(d["moist"])
	match String(op[0]):
		"water":
			# a splash from the pond (if close) or from a held water vessel
			var amount := 0.012
			var p := a.player_pos(pid)
			var got := 0.0
			if World.terrain.pond_q(Vector2(p.x, p.z)) < 2.6 and float(World.env.get("pond_l", 0.0)) > 1.0:
				got = amount
				World.env["pond_l"] = float(World.env["pond_l"]) - got
			else:
				var inv := a.inv(pid)
				var i := inv.find_where(func(s): return s["i"] == "pot" and float(s["d"].get("water", 0.0)) > 0.0)
				if i >= 0:
					var pd: Dictionary = inv.get_slot(i)["d"].duplicate(true)
					got = minf(amount, float(pd["water"]))
					pd["water"] = float(pd["water"]) - got
					inv.set_data(i, pd)
					World.mark_inventory(pid)
			if got <= 0.0:
				World.notify(pid, "No water within reach. Work near the pond, or carry water in a fired vessel.")
				return
			World.update(e["id"], {"moist": m + got / vol})
			World.fx("pour", _world_point(e, Vector3(0, 0.06, 0)), {"amount": 4, "vol": -10.0})
		"knead":
			var strength := clampf(float(op[1]), 0.2, 1.0)
			var homog := float(d["homog"])
			var grit := float(d["grit"])
			var gain := 0.16 * strength
			var note := ""
			if m < 0.19:
				gain *= 0.25
				note = "dry"
			elif m > 0.31:
				gain *= 0.5
				note = "wet"
			homog = minf(1.0, homog + gain)
			grit = maxf(0.0, grit - 0.2 * strength)
			# working clay in the open slowly dries it (never past bone dry)
			var dry := minf(0.0015 * strength, maxf(0.0, m - 0.02))
			World.pools["atmo_water_l"] = float(World.pools.get("atmo_water_l", 0.0)) + dry * vol
			World.update(e["id"], {"homog": homog, "grit": grit, "moist": m - dry, "kneads": int(d.get("kneads", 0)) + 1, "note": note})
			World.fx("clay_squish", _world_point(e, Vector3(0, 0.05, 0)), {"amount": 3})
			a.exert(pid, 0.006)


static func _pot_op(a: Actions, pid: int, e: Dictionary, op: Array, args: Dictionary) -> void:
	var d: Dictionary = e["d"]
	var pot: Dictionary = d["pot"]
	var kind := String(op[0])
	if kind == "add":
		var inv := a.inv(pid)
		if inv.count("clay_prepared") < 1:
			World.notify(pid, "You have no prepared clay to add.")
			return
		var s := inv.take_from(inv.find("clay_prepared"), 1)
		var lm := float(s["d"].get("moist", ItemDB.default_moist("clay_prepared")))
		World.mark_inventory(pid)
		# mix moisture by volume
		var v0 := float(pot["vol"])
		pot["moist"] = (float(pot["moist"]) * v0 + lm * Pottery.LUMP_L) / (v0 + Pottery.LUMP_L)
		Pottery.apply_op(pot, ["add", Pottery.LUMP_L])
		World.fx("clay_squish", _world_point(e, Vector3(0, 0.05, 0)), {"sound": "clay_slap"})
	elif kind == "trim":
		var res := Pottery.apply_op(pot, ["trim", float(op[1])])
		var lumps := int(res.get("lumps", 0))
		if lumps > 0:
			a.give(pid, "clay_prepared", lumps, {"moist": float(pot["moist"])})
		World.fx("clay_squish", _world_point(e, Vector3(0, 0.08, 0)))
	elif kind in ["shape", "hollow", "smooth", "rim"]:
		var clean: Array = [kind]
		for i in range(1, op.size()):
			clean.append(clampf(float(op[i]), -1.0, 1.0))
		while clean.size() < 4:
			clean.append(0.0)
		var m_before := float(pot["moist"])
		Pottery.apply_op(pot, clean)
		# smoothing with wet hands uses a little water from the pond or a vessel (if any)
		var used := (float(pot["moist"]) - m_before) * float(pot["vol"])
		if used > 0.0:
			var pond := float(World.env.get("pond_l", 0.0))
			var take := minf(used, pond)
			World.env["pond_l"] = pond - take
			if take < used:
				pot["moist"] = m_before + take / float(pot["vol"])
	else:
		return
	World.update(e["id"], {"pot": pot})


static func _cord_op(a: Actions, pid: int, e: Dictionary, op: Array) -> void:
	var d: Dictionary = e["d"]
	if String(op[0]) != "twist":
		return
	var amount := clampf(float(op[1]), 0.0, 0.2)
	var evenness := clampf(float(op[2]), 0.0, 1.0)
	var prog := float(d["prog"]) + amount
	var even := lerpf(float(d.get("even", 1.0)), evenness, 0.15)
	World.update(e["id"], {"prog": minf(prog, 1.0), "even": even})
	if int(prog * 8.0) != int(float(d["prog"]) * 8.0):
		World.fx("bind", _world_point(e, Vector3(0, 0.03, 0)), {"sound": "rope_twist", "amount": 2})
	if prog >= 1.0:
		_finish_cordage(a, pid, e)


static func _haft_op(a: Actions, pid: int, e: Dictionary, op: Array) -> void:
	var d: Dictionary = e["d"]
	match String(op[0]):
		"seat":
			var p := Vector3(clampf(float(op[1]), -0.3, 0.3), 0.0, clampf(float(op[2]), -0.2, 0.2))
			var ang := float(op[3])
			var tip := Vector3(0.21, 0.0, 0.0)
			var dist := Vector2(p.x - tip.x, p.z - tip.z).length()
			var ideal := 0.0 if String(d["head"].get("shape", "axe")) == "axe" else PI * 0.5
			var ang_err := absf(wrapf(ang - ideal, -PI * 0.5, PI * 0.5))
			var align := clampf(1.0 - dist / 0.06, 0.0, 1.0) * clampf(1.0 - ang_err / 0.9, 0.0, 1.0)
			var stage := "bind" if dist < 0.035 else "seat"
			World.update(e["id"], {"seat": p, "angle": ang, "align": align, "stage": stage})
		"wrap":
			if String(d.get("stage", "")) == "seat":
				return
			var w := minf(14.0, float(d["wraps"]) + clampf(float(op[1]), 0.0, 0.5))
			World.update(e["id"], {"wraps": w, "stage": "bind"})
			if int(w) != int(float(d["wraps"])):
				World.fx("bind", _world_point(e, Vector3(0.2, 0.03, 0)), {"sound": "rope_twist", "amount": 2})
		"tighten":
			if float(d["wraps"]) < 2.0:
				return
			var t := minf(1.0, float(d["tight"]) + clampf(float(op[1]), 0.0, 0.3))
			World.update(e["id"], {"tight": t, "stage": "tight"})
			World.fx("bind", _world_point(e, Vector3(0.2, 0.03, 0)), {"sound": "rope_tighten", "amount": 1})


# ---------------------------------------------------------------------------
# Finishing
# ---------------------------------------------------------------------------

static func _work_finish(pid: int, args: Dictionary, a: Actions) -> void:
	var eid := int(args.get("eid", -1))
	var e := _owner_ok(pid, eid)
	if e.is_empty():
		return
	match String(e["d"]["kind"]):
		"knap":
			_finish_knap(a, pid, e)
		"clay_prep":
			_finish_clay(a, pid, e)
		"pottery":
			_finish_pot(a, pid, e)
		"cordage":
			World.notify(pid, "Keep twisting until the cord is a full length.")
		"haft":
			_finish_haft(a, pid, e)
		"fire_drill":
			ActionsFire.drill_finish(a, pid, e)


static func _result(pid: int, e: Dictionary, text: String, kind: String = "info") -> void:
	World.craft_result(pid, int(e["id"]), text, kind)


static func _finish_knap(a: Actions, pid: int, e: Dictionary) -> void:
	var d: Dictionary = e["d"]
	var target := String(d.get("target", "blade"))
	var ev := Knap.evaluate(int(d["seed"]), d.get("cuts", []), target)
	var head := {"seed": int(d["seed"]), "cuts": d.get("cuts", []).duplicate(), "q": snappedf(float(ev["q"]), 0.01),
		"stone_kg": float(d.get("kg", 0.4)), "strikes": int(d.get("strikes", 0))}
	World.despawn(e["id"])
	if not ev["usable"]:
		head["shape"] = ""
		a.give(pid, "stone_head", 1, head)
		var notes: PackedStringArray = ev["notes"]
		_result(pid, e, "Not yet %s.\n%s\nYou kept the stone - place it on the anvil to keep working it." % [ItemDB.with_article(String(Knap.TARGETS[target]["name"]).to_lower()), "\n".join(notes)], "warn")
		return
	var q := float(ev["q"])
	var word := ItemDB.quality_word(q)
	if target == "blade":
		head["dur"] = 1.0
		a.give(pid, "blade", 1, head)
		World.discover("first_blade", pid)
	else:
		head["shape"] = target
		a.give(pid, "stone_head", 1, head)
		World.discover("first_" + target + "_head", pid)
	var tail := ""
	if ev["notes"].size() > 0:
		tail = "\n" + ev["notes"][0]
	_result(pid, e, "%s %s.  Outline %d%%, edge %d%%.%s" % [word, String(Knap.TARGETS[target]["name"]).to_lower(),
		int(float(ev["shape"]) * 100.0), int(float(ev["edge"]) * 100.0), tail], "craft")


static func _finish_clay(a: Actions, pid: int, e: Dictionary) -> void:
	var d: Dictionary = e["d"]
	var m := float(d["moist"])
	var homog := float(d["homog"])
	var n := int(round(float(d["vol"]) / Pottery.LUMP_L))
	if homog < 0.85:
		_result(pid, e, "Keep kneading - the clay is still lumpy and gritty.", "warn")
		return
	if m < 0.2:
		_result(pid, e, "Too dry to shape - it would crack. Add a little water and knead it in.", "warn")
		return
	if m > 0.31:
		_result(pid, e, "Too wet and sticky to hold a shape. Knead it longer to work some water out.", "warn")
		return
	World.despawn(e["id"])
	a.give(pid, "clay_prepared", n, {"moist": m})
	World.discover("first_prepared_clay", pid)
	_result(pid, e, "Smooth, even clay - ready to shape.", "craft")


static func _finish_pot(a: Actions, pid: int, e: Dictionary) -> void:
	var d: Dictionary = e["d"]
	var pot: Dictionary = d["pot"].duplicate(true)
	Pottery.finalize(pot)
	var xf: Transform3D = e["xf"]
	World.despawn(e["id"])
	# the wet pot stays where it was made, to be carried off carefully and dried
	World.spawn("item", xf, {"i": "pot", "n": 1, "x": pot})
	World.discover("first_pot", pid)
	var s := Pottery.stats(pot)
	var lines: PackedStringArray = ["A %s." % Pottery.display_name(pot).to_lower()]
	if String(pot["kind"]) != "lump":
		lines.append("It will hold about %.2f L once fired." % float(s["capacity_l"]))
	lines.append_array(Pottery.feedback(pot))
	lines.append("Let it dry completely before firing.")
	_result(pid, e, "\n".join(lines), "craft")


static func _finish_cordage(a: Actions, pid: int, e: Dictionary) -> void:
	var n0 := int(e["d"].get("fibers", 2))
	# a lumpy, uneven twist doesn't hold together: the fiber comes back to try again
	var even := float(e["d"].get("even", 1.0))
	if randf() < clampf((0.55 - even) / 0.35, 0.0, 0.85):
		World.despawn(e["id"])
		a.give(pid, "fiber", n0)
		_result(pid, e, "The twist was too uneven and the cord came apart. Long, steady strokes make a cord that holds.", "warn")
		return
	World.despawn(e["id"])
	a.give(pid, "cordage", 1)
	# a few short fibres are lost in twisting; they go back to the soil
	var n := int(e["d"].get("fibers", 2))
	World.pools["soil_organic_kg"] = float(World.pools.get("soil_organic_kg", 0.0)) + maxf(0.0, n * ItemDB.unit_mass("fiber") - ItemDB.unit_mass("cordage"))
	TerrainActions.add_nutrients(e["xf"].origin, maxf(0.0, n * ItemDB.nutrients("fiber") - ItemDB.nutrients("cordage")))
	World.discover("first_cordage", pid)
	_result(pid, e, "A length of two-ply cord.", "craft")


static func _finish_haft(a: Actions, pid: int, e: Dictionary) -> void:
	var d: Dictionary = e["d"]
	if String(d.get("stage", "")) == "seat":
		_result(pid, e, "Seat the head against the end of the handle first.", "warn")
		return
	var wraps := float(d["wraps"])
	if wraps < 3.0:
		_result(pid, e, "Wind the cord around the joint a few more times.", "warn")
		return
	var head: Dictionary = d["head"]
	var wrap_score := clampf((wraps - 2.0) / 4.0, 0.0, 1.0) * clampf(1.0 - maxf(0.0, wraps - 11.0) / 4.0, 0.4, 1.0)
	var bind := wrap_score * (0.35 + 0.65 * float(d["tight"]))
	var q := clampf(float(head.get("q", 0.5)) * 0.55 + float(d["align"]) * 0.2 + bind * 0.25, 0.05, 1.0)
	var shape := String(head.get("shape", "axe"))
	var tool_id := "axe" if shape == "axe" else "digger"
	World.despawn(e["id"])
	a.give(pid, tool_id, 1, {"q": snappedf(q, 0.01), "dur": 1.0, "head": head, "wraps": int(wraps), "bind": snappedf(bind, 0.01),
		"align": snappedf(float(d["align"]), 0.01), "cords": 1})
	World.discover("first_" + tool_id, pid)
	var note := ""
	if float(d["tight"]) < 0.5:
		note = "\nThe binding is loose - it will wear out sooner."
	elif float(d["align"]) < 0.5:
		note = "\nThe head sits a little crooked."
	var what := ItemDB.with_article("%s %s" % [ItemDB.quality_word(q).to_lower(), ItemDB.display_name(tool_id).to_lower()])
	_result(pid, e, "%s%s.%s" % [what.substr(0, 1).to_upper(), what.substr(1), note], "craft")


static func _work_cancel(pid: int, args: Dictionary, a: Actions) -> void:
	## Gather the work back up: every material returns.
	var eid := int(args.get("eid", -1))
	var e := World.get_entity(eid)
	if e.is_empty() or e["t"] != "work" or not a.in_reach(pid, args, e["xf"].origin, 0.5):
		return
	var by := int(e["d"].get("by", 0))
	if by != 0 and by != pid and Net.players.has(by):
		return
	var d: Dictionary = e["d"]
	World.despawn(eid)
	match String(d["kind"]):
		"knap":
			if int(d.get("strikes", 0)) == 0:
				a.give(pid, "stone", 1)
			else:
				a.give(pid, "stone_head", 1, {"seed": int(d["seed"]), "cuts": d.get("cuts", []), "q": 0.0, "shape": "",
					"stone_kg": float(d.get("kg", 0.4)), "strikes": int(d.get("strikes", 0))})
		"clay_prep":
			a.give(pid, "clay", int(round(float(d["vol"]) / Pottery.LUMP_L)), {"moist": float(d["moist"])})
		"pottery":
			var pot: Dictionary = d["pot"]
			var lumps := int(round(float(pot["vol"]) / Pottery.LUMP_L))
			World.pools["clay_spilled_l"] = float(World.pools.get("clay_spilled_l", 0.0)) + float(pot["vol"]) - lumps * Pottery.LUMP_L
			a.give(pid, "clay_prepared", lumps, {"moist": float(pot["moist"])})
		"cordage":
			a.give(pid, "fiber", int(d.get("fibers", 2)))
		"haft":
			a.give(pid, "stone_head", 1, d["head"])
			a.give(pid, "stick", 1)
			a.give(pid, "cordage", 1)
		"fire_drill":
			ActionsFire.drill_cancel(a, pid, d)
	World.fx("pickup", e["xf"].origin)


static func _work_take(pid: int, args: Dictionary, a: Actions) -> void:
	pass
