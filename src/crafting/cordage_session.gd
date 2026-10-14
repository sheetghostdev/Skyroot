extends CraftSession
## Twisting cordage: two bundles of fibre, rolled under the palm.  Hold LMB and
## roll the mouse steadily left and right; each stroke twists the strands and
## the cord grows.  Even strokes make even cord.

var _rolling := false
var _travel := 0.0
var _strokes: Array = []      # recent stroke lengths, to judge evenness
var _stroke := 0.0
var _dir := 0.0
var _send_t := 0.0
var _visual_twist := 0.0


func camera_xf() -> Transform3D:
	return xf_from(Vector3(0.05, 0.36, 0.16), Vector3(0.05, 0.0, 0.0))


func camera_fov() -> float:
	return 44.0


func hint_text() -> String:
	return "Hold LMB and roll the mouse left and right with steady strokes  ·  Esc: step away"


func handle_input(event: InputEvent) -> bool:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_rolling = event.pressed
		return true
	if event is InputEventMouseMotion and _rolling:
		var dx: float = event.relative.x
		var d := signf(dx)
		if d != 0.0 and d != _dir:
			if _stroke > 6.0:
				_strokes.append(_stroke)
				while _strokes.size() > 6:
					_strokes.pop_front()
			_stroke = 0.0
			_dir = d
		_stroke += absf(dx)
		_travel += absf(dx)
		_visual_twist += dx * 0.02
		return true
	return false


func _evenness() -> float:
	if _strokes.size() < 2:
		return 0.8
	var mean := 0.0
	for s in _strokes:
		mean += s
	mean /= _strokes.size()
	var v := 0.0
	for s in _strokes:
		v += pow(s - mean, 2.0)
	v = sqrt(v / _strokes.size())
	return clampf(1.0 - v / maxf(mean, 1.0), 0.0, 1.0)


func _tick(delta: float) -> void:
	_send_t -= delta
	if _send_t <= 0.0 and _travel > 0.0:
		_send_t = 0.15
		send(["twist", _travel / 2600.0, _evenness()])
		_travel = 0.0
	var v = view()
	if v and v.has_method("set_twist"):
		v.set_twist(_visual_twist)


func _draw_overlay() -> void:
	var vs := overlay.get_viewport_rect().size
	var d := data()
	var at := Vector2(vs.x - 250, vs.y * 0.5 - 40)
	draw_text(at + Vector2(0, -26), "Twisting cordage", 20, UITheme.ACCENT)
	draw_meter(at + Vector2(0, 16), "Length", float(d.get("prog", 0.0)))
	draw_meter(at + Vector2(0, 52), "Evenness", _evenness())
	draw_text(at + Vector2(0, 84), "Long, steady, even strokes." if _evenness() > 0.6 else "Keep your strokes the same length.", 14, UITheme.TEXT, 230)
