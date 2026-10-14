class_name SlotView
extends Control
## One inventory slot: icon (rendered from the real model), count, wear bar.

signal clicked(index: int, button: int)
signal hovered(index: int)

var index := 0
var stack: Dictionary = {}
var selected := false
var compact := false
var icons: IconCache
var highlight := false


func _ready() -> void:
	custom_minimum_size = Vector2(58, 58) if compact else Vector2(66, 66)
	mouse_entered.connect(func(): hovered.emit(index); highlight = true; queue_redraw())
	mouse_exited.connect(func(): highlight = false; queue_redraw())


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		clicked.emit(index, event.button_index)
		accept_event()


func _draw() -> void:
	var r := Rect2(Vector2.ZERO, size)
	var bg := Color(0.08, 0.075, 0.065, 0.62 if compact else 0.8)
	var sb := UITheme.panel(bg, 8, Color(UITheme.ACCENT, 0.95) if selected else (Color(1, 1, 1, 0.22) if highlight else Color(1, 0.9, 0.7, 0.1)), 0)
	sb.set_border_width_all(2 if selected else 1)
	draw_style_box(sb, r)
	if not compact and index < Inventory.HOTBAR:
		draw_string(UITheme.font(), Vector2(5, 14), str(index + 1), HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(1, 1, 1, 0.35))
	if stack.is_empty():
		return
	var id := String(stack.get("i", ""))
	var d: Dictionary = stack.get("d", {})
	var tex: Texture2D = icons.get_icon(id, d) if icons else null
	var pad := 6.0
	if tex:
		draw_texture_rect(tex, Rect2(Vector2(pad, pad), size - Vector2(pad, pad) * 2.0), false)
	else:
		var nm := ItemDB.display_name(id, d)
		draw_circle(size * 0.5, size.x * 0.28, Color(0.5, 0.42, 0.32, 0.8))
		draw_string(UITheme.font_bold(), Vector2(0, size.y * 0.5 + 6), nm.substr(0, 2), HORIZONTAL_ALIGNMENT_CENTER, size.x, 16, UITheme.PAPER)
	var n := int(stack.get("n", 1))
	if n > 1:
		var t := str(n)
		var f := UITheme.font_bold()
		draw_string_outline(f, Vector2(0, size.y - 6), t, HORIZONTAL_ALIGNMENT_RIGHT, size.x - 6, 15, 4, Color(0, 0, 0, 0.8))
		draw_string(f, Vector2(0, size.y - 6), t, HORIZONTAL_ALIGNMENT_RIGHT, size.x - 6, 15, UITheme.PAPER)
	if d.has("dur"):
		var w := (size.x - 12) * clampf(float(d["dur"]), 0.0, 1.0)
		draw_rect(Rect2(6, size.y - 6, size.x - 12, 3), Color(0, 0, 0, 0.5))
		draw_rect(Rect2(6, size.y - 6, w, 3), Color(0.55, 0.85, 0.4).lerp(Color(0.9, 0.3, 0.25), 1.0 - float(d["dur"])))
	if id == "pot" and float(d.get("water", 0.0)) > 0.0:
		var cap := maxf(0.01, Pottery.capacity(d))
		var h := (size.y - 16) * clampf(float(d["water"]) / cap, 0.0, 1.0)
		draw_rect(Rect2(size.x - 7, size.y - 8 - h, 3, h), UITheme.WATER)
