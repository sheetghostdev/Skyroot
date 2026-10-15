class_name HandbookUI
extends Control
## The handbook (H): how-to pages, your goals, and a page for every item - what
## it is, how to get it, what it's for.  Searchable.

var list: ItemList
var search: LineEdit
var title: Label
var body: RichTextLabel
var icons_row: HBoxContainer
var _ids: Array = []


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var dim := ColorRect.new()
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0, 0, 0, 0.4)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(dim)
	var pc := PanelContainer.new()
	pc.set_anchors_preset(Control.PRESET_CENTER)
	pc.offset_left = -520
	pc.offset_right = 520
	pc.offset_top = -330
	pc.offset_bottom = 330
	pc.add_theme_stylebox_override("panel", UITheme.panel(UITheme.BG_SOLID, 12, UITheme.LINE, 18))
	add_child(pc)
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 16)
	pc.add_child(h)
	var left := VBoxContainer.new()
	left.custom_minimum_size = Vector2(300, 0)
	h.add_child(left)
	left.add_child(UITheme.label("Handbook", 22, UITheme.PAPER, true))
	search = LineEdit.new()
	search.placeholder_text = "Search (an item, a block, 'fire'...)"
	search.text_changed.connect(func(_t): _fill())
	left.add_child(search)
	list = ItemList.new()
	list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	list.item_selected.connect(_on_pick)
	left.add_child(list)
	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.add_theme_constant_override("separation", 10)
	h.add_child(right)
	title = UITheme.title_label("", 30)
	right.add_child(title)
	icons_row = HBoxContainer.new()
	icons_row.add_theme_constant_override("separation", 6)
	right.add_child(icons_row)
	body = RichTextLabel.new()
	body.bbcode_enabled = true
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_font_size_override("normal_font_size", 16)
	body.add_theme_font_size_override("bold_font_size", 16)
	body.add_theme_color_override("default_color", UITheme.PAPER)
	body.add_theme_font_override("bold_font", UITheme.font_bold())
	body.meta_clicked.connect(func(m): _open(String(m)))
	right.add_child(body)
	_fill()
	_open(Guide.last_page if Guide.last_page != "" else "goals")


func _fill() -> void:
	list.clear()
	_ids.clear()
	var q := search.text.strip_edges()
	if q == "":
		_add("goals", "Your goals", true)
		for c in Guide.categories:
			if not Guide.for_this_world(c):
				continue
			_add("", String(c["title"]).to_upper(), false)
			for pid in c["pages"]:
				if Guide.for_this_world(Guide.pages[pid]):
					_add(pid, "   " + String(Guide.pages[pid]["title"]), true)
		_add("", "ITEMS", false)
		var items := ItemDB.items.keys()
		items.sort_custom(func(a, b): return ItemDB.label(a) < ItemDB.label(b))
		for it in items:
			_add("item:" + it, "   " + ItemDB.label(it), true, it)
	else:
		for pid in Guide.search(q):
			var p := Guide.page(pid)
			_add(pid, String(p.get("title", pid)), true, pid.substr(5) if pid.begins_with("item:") else "")


func _add(id: String, text: String, selectable: bool, icon_item := "") -> void:
	var tex: Texture2D = Icons.texture(icon_item) if icon_item != "" else null
	var i := list.add_item(text, tex, selectable)
	if not selectable:
		list.set_item_custom_fg_color(i, UITheme.ACCENT)
		list.set_item_disabled(i, true)
	elif id != "" and not id.begins_with("item:") and not Guide.read.has(id) and id != "goals":
		list.set_item_custom_fg_color(i, UITheme.PAPER)
	_ids.append(id)


func _on_pick(i: int) -> void:
	if i >= 0 and i < _ids.size() and String(_ids[i]) != "":
		_open(String(_ids[i]))


func _open(id: String) -> void:
	for ch in icons_row.get_children():
		ch.queue_free()
	if id == "goals":
		title.text = "Your goals"
		var t := ""
		var current := Guide.current_goal()
		for g in Guide.active_goals():
			var mark := "[color=#9fb98a]✔[/color] " if Guide.done.has(g["id"]) else ("[color=#e0a64a]▶[/color] " if g == current else "   ")
			t += "%s[b]%s[/b]\n      %s\n" % [mark, g["title"], g["text"]]
		body.text = t
		Guide.last_page = "goals"
		return
	var p := Guide.page(id)
	if p.is_empty():
		return
	title.text = String(p["title"])
	body.text = _links(String(p.get("body", "")))
	for it in p.get("items", []):
		var tr := TextureRect.new()
		tr.texture = Icons.texture(String(it))
		tr.custom_minimum_size = Vector2(48, 48)
		tr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tr.tooltip_text = ItemDB.label(String(it))
		icons_row.add_child(tr)
	Guide.mark_read(id)


func _links(t: String) -> String:
	## [item:stick] -> a clickable item name
	var re := RegEx.new()
	re.compile("\\[item:([a-z_]+)\\]")
	var out := t
	for m in re.search_all(t):
		var id := m.get_string(1)
		out = out.replace(m.get_string(), "[url=item:%s][color=#e7c27a]%s[/color][/url]" % [id, ItemDB.label(id).to_lower()])
	return out
