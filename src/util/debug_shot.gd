extends Node
## Automated screenshots for visual testing (used with xvfb + a software renderer):
##   --shot=/abs/path.png  --delay=8  --pos=x,y,z  --look=yaw_deg,pitch_deg  --hour=17.5
##   --tp  (third person)  --give=item:n,item:n  --hotbar=N  --panel=inventory|guide|pause|build
##   --menu (capture the title screen)  --hidehud
##   --fire=camp|mound|kiln|ash|drill  --fhours=H  (build, light and fast-forward a fire in view)

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
