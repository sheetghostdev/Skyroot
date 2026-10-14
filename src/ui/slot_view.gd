class_name SlotView
extends Control
## One inventory slot: the item's icon, its count and, for tools, how worn it is.

signal clicked(index: int, button: int, shift: bool)
signal hovered(index: int)

var index := 0
var stack: Dictionary = {}
var selected := false
var compact := false
var highlight := false
var ghost: Dictionary = {}     # what a crafting result would be (drawn faded)
var slot_size := 60.0


func _ready() -> void:
	custom_minimum_size = Vector2(slot_size, slot_size)
	mouse_entered.connect(func(): hovered.emit(index); highlight = true; queue_redraw())
	mouse_exited.connect(func(): highlight = false; queue_redraw())


func set_stack(s: Dictionary) -> void:
	stack = s
	queue_redraw()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and (event.button_index == MOUSE_BUTTON_LEFT or event.button_index == MOUSE_BUTTON_RIGHT):
		clicked.emit(index, 0 if event.button_index == MOUSE_BUTTON_LEFT else 1, event.shift_pressed)
		accept_event()


func _draw() -> void:
	var r := Rect2(Vector2.ZERO, size)
	var bg := Color(0.07, 0.065, 0.055, 0.6 if compact else 0.82)
	var border := Color(UITheme.ACCENT, 0.95) if selected else (Color(1, 1, 1, 0.3) if highlight else Color(1, 0.9, 0.7, 0.12))
	var sb := UITheme.panel(bg, 6, border, 0)
	sb.set_border_width_all(2 if selected else 1)
	draw_style_box(sb, r)
	var s := stack if not stack.is_empty() else ghost
	if s.is_empty():
		return
	draw_item(self, s, Rect2(Vector2(5, 5), size - Vector2(10, 10)), 1.0 if not stack.is_empty() else 0.4)


static func draw_item(ci: CanvasItem, s: Dictionary, rect: Rect2, alpha: float = 1.0) -> void:
	var id := String(s.get("i", ""))
	var d: Dictionary = s.get("d", {})
	var tex := Icons.texture(id, d)
	if tex:
		ci.draw_texture_rect(tex, rect, false, Color(1, 1, 1, alpha))
	else:
		ci.draw_string(UITheme.font_bold(), rect.position + Vector2(0, rect.size.y * 0.6), ItemDB.label(id).substr(0, 3), HORIZONTAL_ALIGNMENT_CENTER, rect.size.x, 14, UITheme.PAPER)
	var n := int(s.get("n", 1))
	var f := UITheme.font_bold()
	if n > 1:
		var t := str(n)
		var p := rect.position + Vector2(0, rect.size.y + 1)
		ci.draw_string_outline(f, p, t, HORIZONTAL_ALIGNMENT_RIGHT, rect.size.x + 2, 15, 4, Color(0, 0, 0, 0.85 * alpha))
		ci.draw_string(f, p, t, HORIZONTAL_ALIGNMENT_RIGHT, rect.size.x + 2, 15, Color(UITheme.PAPER, alpha))
	if d.has("dur"):
		var mx := maxf(1.0, ItemDB.max_durability(id, d))
		var k := clampf(float(d["dur"]) / mx, 0.0, 1.0)
		if k < 0.999:
			var w := rect.size.x * k
			var y := rect.end.y - 2
			ci.draw_rect(Rect2(rect.position.x, y, rect.size.x, 3), Color(0, 0, 0, 0.6))
			ci.draw_rect(Rect2(rect.position.x, y, w, 3), Color(0.55, 0.85, 0.4).lerp(Color(0.9, 0.3, 0.25), 1.0 - k))
	if id == "pot" and int(d.get("w", 0)) > 0:
		var h := rect.size.y * int(d["w"]) / 3.0
		ci.draw_rect(Rect2(rect.end.x - 2, rect.end.y - h, 3, h), UITheme.WATER)
