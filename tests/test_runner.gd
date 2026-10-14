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
