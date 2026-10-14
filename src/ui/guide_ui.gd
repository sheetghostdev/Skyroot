class_name GuideUI
extends Control
## The Survival Guide (H): every entry is readable from the start.  Browse by
## category or search; entries have diagrams, steps, tips and a checklist you
## can pin to the screen.  The island journal lists what everyone on this
## island has discovered.

const NAV_W := 300.0
const DOT_NEW := Color(0.95, 0.68, 0.25)

var hud: Node
var search: LineEdit
var nav: VBoxContainer
var nav_scroll: ScrollContainer
var page: VBoxContainer
var page_scroll: ScrollContainer
var back_btn: Button
var current := ""
var _history: Array = []
var _nav_buttons: Dictionary = {}     # entry id -> Button
var _chips: Array = []                # [TextureRect, item id] waiting for icons
var _sb_nav: Dictionary = {}
var _tex_new: Texture2D
var _tex_pin: Texture2D
var _tex_blank: Texture2D


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_tex_new = _dot_tex(DOT_NEW)
	_tex_pin = _pin_tex()
	_tex_blank = _dot_tex(Color(0, 0, 0, 0))
	_sb_nav = {
		"normal": _flat(Color(0, 0, 0, 0)),
		"hover": _flat(Color(1, 1, 1, 0.06)),
		"pressed": _flat(Color(UITheme.ACCENT, 0.22)),
		"focus": StyleBoxEmpty.new(),
	}
	var dim := ColorRect.new()
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0, 0, 0, 0.5)
	add_child(dim)
	var book := PanelContainer.new()
	book.set_anchors_preset(Control.PRESET_FULL_RECT)
	book.offset_left = 56
	book.offset_right = -56
	book.offset_top = 36
	book.offset_bottom = -36
	book.add_theme_stylebox_override("panel", UITheme.panel(UITheme.BG_SOLID, 14, UITheme.LINE, 18))
	add_child(book)
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 12)
	book.add_child(root)
	# --- header
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 12)
	root.add_child(head)
	var tbox := VBoxContainer.new()
	tbox.add_theme_constant_override("separation", 0)
	tbox.add_child(UITheme.title_label("Survival Guide", 30))
	tbox.add_child(UITheme.label("Everything here is true of this island. Read anything, any time.", 13, UITheme.TEXT_DIM))
	head.add_child(tbox)
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(sp)
	search = LineEdit.new()
	search.placeholder_text = "Search the guide..."
	search.custom_minimum_size = Vector2(320, 40)
	search.clear_button_enabled = true
	search.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	search.text_changed.connect(_on_search)
	search.text_submitted.connect(_on_search_submit)
	head.add_child(search)
	var jb := UITheme.button("Island journal", show_journal, 150)
	jb.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(jb)
	var cb := UITheme.button("Close", func(): hud.close_panel(), 90)
	cb.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(cb)
	# --- body
	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 18)
	root.add_child(body)
	var left := PanelContainer.new()
	left.custom_minimum_size = Vector2(NAV_W, 0)
	left.add_theme_stylebox_override("panel", UITheme.panel(Color(0.07, 0.065, 0.06, 0.7), 10, Color(1, 1, 1, 0.05), 8))
	body.add_child(left)
	nav_scroll = ScrollContainer.new()
	nav_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	left.add_child(nav_scroll)
	nav = VBoxContainer.new()
	nav.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	nav.add_theme_constant_override("separation", 2)
	nav_scroll.add_child(nav)
	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.add_theme_constant_override("separation", 6)
	body.add_child(right)
	back_btn = UITheme.button("Back", _back, 90)
	back_btn.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	back_btn.visible = false
	right.add_child(back_btn)
	page_scroll = ScrollContainer.new()
	page_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	page_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	right.add_child(page_scroll)
	var margin := MarginContainer.new()
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.add_theme_constant_override("margin_right", 22)
	margin.add_theme_constant_override("margin_left", 6)
	page_scroll.add_child(margin)
	page = VBoxContainer.new()
	page.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	page.add_theme_constant_override("separation", 10)
	margin.add_child(page)
	Events.guide_open_entry.connect(_open_from_outside)
	Guide.progress_changed.connect(_refresh_marks)
	Guide.pinned_changed.connect(_refresh_marks)
	if hud and hud.get("icons"):
		hud.icons.icon_ready.connect(_on_icon_ready)
	_build_nav()
	var first := Guide.last_entry
	if not Guide.has_entry(first):
		first = "getting_started" if Guide.has_entry("getting_started") else _first_entry()
	if first != "":
		show_entry(first, false)


