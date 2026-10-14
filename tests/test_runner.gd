extends Node
## Automated gameplay tests.  Runs a real (solo-hosted) island and drives it
## through the same requests a player's clicks produce.
##   godot --headless --path . res://tests/test_main.tscn -- --suite=all|craft|economy|survival|save

var failures := 0
var passes := 0
var lp: LocalPlayer
var _log: PackedStringArray = []


func _ready() -> void:
	await get_tree().process_frame
	var suite := String(Game.cli.get("suite", "all"))
	var err := Game.start_world("solo", "AutoTest_%d" % (randi() % 100000), true)
	if err != "":
		print("START FAILED: ", err)
		get_tree().quit(2)
		return
	await frames(10)
	lp = Game.game_world.local_player()
	var suites := ["craft", "survival", "farm", "fire", "build", "save"] if suite == "all" else [suite]
	for s in suites:
		if has_method("suite_" + s):
			print("\n=== SUITE ", s, " ===")
			# every suite starts from the same dice and a clear sky, so runs are repeatable
			seed(20261014 + suites.find(s))
			World.env["rain"] = 0.0
			World.env["rain_target"] = 0.0
			World.env["cloud"] = 0.2
			await call("suite_" + s)
	print("\nRESULT: %d passed, %d failed" % [passes, failures])
	for l in _log:
		print(l)
	Sfx.shutdown()
	await get_tree().create_timer(0.3).timeout
	get_tree().quit(1 if failures > 0 else 0)


func frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame


func check(cond: bool, msg: String) -> void:
	if cond:
		passes += 1
		print("  ok   ", msg)
	else:
		failures += 1
		print("  FAIL ", msg)
		_log.append("FAIL: " + msg)


func inv() -> Inventory:
	return World.inventory_of(Net.my_id())


var injected := Ledger.empty()


func give(id: String, n: int = 1, d: Dictionary = {}) -> void:
	## Test-only: conjure items.  Recorded so ledger checks can subtract them.
	inv().add(id, n, d)
	World.mark_inventory(Net.my_id())
	Ledger._add(injected, Ledger.item_contrib(id, n, d))


func slot_of(id: String) -> int:
	return inv().find(id)


func req(action: String, args: Dictionary = {}) -> void:
	if not args.has("eye"):
		args["eye"] = lp.eye_position()
	World.request(action, args)


func stand_near(p: Vector3, offset: Vector3 = Vector3(0, 0, 0.9)) -> void:
	var q := p + offset
	q.y = World.terrain.height(q.x, q.z) + 0.05
	lp.global_position = q
	lp.velocity = Vector3.ZERO
	await frames(3)


func newest(t: String) -> Dictionary:
	var best := {}
	for e in World.entities.values():
		if e["t"] == t and (best.is_empty() or int(e["id"]) > int(best["id"])):
			best = e
	return best


func flat_stone_top() -> Vector3:
	var fs := newest("flat_stone")
	var v: Node = Game.game_world.entities.view(int(fs["id"]))
	var top: float = v.work_top()
	return Vector3(fs["xf"].origin.x, top, fs["xf"].origin.z)


func ledger() -> Dictionary:
	var L := Ledger.compute()
	for k in Ledger.KEYS:
		L[k] = float(L[k]) - float(injected[k])
	return L


func ledger_same(a: Dictionary, b: Dictionary, label: String, tol: Dictionary = {}) -> void:
	for k in Ledger.KEYS:
		var t := float(tol.get(k, 0.0005 if k != "water" else 0.01))
		var diff := absf(float(a[k]) - float(b[k]))
		check(diff <= t, "%s: %s conserved (%.5f -> %.5f, diff %.6f)" % [label, k, a[k], b[k], diff])


# ---------------------------------------------------------------------------
# Crafting
# ---------------------------------------------------------------------------

func suite_craft() -> void:
	var L0 := ledger()
	await test_knap_blade()
	await test_knap_axe_and_haft()
	await test_cordage()
	await test_clay_and_pottery()
	var L1 := ledger()
	ledger_same(L0, L1, "crafting")


func _work() -> Dictionary:
	for e in World.entities.values():
		if e["t"] == "work" and int(e["d"].get("by", 0)) == Net.my_id():
			return e
	return {}


func auto_knap(target: String) -> Dictionary:
	## A scripted knapper: heavy blows where stone sticks out past the outline,
	## then light taps along the working edges from both faces.
	var w := _work()
	if w.is_empty():
		return {}
	var eid := int(w["id"])
	req("work_op", {"eid": eid, "op": ["target", target]})
	await frames(2)
	var p := Knap.params(int(w["d"]["seed"]))
	var tgt := Knap.target_poly(p, target)
	for round_i in 6:
		for step in 40:
			w = World.get_entity(eid)
			if w.is_empty():
				return {}
			var cuts: Array = w["d"]["cuts"]
			var ang := step * TAU / 40.0
			var dir := Vector2(cos(ang), sin(ang))
			var edge := Knap.outline_point(p, cuts, dir)
			var t_edge := _poly_reach(tgt, dir)
			var excess := edge.length() - t_edge
			if excess > 0.0025:
				var power := clampf((excess - 0.001) / 0.016, 0.12, 0.65)
				req("work_op", {"eid": eid, "op": ["strike", edge.x, edge.y, power]})
				await frames(1)
		# work the other face too (bifacial)
		req("work_op", {"eid": eid, "op": ["flip"]})
		await frames(2)
	# sharpen the working edges from both faces
	for face in 2:
		w = World.get_entity(eid)
		if w.is_empty():
			return {}
		for seg in Knap.TARGETS[target]["edge"]:
			for k in 7:
				w = World.get_entity(eid)
				var pa := Vector2(seg[0][0] * p["a"] * 0.95, seg[0][1] * p["b"] * 0.95)
				var pb := Vector2(seg[1][0] * p["a"] * 0.95, seg[1][1] * p["b"] * 0.95)
				var q := pa.lerp(pb, (k + 0.5) / 7.0)
				var e2 := Knap.outline_point(p, w["d"]["cuts"], q.normalized())
				req("work_op", {"eid": eid, "op": ["strike", e2.x, e2.y, 0.05]})
				await frames(1)
		req("work_op", {"eid": eid, "op": ["flip"]})
		await frames(2)
	w = World.get_entity(eid)
	return Knap.evaluate(int(w["d"]["seed"]), w["d"]["cuts"], target)


func _poly_reach(poly: PackedVector2Array, dir: Vector2) -> float:
	var r := 0.0
	while r < 0.15 and Geometry2D.is_point_in_polygon(dir * (r + 0.001), poly):
		r += 0.001
	return r


func test_knap_blade() -> void:
	seed(1717)
	print("-- knapping a blade")
	give("stone", 2)
	var top := flat_stone_top()
	await stand_near(top, Vector3(0, 0, 0.8))
	var s := slot_of("stone")
	req("work_start", {"kind": "knap", "surface": int(newest("flat_stone")["id"]), "pos": top + Vector3(-0.1, 0, 0), "slot": s})
	await frames(3)
	var w := _work()
	check(not w.is_empty(), "knapping workpiece created on the flat stone")
	check(inv().count("stone") == 1, "one stone taken into the work, one kept as hammer")
	var ev := await auto_knap("blade")
	print("     evaluation: ", ev)
	check(float(ev.get("q", 0.0)) > 0.35, "scripted knapping reaches a usable blade (q=%.2f)" % float(ev.get("q", 0.0)))
	req("work_finish", {"eid": int(_work()["id"])})
	await frames(3)
	check(_work().is_empty(), "workpiece consumed on finish")
	check(inv().count("blade") == 1 or inv().count("stone_head") == 1, "finished knapping yields a blade (or a shaped stone)")
	check(World.pools.get("debris_stone_kg", 0.0) > 0.0, "knapping flakes accounted as debris")


