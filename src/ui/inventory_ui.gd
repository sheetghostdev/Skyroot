class_name InventoryUI
extends Control
## The inventory screen (E): your backpack and hotbar, the 3x3 crafting grid
## with its result, and - when you open a storage jar - the jar's slots.
##
## Left click picks up / puts down / swaps a stack; right click takes half or
## puts down one; shift-click moves a stack straight across.  The host keeps
## the stack on your cursor, so nothing can get lost or doubled.

var jar_cell = null       # Vector3i when a jar is open
var slots: Dictionary = {}      # slot index -> SlotView (100+i for jar slots)
var output: SlotView
var tip: Label
var cursor: Control
var recipe_hint: Label
var _hover := -1


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var dim := ColorRect.new()
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0, 0, 0, 0.35)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(dim)
	var pc := PanelContainer.new()
	pc.set_anchors_preset(Control.PRESET_CENTER)
	pc.offset_left = -330
	pc.offset_right = 330
	pc.offset_top = -330
	pc.offset_bottom = 330
	pc.add_theme_stylebox_override("panel", UITheme.panel(UITheme.BG_SOLID, 12, UITheme.LINE, 20))
	add_child(pc)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 10)
	pc.add_child(v)
	if jar_cell != null:
		v.add_child(UITheme.label("Storage jar", 18, UITheme.PAPER, true))
		var jg := GridContainer.new()
		jg.columns = 8
		jg.add_theme_constant_override("h_separation", 4)
		jg.add_theme_constant_override("v_separation", 4)
		v.add_child(jg)
		for i in CraftActs.JAR_SLOTS:
			jg.add_child(_slot(100 + i))
	else:
		v.add_child(UITheme.label("Crafting", 18, UITheme.PAPER, true))
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 18)
		v.add_child(row)
		var grid := GridContainer.new()
		grid.columns = 3
		grid.add_theme_constant_override("h_separation", 4)
		grid.add_theme_constant_override("v_separation", 4)
		row.add_child(grid)
		for i in 9:
			grid.add_child(_slot(Inventory.GRID + i))
		var arrow := UITheme.label("→", 34, UITheme.TEXT_DIM, true)
		arrow.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(arrow)
		output = _slot(Actions.OUTPUT)
		output.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(output)
		recipe_hint = UITheme.label("", 13, UITheme.TEXT_DIM)
		recipe_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		recipe_hint.custom_minimum_size = Vector2(240, 0)
		recipe_hint.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(recipe_hint)
	v.add_child(UITheme.label("Backpack", 15, UITheme.TEXT_DIM, true))
	var bag := GridContainer.new()
	bag.columns = 9
	bag.add_theme_constant_override("h_separation", 4)
	bag.add_theme_constant_override("v_separation", 4)
	v.add_child(bag)
	for i in range(Inventory.HOTBAR, Inventory.MAIN):
		bag.add_child(_slot(i))
	v.add_child(UITheme.label("Hotbar", 15, UITheme.TEXT_DIM, true))
	var hot := GridContainer.new()
	hot.columns = 9
	hot.add_theme_constant_override("h_separation", 4)
	v.add_child(hot)
	for i in Inventory.HOTBAR:
		hot.add_child(_slot(i))
	tip = UITheme.label("", 14, UITheme.PAPER)
	tip.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	tip.custom_minimum_size = Vector2(600, 40)
	v.add_child(tip)
	var help := UITheme.label("Left click: take / put down   ·   Right click: half / one   ·   Shift + click: move across", 12, Color(UITheme.TEXT_DIM, 0.8))
	v.add_child(help)
	cursor = Control.new()
	cursor.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cursor.size = Vector2(52, 52)
	cursor.draw.connect(_draw_cursor)
	add_child(cursor)
	Events.inventory_changed.connect(_refresh)
	Events.entity_changed.connect(func(_id, _k): _refresh())
	_refresh()


func _slot(i: int) -> SlotView:
	var s := SlotView.new()
	s.index = i
	s.slot_size = 60
	s.clicked.connect(_on_click)
	s.hovered.connect(func(idx): _hover = idx; _update_tip())
	slots[i] = s
	return s


func _jar_items() -> Array:
	if jar_cell == null:
		return []
	var be := World.be(jar_cell)
	if be.is_empty() or be["t"] != "jar":
		return []
	return be["d"].get("inv", [])


