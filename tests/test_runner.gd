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
	var suites := ["craft", "economy", "survival", "farm", "fire", "build", "save"] if suite == "all" else [suite]
	for s in suites:
		if has_method("suite_" + s):
			print("\n=== SUITE ", s, " ===")
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