func test_knap_axe_and_haft() -> void:
	print("-- knapping an axe head and hafting it")
	seed(4242)
	give("stone", 2)
	var top := flat_stone_top()
	await stand_near(top, Vector3(0, 0, 0.8))
	req("work_start", {"kind": "knap", "surface": int(newest("flat_stone")["id"]), "pos": top + Vector3(0.12, 0, 0.0), "slot": slot_of("stone")})
	await frames(3)
	var ev := await auto_knap("axe")
	print("     evaluation: ", ev)
	req("work_finish", {"eid": int(_work()["id"])})
	await frames(3)
	var hi := inv().find_where(func(s): return s["i"] == "stone_head" and String(s["d"].get("shape", "")) == "axe")
	check(hi >= 0, "axe head produced (q=%.2f)" % float(ev.get("q", 0.0)))
	if hi < 0:
		return
	give("stick", 1)
	give("cordage", 1)
	req("work_start", {"kind": "haft", "surface": int(newest("flat_stone")["id"]), "pos": top + Vector3(-0.05, 0, -0.05), "slot": hi})
	await frames(3)
	var w := _work()
	check(not w.is_empty() and String(w["d"]["kind"]) == "haft", "hafting workpiece created")
	var eid := int(w["id"])
	req("work_op", {"eid": eid, "op": ["seat", 0.205, 0.0, 0.05]})
	await frames(2)
	check(String(World.get_entity(eid)["d"]["stage"]) == "bind", "head seated on the handle")
	for i in 16:
		req("work_op", {"eid": eid, "op": ["wrap", 0.5]})
	await frames(2)
	for i in 5:
		req("work_op", {"eid": eid, "op": ["tighten", 0.25]})
	await frames(2)
	req("work_finish", {"eid": eid})
	await frames(3)
	var ai := inv().find("axe")
	check(ai >= 0, "a stone axe was assembled")
	if ai >= 0:
		print("     axe: ", inv().get_slot(ai)["d"].get("q"), " wraps ", inv().get_slot(ai)["d"].get("wraps"))


func test_cordage() -> void:
	print("-- twisting cordage")
	give("fiber", 2)
	var top := flat_stone_top()
	await stand_near(top, Vector3(0, 0, 0.8))
	var before := inv().count("cordage")
	req("work_start", {"kind": "cordage", "surface": int(newest("flat_stone")["id"]), "pos": top + Vector3(0.0, 0, 0.12), "slot": slot_of("fiber")})
	await frames(3)
	var w := _work()
	check(not w.is_empty(), "cordage workpiece created")
	for i in 12:
		req("work_op", {"eid": int(w["id"]), "op": ["twist", 0.1, 0.9]})
		await frames(1)
	await frames(2)
	check(inv().count("cordage") == before + 1, "two fibres became one cordage")


func test_clay_and_pottery() -> void:
	print("-- preparing clay and shaping a bowl")
	give("clay", 2, {"moist": 0.17})
	var bank := Vector3(TerrainData.POND_CENTER.x + 1.7, 0, TerrainData.POND_CENTER.y + 0.6)
	bank.y = World.terrain.height(bank.x, bank.z)
	await stand_near(bank, Vector3(0.4, 0, 0.4))
	req("work_start", {"kind": "clay_prep", "surface": -1, "pos": bank, "slot": slot_of("clay")})
	await frames(3)
	var w := _work()
	check(not w.is_empty(), "clay preparation started beside the pond")
	if w.is_empty():
		return
	var eid := int(w["id"])
	var pond0 := float(World.env["pond_l"])
	for i in 6:
		req("work_op", {"eid": eid, "op": ["water"]})
	await frames(2)
	check(float(World.env["pond_l"]) < pond0, "water for the clay came out of the pond")
	for i in 9:
		req("work_op", {"eid": eid, "op": ["knead", 0.9]})
	await frames(2)
	print("     clay: ", World.get_entity(eid)["d"])
	req("work_finish", {"eid": eid})
	await frames(3)
	check(inv().count("clay_prepared") == 2, "two lumps of prepared clay")
	# shape a bowl from one lump
	var ps := slot_of("clay_prepared")
	inv().get_slot(ps)  # noqa
	req("work_start", {"kind": "pottery", "surface": -1, "pos": bank + Vector3(0.3, 0, 0), "slot": ps})
	await frames(3)
	w = _work()
	check(not w.is_empty() and String(w["d"]["kind"]) == "pottery", "pottery workpiece created")
	eid = int(w["id"])
	var vol0 := float(w["d"]["pot"]["vol"])
	for i in 8:
		req("work_op", {"eid": eid, "op": ["hollow", 0.1 * (i + 1), 0.25 + 0.06 * i, 0.0]})
	for i in 6:
		req("work_op", {"eid": eid, "op": ["shape", 0.7, -0.0015, 0.0]})
	for i in 6:
		req("work_op", {"eid": eid, "op": ["smooth", 0.5, 0.8, 0.0]})
	await frames(3)
	var pot: Dictionary = World.get_entity(eid)["d"]["pot"]
	var st := Pottery.stats(pot)
	print("     pot stats: kind=%s cap=%.3f wall=%.4f floor=%.4f" % [st["kind"], st["capacity_l"], st["wall_mean"], st["floor_t"]])
	check(absf(Pottery.volume(pot) - vol0) < vol0 * 0.01, "clay volume conserved while shaping (%.4f vs %.4f)" % [Pottery.volume(pot), vol0])
	check(bool(st["hollow"]) and float(st["capacity_l"]) > 0.05, "the lump became a hollow vessel")
	req("work_finish", {"eid": eid})
	await frames(3)
	var potent := {}
	for e in World.entities.values():
		if e["t"] == "item" and String(e["d"]["i"]) == "pot":
			potent = e
	check(not potent.is_empty(), "a wet pot stands where it was made")
	if not potent.is_empty():
		print("     pot: ", Pottery.display_name(potent["d"]["x"]), " cap ", potent["d"]["x"].get("cap"))


# ---------------------------------------------------------------------------
# Fire
# ---------------------------------------------------------------------------

func ground(p: Vector2) -> Vector3:
	return Vector3(p.x, World.terrain.height(p.x, p.y), p.y)


func place(id: String, n: int, x: Dictionary, pos: Vector3) -> int:
	## Test-only: conjure an item lying at pos (recorded for the ledger checks).
	var eid: int = World.actions.spawn_item(id, n, x.duplicate(true), pos + Vector3(0, 0.25, 0))
	Ledger._add(injected, Ledger.item_contrib(id, n, x))
	return eid


func run_fire(hours: float) -> void:
	## Fast-forward the fires (the rest of the island keeps its own time).
	var steps := int(ceil(hours / 0.01))
	for i in steps:
		FireSim.tick(0.01, 0.5)
		if i % 8 == 0:
			await get_tree().physics_frame


func site_near(p: Vector3) -> Dictionary:
	var sid := FireSim.site_at(p)
	return World.get_entity(sid) if sid != -1 else {}


func items_near(p: Vector3, id: String, r: float = 0.8) -> Array:
	var out: Array = []
	for e in World.entities_near(p, r, "item"):
		if String(e["d"].get("i", "")) == id:
			out.append(e)
	return out


func ledger_parts() -> Dictionary:
	## Debug: where the conserved quantities sit, by store.
	var parts := {}
	for k in World.pools:
		if World.pools[k] is float or World.pools[k] is int:
			parts["pool:" + k] = float(World.pools[k])
	for e in World.entities.values():
		var key := "ent:" + String(e["t"]) + ("" if e["t"] != "item" else ":" + String(e["d"].get("i", "")))
		var c := Ledger.entity_contrib(e)
		if not parts.has(key + ":c"):
			parts[key + ":c"] = 0.0
			parts[key + ":n"] = 0.0
		parts[key + ":c"] += float(c["carbon"])
		parts[key + ":n"] += float(c["nutr"])
	var inv_c := 0.0
	var inv_n := 0.0
	for pid in World.inventories:
		for sl in World.inventories[pid].slots:
			if not sl.is_empty():
				var c2 := Ledger.item_contrib(String(sl["i"]), int(sl["n"]), sl["d"])
				inv_c += float(c2["carbon"])
				inv_n += float(c2["nutr"])
	parts["inv:c"] = inv_c
	parts["inv:n"] = inv_n
	parts["terrain:n"] = World.terrain.total_nutrients()
	parts["inj:c"] = float(injected["carbon"])
	parts["inj:n"] = float(injected["nutr"])
	return parts


