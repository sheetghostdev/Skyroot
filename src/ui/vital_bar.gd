class_name VitalBar
extends Control
## Compact labelled bar for a survival stat.

var label := ""
var color := Color.WHITE
var value := 1.0
var _shown := 1.0
var _pulse := 0.0


func _process(delta: float) -> void:
	_shown = move_toward(_shown, value, delta * 0.8)
	_pulse += delta * (6.0 if value < 0.2 else 0.0)
	queue_redraw()


func _draw() -> void:
	var w := size.x - 70.0
	var y := size.y * 0.5
	var low := value < 0.2
	var a := 0.75 + (0.25 * sin(_pulse) if low else 0.0)
	# (outlined: it has to read over bright sky and sunlit grass)
	draw_string_outline(UITheme.font_bold(), Vector2(0, y + 5), label, HORIZONTAL_ALIGNMENT_LEFT, 64, 13, 5, Color(0, 0, 0, 0.7))
	draw_string(UITheme.font_bold(), Vector2(0, y + 5), label, HORIZONTAL_ALIGNMENT_LEFT, 64, 13, Color(UITheme.PAPER, 0.95))
	var r := Rect2(66, y - 4, w, 8)
	draw_rect(r, Color(0, 0, 0, 0.45))
	draw_rect(Rect2(r.position, Vector2(w * clampf(_shown, 0.0, 1.0), 8)), Color(color, a))
	draw_rect(r, Color(1, 1, 1, 0.12), false, 1.0)
