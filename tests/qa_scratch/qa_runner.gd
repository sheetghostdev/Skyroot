extends "res://tests/test_runner.gd"
## QA scratch repros (temporary; delete when done).
##   godot --headless --path . res://tests/qa_scratch/qa_main.tscn -- --suite=qa_<name>


func slots_of(id: String) -> Array:
	var out: Array = []
	for i in inv().slots.size():
		var s: Dictionary = inv().slots[i]
		if not s.is_empty() and String(s["i"]) == id:
			out.append(i)
	return out


# ---------------------------------------------------------------------------
# 1. Cutting grass creates nutrients (and carbon)
# ---------------------------------------------------------------------------

func suite_qa_grass() -> void:
	print("-- QA: cutting grass with a blade and by hand should conserve carbon and nutrients")
	var spot := clear_soil_spot()
	give("blade", 1, {"seed": 5, "cuts": [], "q": 0.8, "stone_kg": 0.3, "dur": 1.0})
	var L0 := ledger()
	var gn0 := float(World.pools.get("grass_nutr", 0.0))
	var n0 := inv().count("grass")
	var cuts := 0
	for i in 16:
		var p := spot + Vector3((i % 4) * 0.8 - 1.2, 0, (i / 4) * 0.8 - 1.2)
		p.y = World.terrain.height(p.x, p.z)
		await stand_near(p, Vector3(0, 0, 0.9))
		# half with the blade, half pulled by hand (an empty hotbar slot)
		var sl := slot_of("blade") if i % 2 == 0 else 8
		req("cut_grass", {"pos": p, "slot": sl})
		await frames(1)
		cuts += 1
	var got := inv().count("grass") - n0
	var L1 := ledger()
	print("     %d cuts gave %d cut grass (%.4f nutrients in them); grass_nutr pool %.5f -> %.5f" % [cuts, got,
		got * ItemDB.nutrients("grass"), gn0, float(World.pools.get("grass_nutr", 0.0))])
	ledger_same(L0, L1, "cutting grass")


# ---------------------------------------------------------------------------
# 2. Food roasted in a fire doesn't stack any more
# ---------------------------------------------------------------------------

func suite_qa_roast() -> void:
	print("-- QA: two tubers roasted at the same fire should stack in one slot")
	var c := ground(Vector2(-0.6, 2.4))
	await stand_near(c, Vector3(0, 0, 1.2))
	var tinder := lay_campfire(c)
	await frames(4)
	FireSim.ignite(tinder, 620.0)
	await run_fire(0.4)
	var t1 := place("tuber", 1, {}, c + Vector3(0.24, 0, -0.05))
	var t2 := place("tuber", 1, {}, c + Vector3(-0.23, 0, 0.06))
	for i in 40:
		await run_fire(0.05)
		var e1 := World.get_entity(t1)
		var e2 := World.get_entity(t2)
		if (e1.is_empty() or String(e1["d"]["i"]) == "tuber_roasted") and (e2.is_empty() or String(e2["d"]["i"]) == "tuber_roasted"):
			break
	for t in [t1, t2]:
		var e := World.get_entity(t)
		print("     on the fire: ", e["d"] if not e.is_empty() else "gone")
		if not e.is_empty():
			req("pickup", {"eid": t})
			await frames(2)
	var sl := slots_of("tuber_roasted")
	for i in sl:
		print("     slot %d: %s" % [i, inv().get_slot(i)])
	check(inv().count("tuber_roasted") == 2, "both roasted tubers picked up (%d)" % inv().count("tuber_roasted"))
	check(sl.size() == 1, "two roasted tubers share one slot (they use %d slots)" % sl.size())
	# and they don't stack with a roasted tuber from anywhere else
	give("tuber_roasted", 1)
	check(slots_of("tuber_roasted").size() == 1, "a third roasted tuber joins the same stack (now %d slots)" % slots_of("tuber_roasted").size())


# ---------------------------------------------------------------------------
# 3. A platform loses its floor the moment one part comes off
# ---------------------------------------------------------------------------

