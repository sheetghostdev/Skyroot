extends Node
## Automated screenshots for visual testing (used with xvfb + a software renderer):
##   --shot=/abs/path.png  --delay=8  --pos=x,y,z  --look=yaw_deg,pitch_deg  --hour=17.5
##   --tp  (third person)  --give=item:n,item:n  --hotbar=N  --panel=inventory|guide|pause|build
##   --menu (capture the title screen)  --hidehud
##   --fire=camp|mound|kiln|ash|drill  --fhours=H  (build, light and fast-forward a fire in view)
##   --compost=H  (three heaps in view - fresh, H hours old, all straw - fast-forwarded)
##   --build=hut|frames  (a finished hut on a deck, or half-built frames, in view)
##   --smoke  (open every panel and guide entry, search, ghost every blueprint, both cameras; then quit)
##   --perf=S  (after S seconds, print average frame/process/physics times, draw calls, nodes; then quit)

var path := ""
var delay := 8.0
var _t := 0.0
var _setup_done := false


func _ready() -> void:
	path = Game.cli.get("shot", "")
	delay = float(Game.cli.get("delay", "8"))
	process_mode = Node.PROCESS_MODE_ALWAYS


func _process(delta: float) -> void:
	_t += delta
	if not _setup_done and Game.game_world and Game.game_world.local_player():
		_setup_done = true
		_setup()
	if _t >= delay and path != "":
		var img := get_viewport().get_texture().get_image()
		img.save_png(path)
		print("SHOT_SAVED ", path)
		get_tree().quit()
		path = ""


func _setup() -> void:
	var lp: LocalPlayer = Game.game_world.local_player()
	if Game.cli.has("hour") and Net.is_host():
		var day := World.day()
		World.env["t"] = day * 24.0 + float(Game.cli["hour"])
	if Game.cli.has("rain") and Net.is_host():
		World.env["rain"] = float(Game.cli["rain"])
		World.env["rain_target"] = float(Game.cli["rain"])
		World.env["cloud"] = 1.0
	if Game.cli.has("pos"):
		var p := String(Game.cli["pos"]).split(",")
		lp.global_position = Vector3(float(p[0]), float(p[1]), float(p[2]))
	if Game.cli.has("look"):
		var l := String(Game.cli["look"]).split(",")
		lp.yaw = deg_to_rad(float(l[0]))
		lp.pitch = deg_to_rad(float(l[1]))
	if Game.cli.has("tp"):
		lp.set_third_person(true)
	if Game.cli.has("give") and Net.is_host():
		for g in String(Game.cli["give"]).split(","):
			var kv := g.split(":")
			World.inventory_of(Net.my_id()).add(kv[0], int(kv[1]) if kv.size() > 1 else 1)
		World.mark_inventory(Net.my_id())
	if Game.cli.has("hotbar"):
		lp.select_hotbar.call_deferred(int(Game.cli["hotbar"]))
	if Game.cli.has("panel"):
		Game.game_world.hud.open_panel.call_deferred(String(Game.cli["panel"]))
	if Game.cli.has("hidehud"):
		Game.game_world.hud.root.visible = false
	if Game.cli.has("craft"):
		_craft_setup.call_deferred(String(Game.cli["craft"]))
	if Game.cli.has("fire"):
		_fire_setup.call_deferred(String(Game.cli["fire"]))
	if Game.cli.has("compost"):
		_compost_setup.call_deferred(float(Game.cli["compost"]))
	if Game.cli.has("build"):
		_build_setup.call_deferred(String(Game.cli["build"]))
	if Game.cli.has("smoke"):
		_smoke.call_deferred()
	if Game.cli.has("perf"):
		_perf.call_deferred(float(Game.cli["perf"]))


func _frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame


