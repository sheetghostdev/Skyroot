extends Node
## Automated screenshots for visual testing (used with xvfb + a software renderer):
##   --shot=/abs/path.png  --delay=8  --pos=x,y,z  --look=yaw_deg,pitch_deg  --hour=17.5
##   --tp  (third person)  --give=item:n,item:n  --hotbar=N  --panel=inventory|guide|pause|build
##   --menu (capture the title screen)  --hidehud

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
