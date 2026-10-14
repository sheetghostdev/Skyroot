class_name HUD
extends CanvasLayer
## Minimal in-world interface: reticle, contextual prompts, hotbar, vitals,
## clock, toasts, contextual hints, chat and overlays.  Owns the full-screen
## panels (inventory, guide, build menu, pause) and the mouse mode while open.

const InventoryUI := preload("res://src/ui/inventory_ui.gd")
const PauseMenu := preload("res://src/ui/pause_menu.gd")

var root: Control
var icons: IconCache
var reticle: Control
var prompts: VBoxContainer
var hotbar: HBoxContainer
var hotbar_slots: Array = []
var held_name: Label
var vitals: Dictionary = {}
var clock: Label
var weather_lbl: Label
var toasts: VBoxContainer
var hint_card: PanelContainer
var hint_title: Label
var hint_text: Label
var hint_id := ""
var chat_box: VBoxContainer
var chat_input: LineEdit
var vignette: ColorRect
var death_panel: Control
var death_text: Label
var fade: ColorRect
var work_hint: Label
var tracker: VBoxContainer
var panel: Control = null
var panel_name := ""
var _target: Dictionary = {}
var _held_t := 0.0
var _hp_last := 1.0
var _hidden := false
var _hint_t := 0.0
var _hint_queue: Array = []


func _ready() -> void:
	layer = 10
	root = Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.theme = UITheme.get_theme()
	add_child(root)
	icons = IconCache.new()
	icons.name = "Icons"
	add_child(icons)
	icons.icon_ready.connect(func(_k): _refresh_hotbar())
	_build_overlays()
	_build_reticle()
	_build_hotbar()
	_build_vitals()
	_build_clock()
	_build_toasts()
	_build_hint()
	_build_chat()
	_build_tracker()
	Events.interaction_target_changed.connect(_on_target)
	Events.inventory_changed.connect(_refresh_hotbar)
	Events.hotbar_selected.connect(func(_i): _refresh_hotbar(); _show_held_name())
	Events.stats_changed.connect(_refresh_vitals)
	Events.toast.connect(toast)
	Events.hint.connect(_on_hint)
	Events.chat.connect(_on_chat)
	Events.player_died.connect(func(_r): _show_death("You fell into the abyss. Everything you carried is gone."))
	Events.ui_mode_changed.connect(_on_mode)
	_refresh_hotbar()
	_refresh_vitals()


func lp() -> LocalPlayer:
	return Game.game_world.local_player() if Game.game_world else null


# ---------------------------------------------------------------------------
# Construction
# ---------------------------------------------------------------------------

func _build_overlays() -> void:
	vignette = ColorRect.new()
	vignette.set_anchors_preset(Control.PRESET_FULL_RECT)
	vignette.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sh := Shader.new()
	sh.code = """shader_type canvas_item;
uniform vec4 col : source_color = vec4(0.6, 0.0, 0.0, 1.0);
uniform float amount = 0.0;
void fragment() {
	vec2 uv = UV - 0.5;
	float v = smoothstep(0.25, 0.75, length(uv * vec2(1.4, 1.0)));
	COLOR = vec4(col.rgb, v * amount);
}"""
	var m := ShaderMaterial.new()
	m.shader = sh
	m.set_shader_parameter("amount", 0.0)
	m.set_shader_parameter("col", Color(0.6, 0.0, 0.0))
	vignette.material = m
	root.add_child(vignette)
	fade = ColorRect.new()
	fade.set_anchors_preset(Control.PRESET_FULL_RECT)
	fade.color = Color(0, 0, 0, 0)
	fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(fade)
	work_hint = UITheme.label("", 16, Color(1, 1, 1, 0.92))
	work_hint.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	work_hint.offset_top = -170
	work_hint.offset_bottom = -140
	work_hint.offset_left = -500
	work_hint.offset_right = 500
	work_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	work_hint.add_theme_constant_override("outline_size", 6)
	work_hint.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.6))
	root.add_child(work_hint)