func print_parts_diff(a: Dictionary, b: Dictionary) -> void:
	var keys := a.keys()
	for k in b:
		if not keys.has(k):
			keys.append(k)
	for k in keys:
		var d := float(b.get(k, 0.0)) - float(a.get(k, 0.0))
		if absf(d) > 0.00005 and not String(k).contains("water"):
			print("       %-40s %+.5f" % [k, d])


func suite_fire() -> void:
	print("-- fire physics: reference arrangements")
	for line in FireBench.run_all():
		check(String(line).begins_with("ok"), String(line).substr(5))
	var L0 := ledger()
	await test_campfire()
	var La := ledger()
	ledger_same(L0, La, "campfire", {"water": 0.05})
	await test_pit_firing()
	var Lb := ledger()
	ledger_same(La, Lb, "pit firing", {"water": 0.05})
	await test_charcoal_mound()
	var Lc := ledger()
	ledger_same(Lb, Lc, "charcoal mound", {"water": 0.05})
	await test_fire_drill()
	var L1 := ledger()
	ledger_same(Lc, L1, "fire drill", {"water": 0.05})


func lay_campfire(c: Vector3, firewood: int = 3) -> int:
	var tinder := place("straw", 3, {"moist": 0.08}, c)
	place("twig", 6, {"moist": 0.1}, c + Vector3(0.07, 0, 0.03))
	place("stick", 3, {"moist": 0.15}, c + Vector3(-0.06, 0, 0.05))
	for i in firewood:
		var a := i * TAU / maxf(firewood, 1)
		place("firewood", 1, {"moist": 0.15}, c + Vector3(cos(a) * 0.13, 0, sin(a) * 0.13))
	return tinder


func test_campfire() -> void:
	print("-- a campfire: tinder, kindling, sticks and firewood")
	var c := ground(Vector2(-0.6, 2.4))
	await stand_near(c, Vector3(0, 0, 1.2))
	var tinder := lay_campfire(c)
	await frames(4)
	check(FireSim.ignite(tinder, 620.0), "the tinder takes the flame")
	await run_fire(0.4)
	var site := site_near(c)
	check(not site.is_empty(), "a fire site formed around the lay")
	if site.is_empty():
		return
	var sid := int(site["id"])
	print("     after 24 min: ", FireSim.describe(site["d"]).replace("\n", " / "), "  T=", site["d"].get("T"), " heat=", site["d"].get("heat"), "kW")
	check(bool(site["d"].get("lit", false)), "the fire is burning")
	check(int(site["d"].get("peak", 0)) > 550, "it got hot (peak %d C)" % int(site["d"].get("peak", 0)))
	var warm := Climate.temp_at(Game.game_world.get_world_3d(), c + Vector3(1.0, 0, 0), FireSim.heat_sources())
	var cold := Climate.temp_at(Game.game_world.get_world_3d(), c + Vector3(1.0, 0, 0), [])
	check(float(warm["temp"]) > float(cold["temp"]) + 3.0, "it warms someone a metre away (%.1f vs %.1f C)" % [warm["temp"], cold["temp"]])
	# roast a tuber at the edge
	var tub := place("tuber", 1, {}, c + Vector3(0.24, 0, -0.05))
	var roasted_at := -1.0
	for i in 20:
		await run_fire(0.05)
		var te := World.get_entity(tub)
		if te.is_empty():
			break
		if String(te["d"]["i"]) == "tuber_roasted":
			roasted_at = (i + 1) * 0.05
			break
	var tr := World.get_entity(tub)
	print("     tuber: roasted after %.2f h, %s" % [roasted_at, tr["d"] if not tr.is_empty() else "gone"])
	check(roasted_at > 0.15, "a tuber at the fire's edge roasted, taking its time (%.2f h)" % roasted_at)
	if not tr.is_empty():
		req("pickup", {"eid": tub})
		await frames(2)
	check(inv().count("tuber_roasted") == 1, "picked the roasted tuber out of the fire")
	# carry fire on a stick and light a second fire with it
	give("stick", 1)
	req("fire_torch", {"eid": sid, "slot": slot_of("stick")})
	await frames(3)
	check(inv().count("torch") == 1, "a stick lit from the fire becomes a burning stick")
	var c2 := ground(Vector2(0.8, 3.3))
	var straw2 := place("straw", 2, {"moist": 0.08}, c2)
	place("twig", 6, {"moist": 0.1}, c2 + Vector3(0.05, 0, 0.02))
	await frames(4)
	await stand_near(c2, Vector3(0, 0, 1.0))
	req("ignite", {"eid": straw2, "slot": slot_of("torch")})
	await frames(3)
	await run_fire(0.1)
	var s2 := site_near(c2)
	check(not s2.is_empty() and bool(s2["d"].get("lit", false)), "the burning stick lit a second fire")
	# let everything burn out
	await run_fire(5.0)
	site = World.get_entity(sid)
	check(not site.is_empty(), "the fire pit remains after the fire")
	if not site.is_empty():
		var wood := 0
		for e in items_near(c, "firewood"):
			wood += 1
			print("     left: ", e["d"])
		var charred := items_near(c, "charred_wood")
		print("     %d charred ends left" % charred.size())
		print("     burnt out: ", FireSim.describe(site["d"]).replace("\n", " / "), "  ash_n=%.4f ash_c=%.4f" % [float(site["d"]["ash_n"]), float(site["d"]["ash_c"])])
		check(not bool(site["d"].get("lit", false)), "the fire has gone out")
		check(wood == 0, "no unburnt firewood is left: what's left is charred")
		check(float(site["d"].get("ash_n", 0.0)) > 0.0, "ash holds the wood's minerals")


func make_pot(moist: float) -> Dictionary:
	var pot := Pottery.new_lump(Pottery.LUMP_L * 2.0, 0.22, 4242)
	for i in 8:
		Pottery.apply_op(pot, ["hollow", 0.1 * (i + 1), 0.25 + 0.06 * i, 0.0])
	for i in 6:
		Pottery.apply_op(pot, ["shape", 0.7, -0.0015, 0.0])
	for i in 6:
		Pottery.apply_op(pot, ["smooth", 0.5, 0.8, 0.0])
	Pottery.finalize(pot)
	pot["moist"] = moist
	pot["state"] = Pottery.moisture_state(moist)
	pot["risk"] = 0.02
	return pot


func test_pit_firing() -> void:
	print("-- firing pottery: pots in the fuel, half buried in earth")
	var c := ground(Vector2(3.0, 0.2))
	await stand_near(c, Vector3(0, 0, 1.3))
	var p1 := place("pot", 1, make_pot(0.03), c + Vector3(0.05, 0, 0.0))
	var p2 := place("pot", 1, make_pot(0.03), c + Vector3(-0.08, 0, 0.06))
	var tinder := lay_campfire(c, 6)
	await frames(4)
	FireSim.ignite(tinder, 620.0)
	await run_fire(0.3)
	var site := site_near(c)
	check(not site.is_empty() and bool(site["d"].get("lit", false)), "the kiln fire is burning")
	if site.is_empty():
		return
	var sid := int(site["id"])
	# bank earth around the lower half
	give("earth", 5)
	var rr := FireSim.dome_radii(site["d"])
	for i in 5:
		var a := i * TAU / 5.0
		var pos := c + Vector3(cos(a) * rr.x, 0.08, sin(a) * rr.x)
		req("fire_cover", {"eid": sid, "pos": pos, "slot": slot_of("earth")})
		await frames(2)
	await frames(4)
	site = World.get_entity(sid)
	print("     enclosure %.2f, open %.3f m2" % [float(site["d"].get("encl", 0.0)), float(site["d"].get("open", 0.0))])
	await run_fire(4.0)
	var fired := 0
	var cracked := 0
	for pid in [p1, p2]:
		var e := World.get_entity(pid)
		if e.is_empty():
			continue
		var st := String(e["d"]["x"].get("state", ""))
		print("     pot: %s  peak %d C" % [st, int(float(e["d"]["x"].get("fpk", 0.0)))])
		if st == "fired":
			fired += 1
		elif st == "cracked":
			cracked += 1
	check(fired + cracked == 2 and fired >= 1, "the pots fired (%d fired, %d cracked)" % [fired, cracked])
	# dig out the earth again
	site = World.get_entity(sid)
	var guard := 0
	while not site.is_empty() and float(site["d"].get("shell_l", 0.0)) > 0.0 and guard < 12:
		req("fire_uncover", {"eid": sid, "pos": c + Vector3(rr.x, 0.1, 0)})
		await frames(2)
		site = World.get_entity(sid)
		guard += 1
	check(site.is_empty() or float(site["d"].get("shell_l", 0.0)) <= 0.0, "the earth bank was dug away again")


