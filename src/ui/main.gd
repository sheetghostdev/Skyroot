extends Node
## Root of the running game: swaps between the main menu and the game world.

const MainMenu := preload("res://src/ui/main_menu.gd")

var menu: Control = null
var current_world: Node = null


func _ready() -> void:
	add_to_group("main")
	get_window().title = "Skyroot"
	if Game.cli.has("shot") or Game.cli.has("smoke") or Game.cli.has("perf"):
		add_child(load("res://src/util/debug_shot.gd").new())
	if Game.cli.has("mptest"):
		add_child(load("res://src/util/mp_test.gd").new())
	if Game.cli.has("autostart"):
		_autostart.call_deferred()
	else:
		show_menu("")


func _autostart() -> void:
	## Used by automated tests and quick iteration:
	##   --autostart=solo|host|join  --world=<name>  --new  --ip=<ip>  --port=<n>
	var mode: String = Game.cli["autostart"]
	var port := int(Game.cli.get("port", str(Net.DEFAULT_PORT)))
	var err := ""
	if mode == "join":
		err = Game.join(Game.cli.get("ip", "127.0.0.1"), port)
	else:
		var wname: String = Game.cli.get("world", "TestIsland")
		var is_new: bool = Game.cli.has("new") or not FileAccess.file_exists(World.save_path(wname))
		err = Game.start_world(mode, wname, is_new, port)
	if err != "":
		push_error(err)
		print("AUTOSTART_ERROR ", err)
		get_tree().quit(2)


func show_menu(reason: String) -> void:
	if current_world:
		current_world.queue_free()
		current_world = null
	if menu == null:
		menu = MainMenu.new()
		add_child(menu)
	menu.visible = true
	menu.refresh()
	if reason != "":
		menu.show_message(reason)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func show_game(world: Node) -> void:
	if menu:
		menu.queue_free()
		menu = null
	if current_world and current_world != world:
		current_world.queue_free()
	current_world = world
	add_child(world)
