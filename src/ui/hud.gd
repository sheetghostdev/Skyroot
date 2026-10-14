class_name HUD
extends CanvasLayer
## Everything on screen while playing: the crosshair with what you look at and
## what the mouse buttons will do, the hotbar, the survival bars, the time, the
## current goal, toasts and one-time hints, the death screen, chat, and the
## panels (inventory, handbook, recipe chooser, pause).

const PauseMenu := preload("res://src/ui/pause_menu.gd")

var root: Control
var reticle: Reticle
var ring: Control
var prompt_box: VBoxContainer
var target_label: Label
var prompt_lines: Array[Label] = []
var hotbar_slots: Array[SlotView] = []
var held_label: Label
var bars: Dictionary = {}
var status_label: Label
var clock_label: Label
var goal_panel: PanelContainer
var goal_title: Label
var goal_text: Label
var toast_box: VBoxContainer
var hint_panel: PanelContainer
var hint_label: Label
var death: Control
var death_label: Label
var chat_box: VBoxContainer
var chat_edit: LineEdit
var panel: Control = null
var panel_name := ""
var _held_t := 0.0
var _hint_t := 0.0
var _hint_id := ""
var _hint_queue: Array = []
var _hud_hidden := false


func _ready() -> void:
	layer = 5
	root = Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.theme = UITheme.get_theme()
	add_child(root)
	_build_center()
	_build_hotbar()
	_build_corners()
	_build_overlays()
	Events.inventory_changed.connect(_refresh_hotbar)
	Events.hotbar_selected.connect(func(_i): _refresh_hotbar(); _show_held_name())
	Events.stats_changed.connect(_refresh_stats)
	Events.toast.connect(toast)
	Events.hint.connect(_on_hint)
	Events.target_changed.connect(_on_target)
	Events.chat.connect(_on_chat)
	Events.open_chooser.connect(_on_chooser)
	Events.goal_progress.connect(_refresh_goal)
	_refresh_hotbar()
	_refresh_stats()
	_refresh_goal()


func player() -> LocalPlayer:
	return get_tree().get_first_node_in_group("local_player") as LocalPlayer


# ---------------------------------------------------------------------------
# Building
# ---------------------------------------------------------------------------

func _outlined(l: Label, size := 4) -> Label:
	l.add_theme_constant_override("outline_size", size)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.75))
	return l


func _build_center() -> void:
	reticle = Reticle.new()
	reticle.set_anchors_preset(Control.PRESET_CENTER)
	reticle.offset_left = -12
	reticle.offset_right = 12
	reticle.offset_top = -12
	reticle.offset_bottom = 12
	reticle.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(reticle)
	ring = Control.new()
	ring.set_anchors_preset(Control.PRESET_CENTER)
	ring.offset_left = -22
	ring.offset_right = 22
	ring.offset_top = -22
	ring.offset_bottom = 22
	ring.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ring.draw.connect(_draw_ring)
	root.add_child(ring)
	prompt_box = VBoxContainer.new()
	prompt_box.set_anchors_preset(Control.PRESET_CENTER)
	prompt_box.offset_left = -260
	prompt_box.offset_right = 260
	prompt_box.offset_top = 26
	prompt_box.offset_bottom = 160
	prompt_box.alignment = BoxContainer.ALIGNMENT_BEGIN
	prompt_box.add_theme_constant_override("separation", 1)
	prompt_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(prompt_box)
	target_label = _outlined(UITheme.label("", 16, UITheme.PAPER, true))
	target_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	prompt_box.add_child(target_label)
	for i in 3:
		var l := _outlined(UITheme.label("", 14, Color(UITheme.PAPER, 0.92)))
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		prompt_box.add_child(l)
		prompt_lines.append(l)