func _craft_setup(kind: String) -> void:
	var lp: LocalPlayer = Game.game_world.local_player()
	var pid := Net.my_id()
	var inv := World.inventory_of(pid)
	var fs := {}
	for e in World.entities.values():
		if e["t"] == "flat_stone":
			fs = e
	var v = Game.game_world.entities.view(int(fs["id"]))
	var top := Vector3(fs["xf"].origin.x, v.work_top(), fs["xf"].origin.z)
	lp.global_position = Vector3(top.x, World.terrain.height(top.x, top.z + 0.8) + 0.05, top.z + 0.8)
	await _frames(3)
	var item := ""
	match kind:
		"knap":
			inv.add("stone", 2)
			item = "stone"
		"pottery":
			inv.add("clay_prepared", 2, {"moist": 0.24})
			item = "clay_prepared"
		"clay_prep":
			inv.add("clay", 2, {"moist": 0.17})
			item = "clay"
		"cordage":
			inv.add("fiber", 2)
			item = "fiber"
		"haft":
			var cuts := []
			inv.add("stone_head", 1, {"shape": "axe", "q": 0.7, "seed": 77, "cuts": cuts, "stone_kg": 0.6})
			inv.add("stick", 1)
			inv.add("cordage", 1)
			item = "stone_head"
	World.mark_inventory(pid)
	await _frames(2)
	World.request("work_start", {"kind": kind, "surface": int(fs["id"]), "pos": top, "slot": inv.find(item), "eye": lp.eye_position()})
	await _frames(4)
	var w := {}
	for e in World.entities.values():
		if e["t"] == "work":
			w = e
	if w.is_empty():
		return
	var eid := int(w["id"])
	var n := int(Game.cli.get("auto", "0"))
	match kind:
		"knap":
			var p := Knap.params(int(w["d"]["seed"]))
			for i in n:
				var ang := i * 2.39996
				var cuts2: Array = World.get_entity(eid)["d"]["cuts"]
				var edge := Knap.outline_point(p, cuts2, Vector2(cos(ang), sin(ang)))
				World.request("work_op", {"eid": eid, "op": ["strike", edge.x, edge.y, 0.15 + 0.5 * float(i % 3 == 0)]})
				await _frames(1)
		"pottery":
			for i in mini(n, 10):
				World.request("work_op", {"eid": eid, "op": ["hollow", 0.08 * (i + 1), 0.3 + 0.05 * i, 0.0]})
			for i in n:
				World.request("work_op", {"eid": eid, "op": ["shape", 0.75, -0.0025, 0.01]})
				World.request("work_op", {"eid": eid, "op": ["smooth", 0.5, 0.5, 0.0]})
			await _frames(2)
		"clay_prep":
			for i in n:
				World.request("work_op", {"eid": eid, "op": ["knead", 0.8]})
		"cordage":
			for i in n:
				World.request("work_op", {"eid": eid, "op": ["twist", 0.07, 0.9]})
		"haft":
			World.request("work_op", {"eid": eid, "op": ["seat", 0.205, 0.0, 0.05]})
			await _frames(2)
			for i in n:
				World.request("work_op", {"eid": eid, "op": ["wrap", 0.5]})


func _compost_setup(hours: float) -> void:
	var lp: LocalPlayer = Game.game_world.local_player()
	var pid := Net.my_id()
	var inv := World.inventory_of(pid)
	var c := Vector3(0.0, 0.0, 3.0)
	c.y = World.terrain.height(c.x, c.z)
	lp.global_position = Vector3(c.x, World.terrain.height(c.x, c.z + 1.8) + 0.05, c.z + 1.8)
	lp.yaw = 0.0
	lp.pitch = deg_to_rad(-30.0)
	await _frames(4)
	var mixes := [{"leaves": 6, "grass": 8, "food_scraps": 4}, {"leaves": 8, "grass": 10, "straw": 16, "fiber": 6, "food_scraps": 4}, {"straw": 18}]
	var ids: Array = []
	for i in 3:
		var p := c + Vector3((i - 1) * 1.55, 0, 0)
		p.y = World.terrain.height(p.x, p.z)
		var mix: Dictionary = mixes[i]
		for id in mix:
			inv.add(id, int(mix[id]))
		World.mark_inventory(pid)
		await _frames(1)
		var first := String(mix.keys()[0])
		World.request("compost_start", {"pos": p, "slot": inv.find(first), "eye": lp.eye_position()})
		await _frames(2)
		var hid := -1
		for e in World.entities_of("compost"):
			if not ids.has(int(e["id"])):
				hid = int(e["id"])
		ids.append(hid)
		if hid == -1:
			push_warning("compost shot: heap %d not started" % i)
			continue
		for id in mix:
			while inv.find(id) != -1:
				World.request("compost_add", {"eid": hid, "slot": inv.find(id), "eye": lp.eye_position()})
				await _frames(1)
	# age the middle heap
	for i in int(hours / 0.2):
		CompostSim._acc = 0.0
		CompostSim.tick(0.2)
		if i % 10 == 0:
			await _frames(1)