func _input(event: InputEvent) -> void:
	# Ctrl+F or / jumps to the search box; Esc leaves it
	if event is InputEventKey and event.pressed and not event.echo:
		var k := event as InputEventKey
		if (k.keycode == KEY_F and k.ctrl_pressed) or (k.keycode == KEY_SLASH and not search.has_focus()):
			search.grab_focus()
			search.select_all()
			get_viewport().set_input_as_handled()
		elif k.keycode == KEY_ESCAPE and search.has_focus():
			search.release_focus()
			if search.text != "":
				search.text = ""
				_on_search("")
			get_viewport().set_input_as_handled()


func _first_entry() -> String:
	for cat in Guide.categories:
		if not cat["entries"].is_empty():
			return String(cat["entries"][0])
	return ""


# ---------------------------------------------------------------------------
# Navigation
# ---------------------------------------------------------------------------

func _build_nav() -> void:
	for c in nav.get_children():
		c.queue_free()
	_nav_buttons.clear()
	for cat in Guide.categories:
		var h := UITheme.label(String(cat["title"]).to_upper(), 12, Color(UITheme.ACCENT, 0.85), true)
		h.add_theme_constant_override("line_spacing", 0)
		var hm := MarginContainer.new()
		hm.add_theme_constant_override("margin_top", 10)
		hm.add_theme_constant_override("margin_left", 8)
		hm.add_child(h)
		nav.add_child(hm)
		for id in cat["entries"]:
			var b := _nav_button(String(id), String(Guide.entry(id).get("title", id)))
			nav.add_child(b)
	_refresh_marks()


func _nav_button(id: String, title: String) -> Button:
	var b := Button.new()
	b.text = title
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.toggle_mode = true
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(0, 30)
	b.add_theme_font_size_override("font_size", 15)
	b.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	b.clip_text = true
	for st in _sb_nav:
		b.add_theme_stylebox_override(st, _sb_nav[st])
	b.add_theme_stylebox_override("hover_pressed", _sb_nav["pressed"])
	b.icon = _tex_blank
	b.expand_icon = false
	b.pressed.connect(func(): show_entry(id))
	b.mouse_entered.connect(func(): Sfx.ui("ui_hover", -18.0))
	_nav_buttons[id] = b
	return b


func _refresh_marks() -> void:
	for id in _nav_buttons:
		var b: Button = _nav_buttons[id]
		if not is_instance_valid(b):
			continue
		b.set_pressed_no_signal(id == current)
		if Guide.fresh.has(id):
			b.icon = _tex_new
			b.add_theme_color_override("font_color", Color(1.0, 0.86, 0.6))
		elif Guide.is_pinned(id):
			b.icon = _tex_pin
			b.remove_theme_color_override("font_color")
		else:
			b.icon = _tex_blank
			b.add_theme_color_override("font_color", UITheme.TEXT if Guide.read.has(id) else Color(UITheme.TEXT, 0.85))


func _on_search(q: String) -> void:
	if q.strip_edges() == "":
		_build_nav()
		return
	for c in nav.get_children():
		c.queue_free()
	_nav_buttons.clear()
	var ids := Guide.search(q)
	var h := UITheme.label("%d result%s" % [ids.size(), "" if ids.size() == 1 else "s"], 12, Color(UITheme.ACCENT, 0.85), true)
	var hm := MarginContainer.new()
	hm.add_theme_constant_override("margin_top", 6)
	hm.add_theme_constant_override("margin_left", 8)
	hm.add_child(h)
	nav.add_child(hm)
	if ids.is_empty():
		var l := UITheme.label("Nothing matches. Try a material (clay, stone), a process (fire, compost) or a problem (cold, cracked).", 13, UITheme.TEXT_DIM)
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.custom_minimum_size.x = NAV_W - 30
		nav.add_child(l)
		return
	for id in ids.slice(0, 30):
		var e := Guide.entry(id)
		nav.add_child(_nav_button(id, String(e.get("title", id))))
		var s := UITheme.label(String(e.get("summary", "")), 12, UITheme.TEXT_DIM)
		s.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		s.custom_minimum_size.x = NAV_W - 40
		s.max_lines_visible = 2
		s.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		var sm := MarginContainer.new()
		sm.add_theme_constant_override("margin_left", 30)
		sm.add_theme_constant_override("margin_bottom", 6)
		sm.add_child(s)
		nav.add_child(sm)
	_refresh_marks()