func _build_hotbar() -> void:
	var box := HBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	box.offset_left = -9 * 31
	box.offset_right = 9 * 31
	box.offset_top = -74
	box.offset_bottom = -12
	box.add_theme_constant_override("separation", 4)
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(box)
	for i in Inventory.HOTBAR:
		var s := SlotView.new()
		s.index = i
		s.compact = true
		s.slot_size = 58
		s.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.add_child(s)
		hotbar_slots.append(s)
	held_label = _outlined(UITheme.label("", 16, UITheme.PAPER, true))
	held_label.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	held_label.offset_left = -300
	held_label.offset_right = 300
	held_label.offset_top = -170
	held_label.offset_bottom = -146
	held_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(held_label)
	# survival bars, two either side above the hotbar
	var left := VBoxContainer.new()
	left.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	left.offset_left = -9 * 31
	left.offset_right = -9 * 31 + 260
	left.offset_top = -128
	left.offset_bottom = -80
	left.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(left)
	var right := VBoxContainer.new()
	right.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	right.offset_left = 9 * 31 - 260
	right.offset_right = 9 * 31
	right.offset_top = -128
	right.offset_bottom = -80
	right.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(right)
	for spec in [["health", "Health", Color(0.86, 0.32, 0.28), left], ["hunger", "Food", Color(0.85, 0.6, 0.28), left],
			["thirst", "Water", UITheme.WATER, right], ["warmth", "Warmth", Color(0.95, 0.75, 0.45), right]]:
		var b := VitalBar.new()
		b.label = spec[1]
		b.color = spec[2]
		b.custom_minimum_size = Vector2(250, 22)
		b.mouse_filter = Control.MOUSE_FILTER_IGNORE
		(spec[3] as Control).add_child(b)
		bars[spec[0]] = b
	status_label = _outlined(UITheme.label("", 14, Color(UITheme.PAPER, 0.9)))
	status_label.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	status_label.offset_left = -300
	status_label.offset_right = 300
	status_label.offset_top = -148
	status_label.offset_bottom = -128
	status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(status_label)


func _build_corners() -> void:
	clock_label = _outlined(UITheme.label("", 15, UITheme.PAPER, true))
	clock_label.position = Vector2(18, 14)
	root.add_child(clock_label)
	goal_panel = PanelContainer.new()
	goal_panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	goal_panel.offset_left = -360
	goal_panel.offset_right = -16
	goal_panel.offset_top = 14
	goal_panel.add_theme_stylebox_override("panel", UITheme.panel(Color(0.08, 0.075, 0.065, 0.72), 10, UITheme.LINE, 12))
	goal_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(goal_panel)
	var gv := VBoxContainer.new()
	gv.add_theme_constant_override("separation", 3)
	goal_panel.add_child(gv)
	gv.add_child(UITheme.label("GOAL", 11, UITheme.ACCENT, true))
	goal_title = UITheme.label("", 16, UITheme.PAPER, true)
	goal_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	gv.add_child(goal_title)
	goal_text = UITheme.label("", 13, UITheme.TEXT_DIM)
	goal_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	gv.add_child(goal_text)
	var hint := UITheme.label("H  handbook  ·  E  inventory & crafting", 11, Color(UITheme.TEXT_DIM, 0.8))
	gv.add_child(hint)
	toast_box = VBoxContainer.new()
	toast_box.set_anchors_preset(Control.PRESET_CENTER_TOP)
	toast_box.offset_left = -330
	toast_box.offset_right = 330
	toast_box.offset_top = 70
	toast_box.add_theme_constant_override("separation", 6)
	toast_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(toast_box)
	hint_panel = PanelContainer.new()
	hint_panel.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	hint_panel.offset_left = -390
	hint_panel.offset_right = -16
	hint_panel.offset_top = -230
	hint_panel.offset_bottom = -96
	hint_panel.add_theme_stylebox_override("panel", UITheme.panel(Color(0.12, 0.1, 0.07, 0.9), 10, Color(UITheme.ACCENT, 0.5), 14))
	hint_panel.visible = false
	hint_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(hint_panel)
	hint_label = UITheme.label("", 14, UITheme.PAPER)
	hint_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint_panel.add_child(hint_label)
	chat_box = VBoxContainer.new()
	chat_box.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	chat_box.offset_left = 16
	chat_box.offset_right = 520
	chat_box.offset_top = -300
	chat_box.offset_bottom = -110
	chat_box.alignment = BoxContainer.ALIGNMENT_END
	chat_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(chat_box)
	chat_edit = LineEdit.new()
	chat_edit.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	chat_edit.offset_left = 16
	chat_edit.offset_right = 520
	chat_edit.offset_top = -104
	chat_edit.offset_bottom = -72
	chat_edit.visible = false
	chat_edit.placeholder_text = "Say something (Enter)"
	chat_edit.text_submitted.connect(_send_chat)
	root.add_child(chat_edit)


func _build_overlays() -> void:
	death = Control.new()
	death.set_anchors_preset(Control.PRESET_FULL_RECT)
	death.visible = false
	root.add_child(death)
	var dim := ColorRect.new()
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0.12, 0.02, 0.02, 0.62)
	death.add_child(dim)
	var v := VBoxContainer.new()
	v.set_anchors_preset(Control.PRESET_CENTER)
	v.offset_left = -300
	v.offset_right = 300
	v.offset_top = -110
	v.offset_bottom = 110
	v.alignment = BoxContainer.ALIGNMENT_CENTER
	v.add_theme_constant_override("separation", 14)
	death.add_child(v)
	var t := UITheme.title_label("You died", 54)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(t)
	death_label = UITheme.label("", 17, UITheme.PAPER)
	death_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	death_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(death_label)
	var b := UITheme.button("Wake up", func(): World.request("respawn"), 220)
	b.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	v.add_child(b)