func _build_reticle() -> void:
	reticle = Reticle.new()
	reticle.set_anchors_preset(Control.PRESET_CENTER)
	reticle.custom_minimum_size = Vector2(24, 24)
	reticle.position = Vector2(-12, -12)
	reticle.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(reticle)
	prompts = VBoxContainer.new()
	prompts.set_anchors_preset(Control.PRESET_CENTER)
	prompts.offset_left = 26
	prompts.offset_top = 14
	prompts.offset_right = 420
	prompts.add_theme_constant_override("separation", 4)
	prompts.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(prompts)


func _build_hotbar() -> void:
	var holder := VBoxContainer.new()
	holder.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	holder.offset_top = -112
	holder.offset_bottom = -18
	holder.offset_left = -300
	holder.offset_right = 300
	holder.alignment = BoxContainer.ALIGNMENT_END
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(holder)
	held_name = UITheme.label("", 16, UITheme.PAPER, true)
	held_name.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	held_name.add_theme_constant_override("outline_size", 5)
	held_name.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.55))
	holder.add_child(held_name)
	hotbar = HBoxContainer.new()
	hotbar.alignment = BoxContainer.ALIGNMENT_CENTER
	hotbar.add_theme_constant_override("separation", 5)
	hotbar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.add_child(hotbar)
	for i in Inventory.HOTBAR:
		var s := SlotView.new()
		s.index = i
		s.icons = icons
		s.compact = true
		s.mouse_filter = Control.MOUSE_FILTER_IGNORE
		hotbar.add_child(s)
		hotbar_slots.append(s)


func _build_vitals() -> void:
	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	box.offset_left = 26
	box.offset_top = -150
	box.offset_bottom = -24
	box.offset_right = 250
	box.alignment = BoxContainer.ALIGNMENT_END
	box.add_theme_constant_override("separation", 5)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(box)
	for spec in [["health", "Health", Color(0.85, 0.32, 0.3)], ["hunger", "Food", Color(0.87, 0.62, 0.3)],
			["thirst", "Water", UITheme.WATER], ["stamina", "Stamina", Color(0.72, 0.8, 0.42)], ["warmth", "Warmth", Color(0.95, 0.6, 0.35)]]:
		var bar := VitalBar.new()
		bar.label = spec[1]
		bar.color = spec[2]
		bar.custom_minimum_size = Vector2(210, 18)
		bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.add_child(bar)
		vitals[spec[0]] = bar


func _build_clock() -> void:
	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	box.offset_left = -300
	box.offset_right = -24
	box.offset_top = 18
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(box)
	clock = UITheme.label("", 18, UITheme.PAPER, true)
	clock.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	clock.add_theme_constant_override("outline_size", 5)
	clock.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.5))
	box.add_child(clock)
	weather_lbl = UITheme.label("", 14, Color(UITheme.PAPER, 0.85))
	weather_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	weather_lbl.add_theme_constant_override("outline_size", 4)
	weather_lbl.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.5))
	box.add_child(weather_lbl)


func _build_toasts() -> void:
	toasts = VBoxContainer.new()
	toasts.set_anchors_preset(Control.PRESET_CENTER_TOP)
	toasts.offset_left = -360
	toasts.offset_right = 360
	toasts.offset_top = 22
	toasts.add_theme_constant_override("separation", 6)
	toasts.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(toasts)