func test_charcoal_mound() -> void:
	print("-- a charcoal mound: light it, cover it, vent it, seal it, wait")
	var c := ground(Vector2(1.6, 4.0))
	await stand_near(c, Vector3(0, 0, 1.4))
	var tinder := place("straw", 3, {"moist": 0.08}, c)
	place("twig", 6, {"moist": 0.1}, c + Vector3(0.05, 0, 0.0))
	place("twig", 6, {"moist": 0.1}, c + Vector3(-0.05, 0, 0.02))
	place("stick", 3, {"moist": 0.15}, c + Vector3(0.0, 0, 0.07))
	place("stick", 3, {"moist": 0.15}, c + Vector3(0.0, 0, -0.07))
	for i in 9:
		var a := i * TAU / 9.0
		var rad := 0.12 if i % 2 == 0 else 0.22
		place("firewood", 1, {"moist": 0.2}, c + Vector3(cos(a) * rad, 0, sin(a) * rad))
	await frames(4)
	FireSim.ignite(tinder, 620.0)
	await run_fire(0.5)
	var site := site_near(c)
	check(not site.is_empty() and bool(site["d"].get("lit", false)), "the woodpile is burning")
	if site.is_empty():
		return
	var sid := int(site["id"])
	var wood0 := 0.0
	for e in World.entities_near(c, 1.0, "item"):
		var x: Dictionary = e["d"].get("x", {})
		wood0 += float(x.get("fm", 0.0))
	# cover it all
	give("earth", 18)
	var guard := 0
	while guard < 30 and inv().count("earth") > 0:
		var d: Dictionary = World.get_entity(sid)["d"]
		var worst := 0
		var wc := 2.0
		for k in FireSim.CELLS:
			var cv := FireSim.coverage(d, k)
			if cv < wc:
				wc = cv
				worst = k
		if wc >= 0.999:
			break
		req("fire_cover", {"eid": sid, "pos": FireSim.cell_point(worst, d, c), "slot": slot_of("earth")})
		await frames(2)
		guard += 1
	site = World.get_entity(sid)
	check(FireSim.shell_coverage(site["d"]) > 0.995, "the pile is sealed under earth (%.0f%%, %.0f L)" % [FireSim.shell_coverage(site["d"]) * 100.0, float(site["d"]["shell_l"])])
	# two vents at the base
	give("stick", 1)
	for k in [2, 10]:
		req("fire_vent", {"eid": sid, "pos": FireSim.cell_point(k, site["d"], c), "slot": slot_of("stick")})
		await frames(2)
	site = World.get_entity(sid)
	check(site["d"].get("vents", []).size() == 2, "two vents poked at the base")
	for i in 5:
		await run_fire(0.5)
		site = World.get_entity(sid)
		var wsum := 0.0
		var csum := 0.0
		for e in World.entities_near(c, 1.0, "item"):
			var x: Dictionary = e["d"].get("x", {})
			wsum += float(x.get("fm", 0.0))
			csum += float(x.get("ch", 0.0))
		print("       %.1fh: T=%s %s smoke=%s sc=%s wood %.2f char %.2f open %.4f" % [(i + 1) * 0.5, site["d"].get("T"), site["d"].get("phase"), site["d"].get("smoke"), site["d"].get("sc"), wsum, csum, float(site["d"].get("open", 0.0))])
	print("     charring: ", FireSim.describe(site["d"]).replace("\n", " / "), "  T=", site["d"].get("T"))
	check(String(site["d"].get("phase", "")) in ["charring", "steaming", "finishing"], "the mound smokes as it chars (%s)" % site["d"].get("phase"))
	await run_fire(3.0)
	# close the vents and let it cool
	site = World.get_entity(sid)
	for k in site["d"].get("vents", []).duplicate():
		req("fire_cover", {"eid": sid, "pos": FireSim.cell_point(int(k), site["d"], c), "slot": slot_of("earth") if inv().count("earth") > 0 else 0})
		await frames(2)
	site = World.get_entity(sid)
	check(site["d"].get("vents", []).is_empty() or inv().count("earth") == 0, "vents closed")
	await run_fire(4.0)
	site = World.get_entity(sid)
	print("     sealed and cooled: ", FireSim.describe(site["d"]).replace("\n", " / "), "  T=", site["d"].get("T"))
	# dig it open
	var g2 := 0
	while not site.is_empty() and float(site["d"].get("shell_l", 0.0)) > 0.0 and g2 < 40:
		var d2: Dictionary = site["d"]
		var best := 0
		var bl := -1.0
		for k in FireSim.CELLS:
			var sh: Array = d2.get("shell", [])
			if k < sh.size() and float(sh[k]) > bl:
				bl = float(sh[k])
				best = k
		req("fire_uncover", {"eid": sid, "pos": FireSim.cell_point(best, d2, c)})
		await frames(2)
		site = World.get_entity(sid)
		g2 += 1
	var coal := 0
	for e in items_near(c, "charcoal", 1.0):
		coal += int(e["d"]["n"])
	var charred := items_near(c, "charred_wood", 1.0).size()
	for e in items_near(c, "charred_wood", 1.0):
		var cx: Dictionary = e["d"]["x"]
		print("       charred %s: wood %.3f char %.3f of %.2f" % [cx.get("from"), float(cx["fm"]), float(cx["ch"]), float(cx.get("m0", 0.0))])
	var yield_kg := coal * ItemDB.unit_mass("charcoal")
	print("     opened: %d charcoal (%.2f kg from %.1f kg of wood), %d pieces of charred wood" % [coal, yield_kg, wood0, charred])
	check(coal >= 5, "the mound made charcoal")
	check(yield_kg >= wood0 * 0.12, "a decent yield (%.0f%%)" % (yield_kg / maxf(wood0, 0.01) * 100.0))


func test_fire_drill() -> void:
	print("-- the fire drill: carve a hearth board, spin for an ember, tip it into tinder")
	var c := ground(Vector2(-1.3, 0.2))
	await stand_near(c, Vector3(0, 0, 0.9))
	give("blade", 1, {"seed": 7, "cuts": [], "q": 0.7, "stone_kg": 0.3, "dur": 1.0})
	var stick_e := place("stick", 1, {"moist": 0.12}, c)
	await frames(3)
	for i in 4:
		req("process", {"eid": stick_e, "slot": slot_of("blade")})
		await frames(2)
	var boards := items_near(c, "hearth_board")
	check(boards.size() == 1, "a stick carved into a hearth board")
	if boards.is_empty():
		return
	give("stick", 1)
	give("straw", 2, {"moist": 0.1})
	req("work_start", {"kind": "fire_drill", "board": int(boards[0]["id"]), "pos": boards[0]["xf"].origin, "slot": slot_of("stick")})
	await frames(3)
	var w := _work()
	check(not w.is_empty() and String(w["d"].get("kind", "")) == "fire_drill", "the drill is set up")
	if w.is_empty():
		return
	var eid := int(w["id"])
	for i in 420:
		req("work_op", {"eid": eid, "op": ["spin", 1.0, 0.05]})
		await get_tree().physics_frame
		if float(World.get_entity(eid)["d"].get("ember", 0.0)) > 0.0:
			break
	check(float(World.get_entity(eid)["d"].get("ember", 0.0)) > 0.0, "spinning made an ember (heat %.2f)" % float(World.get_entity(eid)["d"].get("heat", 0.0)))
	req("work_finish", {"eid": eid})
	await frames(4)
	await run_fire(0.05)
	var site := site_near(c)
	if site.is_empty():
		print("     weather: rain %.2f cloud %.2f wind %s hour %.1f" % [float(World.env.get("rain", 0.0)), float(World.env.get("cloud", 0.0)), str(World.env.get("wind", Vector2.ZERO)), World.hour_of_day()])
	check(not site.is_empty(), "the ember lit the tinder")
	check(inv().count("hearth_board") == 1 and inv().count("stick") >= 1, "the drill set comes back to hand")