func _refresh() -> void:
	var inv := World.my_inventory
	var jar := _jar_items()
	if jar_cell != null and World.be(jar_cell).is_empty():
		var hud = get_meta("hud", null)
		if hud:
			hud.close_panel()
		return
	for i in slots:
		var s: SlotView = slots[i]
		if i >= 100:
			var k: int = i - 100
			s.set_stack(jar[k] if k < jar.size() else {})
		elif i == Actions.OUTPUT:
			s.set_stack({})
		else:
			s.set_stack(inv.get_slot(i))
	if output:
		var grid := inv.grid()
		var m := ItemDB.match_recipe(grid)
		output.ghost = ItemDB.recipe_output(m, grid) if not m.is_empty() else {}
		output.queue_redraw()
		if not m.is_empty():
			recipe_hint.text = "Click the result to make %s.%s" % [ItemDB.label(String(output.ghost["i"])).to_lower(),
				"" if int(output.ghost["n"]) <= 1 else " (%d at a time)" % int(output.ghost["n"])]
		else:
			var any := false
			for gi in 9:
				if not (grid[gi] as Dictionary).is_empty():
					any = true
			recipe_hint.text = "That doesn't make anything." if any else "Put things in the grid to craft. Recipes are in the handbook (H)."
	_update_tip()


func _on_click(i: int, button: int, shift: bool) -> void:
	if i >= 100:
		World.request("container_click", {"c": jar_cell, "slot": i - 100, "button": button, "shift": shift})
	elif jar_cell != null and shift and i < Inventory.MAIN:
		World.request("container_click", {"c": jar_cell, "slot": 100 + i, "button": button, "shift": shift})
	else:
		World.request("inv_click", {"slot": i, "button": button, "shift": shift})
	Sfx.ui("ui_click", -16.0)


func _update_tip() -> void:
	var s: Dictionary = {}
	if slots.has(_hover):
		var sv: SlotView = slots[_hover]
		s = sv.stack if not sv.stack.is_empty() else sv.ghost
	if s.is_empty():
		tip.text = ""
		return
	var id := String(s["i"])
	var d: Dictionary = s.get("d", {})
	var line := ItemDB.label(id, d)
	if d.has("dur"):
		line += "  (%d/%d uses left)" % [int(d["dur"]), ItemDB.max_durability(id, d)]
	if d.has("q") and float(d["q"]) < 0.99:
		line += "  - a little rough"
	var f := ItemDB.food(id)
	if not f.is_empty():
		line += "  ·  food +%d%%" % roundi(float(f.get("hunger", 0.0)) * 100.0)
		if String(f.get("cook", "")) != "":
			line += " (better cooked)"
	var fu := ItemDB.fuel(id)
	if fu != "":
		line += "  ·  %s" % ("tinder" if fu == "tinder" else "fuel")
	tip.text = line + "\n" + ItemDB.desc(id) + "\n[H: its handbook page   1-9: swap onto that hotbar slot]"


func _unhandled_input(event: InputEvent) -> void:
	## Over a slot: H opens that item's handbook page, a number key swaps the
	## slot with that hotbar slot.
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	var sv: SlotView = slots.get(_hover)
	if sv == null or not sv.highlight:
		return
	if event.is_action_pressed("guide"):
		if sv.stack.is_empty():
			return
		Guide.last_page = "item:" + String(sv.stack["i"])
		var hud = get_meta("hud") if has_meta("hud") else null
		if hud:
			hud.open_panel("handbook")
		get_viewport().set_input_as_handled()
		return
	for i in Inventory.HOTBAR:
		if event.is_action_pressed("hotbar_%d" % (i + 1)):
			if _hover < Inventory.CURSOR:
				World.request("inv_swap", {"slot": _hover, "i": i})
				Sfx.ui("ui_click", -16.0)
			get_viewport().set_input_as_handled()
			return


func _process(_delta: float) -> void:
	cursor.position = get_local_mouse_position() - Vector2(26, 26)
	cursor.queue_redraw()


func _draw_cursor() -> void:
	var s := World.my_inventory.get_slot(Inventory.CURSOR)
	if s.is_empty():
		return
	SlotView.draw_item(cursor, s, Rect2(Vector2.ZERO, cursor.size))