func _build_hint() -> void:
	hint_card = PanelContainer.new()
	hint_card.set_anchors_preset(Control.PRESET_CENTER_LEFT)
	hint_card.offset_left = 24
	hint_card.offset_right = 360
	hint_card.offset_top = -120
	hint_card.add_theme_stylebox_override("panel", UITheme.panel(Color(0.09, 0.085, 0.075, 0.82), 10, Color(UITheme.ACCENT, 0.35), 14))
	hint_card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hint_card.visible = false
	root.add_child(hint_card)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	hint_card.add_child(v)
	hint_title = UITheme.label("", 16, UITheme.ACCENT, true)
	v.add_child(hint_title)
	hint_text = UITheme.label("", 15, UITheme.TEXT)
	hint_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint_text.custom_minimum_size = Vector2(300, 0)
	v.add_child(hint_text)
	var keys := UITheme.label("H  open in guide      X  got it, don't show again", 13, UITheme.TEXT_DIM)
	v.add_child(keys)


func _build_chat() -> void:
	chat_box = VBoxContainer.new()
	chat_box.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	chat_box.offset_left = 26
	chat_box.offset_top = -330
	chat_box.offset_bottom = -170
	chat_box.offset_right = 520
	chat_box.alignment = BoxContainer.ALIGNMENT_END
	chat_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(chat_box)
	chat_input = LineEdit.new()
	chat_input.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	chat_input.offset_left = 26
	chat_input.offset_top = -166
	chat_input.offset_bottom = -134
	chat_input.offset_right = 520
	chat_input.placeholder_text = "Say something... (Enter to send, Esc to cancel)"
	chat_input.visible = false
	chat_input.text_submitted.connect(_send_chat)
	root.add_child(chat_input)


func _build_tracker() -> void:
	tracker = GuideTracker.new()
	tracker.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	tracker.offset_left = -380
	tracker.offset_right = -24
	tracker.offset_top = 92
	root.add_child(tracker)


# ---------------------------------------------------------------------------
# Updates
# ---------------------------------------------------------------------------

func _on_target(info: Dictionary) -> void:
	_target = info
	for c in prompts.get_children():
		c.queue_free()
	var opts: Dictionary = info.get("options", {})
	var any := false
	if opts.has("info"):
		# what you're looking at, on a dark card so it reads against bright ground and sky
		var inf: Dictionary = opts["info"]
		var card := PanelContainer.new()
		card.mouse_filter = Control.MOUSE_FILTER_IGNORE
		card.add_theme_stylebox_override("panel", UITheme.panel(Color(0.06, 0.055, 0.05, 0.62), 8, Color(1, 1, 1, 0.06), 10))
		card.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		var cv := VBoxContainer.new()
		cv.add_theme_constant_override("separation", 2)
		card.add_child(cv)
		var tl := UITheme.label(String(inf.get("title", "")), 16, UITheme.ACCENT, true)
		cv.add_child(tl)
		var txt := String(inf.get("text", ""))
		if txt != "":
			var bl := UITheme.label(txt, 14, Color(UITheme.PAPER, 0.92))
			bl.custom_minimum_size.x = 340
			bl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			cv.add_child(bl)
		prompts.add_child(card)
	for key in ["interact", "primary", "secondary"]:
		if not opts.has(key):
			continue
		var o: Dictionary = opts[key]
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var badge := KeyBadge.new()
		badge.text = Settings.key_label(key)
		badge.enabled = o.get("enabled", true)
		row.add_child(badge)
		var l := UITheme.label(String(o.get("label", "")), 16, UITheme.PAPER if o.get("enabled", true) else Color(UITheme.TEXT_DIM, 0.85))
		l.add_theme_constant_override("outline_size", 5)
		l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.55))
		row.add_child(l)
		prompts.add_child(row)
		any = true
	reticle.set("active", any)


