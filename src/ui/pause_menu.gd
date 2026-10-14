extends Control
## Pause / island menu (Esc).  The world keeps running - it's co-op.

const SettingsPanel := preload("res://src/ui/settings_panel.gd")

var hud: Node
var settings: Control
var info: Label


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var dim := ColorRect.new()
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0, 0, 0, 0.45)
	add_child(dim)
	var pc := PanelContainer.new()
	pc.set_anchors_preset(Control.PRESET_CENTER)
	pc.offset_left = -330
	pc.offset_right = 330
	pc.offset_top = -300
	pc.offset_bottom = 300
	pc.add_theme_stylebox_override("panel", UITheme.panel(UITheme.BG_SOLID, 14, UITheme.LINE, 26))
	add_child(pc)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 10)
	pc.add_child(v)
	v.add_child(UITheme.title_label(World.world_name, 32))
	var sub := UITheme.label("Day %d  ·  %d islander%s" % [World.day(), Net.players.size(), "" if Net.players.size() == 1 else "s"], 15, UITheme.TEXT_DIM)
	v.add_child(sub)
	v.add_child(UITheme.button("Resume", func(): hud.close_panel(), 300))
	if Net.is_host():
		v.add_child(UITheme.button("Save the island now", func(): Game.save(), 300))
	var sb := UITheme.button("Settings", _toggle_settings, 300)
	v.add_child(sb)
	settings = SettingsPanel.new()
	settings.visible = false
	settings.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(settings)
	info = UITheme.label(_invite_text(), 14, UITheme.TEXT_DIM)
	info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(info)
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(spacer)
	v.add_child(UITheme.button("Leave the island (main menu)", func(): Game.leave(), 300))
	v.add_child(UITheme.button("Quit game", func(): Game.quit(), 300))


func _toggle_settings() -> void:
	settings.visible = not settings.visible
	info.visible = not settings.visible


func _invite_text() -> String:
	if not Net.is_host():
		return "You are visiting %s's island." % Net.player_name(1)
	if not Net.is_online():
		return "Playing alone. To play with friends, choose 'Open to friends' when starting the island from the main menu."
	var addrs: PackedStringArray = []
	for a in IP.get_local_addresses():
		if a.count(".") == 3 and not a.begins_with("127.") and not a.begins_with("169.254"):
			addrs.append(a)
	return "Friends can join with:  %s   port %d\n(on the same network; over the internet, forward the port)" % [", ".join(addrs) if addrs.size() > 0 else "your IP address", Settings.port]