func _on_search_submit(q: String) -> void:
	var ids := Guide.search(q)
	if not ids.is_empty():
		show_entry(String(ids[0]))
		search.release_focus()


func _open_from_outside(id: String) -> void:
	if Guide.has_entry(id):
		show_entry(id)


func _back() -> void:
	if _history.is_empty():
		return
	var id := String(_history.pop_back())
	if id == "#journal":
		show_journal(false)
	else:
		show_entry(id, false)


# ---------------------------------------------------------------------------
# Pages
# ---------------------------------------------------------------------------

func _clear_page(push: bool) -> void:
	if push and current != "":
		_history.append(current)
		if _history.size() > 30:
			_history.pop_front()
	back_btn.visible = not _history.is_empty()
	for c in page.get_children():
		c.queue_free()
	_chips.clear()
	page_scroll.scroll_vertical = 0


func show_entry(id: String, push: bool = true) -> void:
	if not Guide.has_entry(id):
		return
	if id == current and page.get_child_count() > 0:
		return
	_clear_page(push and id != current)
	current = id
	Guide.last_entry = id
	Guide.mark_read(id)
	var e := Guide.entry(id)
	var cat_title := ""
	for cat in Guide.categories:
		if cat["id"] == e.get("category", ""):
			cat_title = String(cat["title"])
	page.add_child(UITheme.label(cat_title.to_upper(), 12, Color(UITheme.ACCENT, 0.8), true))
	var title_row := HBoxContainer.new()
	title_row.add_theme_constant_override("separation", 14)
	var tl := UITheme.title_label(String(e.get("title", id)), 34)
	tl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	title_row.add_child(tl)
	var pinned := Guide.is_pinned(id)
	var pin := UITheme.button("Unpin" if pinned else "Pin to screen", _toggle_pin.bind(id), 140)
	pin.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	pin.tooltip_text = "Keep this entry's checklist on screen while you play (up to %d)." % Guide.MAX_PINS
	title_row.add_child(pin)
	page.add_child(title_row)
	if String(e.get("summary", "")) != "":
		page.add_child(_rich("[i]%s[/i]" % bb(String(e["summary"])), 17, Color(UITheme.PAPER, 0.92)))
	var items: Array = e.get("items", [])
	if not items.is_empty():
		page.add_child(_chip_row(items))
	if String(e.get("diagram", "")) != "":
		page.add_child(_diagram(String(e["diagram"]), ""))
	for s in e.get("sections", []):
		_section(s)
	var track: Array = e.get("track", [])
	if not track.is_empty():
		page.add_child(_heading("Checklist"))
		for i in track.size():
			page.add_child(_check_row(String(e.get("id", current)), i, track[i]))
	var rel: Array = e.get("related", [])
	if not rel.is_empty():
		page.add_child(_heading("See also"))
		var flow := HFlowContainer.new()
		flow.add_theme_constant_override("h_separation", 8)
		flow.add_theme_constant_override("v_separation", 8)
		for rid in rel:
			if Guide.has_entry(rid):
				var b := UITheme.button(String(Guide.entry(rid).get("title", rid)), show_entry.bind(String(rid)))
				flow.add_child(b)
		page.add_child(flow)
	var pad := Control.new()
	pad.custom_minimum_size.y = 24
	page.add_child(pad)
	_refresh_marks()