func _deck_hit(origin: Vector3, off: Vector3) -> Dictionary:
	var from := origin + off + Vector3(0, 1.0, 0)
	return lp.get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(from, from + Vector3(0, -2.0, 0), EntityView.LAYER_STRUCT))


func suite_qa_float() -> void:
	print("-- QA: things on a platform when one part is taken off / when it is taken apart")
	Events.toast.connect(func(t, k): print("     [toast] ", t))
	var spot := edge_spot()
	var c: Vector2 = spot["c"]
	var dir: Vector2 = spot["dir"]
	var yaw := atan2(dir.x, dir.y)
	var basis := Basis(Vector3.UP, yaw)
	var origin := Vector3(c.x, float(spot["top"]) + 0.04, c.y)
	await stand_near(origin, Vector3(-dir.x * 1.8, 0, -dir.y * 1.8))
	var a_id := await build_frame("platform", Transform3D(basis, origin))
	check(a_id != -1, "a platform on the rim")
	if a_id == -1:
		return
	await complete(a_id)
	var out := basis.z
	var b_id := await build_frame("platform", Transform3D(basis, origin + out * 2.0))
	check(b_id != -1, "a second platform out over the abyss")
	if b_id == -1:
		return
	await complete(b_id)
	await frames(3)
	# set a stone down on the inner deck
	give("stone", 1)
	var hit := _deck_hit(origin, Vector3(0.3, 0, 0.2))
	check(not hit.is_empty(), "the inner deck is solid")
	if hit.is_empty():
		return
	var top: Vector3 = hit["position"]
	req("place", {"slot": slot_of("stone"), "xf": Transform3D(Basis(), top + Vector3(0, 0.03, 0))})
	await frames(2)
	var st := newest("item")
	check(not st.is_empty() and String(st["d"]["i"]) == "stone", "a stone sits on the deck")
	var st_y: float = st["xf"].origin.y
	var gh := World.terrain.height(st["xf"].origin.x, st["xf"].origin.z)
	print("     stone at y=%.3f, ground beneath at %.3f" % [st_y, gh])
	# walk out onto the outer deck, then take ONE lashing off it
	lp.global_position = origin + out * 2.0 + Vector3(0, 0.1, 0)
	lp.velocity = Vector3.ZERO
	await frames(10)
	var y_on := lp.global_position.y
	print("     standing on the outer deck at y=%.2f (alive %s)" % [y_on, me().get("alive")])
	req("build_dismantle", {"eid": b_id})
	await frames(2)
	print("     outer platform now %d/%d parts" % [int(World.get_entity(b_id)["d"]["installed"]), ItemDB.blueprint("platform")["parts"].size()])
	check(not _deck_hit(origin + out * 2.0, Vector3(0.2, 0, 0.1)).is_empty(), "with one lashing off, the outer deck (still showing all its boards) is still solid underfoot")
	var guard := 0
	while bool(me().get("alive", true)) and guard < 300:
		await frames(1)
		guard += 1
	check(bool(me().get("alive", true)), "taking one lashing off the deck you stand on doesn't drop you into the abyss (alive=%s, y=%.1f after %.1f s)" % [me().get("alive"), lp.global_position.y, guard / 60.0])
	if not bool(me().get("alive", true)):
		req("respawn", {})
		await frames(3)
	# now take the inner platform apart completely: the stone should come down
	await stand_near(origin - out * 2.6, Vector3.ZERO)
	guard = 0
	while World.has_entity(a_id) and guard < 20:
		req("build_dismantle", {"eid": a_id})
		await frames(1)
		guard += 1
	check(not World.has_entity(a_id), "the inner platform came apart")
	await frames(10)
	var st2 := World.get_entity(int(st["id"]))
	if not st2.is_empty():
		var p: Vector3 = st2["xf"].origin
		var g2 := World.terrain.height(p.x, p.z)
		print("     the stone is now at y=%.3f, %.2f m above the ground" % [p.y, p.y - g2])
		check(p.y - g2 < 0.15, "the stone that sat on the deck came down to the ground (%.2f m above it)" % (p.y - g2))
		# what you see is what you get: can you still pick it up from the ground?
		lp.global_position = Vector3(p.x, g2 + 0.05, p.z) + Vector3(0, 0, 0.9)
		await frames(3)