# ---------------------------------------------------------------------------
# Live updates
# ---------------------------------------------------------------------------

func _process(delta: float) -> void:
	var p := player()
	ring.queue_redraw()
	_held_t -= delta
	if _held_t <= 0.0:
		held_label.modulate.a = move_toward(held_label.modulate.a, 0.0, delta * 2.0)
	if hint_panel.visible:
		_hint_t -= delta
		if _hint_t <= 0.0:
			hint_panel.visible = false
			_next_hint()
	var h := World.hour_of_day()
	var weather := ""
	if float(World.env.get("rain", 0.0)) > 0.25:
		weather = "  ·  rain"
	elif float(World.env.get("fog", 0.0)) > 0.2:
		weather = "  ·  mist"
	clock_label.text = "Day %d  ·  %02d:%02d%s" % [maxi(1, World.day()), int(h), int(fmod(h, 1.0) * 60.0), weather]
	if p:
		var alive := bool(World.my_stats.get("alive", true))
		if not alive and not death.visible:
			death.visible = true
			death_label.text = Survival._death_text(String(World.my_stats.get("death_cause", "")))
			close_panel()
			p.set_mode("dead")
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		elif alive and death.visible:
			death.visible = false
			p.set_mode("play")
	reticle.active = not (p and p.interactor.lmb_rule.is_empty() and p.interactor.rmb_rule.is_empty())


func _draw_ring() -> void:
	var p := player()
	if p == null:
		return
	var f := p.interactor.hold_progress()
	if f < 0.0:
		f = p.interactor.break_progress()
	if f <= 0.0:
		return
	var c := ring.size * 0.5
	ring.draw_arc(c, 15.0, 0, TAU, 40, Color(0, 0, 0, 0.45), 5.0, true)
	ring.draw_arc(c, 15.0, -PI * 0.5, -PI * 0.5 + TAU * f, 40, Color(UITheme.PAPER, 0.95), 3.0, true)


func _on_target(t: Dictionary) -> void:
	var p := player()
	if p == null:
		return
	target_label.text = _target_name(t)
	var lines: Array = []
	var l: Dictionary = p.interactor.lmb_rule
	var r: Dictionary = p.interactor.rmb_rule
	if not l.is_empty() and String(l.get("text", "")) != "":
		lines.append(("Left: " if l.get("kind", "") != "none" else "") + String(l["text"]))
	if not r.is_empty() and String(r.get("text", "")) != "":
		var pre := "Hold right: " if float(r.get("hold", 0.0)) > 0.5 else "Right: "
		if r.get("kind", "") == "none":
			pre = ""
		var txt := String(r["text"])
		if r.get("kind", "") == "clay_add":
			txt += "   (F: brush %s)" % Interactor.BRUSHES[p.interactor.brush]
		lines.append(pre + txt)
	if l.get("kind", "") == "chip":
		lines[0] = "Left: chip off %s   (F: %s)" % ["a cell" if p.interactor.knap_brush == 0 else "a flake", Interactor.KNAP_BRUSHES[(p.interactor.knap_brush + 1) % Interactor.KNAP_BRUSHES.size()]]
	var sh := UseRules.sneak_hint(t, p.held_stack())
	if sh != "" and not Input.is_action_pressed("sneak"):
		lines.append(sh)
	if String(t.get("type", "")) == "be" and String(t["be"]["t"]) in ["knap", "clay"] and not p.sitting and lines.size() < prompt_lines.size():
		lines.append("%s: sit down for a closer look" % Settings.key_label("sit"))
	for i in prompt_lines.size():
		prompt_lines[i].text = lines[i] if i < lines.size() else ""