func _perf(secs: float) -> void:
	path = ""
	await get_tree().create_timer(3.0).timeout
	var n := 0
	var t_proc := 0.0
	var t_phys := 0.0
	var t_frame := 0.0
	var calls := 0.0
	var prims := 0.0
	var worst := 0.0
	var t0 := Time.get_ticks_usec()
	var last := t0
	while (Time.get_ticks_usec() - t0) / 1e6 < secs:
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		var ft := (now - last) / 1000.0
		last = now
		n += 1
		t_frame += ft
		worst = maxf(worst, ft)
		t_proc += Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
		t_phys += Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
		calls += Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
		prims += Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)
	print("PERF frames %d  frame %.2f ms (worst %.1f)  process %.2f ms  physics %.2f ms  draw calls %.0f  primitives %.0f  nodes %d  entities %d" % [
		n, t_frame / n, worst, t_proc / n, t_phys / n, calls / n, prims / n, int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)), World.entities.size()])
	get_tree().quit()


func _smoke() -> void:
	## Exercise the UI end to end so any engine error shows up in the log.
	var lp: LocalPlayer = Game.game_world.local_player()
	var hud = Game.game_world.hud
	path = ""
	await _frames(30)
	for nm in ["inventory", "build", "pause", "guide"]:
		hud.open_panel(nm)
		await _frames(20)
		if nm != "guide":
			hud.close_panel()
			await _frames(5)
	var g: GuideUI = hud.panel
	var n := 0
	for cat in Guide.categories:
		for id in cat["entries"]:
			g.show_entry(String(id))
			await _frames(4)
			n += 1
	for q in ["clay", "charcoal mound", "cold", "zzz"]:
		g.search.text = q
		g._on_search(q)
		await _frames(4)
	g.show_journal()
	await _frames(6)
	g._toggle_pin("fire")
	await _frames(4)
	hud.close_panel()
	await _frames(10)
	print("SMOKE guide entries shown: ", n)
	for bp in ItemDB.blueprints.keys():
		lp.placer.start_place(String(bp))
		await _frames(8)
	lp.placer.stop()
	await _frames(5)
	lp.set_third_person(true)
	await _frames(30)
	lp.set_third_person(false)
	await _frames(30)
	print("SMOKE_DONE")
	get_tree().quit()


func _structure(bp: String, xf: Transform3D, fraction: float = 1.0) -> int:
	var parts: Array = ItemDB.blueprint(bp).get("parts", [])
	var n := int(round(parts.size() * fraction))
	var used: Array = []
	for i in n:
		used.append(String(parts[i]).get_slice("|", 0))
	return World.spawn("structure", xf, {"bp": bp, "installed": n, "used": used, "sy": 1.0, "by": "Shot", "stress": 0.0})


func _build_setup(kind: String) -> void:
	var lp: LocalPlayer = Game.game_world.local_player()
	var c := Vector3(-0.8, 0.0, 3.3)
	var basis := Basis(Vector3.UP, 0.35)
	var top := -INF
	for o in [Vector3(1, 0, 1), Vector3(-1, 0, 1), Vector3(1, 0, -1), Vector3(-1, 0, -1), Vector3.ZERO]:
		var w: Vector3 = c + basis * (o as Vector3) * 0.95
		top = maxf(top, World.terrain.height(w.x, w.z))
	c.y = top + 0.04
	var cam := Vector3(1.2, 0.0, -0.2)
	if Game.cli.has("cam"):
		var cv := String(Game.cli["cam"]).split(",")
		cam = Vector3(float(cv[0]), 0.0, float(cv[1]))
	lp.global_position = Vector3(cam.x, World.terrain.height(cam.x, cam.z) + 0.05, cam.z)
	var to := c - cam
	lp.yaw = atan2(-to.x, -to.z)
	lp.pitch = deg_to_rad(-8.0)
	await _frames(4)
	if kind == "frames":
		_structure("platform", Transform3D(basis, c), 0.5)
		_structure("wall", Transform3D(basis.rotated(Vector3.UP, PI * 0.5), c + basis.x * 0.93), 0.4)
		_structure("ladder", Transform3D(basis, c - basis.z * 1.2), 0.0)
	else:
		_structure("platform", Transform3D(basis, c))
		_structure("wall", Transform3D(basis, c - basis.z * 0.93))
		_structure("wall", Transform3D(basis.rotated(Vector3.UP, PI * 0.5), c + basis.x * 0.93))
		_structure("doorway", Transform3D(basis.rotated(Vector3.UP, PI * 0.5), c - basis.x * 0.93))
		_structure("roof", Transform3D(basis, c + Vector3(0, 2.2, 0)))
		_structure("sleeping_mat", Transform3D(basis.rotated(Vector3.UP, PI * 0.5), c + basis.x * 0.35 + Vector3(0, 0.0, 0)))
		_structure("railing", Transform3D(basis, c + basis.z * 0.93))
	StructureSim.mark_dirty()


