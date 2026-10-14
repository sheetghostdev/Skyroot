extends Control
## Title screen: choose / create an island, host for friends, join a friend,
## settings.  Sits over a live 3D view of the island (MenuBackdrop).

const SettingsPanel := preload("res://src/ui/settings_panel.gd")
const MenuBackdrop := preload("res://src/ui/menu_backdrop.gd")

var _right: PanelContainer
var _msg: Label
var _name_edit: LineEdit
var _saves_list: ItemList
var _new_name: LineEdit
var _host_check: CheckBox
var _port_edit: LineEdit
var _ip_edit: LineEdit
var _join_status: Label
var _saves: Array = []
var _backdrop: Node3D
var _panels: Dictionary = {}


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	theme = UITheme.get_theme()
	_backdrop = MenuBackdrop.new()
	add_child(_backdrop)
	var shade := TextureRect.new()
	shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	shade.texture = _side_gradient()
	shade.stretch_mode = TextureRect.STRETCH_SCALE
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(shade)

	var left := VBoxContainer.new()
	left.position = Vector2(84, 0)
	left.set_anchors_preset(Control.PRESET_LEFT_WIDE)
	left.offset_left = 84
	left.offset_top = 110
	left.offset_right = 520
	left.add_theme_constant_override("separation", 10)
	add_child(left)
	var title := UITheme.title_label("Skyroot", 96, UITheme.PAPER)
	left.add_child(title)
	var tag := Label.new()
	tag.text = "Everything you have was already here."
	tag.add_theme_font_override("font", load("res://assets/fonts/journal_italic.woff2") if ResourceLoader.exists("res://assets/fonts/journal_italic.woff2") else UITheme.font())
	tag.add_theme_font_size_override("font_size", 24)
	tag.add_theme_color_override("font_color", Color(UITheme.PAPER, 0.85))
	left.add_child(tag)
	var sp := Control.new()
	sp.custom_minimum_size = Vector2(0, 46)
	left.add_child(sp)
	for b in [["Play", "play"], ["Join a friend", "join"], ["Settings", "settings"], ["Quit", "quit"]]:
		var btn := UITheme.button(b[0], _on_menu.bind(b[1]), 300)
		btn.custom_minimum_size = Vector2(300, 48)
		btn.add_theme_font_size_override("font_size", 20)
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		left.add_child(btn)

	_right = PanelContainer.new()
	_right.set_anchors_preset(Control.PRESET_RIGHT_WIDE)
	_right.offset_left = -620
	_right.offset_right = -70
	_right.offset_top = 110
	_right.offset_bottom = -110
	_right.add_theme_stylebox_override("panel", UITheme.panel(UITheme.BG, 14, UITheme.LINE, 26))
	add_child(_right)

	_msg = UITheme.label("", 17, UITheme.ACCENT)
	_msg.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_msg.offset_left = 86
	_msg.offset_top = -96
	_msg.offset_right = 900
	_msg.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_msg)
	var foot := UITheme.label("v%s  ·  Co-op for 1-4 players  ·  H opens the Survival Guide in game" % ProjectSettings.get_setting("application/config/version"), 14, Color(UITheme.TEXT_DIM, 0.8))
	foot.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	foot.offset_left = 86
	foot.offset_top = -46
	foot.offset_right = 900
	add_child(foot)
	_build_play_panel()
	_build_join_panel()
	_build_settings_panel()
	_show_panel("play")


func _side_gradient() -> Texture2D:
	var g := Gradient.new()
	g.set_color(0, Color(0.05, 0.05, 0.06, 0.78))
	g.set_color(1, Color(0.05, 0.05, 0.06, 0.0))
	g.add_point(0.42, Color(0.05, 0.05, 0.06, 0.25))
	var gt := GradientTexture2D.new()
	gt.gradient = g
	gt.fill_from = Vector2(0, 0)
	gt.fill_to = Vector2(1, 0)
	gt.width = 512
	gt.height = 4
	return gt


func refresh() -> void:
	_saves = World.list_saves()
	if _saves_list:
		_saves_list.clear()
		for s in _saves:
			_saves_list.add_item("%s   —   day %d   (%s)" % [s.get("name", "?"), int(s.get("day", 1)), String(s.get("saved_at", "")).replace("T", " ")])
		if _saves.size() > 0:
			_saves_list.select(0)
		else:
			_saves_list.add_item("No islands yet - name one below and wake on it.", null, false)
			_saves_list.set_item_disabled(0, true)
	if _name_edit:
		_name_edit.text = Settings.player_name


func show_message(text: String) -> void:
	_msg.text = text


func _on_menu(which: String) -> void:
	if which == "quit":
		Game.quit()
		return
	_show_panel(which)


func _show_panel(which: String) -> void:
	for k in _panels:
		_panels[k].visible = k == which


func _section(title: String) -> VBoxContainer:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 12)
	v.add_child(UITheme.title_label(title, 34, UITheme.PAPER))
	var line := ColorRect.new()
	line.color = UITheme.LINE
	line.custom_minimum_size = Vector2(0, 1)
	v.add_child(line)
	return v