func suite_qa_hang() -> void:
	print("-- QA: a stone set down on a deck over the abyss, then the deck is taken apart")
	Events.toast.connect(func(t, k): print("     [toast] ", t))
	var spot := edge_spot()
	var c: Vector2 = spot["c"]
	var dir: Vector2 = spot["dir"]
	var basis := Basis(Vector3.UP, atan2(dir.x, dir.y))
	var origin := Vector3(c.x, float(spot["top"]) + 0.04, c.y)
	await stand_near(origin, Vector3(-dir.x * 1.8, 0, -dir.y * 1.8))
	var a_id := await build_frame("platform", Transform3D(basis, origin))
	await complete(a_id)
	var out := basis.z
	var b_id := await build_frame("platform", Transform3D(basis, origin + out * 2.0))
	await complete(b_id)
	check(a_id != -1 and b_id != -1, "two platforms, the second out over the abyss")
	# stand on the inner deck near its outer edge and set a stone on the outer deck
	lp.global_position = origin + out * 0.6 + Vector3(0, 0.1, 0)
	lp.velocity = Vector3.ZERO
	await frames(10)
	give("stone", 1)
	var hit := _deck_hit(origin + out * 2.0, Vector3(0.2, 0, 0.3))
	check(not hit.is_empty(), "the outer deck is solid")
	if hit.is_empty():
		return
	var top: Vector3 = hit["position"]
	req("place", {"slot": slot_of("stone"), "xf": Transform3D(Basis(), top + Vector3(0, 0.03, 0))})
	await frames(2)
	var st := newest("item")
	check(not st.is_empty() and String(st["d"]["i"]) == "stone", "a stone sits on the outer deck")
	if st.is_empty():
		return
	var sp: Vector3 = st["xf"].origin
	print("     stone at (%.2f, %.2f, %.2f), over the island: %s" % [sp.x, sp.y, sp.z, World.terrain.is_inside(sp.x, sp.z)])
	var lost0 := float(World.pools.get("lost_stone", 0.0))
	# take the outer deck apart from where we stand
	var guard := 0
	while World.has_entity(b_id) and guard < 20:
		req("build_dismantle", {"eid": b_id})
		await frames(1)
		guard += 1
	check(not World.has_entity(b_id), "the outer platform came apart (every part back in the pack)")
	await frames(30)
	var st2 := World.get_entity(int(st["id"]))
	var lost := float(World.pools.get("lost_stone", 0.0)) - lost0
	if not st2.is_empty():
		var p2: Vector3 = st2["xf"].origin
		var below := lp.get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(p2 + Vector3(0, 0.05, 0), p2 + Vector3(0, -60, 0), EntityView.LAYER_TERRAIN | EntityView.LAYER_STRUCT | EntityView.LAYER_ITEMS, [st2_body(int(st["id"]))]))
		print("     the stone is still at (%.2f, %.2f, %.2f); anything under it within 60 m: %s" % [p2.x, p2.y, p2.z, not below.is_empty()])
	check(st2.is_empty() and lost >= ItemDB.unit_mass("stone") - 1e-4, "with the deck gone, the stone fell into the abyss and is booked as lost (still there: %s, lost %.2f kg)" % [not st2.is_empty(), lost])


func st2_body(eid: int) -> RID:
	var v: Node = Game.game_world.entities.view(eid)
	if v and v.get("body"):
		return v.body.get_rid()
	return RID()


# ---------------------------------------------------------------------------
# 4. Taking a platform apart puts you over the carry limit
# ---------------------------------------------------------------------------

