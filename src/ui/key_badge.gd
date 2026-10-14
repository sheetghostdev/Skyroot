class_name KeyBadge
extends Control
## A small rounded key cap, e.g. [E] or [LMB].

var text := "E"
var enabled := true


func _ready() -> void:
	var w := 26.0 + maxf(0.0, (text.length() - 1) * 8.0)
	custom_minimum_size = Vector2(w, 24)


func _draw() -> void:
	var sb := UITheme.panel(Color(0.95, 0.9, 0.8, 0.92) if enabled else Color(0.5, 0.48, 0.44, 0.6), 5, Color(0, 0, 0, 0.3), 0)
	draw_style_box(sb, Rect2(Vector2.ZERO, size))
	draw_string(UITheme.font_bold(), Vector2(0, size.y * 0.5 + 5), text, HORIZONTAL_ALIGNMENT_CENTER, size.x, 13, Color(0.12, 0.1, 0.08))
