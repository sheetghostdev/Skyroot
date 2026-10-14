extends Control
## Inventory (Tab).  Click a slot then another to move/merge/swap, right-click
## to split a stack, shift-click to move between hotbar and pack, Q to drop.

var hud: Node
var slots: Array = []
var picked := -1
var detail_title: Label
var detail_text: Label
var detail_guide: Button
var hovered := -1
var storage_panel: Control


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var dim := ColorRect.new()
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0, 0, 0, 0.35)
	add_child(dim)
	var pc := PanelContainer.new()
	pc.set_anchors_preset(Control.PRESET_CENTER)
	pc.offset_left = -560
	pc.offset_right = 560
	pc.offset_top = -250
	pc.offset_bottom = 250
	pc.add_theme_stylebox_override("panel", UITheme.panel(UITheme.BG_SOLID, 14, UITheme.LINE, 22))
	add_child(pc)
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 26)
	pc.add_child(h)
	var left := VBoxContainer.new()
	left.add_theme_constant_override("separation", 10)
	h.add_child(left)
	left.add_child(UITheme.title_label("Carried", 30))
	var pack := GridContainer.new()
	pack.columns = 9
	pack.add_theme_constant_override("h_separation", 6)
	pack.add_theme_constant_override("v_separation", 6)
	left.add_child(pack)
	for i in range(Inventory.HOTBAR, Inventory.SIZE):
		pack.add_child(_slot(i))
	var sep := UITheme.label("HOTBAR  (1-9, mouse wheel)", 12, UITheme.TEXT_DIM, true)
	left.add_child(sep)
	var hb := GridContainer.new()
	hb.columns = 9
	hb.add_theme_constant_override("h_separation", 6)
	left.add_child(hb)
	for i in Inventory.HOTBAR:
		hb.add_child(_slot(i))
	var help := UITheme.label("Click: pick up / place    Right-click: split    Shift-click: move to pack/hotbar    Q: drop", 13, UITheme.TEXT_DIM)
	left.add_child(help)
	var right := VBoxContainer.new()
	right.custom_minimum_size = Vector2(330, 0)
	right.add_theme_constant_override("separation", 10)
	h.add_child(right)
	detail_title = UITheme.title_label("", 24, UITheme.PAPER)
	detail_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	right.add_child(detail_title)
	detail_text = UITheme.label("Hover an item to learn about it.", 15, UITheme.TEXT)
	detail_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	detail_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right.add_child(detail_text)
	detail_guide = UITheme.button("Read about it in the guide", _open_guide, 0)
	detail_guide.visible = false
	right.add_child(detail_guide)
	Events.inventory_changed.connect(_refresh)
	_refresh()


func _slot(i: int) -> SlotView:
	var s := SlotView.new()
	s.index = i
	s.icons = hud.icons
	s.clicked.connect(_on_click)
	s.hovered.connect(_on_hover)
	slots.append(s)
	return s


func _refresh() -> void:
	var inv := World.my_inventory
	var lp: LocalPlayer = hud.lp()
	for s in slots:
		s.stack = inv.get_slot(s.index)
		s.selected = s.index == picked or (picked < 0 and lp and s.index == lp.hotbar)
		s.queue_redraw()
	if hovered >= 0:
		_on_hover(hovered)


func _on_hover(i: int) -> void:
	hovered = i
	var s := World.my_inventory.get_slot(i)
	if s.is_empty():
		detail_title.text = ""
		detail_text.text = "Empty slot." if picked < 0 else "Click to put it here."
		detail_guide.visible = false
		return
	var id := String(s["i"])
	detail_title.text = ItemDB.display_name(id, s["d"]) + ("  ×%d" % int(s["n"]) if int(s["n"]) > 1 else "")
	var lines: PackedStringArray = [ItemDB.describe(id, s["d"])]
	var fuel := ItemDB.fuel(id)
	if not fuel.is_empty():
		lines.append("Fuel: %s" % ("catches easily" if float(fuel["ign"]) < 300 else ("burns steadily" if float(fuel["ign"]) < 420 else "needs a hot fire")))
	var food := ItemDB.food(id)
	if not food.is_empty():
		lines.append("Food: %s" % ("filling" if float(food.get("hunger", 0)) > 0.15 else "a small bite"))
	if ItemDB.has_tag(id, "compostable"):
		lines.append("Compostable.")
	detail_text.text = "\n".join(lines)
	var g := ItemDB.guide_entry(id)
	detail_guide.visible = g != "" and Guide.has_entry(g)
	detail_guide.set_meta("entry", g)


func _on_click(i: int, button: int) -> void:
	var inv := World.my_inventory
	if button == MOUSE_BUTTON_RIGHT:
		var empty := _first_empty(i < Inventory.HOTBAR)
		if empty >= 0 and int(inv.get_slot(i).get("n", 0)) > 1:
			World.request("inv_split", {"from": i, "to": empty})
		return
	if Input.is_key_pressed(KEY_SHIFT):
		if inv.is_empty_slot(i):
			return
		var to := _first_empty(i >= Inventory.HOTBAR)
		if to >= 0:
			World.request("inv_move", {"from": i, "to": to})
		return
	if picked < 0:
		if not inv.is_empty_slot(i):
			picked = i
			Sfx.ui("ui_click", -10.0)
	else:
		if picked != i:
			World.request("inv_move", {"from": picked, "to": i})
			Sfx.ui("drop", -10.0)
		picked = -1
	_refresh()


func _first_empty(in_hotbar: bool) -> int:
	var inv := World.my_inventory
	var r := range(0, Inventory.HOTBAR) if in_hotbar else range(Inventory.HOTBAR, Inventory.SIZE)
	for i in r:
		if inv.is_empty_slot(i):
			return i
	return -1


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("drop") and hovered >= 0 and not World.my_inventory.is_empty_slot(hovered):
		World.request("inv_drop_slot", {"slot": hovered, "n": 999 if Input.is_key_pressed(KEY_CTRL) else 1})
		get_viewport().set_input_as_handled()


func _open_guide() -> void:
	var e := String(detail_guide.get_meta("entry", ""))
	hud.open_panel("guide")
	Events.guide_open_entry.emit(e)