func suite_qa_carry() -> void:
	print("-- QA: carry limit vs. dismantling")
	var spot := clear_soil_spot()
	var origin := spot + Vector3(0, 0.04, 0)
	for cc in [Vector3(1, 0, 1), Vector3(-1, 0, 1), Vector3(1, 0, -1), Vector3(-1, 0, -1)]:
		var w: Vector3 = origin + (cc as Vector3) * 0.95
		origin.y = maxf(origin.y, World.terrain.height(w.x, w.z) + 0.04)
	await stand_near(origin, Vector3(0, 0, 2.4))
	var id := await build_frame("platform", Transform3D(Basis(), origin))
	check(id != -1, "a platform")
	if id == -1:
		return
	await complete(id)
	var guard := 0
	while World.has_entity(id) and guard < 20:
		req("build_dismantle", {"eid": id})
		await frames(1)
		guard += 1
	var kg := inv().carried_kg()
	print("     carrying %.1f kg (limit %.0f)" % [kg, Actions.CARRY_KG])
	check(kg <= Actions.CARRY_KG + 0.01, "taking a platform apart doesn't load you past the carry limit (%.1f kg)" % kg)
	var stick := place("stick", 1, {}, lp.global_position + Vector3(0.5, 0, 0.5))
	await frames(2)
	req("pickup", {"eid": stick})
	await frames(2)
	print("     and a 0.35 kg stick: %s" % ("picked up" if not World.has_entity(stick) else "refused"))


# ---------------------------------------------------------------------------
# 5. Dying while in a crafting close-up
# ---------------------------------------------------------------------------

func _press(action: String) -> void:
	var ev := InputEventAction.new()
	ev.action = action
	ev.pressed = true
	Input.parse_input_event(ev)
	await frames(2)
	var up := InputEventAction.new()
	up.action = action
	up.pressed = false
	Input.parse_input_event(up)
	await frames(2)


func suite_qa_deathcraft() -> void:
	print("-- QA: dying while knapping, then waking up")
	var cc: CraftController = Game.game_world.crafting
	give("stone", 2)
	var top := flat_stone_top()
	await stand_near(top, Vector3(0, 0, 0.8))
	req("work_start", {"kind": "knap", "surface": int(newest("flat_stone")["id"]), "pos": top + Vector3(-0.1, 0, 0), "slot": slot_of("stone")})
	await frames(40)
	check(cc.is_open() and lp.mode == "craft", "the knapping close-up is open (mode %s)" % lp.mode)
	Survival.damage(Net.my_id(), 2.0, "cold")
	await frames(10)
	print("     after death: mode=%s, craft open=%s, camera=%s" % [lp.mode, cc.is_open(), get_viewport().get_camera_3d().name])
	req("respawn", {})
	await frames(30)
	var cam := get_viewport().get_camera_3d()
	print("     after waking: mode=%s, craft open=%s, camera=%s, alive=%s" % [lp.mode, cc.is_open(), cam.name, me().get("alive")])
	check(not cc.is_open(), "the knapping close-up closed when you died / woke up (open=%s)" % cc.is_open())
	check(cam == lp.active_camera(), "you look through your own eyes again after waking (camera: %s)" % cam.name)
	# Esc is what the close-up says steps away; what does it do now?
	await _press("pause")
	var hud = Game.game_world.hud
	print("     Esc -> panel '%s', craft open=%s, camera=%s" % [hud.panel_name, cc.is_open(), get_viewport().get_camera_3d().name])
	check(not cc.is_open(), "Esc gets you out of the stale close-up (panel '%s', craft open %s)" % [hud.panel_name, cc.is_open()])
	if hud.panel_name != "":
		hud.close_panel()


# ---------------------------------------------------------------------------
# 6. Conservation sweep over action paths the suites don't exercise
# ---------------------------------------------------------------------------

func _scenario_end(L0: Dictionary, label: String) -> void:
	await frames(2)
	ledger_same(L0, ledger(), label, {"water": 0.01})