func _process(delta: float) -> void:
	var p := lp()
	if p == null:
		return
	# clock & weather
	var h := World.hour_of_day()
	clock.text = "Day %d  ·  %02d:%02d" % [World.day(), int(h), int(fmod(h, 1.0) * 60.0)]
	var rain := float(World.env.get("rain", 0.0))
	var cloud := float(World.env.get("cloud", 0.0))
	var wind: Vector2 = World.env.get("wind", Vector2.ZERO)
	var sky := "Rain" if rain > 0.15 else ("Mist" if float(World.env.get("fog", 0.0)) > 0.25 else ("Overcast" if cloud > 0.7 else ("Cloudy" if cloud > 0.4 else "Clear")))
	var temp := float(World.my_stats.get("temp", Climate.base_temp()))
	weather_lbl.text = "%s  ·  %s  ·  %d°C" % [sky, "breezy" if wind.length() > 2.5 else "calm", int(round(temp))]
	if _held_t > 0.0:
		_held_t -= delta
		held_name.modulate.a = clampf(_held_t, 0.0, 1.0)
	if _hint_t > 0.0:
		# a tip waits (hidden) while a full-screen panel is open or hands are busy crafting
		var away := panel != null or p.mode == "craft"
		if not away:
			_hint_t -= delta
		hint_card.modulate.a = 0.0 if away else clampf(_hint_t, 0.0, 1.0)
		if _hint_t <= 0.0:
			hint_card.visible = false
			_next_hint()
	for t in toasts.get_children():
		var life: float = t.get_meta("life", 0.0) - delta
		t.set_meta("life", life)
		t.modulate.a = clampf(life, 0.0, 1.0)
		if life <= 0.0:
			t.queue_free()
	for c in chat_box.get_children():
		var life2: float = c.get_meta("life", 0.0) - delta
		c.set_meta("life", life2)
		c.modulate.a = 1.0 if chat_input.visible else clampf(life2, 0.0, 1.0)
	var m: ShaderMaterial = vignette.material
	var amt := float(m.get_shader_parameter("amount") if m.get_shader_parameter("amount") != null else 0.0)
	m.set_shader_parameter("amount", maxf(0.0, amt - delta * 0.8))
	var warmth := float(World.my_stats.get("warmth", 1.0))
	if warmth < 0.25 and amt < 0.2:
		m.set_shader_parameter("col", Color(0.4, 0.6, 0.9))
		m.set_shader_parameter("amount", (0.25 - warmth) * 1.6)
	var mode := p.mode
	fade.color.a = move_toward(fade.color.a, 0.92 if mode == "sleep" else (0.55 if mode == "dead" else 0.0), delta * 0.8)
	_tick_hint_keys()


func _tick_hint_keys() -> void:
	pass


func _refresh_hotbar() -> void:
	var inv := World.my_inventory
	var sel := lp().hotbar if lp() else 0
	for i in hotbar_slots.size():
		var s: SlotView = hotbar_slots[i]
		s.stack = inv.get_slot(i)
		s.selected = i == sel
		s.queue_redraw()
	if lp():
		lp().hands.set_held(lp().held_stack())
		lp().model.set_held(lp().held_id())


func _show_held_name() -> void:
	var p := lp()
	if p == null:
		return
	var s := p.held_stack()
	held_name.text = ItemDB.display_name(String(s.get("i", "")), s.get("d", {})) if not s.is_empty() else ""
	_held_t = 2.2


func _refresh_vitals() -> void:
	var st := World.my_stats
	for k in vitals:
		var bar: VitalBar = vitals[k]
		bar.value = float(st.get(k, 1.0))
		bar.queue_redraw()
	var hp := float(st.get("health", 1.0))
	if hp < _hp_last - 0.01:
		var m: ShaderMaterial = vignette.material
		m.set_shader_parameter("col", Color(0.65, 0.05, 0.05))
		m.set_shader_parameter("amount", clampf((_hp_last - hp) * 6.0, 0.25, 0.9))
	_hp_last = hp
	if not bool(st.get("alive", true)) and lp() and lp().mode != "dead":
		# (after a reload or rejoin we only know the cause, not the words)
		_show_death(Survival._death_text(String(st.get("death_cause", ""))))
	elif bool(st.get("alive", true)) and death_panel and death_panel.visible:
		death_panel.visible = false
		if lp():
			lp().set_mode("play")