func _section(s: Dictionary) -> void:
	if s.has("h"):
		page.add_child(_heading(String(s["h"])))
	if s.has("text"):
		page.add_child(_rich(bb(String(s["text"])), 16, UITheme.TEXT))
	if s.has("diagram"):
		page.add_child(_diagram(String(s["diagram"]), String(s.get("caption", ""))))
	var steps: Array = s.get("steps", [])
	for i in steps.size():
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)
		var num := Label.new()
		num.text = str(i + 1)
		num.custom_minimum_size = Vector2(28, 28)
		num.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		num.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		num.add_theme_font_override("font", UITheme.font_bold())
		num.add_theme_font_size_override("font_size", 14)
		num.add_theme_color_override("font_color", UITheme.INK)
		var sb := UITheme.panel(UITheme.ACCENT, 14, Color(0, 0, 0, 0), 0)
		num.add_theme_stylebox_override("normal", sb)
		num.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
		row.add_child(num)
		var r := _rich(bb(String(steps[i])), 16, UITheme.TEXT)
		r.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(r)
		page.add_child(row)
	for item in s.get("list", []):
		var row2 := HBoxContainer.new()
		row2.add_theme_constant_override("separation", 10)
		var dot := UITheme.label("•", 18, UITheme.ACCENT)
		dot.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
		row2.add_child(dot)
		var r2 := _rich(bb(String(item)), 16, UITheme.TEXT)
		r2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row2.add_child(r2)
		page.add_child(row2)
	if s.has("tip"):
		page.add_child(_boxed("Tip", String(s["tip"]), UITheme.ACCENT_2))
	if s.has("warn"):
		page.add_child(_boxed("Careful", String(s["warn"]), UITheme.DANGER))


func _heading(text: String) -> Control:
	var m := MarginContainer.new()
	m.add_theme_constant_override("margin_top", 8)
	m.add_child(UITheme.label(text, 20, UITheme.ACCENT, true))
	return m


func _rich(text: String, size: int, col: Color) -> RichTextLabel:
	var r := RichTextLabel.new()
	r.bbcode_enabled = true
	r.fit_content = true
	r.scroll_active = false
	r.selection_enabled = false
	r.mouse_filter = Control.MOUSE_FILTER_PASS
	r.add_theme_font_size_override("normal_font_size", size)
	r.add_theme_font_size_override("bold_font_size", size)
	r.add_theme_font_size_override("italics_font_size", size)
	r.add_theme_color_override("default_color", col)
	r.add_theme_constant_override("line_separation", 3)
	r.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	r.text = text
	return r


func _boxed(label: String, text: String, col: Color) -> Control:
	var pc := PanelContainer.new()
	pc.add_theme_stylebox_override("panel", UITheme.panel(Color(col, 0.12), 8, Color(col, 0.55), 12))
	var r := _rich("[b]%s:[/b] %s" % [label, bb(text)], 15, UITheme.TEXT)
	pc.add_child(r)
	return pc


func _diagram(kind: String, caption: String) -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	box.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	var script: Script = load("res://src/ui/guide_diagram.gd") if ResourceLoader.exists("res://src/ui/guide_diagram.gd") else null
	if script != null:
		var dg: Control = script.new()
		dg.set("kind", kind)
		dg.custom_minimum_size = Vector2(576, 324)
		dg.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		box.add_child(dg)
	if caption != "":
		var c := _rich("[center][i]%s[/i][/center]" % bb(caption), 14, UITheme.TEXT_DIM)
		c.custom_minimum_size.x = 576
		box.add_child(c)
	return box


func _chip_row(items: Array) -> Control:
	var flow := HFlowContainer.new()
	flow.add_theme_constant_override("h_separation", 8)
	flow.add_theme_constant_override("v_separation", 6)
	for id in items:
		if not ItemDB.exists(String(id)):
			continue
		var pc := PanelContainer.new()
		pc.add_theme_stylebox_override("panel", UITheme.panel(Color(1, 1, 1, 0.05), 16, Color(1, 1, 1, 0.08), 6))
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		var tr := TextureRect.new()
		tr.custom_minimum_size = Vector2(28, 28)
		tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		if hud and hud.get("icons"):
			tr.texture = hud.icons.get_icon(String(id))
			if tr.texture == null:
				_chips.append([tr, String(id)])
		row.add_child(tr)
		var have := World.my_inventory.count(String(id)) if World.my_inventory else 0
		row.add_child(UITheme.label(ItemDB.display_name(String(id)) + ("  ×%d" % have if have > 0 else ""), 14, UITheme.PAPER if have > 0 else UITheme.TEXT_DIM))
		pc.add_child(row)
		pc.tooltip_text = String(ItemDB.def(String(id)).get("desc", ""))
		flow.add_child(pc)
	return flow


func _on_icon_ready(_key: String) -> void:
	for c in _chips:
		var tr: TextureRect = c[0]
		if is_instance_valid(tr) and tr.texture == null:
			tr.texture = hud.icons.get_icon(String(c[1]))


