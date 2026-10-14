class_name Reticle
extends Control
## Small centre dot that opens into a ring when something can be interacted with.

var active := false:
	set(v):
		active = v
		queue_redraw()
var _t := 0.0


func _process(delta: float) -> void:
	var target := 1.0 if active else 0.0
	if absf(_t - target) > 0.001:
		_t = move_toward(_t, target, delta * 8.0)
		queue_redraw()


func _draw() -> void:
	var c := size * 0.5
	var r := lerpf(6.0, 10.0, _t)
	# a small plus
	for d in [Vector2(1, 0), Vector2(0, 1)]:
		draw_line(c - d * 7.0, c + d * 7.0, Color(0, 0, 0, 0.45), 4.0)
	for d in [Vector2(1, 0), Vector2(0, 1)]:
		draw_line(c - d * 6.0, c + d * 6.0, Color(1, 0.97, 0.9, 0.9), 2.0)
	if _t > 0.01:
		draw_arc(c, r, 0, TAU, 32, Color(0, 0, 0, 0.35 * _t), 3.0, true)
		draw_arc(c, r, 0, TAU, 32, Color(1, 0.95, 0.85, 0.85 * _t), 1.5, true)
