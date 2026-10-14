class_name BuildMenu
extends Control
## Blueprint selection (B).  Choosing a blueprint doesn't build anything: it
## lets you position a frame in the world, which you then complete by bringing
## the materials to it, part by part.

var hud: Node
var detail: VBoxContainer
var _selected := ""

const ORDER := ["platform", "post", "railing", "ladder", "wall", "doorway", "roof", "shelf", "sleeping_mat"]


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var dim := ColorRect.new()
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0, 0, 0, 0.35)
	add_child(dim)
	var pc := PanelContainer.new()
	pc.set_anchors_preset(Control.PRESET_CENTER)
	pc.offset_left = -470
	pc.offset_right = 470
	pc.offset_top = -280
	pc.offset_bottom = 280
	pc.add_theme_stylebox_override("panel", UITheme.panel(UITheme.BG_SOLID, 14, UITheme.LINE, 22))
	add_child(pc)
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 12)
	pc.add_child(root)
	var head := HBoxContainer.new()
	head.add_child(UITheme.title_label("Build", 30))
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(sp)
	head.add_child(UITheme.button("Take apart...", _dismantle, 150))
	root.add_child(head)
	var hint := UITheme.label("Pick a blueprint and set its frame down where you want it. Then bring the materials to the frame - each part goes in by hand.", 14, UITheme.TEXT_DIM)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(hint)
	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 16)
	root.add_child(body)
	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 8)
	body.add_child(grid)
	for id in ORDER:
		var bp := ItemDB.blueprint(id)
		if bp.is_empty():
			continue
		var b := Button.new()
		b.text = String(bp.get("name", id))
		b.custom_minimum_size = Vector2(170, 64)
		b.add_theme_font_size_override("font_size", 15)
		b.pressed.connect(_select.bind(id))
		b.mouse_entered.connect(_select.bind(id))
		grid.add_child(b)
	detail = VBoxContainer.new()
	detail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	detail.add_theme_constant_override("separation", 8)
	body.add_child(detail)
	_select(ORDER[0])


func _select(id: String) -> void:
	if id == _selected:
		return
	_selected = id
	for c in detail.get_children():
		c.queue_free()
	var bp := ItemDB.blueprint(id)
	detail.add_child(UITheme.label(String(bp.get("name", id)), 22, UITheme.ACCENT, true))
	var desc := UITheme.label(String(bp.get("desc", "")), 15, UITheme.TEXT)
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.custom_minimum_size.x = 340
	detail.add_child(desc)
	detail.add_child(UITheme.label("Materials", 15, UITheme.PAPER, true))
	var totals := ItemDB.blueprint_totals(id)
	for k in totals:
		var have := 0
		var names: PackedStringArray = []
		for item in String(k).split("|"):
			have += World.my_inventory.count(item)
			names.append(ItemDB.display_name(item).to_lower())
		var need := int(totals[k])
		var ok := have >= need
		var l := UITheme.label("%s  %d / %d" % [" or ".join(names), mini(have, need), need], 14, UITheme.TEXT if ok else Color(1.0, 0.72, 0.55))
		detail.add_child(l)
	var note := ""
	match String(bp.get("kind", "")):
		"floor":
			note = "Snaps to the edges of other platforms. Two steps out from solid ground it starts to creak; a post or brace beneath steadies it."
		"post":
			note = "Aim under a platform corner. Where the corner hangs over the abyss it slants back to the cliff as a brace."
		"edge":
			note = "Snaps along platform edges."
		"wall":
			note = "Snaps along platform edges, or stands on the ground. Walls keep wind and cold out."
		"roof":
			note = "Sits on top of walls around a platform. A roof keeps rain and cold off."
		"ladder":
			note = "Aim at a wall or a platform edge to lean it there."
	if bool(bp.get("bed", false)):
		note = "Sleep on it to rest - and to wake here after a misfortune."
	if note != "":
		var nl := UITheme.label(note, 13, UITheme.TEXT_DIM)
		nl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		nl.custom_minimum_size.x = 340
		detail.add_child(nl)
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	detail.add_child(spacer)
	detail.add_child(UITheme.button("Place this frame", _place, 240))


func _place() -> void:
	var p: LocalPlayer = Game.game_world.local_player()
	var id := _selected
	hud.close_panel()
	if p:
		p.placer.start_place(id)
		Events.hint.emit("building")


func _dismantle() -> void:
	var p: LocalPlayer = Game.game_world.local_player()
	hud.close_panel()
	if p:
		p.placer.start_dismantle()