func suite_qa_ledger() -> void:
	print("-- QA: conservation sweep")
	var top := flat_stone_top()
	var fsid := int(newest("flat_stone")["id"])
	var spot := clear_soil_spot()
	# A. knapping: strike a few times, then gather the work up
	await stand_near(top, Vector3(0, 0, 0.8))
	give("stone", 2)
	var L0 := ledger()
	req("work_start", {"kind": "knap", "surface": fsid, "pos": top + Vector3(-0.1, 0, 0), "slot": slot_of("stone")})
	await frames(3)
	var w := _work()
	if not w.is_empty():
		var p := Knap.params(int(w["d"]["seed"]))
		for k in 5:
			var e2 := Knap.outline_point(p, World.get_entity(int(w["id"]))["d"]["cuts"], Vector2(cos(k * 1.3), sin(k * 1.3)))
			req("work_op", {"eid": int(w["id"]), "op": ["strike", e2.x, e2.y, 0.5]})
			await frames(1)
		req("work_cancel", {"eid": int(w["id"])})
	await _scenario_end(L0, "A knap + gather up")
	# B. clay prep with pond water, then gathered up
	var bank := Vector3(TerrainData.POND_CENTER.x + 1.7, 0, TerrainData.POND_CENTER.y + 0.6)
	bank.y = World.terrain.height(bank.x, bank.z)
	await stand_near(bank, Vector3(0.4, 0, 0.4))
	give("clay", 5, {"moist": 0.17})
	L0 = ledger()
	req("work_start", {"kind": "clay_prep", "surface": -1, "pos": bank, "slot": slot_of("clay")})
	await frames(3)
	w = _work()
	if not w.is_empty():
		for k in 3:
			req("work_op", {"eid": int(w["id"]), "op": ["water"]})
		for k in 3:
			req("work_op", {"eid": int(w["id"]), "op": ["knead", 0.8]})
		await frames(2)
		req("work_cancel", {"eid": int(w["id"])})
	await _scenario_end(L0, "B clay prep + gather up")
	# C. pottery: hollow, trim, add a lump, gather up
	give("clay_prepared", 3, {"moist": 0.25})
	L0 = ledger()
	req("work_start", {"kind": "pottery", "surface": -1, "pos": bank + Vector3(0.3, 0, 0), "slot": slot_of("clay_prepared")})
	await frames(3)
	w = _work()
	if not w.is_empty():
		var eid := int(w["id"])
		for i in 6:
			req("work_op", {"eid": eid, "op": ["hollow", 0.1 * (i + 1), 0.25 + 0.06 * i, 0.0]})
		for i in 6:
			req("work_op", {"eid": eid, "op": ["smooth", 0.5, 0.8, 0.0]})
		req("work_op", {"eid": eid, "op": ["trim", 0.45]})
		await frames(2)
		print("     pot vol after trim %.3f, prepared clay in pack %d" % [float(World.get_entity(eid)["d"]["pot"]["vol"]), inv().count("clay_prepared")])
		if inv().count("clay_prepared") > 0:
			req("work_op", {"eid": eid, "op": ["add"]})
		await frames(2)
		req("work_cancel", {"eid": eid})
	await _scenario_end(L0, "C pottery + trim + add + gather up")
	# D. pottery 'add' when the pack holds two lumps of different dampness
	for i in inv().slots.size():
		if inv().item_at(i) == "clay_prepared":
			inv().set_slot(i, {})
	World.mark_inventory(Net.my_id())
	await frames(1)
	injected = Ledger.empty()
	give("clay_prepared", 16, {"moist": 0.21})
	give("clay_prepared", 1, {"moist": 0.31})
	print("     clay slots: ", slots_of("clay_prepared").map(func(i): return inv().get_slot(i)["d"]))
	L0 = ledger()
	req("work_start", {"kind": "pottery", "surface": -1, "pos": bank + Vector3(-0.3, 0, 0.1), "slot": slots_of("clay_prepared")[0]})
	await frames(3)
	w = _work()
	if not w.is_empty():
		req("work_op", {"eid": int(w["id"]), "op": ["add"]})
		await frames(2)
	await _scenario_end(L0, "D pottery add from mixed stacks (work still open)")
	if not w.is_empty():
		req("work_cancel", {"eid": int(w["id"])})
		await frames(2)
	# E. hafting gathered up; cordage gathered up
	await stand_near(top, Vector3(0, 0, 0.8))
	give("stone_head", 1, {"seed": 9, "cuts": [], "q": 0.6, "stone_kg": 0.35, "shape": "axe", "strikes": 4})
	give("stick", 1)
	give("cordage", 1)
	give("fiber", 2)
	L0 = ledger()
	var hi := inv().find_where(func(s): return s["i"] == "stone_head")
	req("work_start", {"kind": "haft", "surface": fsid, "pos": top + Vector3(0.1, 0, 0.05), "slot": hi})
	await frames(3)
	w = _work()
	if not w.is_empty():
		req("work_cancel", {"eid": int(w["id"])})
	await frames(2)
	req("work_start", {"kind": "cordage", "surface": fsid, "pos": top + Vector3(-0.1, 0, -0.08), "slot": slot_of("fiber")})
	await frames(3)
	w = _work()
	if not w.is_empty():
		for i in 3:
			req("work_op", {"eid": int(w["id"]), "op": ["twist", 0.1, 0.9]})
		req("work_cancel", {"eid": int(w["id"])})
	await _scenario_end(L0, "E haft and cordage gathered up")
	# F. a cracked pot with water and grain broken into sherds
	await stand_near(spot, Vector3(0, 0, 0.9))
	var pot := make_pot(0.0)
	pot["state"] = "cracked"
	pot["water"] = 0.0
	pot["contents"] = {"seed_grain": 4}
	give("pot", 1, pot)
	L0 = ledger()
	req("break_pot", {"slot": slot_of("pot")})
	await _scenario_end(L0, "F breaking a cracked pot")
	# G. threshing grain by hand
	give("grain", 2)
	L0 = ledger()
	req("process_held", {"slot": slot_of("grain")})
	await _scenario_end(L0, "G threshing")
	# H. an axe wearing out on the outcrop
	var oc: Dictionary = World.entities_of("outcrop")[0]
	await stand_near(oc["xf"].origin, Vector3(1.6, 0, 0.6))
	give("axe", 1, {"q": 0.6, "dur": 0.004, "bind": 0.6, "cords": 1, "head": {"stone_kg": 0.3, "seed": 3, "cuts": [], "shape": "axe", "strikes": 3}})
	var loose: Array = World.get_entity(int(oc["id"]))["d"]["loose"]
	L0 = ledger()
	for i in 3:
		if slot_of("axe") == -1:
			break
		req("outcrop_break", {"eid": int(oc["id"]), "slot": slot_of("axe")})
		await frames(1)
	print("     axe broke: %s (loose stones %s)" % [slot_of("axe") == -1, str(loose)])
	await _scenario_end(L0, "H a worn-out axe breaking")
	# I. a burning stick that burns out in the pack
	give("torch", 1, {"mass": 0.004})
	L0 = ledger()
	FireSim._torches(60.0)
	await _scenario_end(L0, "I a burning stick burning out in the pack")
	# J. planting a tree seed
	var far := clear_soil_spot([spot])
	await stand_near(far, Vector3(0, 0, 0.9))
	give("seed_tree", 1)
	L0 = ledger()
	req("plant", {"pos": far, "slot": slot_of("seed_tree")})
	await frames(2)
	print("     trees now: %d" % World.entities_of("tree").size())
	await _scenario_end(L0, "J planting a tree seed")