func _target_name(t: Dictionary) -> String:
	match String(t.get("type", "")):
		"block":
			var id: int = t["id"]
			var nm := Blocks.label(id)
			if Blocks.def(id).has("crop"):
				var st := World.block_meta(t["cell"])
				nm += " (ripe)" if st >= 3 else " (growing)"
			elif Blocks.name_of(id) == "berry_bush" and World.block_meta(t["cell"]) == 1:
				nm += " (ripe)"
			elif Blocks.name_of(id) == "farmland":
				nm += " (moist)" if World.block_meta(t["cell"]) == 1 else " (dry)"
			return nm
		"satchel":
			return "Bag of things"
		"be":
			var be: Dictionary = t["be"]
			var d: Dictionary = be["d"]
			match String(be["t"]):
				"firepit":
					var bits: Array = []
					if bool(d.get("lit", false)):
						bits.append("burning")
					elif bool(d.get("ash", false)) and int(d.get("sticks", 0)) == 0:
						bits.append("ashes")
					if int(d.get("tinder", 0)) > 0:
						bits.append("tinder")
					if int(d.get("sticks", 0)) > 0:
						bits.append("%d stick%s" % [int(d["sticks"]), "" if int(d["sticks"]) == 1 else "s"])
					if int(d.get("logs", 0)) > 0:
						bits.append("%d firewood" % int(d["logs"]))
					return "Fire pit" + (" (" + ", ".join(bits) + ")" if not bits.is_empty() else "")
				"kiln":
					if bool(d.get("lit", false)):
						return "Pit kiln (firing, %d%%)" % int(clampf(float(d.get("t", 0.0)) / FireActs.KILN_H, 0.0, 1.0) * 100.0)
					return "Pit kiln (%d/%d dry grass, %d/%d sticks)" % [int(d["grass"]), FireActs.KILN_GRASS, int(d["sticks"]), FireActs.KILN_STICKS]
				"knap":
					var r := String(d.get("r", ""))
					var nm2 := ("Flint" if String(d.get("mat", "")) == "flint" else "Stone") + " for knapping"
					if r != "":
						var left := CraftActs.edge_cells(d["cells"], ItemDB.knapping[r]["mask"])
						nm2 = "%s: %s (%d red cells to chip)" % [nm2, String(ItemDB.knapping[r]["label"]).to_lower(), left]
					return nm2
				"clay":
					var r2 := String(d.get("r", ""))
					if r2 == "":
						return "Clay"
					var layers: Array = ItemDB.clayforming[r2]["layers"]
					return "Clay: %s (layer %d of %d, %d left in this lump)" % [String(ItemDB.clayforming[r2]["label"]).to_lower(),
						mini(int(d["layer"]) + 1, layers.size()), layers.size(), int(d["budget"])]
				"ground":
					var items: Array = d.get("items", [])
					var names: Array = []
					for s in items:
						names.append(("%d " % int(s["n"]) if int(s["n"]) > 1 else "") + ItemDB.label(String(s["i"]), s.get("d", {})).to_lower())
					return ", ".join(names).capitalize() if names.size() == 1 else ", ".join(names)
				"jar":
					return "Storage jar"
	return ""


func _refresh_hotbar() -> void:
	var p := player()
	for i in hotbar_slots.size():
		hotbar_slots[i].set_stack(World.my_inventory.get_slot(i))
		hotbar_slots[i].selected = p != null and p.hotbar == i
		hotbar_slots[i].queue_redraw()
	_last_target_refresh()


func _last_target_refresh() -> void:
	var p := player()
	if p:
		p.interactor._last_key = ""


func _show_held_name() -> void:
	var p := player()
	if p == null:
		return
	var s := p.held_stack()
	held_label.text = ItemDB.label(String(s["i"]), s.get("d", {})) if not s.is_empty() else ""
	held_label.modulate.a = 1.0
	_held_t = 1.6


func _refresh_stats() -> void:
	var st := World.my_stats
	for k in bars:
		(bars[k] as VitalBar).value = float(st.get(k, 1.0))
	var temp := float(st.get("temp", 15.0))
	var warm := float(st.get("warmth", 1.0))
	var txt := ""
	if bool(st.get("near_fire", false)):
		txt = "Warm by the fire"
	elif warm < 0.35:
		txt = "Freezing: get to a fire or under cover" if warm < 0.15 else "Cold (%d °C)" % int(round(temp))
	elif temp < 8.0:
		txt = "Chilly (%d °C)" % int(round(temp))
	status_label.text = txt


func _refresh_goal() -> void:
	var g := Guide.current_goal()
	goal_panel.visible = not g.is_empty() and not _hud_hidden
	if g.is_empty():
		return
	goal_title.text = String(g.get("title", ""))
	goal_text.text = String(g.get("text", ""))