func toast(text: String, kind: String = "info") -> void:
	if kind == "death":
		_show_death(text)
		return
	# the same message again just stays up longer
	for t in toasts.get_children():
		if t.get_meta("text", "") == text and not t.is_queued_for_deletion():
			t.set_meta("life", maxf(float(t.get_meta("life", 0.0)), 4.5))
			toasts.move_child(t, -1)
			return
	var pc := PanelContainer.new()
	var col: Color = {"warn": Color(0.4, 0.22, 0.12, 0.85), "error": Color(0.45, 0.14, 0.12, 0.88), "save": Color(0.15, 0.25, 0.18, 0.85),
		"discovery": Color(0.32, 0.25, 0.1, 0.9)}.get(kind, Color(0.08, 0.075, 0.065, 0.8))
	pc.add_theme_stylebox_override("panel", UITheme.panel(col, 8, Color(1, 1, 1, 0.08), 12))
	pc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var l := UITheme.label(text, 15, UITheme.PAPER)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.custom_minimum_size = Vector2(min(640, 40 + text.length() * 8), 0)
	pc.add_child(l)
	pc.set_meta("life", 4.5 if kind != "discovery" else 7.0)
	pc.set_meta("text", text)
	pc.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	toasts.add_child(pc)
	while toasts.get_child_count() > 4:
		var old := toasts.get_child(0)
		toasts.remove_child(old)
		old.queue_free()
	if kind == "warn" or kind == "error":
		Sfx.ui("ui_error", -10.0)


func _on_hint(hint_id_req: String) -> void:
	var hid := hint_id_req
	if hid.begins_with("item:"):
		Guide.encountered_item(hid.substr(5))
		hid = "item_" + hid.substr(5)
	if not Guide.should_show(hid):
		return
	if hid == hint_id and hint_card.visible:
		return
	if _hint_queue.has(hid):
		return
	_hint_queue.append(hid)
	if not hint_card.visible:
		_next_hint()


func _next_hint() -> void:
	if _hint_queue.is_empty():
		return
	var hid: String = _hint_queue.pop_front()
	if not Guide.should_show(hid):
		_next_hint()
		return
	var h: Dictionary = Guide.hints[hid]
	hint_id = hid
	hint_title.text = String(h.get("title", "Tip"))
	hint_text.text = String(h.get("text", ""))
	hint_card.visible = true
	hint_card.modulate.a = 1.0
	_hint_t = float(h.get("time", 14.0))
	Sfx.ui("hint", -10.0)


func _on_chat(from: String, text: String) -> void:
	var l := Label.new()
	l.text = ("%s: %s" % [from, text]) if from != "" else text
	l.add_theme_font_size_override("font_size", 15)
	l.add_theme_color_override("font_color", UITheme.PAPER if from != "" else UITheme.ACCENT_2)
	l.add_theme_constant_override("outline_size", 5)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.6))
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.set_meta("life", 10.0)
	chat_box.add_child(l)
	while chat_box.get_child_count() > 8:
		var old := chat_box.get_child(0)
		chat_box.remove_child(old)
		old.queue_free()


func _send_chat(text: String) -> void:
	Net.send_chat(text)
	chat_input.text = ""
	chat_input.visible = false
	chat_input.release_focus()
	if lp():
		lp().set_mode("play")


