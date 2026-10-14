class_name ChooserUI
extends Control
## Pick what to make from a stone laid down for knapping or a lump of clay:
## a row of shapes, each with its icon and a picture of its outline.

var kind := "knap"
var cell := Vector3i.ZERO


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var dim := ColorRect.new()
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0, 0, 0, 0.3)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(dim)
	var pc := PanelContainer.new()
	pc.set_anchors_preset(Control.PRESET_CENTER)
	pc.offset_left = -360
	pc.offset_right = 360
	pc.offset_top = -170
	pc.offset_bottom = 170
	pc.add_theme_stylebox_override("panel", UITheme.panel(UITheme.BG_SOLID, 12, UITheme.LINE, 20))
	add_child(pc)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 12)
	pc.add_child(v)
	var title := "What will you knap?" if kind == "knap" else "What will you shape?"
	v.add_child(UITheme.label(title, 22, UITheme.PAPER, true))
	var sub := "Chip away the tinted cells and keep the shape. Chip into the shape more than twice and the stone splits." if kind == "knap" \
		else "Build it up one layer at a time: right click adds clay, left click removes it, F changes the brush. Each lump of clay is worth 32 cells."
	var sl := UITheme.label(sub, 14, UITheme.TEXT_DIM)
	sl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(sl)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	v.add_child(row)
	var recipes: Dictionary = ItemDB.knapping if kind == "knap" else ItemDB.clayforming
	for r in recipes:
		row.add_child(_card(String(r), recipes[r]))
	var close := UITheme.button("Not now", _close, 140)
	close.size_flags_horizontal = Control.SIZE_SHRINK_END
	v.add_child(close)


func _card(r: String, def: Dictionary) -> Control:
	var b := Button.new()
	b.custom_minimum_size = Vector2(150, 170)
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(_choose.bind(r))
	var out := r if kind == "knap" else String(def["out"])
	var mask: PackedByteArray = def["mask"] if kind == "knap" else _top_view(def["layers"])
	var pic := Control.new()
	pic.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pic.set_anchors_preset(Control.PRESET_FULL_RECT)
	pic.draw.connect(func():
		var cs := 5.0
		var o := Vector2((150 - 16 * cs) * 0.5, 12)
		for z in 16:
			for x in 16:
				var on := mask[x + z * 16] == 1
				pic.draw_rect(Rect2(o + Vector2(x, z) * cs, Vector2(cs - 0.5, cs - 0.5)), Color(0.85, 0.8, 0.7, 0.95) if on else Color(1, 1, 1, 0.06))
		var tex := Icons.texture(out, {"mat": "flint"} if kind == "knap" else {})
		if tex:
			pic.draw_texture_rect(tex, Rect2(Vector2(108, 70), Vector2(36, 36)), false)
		pic.draw_string(UITheme.font_bold(), Vector2(0, 116), String(def["label"]), HORIZONTAL_ALIGNMENT_CENTER, 150, 15, UITheme.PAPER)
		if kind == "clay":
			var cells := 0
			for l in def["layers"]:
				cells += (l as PackedByteArray).count(1)
			pic.draw_string(UITheme.font(), Vector2(0, 136), "%d layers, ~%d clay" % [(def["layers"] as Array).size(), int(ceil(cells / float(ItemDB.CLAY_PER_LUMP)))], HORIZONTAL_ALIGNMENT_CENTER, 150, 12, UITheme.TEXT_DIM)
		else:
			pic.draw_string(UITheme.font(), Vector2(0, 136), "%d cells to chip" % _to_chip(mask), HORIZONTAL_ALIGNMENT_CENTER, 150, 12, UITheme.TEXT_DIM)
	)
	b.add_child(pic)
	return b


func _to_chip(mask: PackedByteArray) -> int:
	var n := 0
	for i in 256:
		if ItemDB.stone_mask[i] == 1 and mask[i] == 0:
			n += 1
	return n


func _top_view(layers: Array) -> PackedByteArray:
	var m := PackedByteArray()
	m.resize(256)
	for l in layers:
		for i in 256:
			if (l as PackedByteArray)[i] == 1:
				m[i] = 1
	return m


func _choose(r: String) -> void:
	World.request("knap_choose" if kind == "knap" else "clay_choose", {"c": cell, "r": r})
	Sfx.ui("ui_click", -10.0)
	_close()


func _close() -> void:
	var hud = get_meta("hud", null)
	if hud:
		hud.close_panel()