func suite_drill() -> void:
	await test_fire_drill()


func suite_camp() -> void:
	await test_campfire()


func suite_pit() -> void:
	await test_pit_firing()


func suite_mound() -> void:
	await test_charcoal_mound()


func suite_mtime() -> void:
	var t0 := Time.get_ticks_msec()
	await test_charcoal_mound()
	print("mound test took %d ms" % (Time.get_ticks_msec() - t0))


# ---------------------------------------------------------------------------
# Construction
# ---------------------------------------------------------------------------

func structures() -> Array:
	return World.entities_of("structure")


func build_frame(bp: String, xf: Transform3D, sy: float = 1.0) -> int:
	var before := structures().size()
	req("build_place", {"bp": bp, "xf": xf, "sy": sy})
	await frames(2)
	if structures().size() == before:
		return -1
	var newest_s := newest("structure")
	return int(newest_s["id"])


func complete(eid: int) -> void:
	## Bring every part the frame still needs and fit it.
	var e := World.get_entity(eid)
	var parts: Array = ItemDB.blueprint(String(e["d"]["bp"])).get("parts", [])
	for i in range(int(e["d"]["installed"]), parts.size()):
		var id := String(parts[i]).get_slice("|", 0)
		if inv().count(id) < 1:
			give(id, 1)
		req("build_install", {"eid": eid, "slot": slot_of(id)})
		await frames(1)


func edge_spot() -> Dictionary:
	## A flattish place just inside the island's rim, and the direction out.
	var best := {}
	for k in 16:
		var a := k * TAU / 16.0
		var dir := Vector2(cos(a), sin(a))
		var r := 0.0
		while r < 12.0 and World.terrain.is_inside(dir.x * r, dir.y * r):
			r += 0.05
		var c := dir * (r - 1.15)
		var hs: Array = []
		for o in [Vector2.ZERO, Vector2(0.9, 0.9), Vector2(-0.9, 0.9), Vector2(0.9, -0.9), Vector2(-0.9, -0.9)]:
			hs.append(World.terrain.height(c.x + o.x, c.y + o.y))
		var spread: float = hs.max() - hs.min()
		var near_tree := c.distance_to(TerrainData.TREE_POS) < 3.0 or c.distance_to(TerrainData.OUTCROP_POS) < 3.2 or c.distance_to(TerrainData.POND_CENTER) < 3.0
		if not near_tree and (best.is_empty() or spread < float(best["spread"])):
			best = {"c": c, "dir": dir, "spread": spread, "top": hs.max()}
	return best


func suite_build() -> void:
	Events.toast.connect(func(t, k): print("     [toast] ", t))
	var L0 := ledger()
	var spot := edge_spot()
	var c: Vector2 = spot["c"]
	var dir: Vector2 = spot["dir"]
	var yaw := atan2(dir.x, dir.y)
	var basis := Basis(Vector3.UP, yaw)
	print("-- building at the rim (%.1f, %.1f), ground spread %.2f m" % [c.x, c.y, float(spot["spread"])])
	var origin := Vector3(c.x, float(spot["top"]) + 0.04, c.y)
	await stand_near(origin, Vector3(-dir.x * 1.8, 0, -dir.y * 1.8))
	var a_id := await build_frame("platform", Transform3D(basis, origin))
	check(a_id != -1, "a platform frame was placed on the ground")
	if a_id == -1:
		return
	check(int(World.get_entity(a_id)["d"]["installed"]) == 0, "the frame starts empty")
	req("build_install", {"eid": a_id, "slot": 0})
	await frames(1)
	check(int(World.get_entity(a_id)["d"]["installed"]) == 0, "nothing goes in without the right material")
	await complete(a_id)
	var a := World.get_entity(a_id)
	check(StructureSim.is_complete(a["d"]), "every part installed by hand: the platform is finished")
	await frames(3)
	var hit := lp.get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(origin + Vector3(0.3, 1.0, 0.2), origin + Vector3(0.3, -1.0, 0.2), EntityView.LAYER_STRUCT))
	check(not hit.is_empty(), "the finished deck is solid underfoot")
	# out over the abyss
	var out := basis.z
	var b_xf := Transform3D(basis, origin + out * 2.0)
	var b_id := await build_frame("platform", b_xf)
	check(b_id != -1, "a second platform can reach out over the edge")
	await complete(b_id)
	# walk out onto the new deck to keep building
	lp.global_position = origin + out * 1.6 + Vector3(0, 0.1, 0)
	lp.velocity = Vector3.ZERO
	await frames(3)
	var c_xf := Transform3D(basis, origin + out * 4.0)
	var c_id := await build_frame("platform", c_xf)
	check(c_id != -1, "a third one is allowed, with a warning")
	if c_id == -1:
		return
	await complete(c_id)
	StructureSim.tick(0.1)
	await frames(2)
	check(float(World.get_entity(c_id)["d"].get("stress", 0.0)) == 0.5, "two steps out it creaks (stress %.1f)" % float(World.get_entity(c_id)["d"].get("stress", 0.0)))
	check(float(World.get_entity(b_id)["d"].get("stress", 0.0)) == 0.0, "one step out holds fine")
	var d_id := await build_frame("platform", Transform3D(basis, origin + out * 6.0))
	check(d_id == -1, "a fourth one out is refused: nothing would hold it")
	# a railing along the far edge, and a mat to sleep on
	var r_id := await build_frame("railing", Transform3D(basis.rotated(Vector3.UP, 0.0), origin + out * 0.93))
	check(r_id != -1, "a railing frame along an edge")
	if r_id != -1:
		await complete(r_id)
	var m_id := await build_frame("sleeping_mat", Transform3D(basis, origin + Vector3(0.3, 0.0, 0.0) - out * 0.4))
	check(m_id != -1, "a sleeping mat on the deck")
	if m_id != -1:
		await complete(m_id)
		req("bed_set", {"eid": m_id})
		await frames(2)
		check(int(World.stats[Net.my_id()].get("bed", -1)) == m_id, "sleeping on the mat makes it home")
	# take the far platform apart: every part comes back
	var have_boards := inv().count("board")
	var guard := 0
	while World.has_entity(c_id) and guard < 20:
		req("build_dismantle", {"eid": c_id})
		await frames(1)
		guard += 1
	check(not World.has_entity(c_id), "the far platform came apart")
	check(inv().count("board") == have_boards + 6, "its six boards came back")
	# now pull the grounded platform out from under the other one
	await stand_near(origin - out * 2.6, Vector3.ZERO)
	var lost0 := float(World.pools.get("lost_carbon", 0.0))
	guard = 0
	while World.has_entity(a_id) and guard < 20:
		req("build_dismantle", {"eid": a_id})
		await frames(1)
		guard += 1
	StructureSim.mark_dirty()
	StructureSim.tick(0.1)
	await frames(2)
	check(float(World.get_entity(b_id)["d"].get("stress", 0.0)) >= 1.0, "without its support, the outer platform groans")
	for i in 30:
		StructureSim.tick(0.5)
		await frames(1)
	check(not World.has_entity(b_id), "...and then it falls")
	var lost := float(World.pools.get("lost_carbon", 0.0)) - lost0
	check(lost > 1.0, "what hung over the abyss fell into it (%.1f kg of wood)" % lost)
	await frames(2)
	var floating := 0
	for e in World.entities_near(b_xf.origin, 3.5, "item"):
		var p: Vector3 = e["xf"].origin
		if World.terrain.is_inside(p.x, p.z) and p.y > World.terrain.height(p.x, p.z) + 0.4:
			floating += 1
	check(floating == 0, "nothing is left hanging in mid-air (%d)" % floating)
	await frames(3)
	var L1 := ledger()
	ledger_same(L0, L1, "construction")
	await test_hut()
	ledger_same(L1, ledger(), "hut")