func _check_row(entry_id: String, i: int, st: Dictionary) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	var done := Guide.step_done(entry_id, i, st)
	var tr := TextureRect.new()
	tr.texture = UITheme._check_tex(done)
	tr.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	tr.custom_minimum_size = Vector2(22, 22)
	row.add_child(tr)
	var l := _rich(bb(String(st.get("text", ""))), 15, UITheme.TEXT_DIM if done else UITheme.TEXT)
	row.add_child(l)
	return row


func _toggle_pin(id: String) -> void:
	Guide.toggle_pin(id)
	var keep := current
	current = ""
	show_entry(keep, false)
	if Guide.is_pinned(id):
		Events.toast.emit("Pinned: its checklist stays on screen. Unpin it here, or with H later.", "info")


func show_journal(push: bool = true) -> void:
	_clear_page(push and current != "#journal")
	current = "#journal"
	page.add_child(UITheme.label("THIS ISLAND", 12, Color(UITheme.ACCENT, 0.8), true))
	page.add_child(UITheme.title_label("Island journal", 34))
	var all: Dictionary = Guide.discovery_defs
	var made := 0
	for k in World.discoveries:
		if all.has(k):
			made += 1
	page.add_child(_rich("[i]Discoveries made on this island, shared by everyone who lives here. %d of %d so far.[/i]" % [made, all.size()], 16, Color(UITheme.PAPER, 0.9)))
	if World.discoveries.is_empty():
		page.add_child(_rich("Nothing yet. The first blade, the first fire, the first pot - each will be written here, with the name of whoever managed it.", 16, UITheme.TEXT_DIM))
	for k in World.discoveries:
		var def: Dictionary = all.get(k, {})
		if def.is_empty():
			continue
		var who := String(World.discoveries[k])
		var pc := PanelContainer.new()
		pc.add_theme_stylebox_override("panel", UITheme.panel(Color(1, 1, 1, 0.04), 8, Color(UITheme.ACCENT, 0.25), 12))
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 12)
		var v := VBoxContainer.new()
		v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		v.add_child(UITheme.label(String(def.get("title", k)), 17, UITheme.ACCENT, true))
		v.add_child(_rich(bb(String(def.get("text", "")).replace("{who}", "[b]%s[/b]" % who)), 15, UITheme.TEXT))
		row.add_child(v)
		var ent := String(def.get("entry", ""))
		if Guide.has_entry(ent):
			var b := UITheme.button("Read", show_entry.bind(ent), 80)
			b.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			row.add_child(b)
		pc.add_child(row)
		page.add_child(pc)
	_refresh_marks()


func on_close() -> void:
	Guide.save_local()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

static func bb(text: String) -> String:
	## Guide text markup -> RichTextLabel BBCode: [key]E[/key] becomes a keycap.
	var out := text
	var guard := 0
	while out.contains("[key]") and guard < 64:
		guard += 1
		var a := out.find("[key]")
		var b := out.find("[/key]", a)
		if b < 0:
			break
		var k := out.substr(a + 5, b - a - 5)
		out = out.substr(0, a) + "[bgcolor=#3b3329][color=#f3dfb3][b] %s [/b][/color][/bgcolor]" % k + out.substr(b + 6)
	return out


static func plain(text: String) -> String:
	## Guide markup stripped for plain labels: keys keep their name.
	var re := RegEx.new()
	re.compile("\\[/?(b|i|key)\\]")
	return re.sub(text, "", true)


static func _flat(col: Color) -> StyleBoxFlat:
	var sb := UITheme.panel(col, 6, Color(0, 0, 0, 0), 8)
	sb.content_margin_top = 4
	sb.content_margin_bottom = 4
	return sb


static func _dot_tex(col: Color) -> Texture2D:
	var s := 14
	var img := Image.create(s, s, false, Image.FORMAT_RGBA8)
	var c := (s - 1) / 2.0
	for y in s:
		for x in s:
			var d := Vector2(x - c, y - c).length()
			img.set_pixel(x, y, Color(col, col.a * clampf(3.6 - d + 0.5, 0.0, 1.0)))
	return ImageTexture.create_from_image(img)


static func _pin_tex() -> Texture2D:
	var s := 14
	var img := Image.create(s, s, false, Image.FORMAT_RGBA8)
	var col := UITheme.ACCENT_2
	for y in s:
		for x in s:
			# a small diamond: "kept on screen"
			var d := absf(x - 6.5) + absf(y - 6.5)
			img.set_pixel(x, y, Color(col, clampf(5.5 - d, 0.0, 1.0)))
	return ImageTexture.create_from_image(img)