func suite_qa_toolbreak() -> void:
	print("-- QA: tools wearing out")
	var spot := clear_soil_spot()
	await stand_near(spot, Vector3(0, 0, 0.9))
	for tool in ["axe", "blade"]:
		if tool == "axe":
			give("axe", 1, {"q": 0.6, "dur": 0.003, "bind": 0.6, "cords": 1, "head": {"stone_kg": 0.3, "seed": 3, "cuts": [], "shape": "axe", "strikes": 3}})
		else:
			give("blade", 1, {"seed": 5, "cuts": [], "q": 0.8, "stone_kg": 0.3, "dur": 0.002})
		var br := place("branch", 1, {"moist": 0.45}, spot + Vector3(0.3, 0, 0.3))
		await frames(3)
		var L0 := ledger()
		req("process", {"eid": br, "slot": slot_of(tool)})
		await frames(2)
		print("     %s broke: %s; pack: stick %d, stone_head %d, fiber %d" % [tool, slot_of(tool) == -1, inv().count("stick"), inv().count("stone_head"), inv().count("fiber")])
		await _scenario_end(L0, "a worn-out %s breaking" % tool)
		if World.has_entity(br):
			req("pickup", {"eid": br})
			await frames(2)


func suite_qa_torch() -> void:
	print("-- QA: a burning stick set down for a moment and picked up again")
	var spot := clear_soil_spot()
	await stand_near(spot, Vector3(0, 0, 0.9))
	give("torch", 1, {"mass": ItemDB.unit_mass("stick")})
	var L0 := ledger()
	var at := spot + Vector3(0.3, 0, 0.2)
	at.y = World.terrain.height(at.x, at.z)
	req("place", {"slot": slot_of("torch"), "xf": Transform3D(Basis(), at + Vector3(0, 0.02, 0))})
	await frames(2)
	var te := newest("item")
	check(String(te["d"].get("i", "")) == "torch", "the burning stick lies on the ground")
	await run_fire(0.3)
	te = World.get_entity(int(te["id"]))
	print("     on the ground: ", te["d"] if not te.is_empty() else "gone")
	if te.is_empty():
		return
	req("pickup", {"eid": int(te["id"])})
	await frames(2)
	var s := inv().get_slot(slot_of("torch"))
	print("     back in the pack: ", s)
	ledger_same(L0, ledger(), "after picking the burning stick up again", {"water": 0.05})
	# it keeps burning in the pack
	for i in 6:
		FireSim._torches(600.0)
	s = inv().get_slot(slot_of("torch"))
	print("     after an hour in the pack: ", s if not s.is_empty() else "burnt out")
	ledger_same(L0, ledger(), "after it burned on in the pack for an hour", {"water": 0.05})
	for i in 12:
		FireSim._torches(600.0)
	print("     burnt out: %s" % (slot_of("torch") == -1))
	ledger_same(L0, ledger(), "after it burned out in the pack", {"water": 0.05})