func _show_death(text: String) -> void:
	# whatever you were doing ends here: step out of any close-up work and close panels
	var cc := get_tree().get_first_node_in_group("crafting")
	if cc and cc.has_method("is_open") and cc.is_open():
		cc.close(true)
	if panel:
		close_panel()
	var p := lp()
	if p:
		if p.has_method("wake") and p.mode == "sleep":
			p.wake()
		p.set_mode("dead")
	if death_panel == null:
		death_panel = VBoxContainer.new()
		death_panel.set_anchors_preset(Control.PRESET_CENTER)
		death_panel.offset_left = -300
		death_panel.offset_right = 300
		death_panel.offset_top = -80
		(death_panel as VBoxContainer).alignment = BoxContainer.ALIGNMENT_CENTER
		(death_panel as VBoxContainer).add_theme_constant_override("separation", 18)
		root.add_child(death_panel)
		death_text = UITheme.title_label("", 30, UITheme.PAPER)
		death_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		death_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		death_panel.add_child(death_text)
		var b := UITheme.button("Wake up on the island", func(): World.request("respawn", {}); Input.mouse_mode = Input.MOUSE_MODE_CAPTURED, 280)
		b.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		death_panel.add_child(b)
	if text == "" or text == "abyss":
		text = "You died."
	death_text.text = text
	death_panel.visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _on_mode(m: String) -> void:
	reticle.visible = m == "play"
	prompts.visible = m == "play"


# ---------------------------------------------------------------------------
# Panels & keys
# ---------------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	var p := lp()
	if p == null:
		return
	if chat_input.visible:
		if event.is_action_pressed("pause"):
			chat_input.visible = false
			p.set_mode("play")
			get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("pause"):
		if panel:
			close_panel()
		elif p.mode == "craft":
			pass  # the craft session handles Esc
		elif p.mode == "build":
			p.placer.stop()
		elif p.mode == "sleep":
			p.wake()
		else:
			open_panel("pause")
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("inventory") and (p.mode == "play" or panel_name == "inventory"):
		toggle_panel("inventory")
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("guide") and (p.mode == "play" or panel_name == "guide"):
		if hint_card.visible and hint_id != "" and panel == null:
			var entry := String(Guide.hints.get(hint_id, {}).get("entry", ""))
			toggle_panel("guide")
			if entry != "":
				Events.guide_open_entry.emit(entry)
		else:
			toggle_panel("guide")
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("build") and (p.mode == "play" or panel_name == "build"):
		toggle_panel("build")
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("chat") and p.mode == "play" and panel == null:
		chat_input.visible = true
		chat_input.grab_focus()
		p.set_mode("ui")
		get_viewport().set_input_as_handled()
	elif event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_X and hint_card.visible and panel == null:
		Guide.dismiss_hint(hint_id)
		hint_card.visible = false
		_next_hint()
	elif event.is_action_pressed("quick_save") and Net.is_host():
		Game.save()
	elif event.is_action_pressed("toggle_hud"):
		_hidden = not _hidden
		root.visible = not _hidden
	elif event.is_action_pressed("screenshot"):
		var img := get_viewport().get_texture().get_image()
		DirAccess.make_dir_recursive_absolute("user://screenshots")
		var path := "user://screenshots/skyroot_%d.png" % Time.get_unix_time_from_system()
		img.save_png(path)
		toast("Screenshot saved.", "save")


func toggle_panel(nm: String) -> void:
	if panel_name == nm:
		close_panel()
	else:
		open_panel(nm)


func open_panel(nm: String) -> void:
	close_panel()
	var p := lp()
	match nm:
		"inventory":
			panel = InventoryUI.new()
			panel.set("hud", self)
		"pause":
			panel = PauseMenu.new()
			panel.set("hud", self)
		"guide":
			panel = GuideUI.new()
			panel.set("hud", self)
		"build":
			panel = BuildMenu.new()
			panel.set("hud", self)
	if panel == null:
		return
	panel_name = nm
	root.add_child(panel)
	if p:
		p.set_mode("ui")
	Sfx.ui("ui_open" if nm != "guide" else "book_open", -6.0)


func close_panel() -> void:
	if panel == null:
		return
	if panel.has_method("on_close"):
		panel.on_close()
	panel.queue_free()
	panel = null
	var was := panel_name
	panel_name = ""
	var p := lp()
	if p and p.mode == "ui":
		p.set_mode("play")
	Sfx.ui("ui_close" if was != "guide" else "book_close", -6.0)


func set_work_hint(text: String) -> void:
	work_hint.text = text