func test_hut() -> void:
	print("-- a hut: deck, three walls and a doorway, a thatch roof")
	var spot := clear_soil_spot()
	if spot == Vector3.INF:
		check(false, "found flat ground for a hut")
		return
	var basis := Basis(Vector3.UP, 0.4)
	var origin := spot + Vector3(0, 0.04, 0)
	# the deck sits on the ground: lift it to the highest corner so it isn't buried
	for c in [Vector3(1, 0, 1), Vector3(-1, 0, 1), Vector3(1, 0, -1), Vector3(-1, 0, -1)]:
		var w: Vector3 = origin + basis * (c as Vector3) * 0.95
		origin.y = maxf(origin.y, World.terrain.height(w.x, w.z) + 0.04)
	await stand_near(origin, basis.z * 2.6)
	var deck := await build_frame("platform", Transform3D(basis, origin))
	check(deck != -1, "a deck on the ground")
	if deck == -1:
		return
	await complete(deck)
	var ids: Array = [deck]
	# walls on three sides (they stand on the deck), a doorway on the fourth
	var sides := [[basis.z, 0.0, "doorway"], [-basis.z, 0.0, "wall"], [basis.x, PI * 0.5, "wall"], [-basis.x, PI * 0.5, "wall"]]
	for sd in sides:
		var at: Vector3 = origin + (sd[0] as Vector3) * 0.93
		var wid := await build_frame(String(sd[2]), Transform3D(basis.rotated(Vector3.UP, float(sd[1])), at))
		check(wid != -1, "%s frame on the deck edge" % String(sd[2]))
		if wid != -1:
			await complete(wid)
			ids.append(wid)
	# the roof rests on the wall tops
	lp.global_position = origin + Vector3(0, 0.2, 0)
	lp.velocity = Vector3.ZERO
	await frames(3)
	var roof := await build_frame("roof", Transform3D(basis, origin + Vector3(0, 2.2, 0)))
	check(roof != -1, "a thatch roof frame sits on the walls")
	if roof == -1:
		return
	await complete(roof)
	ids.append(roof)
	StructureSim.mark_dirty()
	StructureSim.tick(0.1)
	await frames(3)
	var all_ok := true
	for i in ids:
		var d: Dictionary = World.get_entity(int(i))["d"]
		if not StructureSim.is_complete(d) or float(d.get("stress", 0.0)) > 0.0:
			all_ok = false
	check(all_ok, "everything is finished and nothing creaks")
	var inside := origin + Vector3(0, 0.3, 0)
	check(Shelter.roof_above(lp.get_world_3d(), inside + Vector3(0, 1.4, 0)), "there is a roof overhead inside")
	var cover := Shelter.wall_cover(lp.get_world_3d(), inside + Vector3(0, 1.0, 0))
	check(cover >= 0.6, "and walls all round (%.0f%%)" % (cover * 100.0))
	World.env["t"] = float(World.day()) * 24.0 + 26.0
	World.env["wind"] = Vector2(3.0, 1.0)
	var outside := origin + basis.z * 4.0
	outside.y = World.terrain.height(outside.x, outside.z) + 0.1
	var t_in := float(Climate.temp_at(lp.get_world_3d(), inside)["temp"])
	var t_out := float(Climate.temp_at(lp.get_world_3d(), outside)["temp"])
	print("     2 am in the wind: %.1f C outside, %.1f C inside" % [t_out, t_in])
	check(t_in > t_out + 3.0, "the hut keeps the night wind off")
	# taking the roof down gives every part back
	var before := inv().count("straw")
	var guard := 0
	while World.has_entity(roof) and guard < 30:
		req("build_dismantle", {"eid": roof})
		await frames(1)
		guard += 1
	check(not World.has_entity(roof) and inv().count("straw") == before + 8, "the roof comes apart into its eight bundles of straw and the rest")


# ---------------------------------------------------------------------------
# Farming & compost
# ---------------------------------------------------------------------------

func clear_soil_spot(avoid: Array = []) -> Vector3:
	## Flat open soil away from the tree, pond, rocks, plants and anything in `avoid`.
	var t := World.terrain
	var best := Vector3.INF
	var best_score := INF
	for ix in range(-10, 11):
		for iz in range(-10, 11):
			var x := ix * 0.5
			var z := iz * 0.5
			if not t.is_inside(x, z) or t.layer_at(x, z) != "soil":
				continue
			var p := ground(Vector2(x, z))
			var ok := true
			for e in World.entities_near(p, 1.6):
				if String(e["t"]) != "item":
					ok = false
			for q in avoid:
				if (q as Vector3).distance_to(p) < 2.0:
					ok = false
			# keep away from the rim
			for i in 8:
				var a := i * TAU / 8.0
				if not t.is_inside(x + cos(a) * 1.6, z + sin(a) * 1.6):
					ok = false
			if not ok:
				continue
			var slope := absf(t.height(x + 0.3, z) - t.height(x - 0.3, z)) + absf(t.height(x, z + 0.3) - t.height(x, z - 0.3))
			var score := slope + p.distance_to(lp.global_position) * 0.02
			if score < best_score:
				best_score = score
				best = p
	return best


func heaps() -> Array:
	return World.entities_of("compost")


func me() -> Dictionary:
	return World.stats.get(Net.my_id(), {})


func suite_survival() -> void:
	var L0 := ledger()
	print("-- needs fall over time")
	var st := me()
	st["hunger"] = 0.9
	st["thirst"] = 0.9
	var h0 := float(st["hunger"])
	var t0 := float(st["thirst"])
	await sim_hours(6.0, 0.25, false)
	st = me()
	var dh := h0 - float(st["hunger"])
	var dt := t0 - float(st["thirst"])
	print("     6 h: hunger -%.3f, thirst -%.3f" % [dh, dt])
	check(dh > 6.0 / Survival.HUNGER_HOURS * 0.8 and dh < 6.0 / Survival.HUNGER_HOURS * 1.8, "hunger falls at about its stated rate")
	check(dt > 6.0 / Survival.THIRST_HOURS * 0.8 and dt < 6.0 / Survival.THIRST_HOURS * 2.0, "thirst falls faster than hunger")
	print("-- drinking from the pond")
	var pc := TerrainData.POND_CENTER
	var bank := Vector2(pc.x, pc.y) + Vector2(TerrainData.POND_RADII.x + 0.5, 0.0)
	lp.global_position = ground(bank) + Vector3(0, 0.1, 0)
	lp.velocity = Vector3.ZERO
	await frames(3)
	var pond0 := float(World.env["pond_l"])
	var th0 := float(me()["thirst"])
	req("drink_pond", {})
	await frames(1)
	var drunk := (float(me()["thirst"]) - th0) * Survival.BODY_WATER_L
	check(drunk > 0.05, "cupped hands bring a mouthful (%.2f L)" % drunk)
	check(absf((pond0 - float(World.env["pond_l"])) - drunk) < 1e-4, "and exactly that much leaves the pond")
	print("-- eating")
	give("berries", 3)
	var hu0 := float(me()["hunger"])
	for i in 3:
		req("eat", {"slot": slot_of("berries")})
		await frames(1)
	check(float(me()["hunger"]) > hu0 + 0.09, "berries are a little food")
	print("-- cold nights, warm fires")
	World.env["t"] = float(World.day()) * 24.0 + 27.0   # 3 am tomorrow
	var night := Climate.temp_at(lp.get_world_3d(), lp.global_position)
	var fire := Climate.temp_at(lp.get_world_3d(), lp.global_position, [{"pos": lp.global_position + Vector3(1.0, 0.3, 0), "kw": 12.0}])
	print("     3 am: %.1f C in the open, %.1f C beside a fire" % [float(night["temp"]), float(fire["temp"])])
	check(float(night["temp"]) < 10.0, "nights are cold up here")
	check(float(fire["temp"]) > float(night["temp"]) + 8.0, "a fire warms you")
	print("-- falling into the abyss")
	give("stone", 2)
	give("clay", 3, {"moist": 0.2})
	var lost_c0 := float(World.pools.get("lost_clay", 0.0))
	var dir := (Vector2(lp.global_position.x, lp.global_position.z)).normalized()
	var r := 0.0
	while World.terrain.is_inside(dir.x * r, dir.y * r) and r < 14.0:
		r += 0.1
	lp.global_position = Vector3(dir.x * (r + 3.0), lp.global_position.y, dir.y * (r + 3.0))
	lp.velocity = Vector3.ZERO
	var guard := 0
	while bool(me().get("alive", true)) and guard < 600:
		await frames(1)
		guard += 1
	check(not bool(me().get("alive", true)), "stepping off the edge is fatal (%.1f s)" % (guard / 60.0))
	check(inv().count("stone") == 0 and inv().count("clay") == 0, "everything carried is gone")
	check(float(World.pools.get("lost_clay", 0.0)) > lost_c0, "and recorded as lost to the abyss")
	req("respawn", {})
	await frames(3)
	check(bool(me().get("alive", false)), "you wake on the island again")
	var sp := World.spawn_point(Net.my_id())
	check(lp.global_position.distance_to(sp) < 3.0, "at the spawn point")
	check(absf(float(me()["health"]) - 0.6) < 0.05, "weakened (health %.2f)" % float(me()["health"]))
	print("-- dying on the island leaves your things behind")
	give("cordage", 2)
	give("stone", 1)
	var where := lp.global_position
	Survival.damage(Net.my_id(), 2.0, "burn")
	await frames(2)
	var satchels := World.entities_of("satchel")
	check(satchels.size() == 1, "a satchel of belongings lies where you fell")
	req("respawn", {})
	await frames(3)
	if not satchels.is_empty():
		var sat: Dictionary = satchels[0]
		await stand_near(sat["xf"].origin, Vector3(0, 0, 0.8))
		req("satchel_take", {"eid": int(sat["id"])})
		await frames(2)
		check(inv().count("cordage") == 2 and inv().count("stone") == 1, "and you can get it all back")
		check(World.entities_of("satchel").is_empty(), "the empty satchel is gone")
	var L1 := ledger()
	ledger_same(L0, L1, "survival", {"water": 0.05})