func suite_qa_reload() -> void:
	print("-- QA: save/load with a dead player, a groaning platform and a half-knapped stone")
	var hud = Game.game_world.hud
	# a platform two steps out, then its support removed so it groans
	var spot := edge_spot()
	var c: Vector2 = spot["c"]
	var dir: Vector2 = spot["dir"]
	var basis := Basis(Vector3.UP, atan2(dir.x, dir.y))
	var origin := Vector3(c.x, float(spot["top"]) + 0.04, c.y)
	await stand_near(origin, Vector3(-dir.x * 1.8, 0, -dir.y * 1.8))
	var a_id := await build_frame("platform", Transform3D(basis, origin))
	await complete(a_id)
	var b_id := await build_frame("platform", Transform3D(basis, origin + basis.z * 2.0))
	await complete(b_id)
	req("build_dismantle", {"eid": a_id})
	await frames(2)
	StructureSim.mark_dirty()
	StructureSim.tick(0.1)
	await frames(2)
	check(float(World.get_entity(b_id)["d"].get("stress", 0.0)) >= 1.0, "the outer platform groans")
	# a half-knapped stone on the anvil
	give("stone", 2)
	var top := flat_stone_top()
	await stand_near(top, Vector3(0, 0, 0.8))
	req("work_start", {"kind": "knap", "surface": int(newest("flat_stone")["id"]), "pos": top + Vector3(-0.1, 0, 0), "slot": slot_of("stone")})
	await frames(40)
	Game.game_world.crafting.close(true)
	await frames(30)
	var wid := int(_work()["id"]) if not _work().is_empty() else -1
	# and the islander dies of cold
	Survival.damage(Net.my_id(), 2.0, "cold")
	await frames(5)
	print("     death screen says: '%s'" % (hud.death_text.text if hud.death_panel else "-"))
	var L0 := ledger()
	var err := await reload_world()
	check(err == "", "saved and reloaded (%s)" % err)
	hud = Game.game_world.hud
	await frames(10)
	print("     after the reload: alive=%s, mode=%s, death panel %s, text '%s'" % [me().get("alive"), lp.mode,
		hud.death_panel.visible if hud.death_panel else false, hud.death_text.text if hud.death_panel else "-"])
	check(hud.death_panel != null and hud.death_panel.visible, "a dead islander still sees the death screen after a reload")
	check(hud.death_panel != null and hud.death_text.text == Survival._death_text("cold"), "and it says why ('%s', expected '%s')" % [hud.death_text.text if hud.death_panel else "-", Survival._death_text("cold")])
	ledger_same(L0, ledger(), "reload with all of that going on", {"water": 0.05})
	req("respawn", {})
	await frames(5)
	# the groaning platform still comes down
	for i in 30:
		StructureSim.tick(0.5)
		await frames(1)
	check(not World.has_entity(b_id), "the platform that was groaning at the save still falls after the reload")
	# and the half-knapped stone can be picked up again by its owner
	if wid != -1:
		check(World.has_entity(wid), "the half-knapped stone is still on the anvil")
		await stand_near(top, Vector3(0, 0, 0.8))
		req("work_open", {"eid": wid})
		await frames(30)
		check(Game.game_world.crafting.is_open(), "and work on it resumes after the reload")
		Game.game_world.crafting.close(true)
		await frames(20)


