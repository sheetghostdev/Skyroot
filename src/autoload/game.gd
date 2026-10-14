extends Node
## Session flow: main menu -> (solo | host | join) -> playing -> menu.

const AUTOSAVE_SECONDS := 180.0
const GameWorldScript := preload("res://src/world/game_world.gd")

var state := "menu"          # menu | connecting | playing
var game_world: Node3D = null
var _autosave := AUTOSAVE_SECONDS
var _quitting := false

# Command-line options for automated tests: --autostart=solo|host|join, --world=, --ip=, --name=
var cli: Dictionary = {}


func _ready() -> void:
	get_tree().set_auto_accept_quit(false)
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--"):
			var kv := arg.substr(2).split("=", true, 1)
			cli[kv[0]] = kv[1] if kv.size() > 1 else "1"
	if cli.has("name"):
		Settings.player_name = cli["name"]
	Net.session_ended.connect(_on_session_ended)
	Net.join_failed.connect(_on_join_failed)


func main_node() -> Node:
	return get_tree().get_first_node_in_group("main")


func start_world(mode: String, world_name: String, is_new: bool, port: int = Net.DEFAULT_PORT) -> String:
	## Returns "" on success or an error message.
	if mode == "host":
		var err := Net.host(port)
		if err != OK:
			return "Could not open port %d (%s). Is another game already hosting?" % [port, error_string(err)]
	else:
		Net.start_offline()
	if is_new:
		World.new_world(world_name)
		WorldGen.populate()
	else:
		var lerr := World.load_world(world_name)
		if lerr != OK:
			Net.close()
			return "Could not load world '%s' (%s)." % [world_name, error_string(lerr)]
	var info := World.on_player_joined(Net.my_id(), Settings.player_name)
	Guide.load_local(_guide_key())
	Guide.import_state(World.guide_states.get(Net.my_id(), {}))
	_first_steps(info)
	_enter_game(info)
	return ""


func join(ip: String, port: int = Net.DEFAULT_PORT) -> String:
	var err := Net.join(ip, port)
	if err != OK:
		return "Could not start connection (%s)." % error_string(err)
	state = "connecting"
	return ""


func on_client_snapshot() -> void:
	pass  # the welcome message that follows carries our spawn info


func on_client_welcome(info: Dictionary) -> void:
	Guide.load_local(_guide_key())
	World.guide_states[Net.my_id()] = info.get("guide", {})
	Guide.import_state(info.get("guide", {}))
	_first_steps(info)
	_enter_game(info)


func _first_steps(info: Dictionary) -> void:
	## Someone new to this island starts with the first-hour checklist on screen.
	if bool(info.get("new", false)) and Guide.pinned.is_empty() and Guide.read.is_empty() and Guide.has_entry("getting_started"):
		Guide.toggle_pin("getting_started")


func _guide_key() -> String:
	return "%s_%d" % [World.world_name.validate_filename(), World.world_seed]


func _enter_game(info: Dictionary) -> void:
	state = "playing"
	_autosave = AUTOSAVE_SECONDS
	var m := main_node()
	if game_world:
		game_world.queue_free()
	game_world = GameWorldScript.new()
	game_world.name = "GameWorld"
	game_world.spawn_info = info
	if m:
		m.show_game(game_world)
	else:
		get_tree().root.add_child(game_world)
	Events.world_loaded.emit()


func leave(reason: String = "") -> void:
	if state == "playing" and Net.is_host():
		save()
	_teardown()
	var m := main_node()
	if m:
		m.show_menu(reason)


func _teardown() -> void:
	state = "menu"
	if game_world:
		game_world.queue_free()
		game_world = null
	Sfx.stop_all_ambient()
	Net.close()
	World.reset()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func save() -> Error:
	if state != "playing" or not Net.is_host():
		return ERR_UNAVAILABLE
	var live := {}
	for pid in Net.players:
		var pose: Dictionary = Net.poses.get(pid, {})
		live[pid] = {"name": Net.player_name(pid), "pos": pose.get("p", World.spawn_point(pid)), "yaw": pose.get("y", 0.0)}
	var err := World.save_world(live)
	if err == OK:
		Events.toast.emit("Island saved.", "save")
	else:
		Events.toast.emit("Save failed: " + error_string(err), "error")
	return err


func _process(delta: float) -> void:
	if state == "playing" and Net.is_host():
		_autosave -= delta
		if _autosave <= 0.0:
			_autosave = AUTOSAVE_SECONDS
			save()


func _on_session_ended(reason: String) -> void:
	if state != "menu":
		_teardown()
		var m := main_node()
		if m:
			m.show_menu(reason)


func _on_join_failed(reason: String) -> void:
	if state == "connecting" or state == "playing":
		_teardown()
	var m := main_node()
	if m:
		m.show_menu(reason)


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST and not _quitting:
		quit()


func _exit_tree() -> void:
	# static caches hold resources; release them so the engine shuts down cleanly
	Tex._cache.clear()
	Models._scenes.clear()
	Models._mats.clear()
	Models._held.clear()
	ProcMesh._cache.clear()
	Geo._ico_cache.clear()
	InteractionRules._lift_cache.clear()
	UITheme._theme = null
	UITheme._font = null
	UITheme._font_bold = null
	UITheme._font_title = null
	FireSim.reset()
	ActionsFire._drill_t.clear()
	preload("res://src/entities/site_view.gd").clear_cache()


func quit() -> void:
	_quitting = true
	if state == "playing" and Net.is_host():
		save()
	Settings.save_settings()
	Guide.save_local()
	Net.close()
	Sfx.shutdown()
	await get_tree().create_timer(0.15).timeout
	get_tree().quit()