func keep_fed() -> void:
	## Long fast-forwards: the test player drinks pond water and eats tubers so
	## they don't starve (real transfers, so the ledger still balances).
	var pid := Net.my_id()
	var st: Dictionary = World.stats.get(pid, {})
	if st.is_empty() or not st.get("alive", true):
		return
	if float(st["thirst"]) < 0.6:
		var want := (0.9 - float(st["thirst"])) * Survival.BODY_WATER_L
		var take := minf(want, float(World.env["pond_l"]))
		World.env["pond_l"] = float(World.env["pond_l"]) - take
		Survival.drink(pid, take)
	if float(st["hunger"]) < 0.6:
		give("tuber_roasted", 2)
		for i in 2:
			req("eat", {"slot": slot_of("tuber_roasted")})


func sim_hours(hours: float, step: float = 0.25, feed: bool = true) -> void:
	## Fast-forward the whole island (water, plants, compost, survival...).
	var sim = Game.game_world.sim
	var n := int(ceil(hours / step))
	for i in n:
		World.env["t"] = float(World.env["t"]) + step
		sim._tick(step, 0.5)
		if feed:
			keep_fed()
		if i % 6 == 0:
			await get_tree().physics_frame


func suite_farm() -> void:
	var L0 := ledger()
	await test_compost()
	var L1 := ledger()
	ledger_same(L0, L1, "compost", {"water": 0.05})
	await test_crops()
	var L2 := ledger()
	ledger_same(L1, L2, "crops", {"water": 0.05})


func test_compost() -> void:
	print("-- compost heap")
	var spot := clear_soil_spot()
	check(spot != Vector3.INF, "found open soil for a heap")
	if spot == Vector3.INF:
		return
	await stand_near(spot, Vector3(0, 0, 1.1))
	give("leaves", 8)
	give("grass", 10)
	give("straw", 16)
	give("fiber", 6)
	give("food_scraps", 4)
	give("stick", 1)
	req("compost_start", {"pos": spot, "slot": slot_of("leaves")})
	await frames(2)
	check(heaps().size() == 1, "holding leaves, E on bare soil starts a heap")
	if heaps().is_empty():
		return
	var hid := int(heaps()[0]["id"])
	req("compost_start", {"pos": spot + Vector3(0.6, 0, 0), "slot": slot_of("leaves")})
	await frames(2)
	check(heaps().size() == 1, "a second heap right beside it is refused")
	for id in ["leaves", "grass", "straw", "fiber", "food_scraps"]:
		while slot_of(id) != -1:
			req("compost_add", {"eid": hid, "slot": slot_of(id)})
			await frames(1)
	var d: Dictionary = World.get_entity(hid)["d"]
	var want_g := 8 * 0.25 + 10 * 0.15 + 4 * 0.05
	var want_b := 16 * 0.07 + 6 * 0.04
	check(absf(float(d["g"]) - want_g) < 0.001 and absf(float(d["b"]) - want_b) < 0.001, "greens %.2f kg and browns %.2f kg went in" % [float(d["g"]), float(d["b"])])
	req("compost_add", {"eid": hid, "slot": slot_of("stick")})
	await frames(1)
	check(slot_of("stick") != -1, "wood isn't accepted - it would take years")
	var f := CompostSim.factors(World.get_entity(hid)["d"])
	print("     mix: %.0f%% browns, wetness %.2f, activity %.2f" % [float(f["browns"]) * 100.0, float(f["wet"]), float(f["act"])])
	check(float(f["wet"]) > 0.35 and float(f["wet"]) < 0.7, "fresh greens make it damp, not dry or soggy (%.2f)" % float(f["wet"]))
	await sim_hours(14.0)
	d = World.get_entity(hid)["d"]
	print("     after 14 h: %.1f C, air %.2f, rotting %.2f kg, compost %.2f kg" % [float(d["T"]), float(d["air"]), CompostSim.raw(d), float(d["hu"])])
	check(float(d["T"]) > Climate.base_temp() + 15.0, "a working heap heats itself (%.0f C)" % float(d["T"]))
	check(float(d["air"]) < 0.6, "and uses up its air (%.2f)" % float(d["air"]))
	var air0 := float(d["air"])
	for i in 3:
		req("compost_turn", {"eid": hid, "slot": -1})
		await frames(1)
	check(float(World.get_entity(hid)["d"]["air"]) > air0 + 0.5, "turning it lets air back in")
	await sim_hours(30.0)
	d = World.get_entity(hid)["d"]
	var rotted := 1.0 - CompostSim.raw(d) / (want_g + want_b)
	print("     after 44 h: %.0f%% rotted, %.2f kg compost, %d ready, %.2f L free water" % [rotted * 100.0, float(d["hu"]), CompostSim.ready_count(d), float(d["w"])])
	check(rotted > 0.6, "most of a well-kept heap rots within two days (%.0f%%)" % (rotted * 100.0))
	check(CompostSim.ready_count(d) >= 2, "finished compost is ready (%d)" % CompostSim.ready_count(d))
	var n_ready := CompostSim.ready_count(d)
	for i in n_ready:
		req("compost_take", {"eid": hid, "slot": -1})
		await frames(1)
	check(inv().count("compost") == n_ready, "took %d compost" % n_ready)
	check(World.discoveries.has("first_compost"), "the island journal records the first compost")
	# a heap of browns alone hardly rots
	var spot2 := clear_soil_spot([spot])
	await stand_near(spot2, Vector3(0, 0, 1.1))
	give("straw", 20)
	req("compost_start", {"pos": spot2, "slot": slot_of("straw")})
	await frames(2)
	var h2 := -1
	for e in heaps():
		if int(e["id"]) != hid:
			h2 = int(e["id"])
	check(h2 != -1, "a second heap, all straw")
	if h2 != -1:
		while slot_of("straw") != -1:
			req("compost_add", {"eid": h2, "slot": slot_of("straw")})
			await frames(1)
		var m0 := CompostSim.raw(World.get_entity(h2)["d"])
		await sim_hours(20.0)
		var dry: Dictionary = World.get_entity(h2)["d"]
		var r2 := 1.0 - CompostSim.raw(dry) / m0
		check(r2 < 0.12, "dry browns alone barely rot (%.0f%% in 20 h)" % (r2 * 100.0))
		check(CompostSim.describe(dry).contains("dry") or CompostSim.describe(dry).contains("browns"), "and the heap says why")
		req("compost_spread", {"eid": h2, "slot": -1})
		await frames(2)
		check(not World.has_entity(h2), "spreading a heap returns it to the soil")
	# spread what's left of the first one too
	await stand_near(spot, Vector3(0, 0, 1.1))
	if World.has_entity(hid):
		req("compost_spread", {"eid": hid, "slot": -1})
		await frames(2)
	# work the compost into the soil
	var nutr0 := World.terrain.total_nutrients()
	req("fertilize", {"pos": spot + Vector3(0.6, 0, 0), "slot": slot_of("compost")})
	await frames(1)
	check(World.terrain.total_nutrients() > nutr0 + CompostSim.unit_nutr() * 0.99, "compost worked into the soil feeds it")