func suite_qa_fullpack_torch() -> void:
	print("-- QA: lighting a stick at a fire with a full pack")
	Events.toast.connect(func(t, k): print("     [toast] ", t))
	var c := ground(Vector2(-0.6, 2.4))
	await stand_near(c, Vector3(0, 0, 1.2))
	var tinder := lay_campfire(c)
	await frames(4)
	FireSim.ignite(tinder, 620.0)
	await run_fire(0.4)
	var site := site_near(c)
	check(not site.is_empty() and bool(site["d"].get("lit", false)), "a campfire is burning")
	# a hand of sticks, and every other slot full
	give("stick", 5)
	var filler := ["stone", "cordage", "fiber", "twig", "leaves", "berries", "straw", "clay", "earth", "seed_grain", "seed_fiber", "ash", "charcoal", "potsherds", "mushroom", "tuber", "grain", "food_scraps", "compost", "firewood", "pole", "hearth_board", "seed_tree", "board", "clay_prepared", "grass"]
	for id in filler:
		var free := 0
		for sl in inv().slots:
			if sl.is_empty():
				free += 1
		if free == 0:
			break
		if inv().count(id) == 0:
			give(id, 1)
	var empty := 0
	for s in inv().slots:
		if s.is_empty():
			empty += 1
	print("     empty slots: %d, carrying %.1f kg" % [empty, inv().carried_kg()])
	var hp0 := float(me()["health"])
	req("fire_torch", {"eid": int(site["id"]), "slot": slot_of("stick")})
	await frames(3)
	var torches := items_near(lp.global_position, "torch", 0.6)
	print("     burning sticks at my feet: %d" % torches.size())
	# stand still for a few seconds of real time (the island keeps ticking)
	for i in 6:
		await get_tree().create_timer(0.5).timeout
		Game.game_world.sim._tick(0.0, 0.5)
	var hp1 := float(me()["health"])
	print("     health %.2f -> %.2f; fire at my feet: %s" % [hp0, hp1, FireSim.burn_at(lp.global_position) > 0.0])
	check(hp1 >= hp0 - 0.01, "lighting a stick with a full pack doesn't set fire to your feet (health %.2f -> %.2f)" % [hp0, hp1])
