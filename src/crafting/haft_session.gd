extends CraftSession
## Hafting: seat the knapped head against the end of the handle, wind cord
## around the joint, then pull it tight.
##   1. drag the head (LMB) onto the end of the handle; wheel turns it
##   2. hold LMB and circle the mouse around the joint to wind the cord
##   3. hold RMB and pull down to tighten
##   Enter: finish

var _dragging := false
var _seat := Vector3(0.12, 0.0, 0.0)
var _angle := 0.6
var _send_t := 0.0
var _winding := false
var _tighten := false
var _last_ang := 0.0
var _wrap_acc := 0.0
var _tight_acc := 0.0
const JOINT := Vector3(0.21, 0.0, 0.0)


func _start() -> void:
	var d := data()
	_seat = d.get("seat", _seat)
	_angle = float(d.get("angle", _angle))


func camera_xf() -> Transform3D:
	return xf_from(Vector3(0.12, 0.38, 0.2), Vector3(0.12, 0.0, 0.0))


func camera_fov() -> float:
	return 42.0


func hint_text() -> String:
	return "Drag the head onto the handle (wheel turns it)  ·  then hold LMB and circle around the joint to bind  ·  hold RMB and pull down to tighten  ·  Enter: finish  ·  Esc: step away"


func handle_input(event: InputEvent) -> bool:
	var d := data()
	var stage := String(d.get("stage", "seat"))
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if stage == "seat":
				_dragging = event.pressed
				if not event.pressed:
					send(["seat", _seat.x, _seat.z, _angle])
			else:
				_winding = event.pressed
				_last_ang = _mouse_angle()
			return true
		if event.button_index == MOUSE_BUTTON_RIGHT:
			_tighten = event.pressed and stage != "seat"
			return true
		if event.pressed and stage == "seat" and (event.button_index == MOUSE_BUTTON_WHEEL_UP or event.button_index == MOUSE_BUTTON_WHEEL_DOWN):
			_angle += 0.15 if event.button_index == MOUSE_BUTTON_WHEEL_UP else -0.15
			send(["seat", _seat.x, _seat.z, _angle])
			return true
	if event is InputEventMouseMotion:
		if _dragging:
			var hit = ray_plane_local(0.03)
			if hit != null:
				var h: Vector3 = hit
				_seat = Vector3(h.x, 0.0, h.z)
		elif _tighten:
			_tight_acc += maxf(0.0, event.relative.y) / 600.0
		return true
	return false


func _mouse_angle() -> float:
	var c := to_screen(JOINT + Vector3(0, 0.02, 0))
	var mp := overlay.get_viewport().get_mouse_position()
	return atan2(mp.y - c.y, mp.x - c.x)


func _tick(delta: float) -> void:
	if _winding:
		var a := _mouse_angle()
		var da := wrapf(a - _last_ang, -PI, PI)
		_last_ang = a
		_wrap_acc += absf(da) / TAU
	_send_t -= delta
	if _send_t <= 0.0:
		_send_t = 0.12
		if _dragging:
			send(["seat", _seat.x, _seat.z, _angle])
		if _wrap_acc > 0.02:
			send(["wrap", _wrap_acc])
			_wrap_acc = 0.0
		if _tight_acc > 0.01:
			send(["tighten", _tight_acc])
			_tight_acc = 0.0
	var v = view()
	if v and v.has_method("set_local_seat") and _dragging:
		v.set_local_seat(_seat, _angle)


func _draw_overlay() -> void:
	var vs := overlay.get_viewport_rect().size
	var d := data()
	var at := Vector2(vs.x - 250, vs.y * 0.5 - 60)
	var stage := String(d.get("stage", "seat"))
	draw_text(at + Vector2(0, -26), "Hafting", 20, UITheme.ACCENT)
	draw_meter(at + Vector2(0, 16), "Fit", float(d.get("align", 0.0)))
	draw_meter(at + Vector2(0, 52), "Wraps  %d" % int(float(d.get("wraps", 0.0))), clampf(float(d.get("wraps", 0.0)) / 12.0, 0.0, 1.0), 0.45, 0.92)
	draw_meter(at + Vector2(0, 88), "Tightness", float(d.get("tight", 0.0)))
	var tip := ""
	match stage:
		"seat":
			tip = "Drag the head to the end of the handle. Axe: edge in line with the handle. Digging blade: edge across it."
		"bind":
			tip = "Circle the mouse around the joint to wind the cord. Six to eleven turns hold well."
		_:
			tip = "Pull tight (RMB, drag down). Then press Enter."
	draw_text(at + Vector2(0, 120), tip, 14, UITheme.TEXT, 240)
	if stage != "seat":
		var c := to_screen(JOINT + Vector3(0, 0.02, 0))
		overlay.draw_arc(c, 34, 0, TAU, 40, Color(1, 0.9, 0.7, 0.25 if not _winding else 0.6), 2.0, true)