func test_crops() -> void:
	print("-- growing tubers")
	var spot := clear_soil_spot()
	if spot == Vector3.INF:
		check(false, "found soil for a crop")
		return
	await stand_near(spot, Vector3(0, 0, 1.0))
	give("digger", 1, {"q": 0.8, "dur": 1.0, "bind": 0.8, "cords": 1, "head": {"stone_kg": 0.25}})
	give("tuber", 1)
	req("plant", {"pos": spot, "slot": slot_of("tuber")})
	await frames(1)
	check(World.entities_of("plant").filter(func(e): return e["xf"].origin.distance_to(spot) < 0.3).is_empty(), "nothing grows in untilled ground")
	req("till", {"pos": spot, "slot": slot_of("digger")})
	await frames(2)
	var k: int = World.actions.cell_index_at(spot)
	check(World.terrain.tilled[k] == 1, "the digging tool tills the soil")
	req("plant", {"pos": spot, "slot": slot_of("tuber")})
	await frames(2)
	var plants := World.entities_of("plant").filter(func(e): return e["xf"].origin.distance_to(spot) < 0.3)
	check(plants.size() == 1, "a tuber planted in tilled soil")
	if plants.is_empty():
		return
	var pid := int(plants[0]["id"])
	# keep it watered: the soil under it stays moist
	for day in 5:
		for c in World.terrain.cells_in_radius(Vector2(spot.x, spot.z), 0.4):
			if World.terrain.moist[c] < 0.4:
				var add := (0.4 - World.terrain.moist[c]) * WaterSim.cell_l()
				var take := minf(add, float(World.env["pond_l"]))
				World.env["pond_l"] = float(World.env["pond_l"]) - take
				World.terrain.moist[c] += take / WaterSim.cell_l()
		await sim_hours(24.0, 0.5)
		var pd: Dictionary = World.get_entity(pid)["d"]
		print("     day %d: growth %.2f, thirst %.2f, hunger %.2f, vigour %.2f" % [day + 1, float(pd.get("g", 0.0)), float(pd.get("thirst", 0.0)), float(pd.get("hunger", 0.0)), float(pd.get("vig", 1.0))])
		if float(pd.get("g", 0.0)) >= 1.0:
			break
	var g := float(World.get_entity(pid)["d"].get("g", 0.0))
	check(g >= 1.0, "watered, it ripens in a few days (growth %.2f)" % g)
	var before := inv().count("tuber")
	req("harvest", {"eid": pid, "slot": -1})
	await frames(2)
	var got := inv().count("tuber") - before
	check(got >= 3, "dug up %d tubers" % got)


# ---------------------------------------------------------------------------
# Persistence
# ---------------------------------------------------------------------------

func world_snapshot() -> Dictionary:
	var types := {}
	for e in World.entities.values():
		types[e["t"]] = int(types.get(e["t"], 0)) + 1
	var items := {}
	for s in inv().slots:
		if not s.is_empty():
			items[s["i"]] = int(items.get(s["i"], 0)) + int(s["n"])
	var hsum := 0.0
	var t := World.terrain
	for k in t.inside.size():
		if t.inside[k]:
			hsum += t.rock[k] + t.clay[k] + t.soil[k] + t.moist[k] * 0.01 + t.nutr[k] + float(t.tilled[k])
	return {"types": types, "inv": items, "disc": World.discoveries.duplicate(), "next_id": World.next_id,
		"pond": snappedf(float(World.env.get("pond_l", 0.0)), 0.001), "soil": snappedf(World.terrain.total_soil_l(), 0.001),
		"clay": snappedf(World.terrain.total_clay_l(), 0.001), "hsum": snappedf(hsum, 0.001), "t": snappedf(float(World.env["t"]), 0.0001)}


func reload_world() -> String:
	## Save, leave to nothing, and load the same island again.
	var name := World.world_name
	var err := Game.save()
	if err != OK:
		return "save failed: " + error_string(err)
	Game._teardown()
	await frames(3)
	var e2 := Game.start_world("solo", name, false)
	if e2 != "":
		return e2
	await frames(12)
	lp = Game.game_world.local_player()
	return ""


func suite_save() -> void:
	print("-- save and reload")
	give("stone", 3)
	give("cordage", 2)
	give("clay", 4, {"moist": 0.22})
	var spot := clear_soil_spot()
	await stand_near(spot, Vector3(0, 0, 1.0))
	give("leaves", 5)
	req("compost_start", {"pos": spot, "slot": slot_of("leaves")})
	await frames(2)
	var hid := -1
	for e in heaps():
		hid = int(e["id"])
	while slot_of("leaves") != -1 and hid != -1:
		req("compost_add", {"eid": hid, "slot": slot_of("leaves")})
		await frames(1)
	await sim_hours(2.0)
	World.discover("first_compost", Net.my_id())
	Guide.mark_read("composting")
	World.request("guide_state", {"state": Guide.export_state()})
	await frames(2)
	var heap_before: Dictionary = World.get_entity(hid)["d"].duplicate(true) if hid != -1 else {}
	var S0 := world_snapshot()
	var L0 := ledger()
	var err := await reload_world()
	check(err == "", "saved, left, and loaded the island again (%s)" % (err if err != "" else "ok"))
	if err != "":
		return
	check(FileAccess.file_exists(World.save_path(World.world_name)), "the save file is on disk")
	var S1 := world_snapshot()
	for k in S0:
		if k == "t":
			# the clock keeps running for the few frames around the save
			check(float(S1[k]) >= float(S0[k]) and float(S1[k]) - float(S0[k]) < 0.05, "the time of day survived the reload")
		else:
			check(str(S0[k]) == str(S1[k]), "%s survived the reload" % k)
	ledger_same(L0, ledger(), "reload")
	if hid != -1:
		check(World.has_entity(hid) and absf(float(World.get_entity(hid)["d"]["g"]) - float(heap_before["g"])) < 1e-6, "the compost heap is exactly as it was")
	check(Guide.read.has("composting"), "your guide progress came back with you")
	# again, to be sure nothing doubles up
	var err2 := await reload_world()
	check(err2 == "", "and a second time")
	var S2 := world_snapshot()
	check(str(S2["inv"]) == str(S0["inv"]), "no item was duplicated across two reloads")
	check(str(S2["types"]) == str(S0["types"]), "no entity was duplicated across two reloads")
	ledger_same(L0, ledger(), "second reload")
	# the island keeps running after a load
	if hid != -1 and World.has_entity(hid):
		var g0 := float(World.get_entity(hid)["d"]["g"])
		await sim_hours(2.0)
		check(float(World.get_entity(hid)["d"]["g"]) < g0, "the heap keeps rotting after the reload")


func suite_drift() -> void:
	## Debug: does anything create or destroy matter while the island just runs?
	for round in 3:
		var L0 := ledger()
		var P0 := ledger_parts()
		await sim_hours(12.0)
		var L1 := ledger()
		ledger_same(L0, L1, "12 idle hours (round %d)" % round, {"water": 0.05})
		print_parts_diff(P0, ledger_parts())


func suite_pond() -> void:
	var t := World.terrain
	print("pond capacity %.1f L, pond_l %.1f L, level %.3f, bed at centre %.3f" % [t.pond_capacity(), float(World.env.get("pond_l", -1)), Game.game_world.island.water_level(), t.height(TerrainData.POND_CENTER.x, TerrainData.POND_CENTER.y)])
	print("water visible: ", Game.game_world.island.water_mi.visible, " pos ", Game.game_world.island.water_mi.global_position)
