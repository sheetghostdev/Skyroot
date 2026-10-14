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