func _labeled(text: String, ctrl: Control) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 12)
	var l := UITheme.label(text, 16, UITheme.TEXT_DIM)
	l.custom_minimum_size = Vector2(120, 0)
	h.add_child(l)
	ctrl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(ctrl)
	return h


func _build_play_panel() -> void:
	var v := _section("Your islands")
	_name_edit = LineEdit.new()
	_name_edit.text = Settings.player_name
	_name_edit.max_length = 18
	_name_edit.placeholder_text = "Your name"
	_name_edit.text_changed.connect(func(t): Settings.player_name = t.strip_edges(); Settings.save_settings())
	v.add_child(_labeled("Your name", _name_edit))
	_saves_list = ItemList.new()
	_saves_list.custom_minimum_size = Vector2(0, 180)
	_saves_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_saves_list.item_activated.connect(func(_i): _start_selected())
	v.add_child(_saves_list)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.add_child(UITheme.button("Continue selected island", _start_selected, 260))
	v.add_child(row)
	var line := ColorRect.new()
	line.color = UITheme.LINE
	line.custom_minimum_size = Vector2(0, 1)
	v.add_child(line)
	_new_name = LineEdit.new()
	_new_name.placeholder_text = "Name your island"
	_new_name.text = "Skyroot %d" % (randi() % 900 + 100)
	_new_name.max_length = 28
	v.add_child(_labeled("New island", _new_name))
	var row2 := HBoxContainer.new()
	row2.add_theme_constant_override("separation", 10)
	row2.add_child(UITheme.button("Wake on a new island", _start_new, 260))
	v.add_child(row2)
	var line2 := ColorRect.new()
	line2.color = UITheme.LINE
	line2.custom_minimum_size = Vector2(0, 1)
	v.add_child(line2)
	_host_check = UITheme.checkbox("Open to friends (host co-op over LAN or direct IP)", true, func(_on): pass)
	v.add_child(_host_check)
	_port_edit = LineEdit.new()
	_port_edit.text = str(Settings.port)
	_port_edit.max_length = 5
	v.add_child(_labeled("Port", _port_edit))
	var hint := UITheme.label("Friends join with your IP address and this port. Up to four players.", 14, UITheme.TEXT_DIM)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(hint)
	_right.add_child(v)
	_panels["play"] = v


func _build_join_panel() -> void:
	var v := _section("Join a friend")
	var name2 := LineEdit.new()
	name2.text = Settings.player_name
	name2.max_length = 18
	name2.text_changed.connect(func(t): Settings.player_name = t.strip_edges(); Settings.save_settings(); _name_edit.text = t)
	v.add_child(_labeled("Your name", name2))
	_ip_edit = LineEdit.new()
	_ip_edit.text = Settings.last_ip
	_ip_edit.placeholder_text = "Host IP address, e.g. 192.168.1.20"
	v.add_child(_labeled("Host address", _ip_edit))
	var port2 := LineEdit.new()
	port2.text = str(Settings.port)
	port2.max_length = 5
	port2.text_changed.connect(func(t): if t.is_valid_int(): Settings.port = int(t))
	v.add_child(_labeled("Port", port2))
	v.add_child(UITheme.button("Join island", _join, 220))
	_join_status = UITheme.label("", 15, UITheme.TEXT_DIM)
	_join_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(_join_status)
	var help := UITheme.label("The host chooses Play → 'Open to friends'. On the same network use the host's local IP; over the internet the host must forward the port.", 14, UITheme.TEXT_DIM)
	help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(help)
	v.visible = false
	_right.add_child(v)
	_panels["join"] = v


func _build_settings_panel() -> void:
	var v := _section("Settings")
	var sp := SettingsPanel.new()
	sp.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(sp)
	v.visible = false
	_right.add_child(v)
	_panels["settings"] = v


func _start_selected() -> void:
	var sel := _saves_list.get_selected_items()
	if sel.is_empty():
		show_message("Select an island first - or wake on a new one.")
		return
	_launch(String(_saves[sel[0]].get("name", "")), false)


func _start_new() -> void:
	var n := _new_name.text.strip_edges()
	if n == "":
		show_message("Give your island a name.")
		return
	if FileAccess.file_exists(World.save_path(n)):
		show_message("An island called '%s' already exists. Choose another name or continue it." % n)
		return
	_launch(n, true)


func _launch(world_name: String, is_new: bool) -> void:
	if not _port_edit.text.is_valid_int():
		show_message("Port must be a number.")
		return
	Settings.port = int(_port_edit.text)
	Settings.save_settings()
	show_message("Waking up...")
	await get_tree().process_frame
	var err := Game.start_world("host" if _host_check.button_pressed else "solo", world_name, is_new, Settings.port)
	if err != "":
		show_message(err)


func _join() -> void:
	var ip := _ip_edit.text.strip_edges()
	if ip == "":
		_join_status.text = "Enter the host's IP address."
		return
	Settings.last_ip = ip
	Settings.save_settings()
	_join_status.text = "Connecting to %s:%d ..." % [ip, Settings.port]
	var err := Game.join(ip, Settings.port)
	if err != "":
		_join_status.text = err
