extends CraftSession
## Preparing raw clay.  Knead (press LMB and drag down, release to fold) to
## work out grit and even the moisture; RMB splashes in water (from the pond if
## you're beside it, or a vessel you carry).  Enter when it's smooth and evenly
## damp.

var _pressing := false
var _press := 0.0
var _press_start := Vector2.ZERO
var _press_amt := 0.0


func camera_xf() -> Transform3D:
	return xf_from(Vector3(0.0, 0.22, 0.26), Vector3(0.0, 0.03, 0.0))


func camera_fov() -> float:
	return 42.0


func hint_text() -> String:
	return "Knead: press LMB and drag down, release to fold  ·  RMB: splash in water  ·  Enter: done  ·  Esc: step away"


func handle_input(event: InputEvent) -> bool:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				_pressing = true
				_press_start = event.position
				_press_amt = 0.0
			elif _pressing:
				_pressing = false
				if _press_amt > 0.08:
					send(["knead", clampf(_press_amt, 0.2, 1.0)])
			return true
		if event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
			send(["water"])
			return true
	if event is InputEventMouseMotion and _pressing:
		_press_amt = clampf((event.position.y - _press_start.y) / 140.0, 0.0, 1.0)
		return true
	return false


func _tick(delta: float) -> void:
	var target := _press_amt if _pressing else 0.0
	_press = lerpf(_press, target, 1.0 - exp(-18.0 * delta))
	var v = view()
	if v and v.has_method("set_press"):
		v.set_press(_press)


func _draw_overlay() -> void:
	var vs := overlay.get_viewport_rect().size
	var d := data()
	var at := Vector2(vs.x - 260, vs.y * 0.5 - 60)
	draw_text(at + Vector2(0, -26), "Preparing clay  (%.2f L)" % float(d.get("vol", 0.0)), 19, UITheme.ACCENT)
	var m := float(d.get("moist", 0.17))
	draw_meter(at + Vector2(0, 16), "Moisture  (dry … wet)", clampf((m - 0.1) / 0.25, 0.0, 1.0), 0.4, 0.84)
	draw_meter(at + Vector2(0, 52), "Evenness", float(d.get("homog", 0.0)))
	var tip := ""
	if m < 0.19:
		tip = "Too dry - it cracks and crumbles as you knead. Add water (RMB)."
	elif m > 0.31:
		tip = "Too wet and sticky. Keep kneading to work water out."
	elif float(d.get("homog", 0.0)) < 0.85:
		tip = "Good moisture. Keep kneading until it's smooth."
	else:
		tip = "Smooth and evenly damp. Press Enter."
	draw_text(at + Vector2(0, 84), tip, 14, UITheme.TEXT, 240)
