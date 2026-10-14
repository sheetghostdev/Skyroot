extends Node
## Player preferences, persisted to user://settings.cfg, and the input map.

const PATH := "user://settings.cfg"

var player_name := ""
var last_ip := "127.0.0.1"
var port := 7777
var mouse_sensitivity := 0.0024
var invert_y := false
var fov := 78.0
var head_bob := true
var master_volume := 0.9
var sfx_volume := 1.0
var ambience_volume := 0.8
var shadows_quality := 2        # 0 low .. 3 ultra
var render_scale := 1.0
var grass_density := 1.0
var show_hints := true
var fullscreen := false
var vsync := true
var ssao := true

# action -> list of event specs.  "k:<keycode>" keyboard (physical), "m:<button>" mouse.
const INPUTS := {
	"move_forward": ["k:W", "k:Up"],
	"move_back": ["k:S", "k:Down"],
	"move_left": ["k:A", "k:Left"],
	"move_right": ["k:D", "k:Right"],
	"jump": ["k:Space"],
	"sprint": ["k:Shift"],
	"crouch": ["k:Ctrl", "k:C"],
	"interact": ["k:E"],
	"primary": ["m:1"],
	"secondary": ["m:2"],
	"inventory": ["k:Tab", "k:I"],
	"guide": ["k:H"],
	"build": ["k:B"],
	"camera_toggle": ["k:V"],
	"drop": ["k:Q"],
	"rotate": ["k:R"],
	"pause": ["k:Escape"],
	"confirm": ["k:Enter", "k:Kp Enter"],
	"chat": ["k:T"],
	"hotbar_next": ["m:5"],
	"hotbar_prev": ["m:4"],
	"hotbar_1": ["k:1"], "hotbar_2": ["k:2"], "hotbar_3": ["k:3"],
	"hotbar_4": ["k:4"], "hotbar_5": ["k:5"], "hotbar_6": ["k:6"],
	"hotbar_7": ["k:7"], "hotbar_8": ["k:8"], "hotbar_9": ["k:9"],
	"quick_save": ["k:F5"],
	"screenshot": ["k:F12"],
	"toggle_hud": ["k:F1"],
}


func _ready() -> void:
	load_settings()
	setup_input()
	apply()


func setup_input() -> void:
	for action in INPUTS:
		if InputMap.has_action(action):
			InputMap.erase_action(action)
		InputMap.add_action(action, 0.2)
		for spec in INPUTS[action]:
			var ev := _make_event(spec)
			if ev:
				InputMap.action_add_event(action, ev)


func _make_event(spec: String) -> InputEvent:
	var parts := spec.split(":", true, 1)
	if parts[0] == "k":
		var ev := InputEventKey.new()
		var code := OS.find_keycode_from_string(parts[1])
		if code == KEY_NONE:
			push_warning("Unknown key " + parts[1])
			return null
		ev.physical_keycode = code
		return ev
	elif parts[0] == "m":
		var mb := InputEventMouseButton.new()
		mb.button_index = int(parts[1]) as MouseButton
		return mb
	return null


func key_label(action: String) -> String:
	## Human readable binding for prompts, e.g. "E", "LMB".
	if not InputMap.has_action(action):
		return "?"
	for ev in InputMap.action_get_events(action):
		if ev is InputEventKey:
			return OS.get_keycode_string(ev.physical_keycode)
		if ev is InputEventMouseButton:
			match ev.button_index:
				MOUSE_BUTTON_LEFT: return "LMB"
				MOUSE_BUTTON_RIGHT: return "RMB"
				MOUSE_BUTTON_MIDDLE: return "MMB"
				MOUSE_BUTTON_WHEEL_UP: return "Wheel"
				MOUSE_BUTTON_WHEEL_DOWN: return "Wheel"
	return "?"


func load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(PATH) != OK:
		if player_name == "":
			player_name = _default_name()
		return
	for key in _keys():
		set(key, cfg.get_value("settings", key, get(key)))
	if player_name.strip_edges() == "":
		player_name = _default_name()


func save_settings() -> void:
	var cfg := ConfigFile.new()
	for key in _keys():
		cfg.set_value("settings", key, get(key))
	cfg.save(PATH)


func _keys() -> Array:
	return ["player_name", "last_ip", "port", "mouse_sensitivity", "invert_y", "fov", "head_bob",
		"master_volume", "sfx_volume", "ambience_volume", "shadows_quality", "render_scale",
		"grass_density", "show_hints", "fullscreen", "vsync", "ssao"]


func _default_name() -> String:
	var names := ["Wren", "Moss", "Fern", "Ash", "Rook", "Sage", "Briar", "Linden", "Tamsin", "Corin"]
	return names[randi() % names.size()]


func apply() -> void:
	var bus := AudioServer.get_bus_index("Master")
	AudioServer.set_bus_volume_db(bus, linear_to_db(maxf(master_volume, 0.0001)))
	if DisplayServer.get_name() != "headless":
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN if fullscreen else DisplayServer.WINDOW_MODE_WINDOWED)
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED if vsync else DisplayServer.VSYNC_DISABLED)
	var vp := get_viewport()
	if vp:
		vp.scaling_3d_scale = clampf(render_scale, 0.5, 1.0)
	RenderingServer.directional_shadow_atlas_set_size([1024, 2048, 4096, 8192][clampi(shadows_quality, 0, 3)], true)
	Events.env_changed.emit()
