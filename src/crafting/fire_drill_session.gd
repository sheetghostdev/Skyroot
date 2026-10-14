extends CraftSession
## The hand drill: a straight stick spun between the palms, its tip in the
## notch of a hearth board.  Hold LMB and sweep the mouse left and right -
## fast, steady strokes.  Friction heats the wood; black dust gathers in the
## notch, smoke curls up, and if you keep the heat up long enough the dust
## glows: an ember.  Tip it into a tinder bundle (Enter) and blow it to flame.

var _spinning := false
var _px := 0.0                # pixels of mouse travel since the last send
var _angle := 0.0
var _send_t := 0.0
var _speed := 0.0


func camera_xf() -> Transform3D:
	return xf_from(Vector3(0.0, 0.42, 0.34), Vector3(0.0, 0.1, 0.0))


func camera_fov() -> float:
	return 46.0


func hint_text() -> String:
	return "Hold LMB and sweep the mouse left-right, fast and steady  ·  Enter: tip the ember into tinder  ·  Esc: step away"


func handle_input(event: InputEvent) -> bool:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_spinning = event.pressed
		if not _spinning:
			send(["stop"])
		return true
	if event is InputEventMouseMotion and _spinning:
		var dx: float = event.relative.x
		_px += absf(dx)
		_angle += dx * 0.06
		return true
	return false


func _tick(delta: float) -> void:
	_send_t -= delta
	if _send_t <= 0.0:
		var span := 0.1 - _send_t
		_send_t = 0.1
		var sp := clampf(_px / maxf(span, 0.02) / 1400.0, 0.0, 1.0) if _spinning else 0.0
		_speed = lerpf(_speed, sp, 0.5)
		if _spinning:
			send(["spin", _speed, span])
		_px = 0.0
	var v = view()
	if v and v.has_method("set_spin"):
		v.set_spin(_angle, _speed)


func _tinder_text() -> String:
	var inv := World.my_inventory
	for t in ActionsFire.TINDER:
		if inv.count(t) >= int(ActionsFire.TINDER[t]):
			return "Tinder ready: %s." % ItemDB.display_name(t).to_lower()
	return "No tinder! You'll need 2 straw or 3 plant fibres for the ember."


func _draw_overlay() -> void:
	var vs := overlay.get_viewport_rect().size
	var d := data()
	var at := Vector2(vs.x - 260, vs.y * 0.5 - 60)
	draw_text(at + Vector2(0, -26), "Fire drill", 20, UITheme.ACCENT)
	var heat := float(d.get("heat", 0.0))
	draw_meter(at + Vector2(0, 16), "Friction heat", heat)
	draw_meter(at + Vector2(0, 52), "Spin", _speed)
	var ember := float(d.get("ember", 0.0))
	var tip := ""
	if ember > 0.0:
		tip = "An ember is glowing in the notch! Press Enter to tip it into your tinder (%ds)." % int(ceil(ember))
	elif heat > 0.85:
		tip = "Smoking hard - keep it up..."
	elif heat > 0.4:
		tip = "Smoke! Faster, and don't stop."
	elif _speed < 0.3 and _spinning:
		tip = "Faster - long, quick sweeps."
	else:
		tip = "Spin the stick: hold the left button and sweep the mouse side to side."
	draw_text(at + Vector2(0, 86), tip, 14, UITheme.PAPER if ember > 0.0 else UITheme.TEXT, 240)
	draw_text(at + Vector2(0, 150), _tinder_text(), 13, UITheme.TEXT_DIM, 240)