func toast(text: String, kind: String = "info") -> void:
	var pc := PanelContainer.new()
	var col := Color(0.08, 0.075, 0.065, 0.85)
	var border := UITheme.LINE
	match kind:
		"warn": border = Color(UITheme.ACCENT, 0.7)
		"error", "death": border = Color(UITheme.DANGER, 0.8)
		"goal": border = Color(UITheme.ACCENT_2, 0.9)
	pc.add_theme_stylebox_override("panel", UITheme.panel(col, 8, border, 10))
	pc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var l := UITheme.label(text, 15, UITheme.PAPER)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	pc.add_child(l)
	toast_box.add_child(pc)
	_trim(toast_box, 4)
	var tw := pc.create_tween()
	tw.tween_interval(3.8 if kind != "goal" else 5.0)
	tw.tween_property(pc, "modulate:a", 0.0, 0.6)
	tw.tween_callback(pc.queue_free)
	if kind == "goal":
		Sfx.ui("discovery", -6.0)
	elif kind == "warn" or kind == "error":
		Sfx.ui("ui_error", -12.0)


func _trim(box: Control, keep: int) -> void:
	## Drop the oldest lines (removed at once: queue_free alone would leave them counted).
	while box.get_child_count() > keep:
		var old := box.get_child(0)
		box.remove_child(old)
		old.queue_free()


func _on_hint(hint_id: String) -> void:
	if not Guide.should_show(hint_id) or _hint_queue.has(hint_id) or _hint_id == hint_id:
		return
	_hint_queue.append(hint_id)
	if not hint_panel.visible:
		_next_hint()


func _next_hint() -> void:
	if _hint_queue.is_empty():
		_hint_id = ""
		return
	_hint_id = _hint_queue.pop_front()
	var h: Dictionary = Guide.hints.get(_hint_id, {})
	hint_label.text = String(h.get("text", ""))
	hint_panel.visible = true
	_hint_t = clampf(hint_label.text.length() * 0.07, 7.0, 16.0)
	Guide.mark_seen(_hint_id)
	Sfx.ui("hint", -8.0)


func _on_chat(from: String, text: String) -> void:
	var l := _outlined(UITheme.label(("%s: %s" % [from, text]) if from != "" else text, 14, UITheme.PAPER if from != "" else UITheme.TEXT_DIM))
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	chat_box.add_child(l)
	_trim(chat_box, 7)
	var tw := l.create_tween()
	tw.tween_interval(12.0)
	tw.tween_property(l, "modulate:a", 0.0, 1.0)
	tw.tween_callback(l.queue_free)


func _send_chat(text: String) -> void:
	Net.send_chat(text)
	chat_edit.text = ""
	chat_edit.visible = false
	var p := player()
	if p:
		p.set_mode("play")


# ---------------------------------------------------------------------------
# Panels
# ---------------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	var p := player()
	if p == null:
		return
	if chat_edit.visible:
		if event.is_action_pressed("pause"):
			chat_edit.visible = false
			p.set_mode("play")
			get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("pause"):
		if panel:
			close_panel()
		elif p.mode == "play":
			open_panel("pause")
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("inventory"):
		if panel_name == "inventory" or panel_name == "jar":
			close_panel()
		elif p.mode == "play":
			open_panel("inventory")
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("guide"):
		if panel_name == "handbook":
			close_panel()
		elif p.mode == "play":
			open_panel("handbook")
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("chat") and p.mode == "play" and not panel:
		chat_edit.visible = true
		chat_edit.grab_focus.call_deferred()
		p.set_mode("ui")
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("toggle_hud"):
		_hud_hidden = not _hud_hidden
		for c in root.get_children():
			if c != death and c != panel:
				(c as CanvasItem).visible = not _hud_hidden
		_refresh_goal()
	elif event.is_action_pressed("quick_save") and Net.is_host():
		Game.save()


func open_panel(nm: String, arg: Variant = null) -> void:
	close_panel()
	var p := player()
	match nm:
		"pause":
			var pm := PauseMenu.new()
			pm.hud = self
			panel = pm
		"inventory":
			panel = InventoryUI.new()
		"jar":
			var iu := InventoryUI.new()
			iu.jar_cell = arg
			panel = iu
		"handbook":
			panel = HandbookUI.new()
		"chooser":
			var ch := ChooserUI.new()
			ch.kind = String(arg[0])
			ch.cell = arg[1]
			panel = ch
	if panel == null:
		return
	panel_name = nm
	panel.set_meta("hud", self)
	root.add_child(panel)
	if p:
		p.set_mode("ui")
	Sfx.ui("ui_open", -10.0)


func close_panel() -> void:
	if panel == null:
		return
	if panel_name == "inventory" or panel_name == "jar":
		World.request("inv_close")
	panel.queue_free()
	panel = null
	panel_name = ""
	var p := player()
	if p and p.mode == "ui":
		p.set_mode("play")
	Sfx.ui("ui_close", -12.0)


func _on_chooser(kind: String, c: Vector3i) -> void:
	if kind == "jar":
		open_panel("jar", c)
	else:
		open_panel("chooser", [kind, c])