func _spawn(id: String, n: int, x: Dictionary, p: Vector3) -> int:
	return World.actions.spawn_item(id, n, x, p + Vector3(0, 0.25, 0))


func _fire_setup(kind: String) -> void:
	var lp: LocalPlayer = Game.game_world.local_player()
	var c := Vector3(0.0, 0.0, 3.0)
	c.y = World.terrain.height(c.x, c.z)
	var back := Vector3(0.0, 0.0, 1.5) if kind != "drill" else Vector3(0.0, 0.0, 0.9)
	lp.global_position = Vector3(c.x + back.x, World.terrain.height(c.x + back.x, c.z + back.z) + 0.05, c.z + back.z)
	lp.yaw = 0.0
	lp.pitch = deg_to_rad(-28.0)
	await _frames(4)
	var hours := float(Game.cli.get("fhours", "0.3"))
	if kind == "drill":
		var inv := World.inventory_of(Net.my_id())
		inv.add("hearth_board", 1)
		inv.add("stick", 1)
		inv.add("straw", 2)
		World.mark_inventory(Net.my_id())
		await _frames(2)
		World.request("work_start", {"kind": "fire_drill", "pos": c, "slot": inv.find("hearth_board"), "eye": lp.eye_position()})
		await _frames(4)
		var w := {}
		for e in World.entities.values():
			if e["t"] == "work":
				w = e
		if not w.is_empty():
			for i in int(Game.cli.get("auto", "60")):
				World.request("work_op", {"eid": int(w["id"]), "op": ["spin", 1.0, 0.05]})
				await _frames(1)
		return
	var tinder := _spawn("straw", 3, {"moist": 0.08}, c)
	_spawn("twig", 6, {"moist": 0.1}, c + Vector3(0.06, 0, 0.03))
	_spawn("stick", 3, {"moist": 0.15}, c + Vector3(-0.05, 0, 0.05))
	var nfw := 9 if kind == "mound" else (6 if kind == "kiln" else 3)
	if kind == "kiln":
		var pot := Pottery.new_lump(Pottery.LUMP_L * 2.0, 0.22, 99)
		for i in 8:
			Pottery.apply_op(pot, ["hollow", 0.1 * (i + 1), 0.25 + 0.06 * i, 0.0])
		Pottery.finalize(pot)
		pot["moist"] = 0.03
		pot["state"] = "dry"
		_spawn("pot", 1, pot, c + Vector3(0.02, 0, 0.0))
	for i in nfw:
		var a := i * TAU / nfw
		var rad := 0.13 if (nfw < 9 or i % 2 == 0) else 0.22
		_spawn("firewood", 1, {"moist": 0.15}, c + Vector3(cos(a) * rad, 0, sin(a) * rad))
	await _frames(4)
	FireSim.ignite(tinder, 620.0)
	var pid := Net.my_id()
	var pre := 0.5 if kind == "mound" else (0.3 if kind == "kiln" else hours)
	for i in int(pre / 0.05):
		FireSim.tick(0.05, 2.5)
		await _frames(1)
	if kind == "mound" or kind == "kiln":
		var sid := FireSim.site_at(c)
		var inv2 := World.inventory_of(pid)
		inv2.add("earth", 20 if kind == "mound" else 5)
		World.mark_inventory(pid)
		await _frames(2)
		var guard := 0
		while guard < 24 and inv2.count("earth") > 0:
			var d: Dictionary = World.get_entity(sid)["d"]
			var worst := 0
			var wc := 2.0
			for k in FireSim.CELLS:
				var cv := FireSim.coverage(d, k)
				if kind == "kiln" and k >= FireSim.AZ:
					continue
				if cv < wc:
					wc = cv
					worst = k
			if wc >= 0.999:
				break
			World.request("fire_cover", {"eid": sid, "pos": FireSim.cell_point(worst, d, c), "slot": inv2.find("earth"), "eye": lp.eye_position()})
			await _frames(1)
			guard += 1
		if kind == "mound":
			inv2.add("stick", 1)
			World.mark_inventory(pid)
			await _frames(1)
			for k in [3, 6]:
				World.request("fire_vent", {"eid": sid, "pos": FireSim.cell_point(k, World.get_entity(sid)["d"], c), "slot": inv2.find("stick"), "eye": lp.eye_position()})
				await _frames(1)
		for i in int(hours / 0.05):
			FireSim.tick(0.05, 2.5)
			await _frames(1)
	if kind == "ash":
		for i in int(5.0 / 0.05):
			FireSim.tick(0.05, 2.5)
			await _frames(1)
