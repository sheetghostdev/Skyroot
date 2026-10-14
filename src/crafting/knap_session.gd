extends CraftSession
## Knapping close-up.  The stone lies on the anvil; a faint chalk outline shows
## the form you're aiming for.  Aim at the edge:
##   tap LMB   - a fine pressure flake: thins and sharpens the edge there
##   hold LMB  - a heavy blow: knocks off a big flake to reshape the outline
##   RMB       - turn the stone over to work the other face
##   1/2/3     - choose the form (blade / axe head / digging blade)

const CHARGE_TIME := 0.55

var outline_mi: MeshInstance3D
var marker: MeshInstance3D
var hammer: MeshInstance3D
var _charging := false
var _charge := 0.0
var _hover := Vector3.ZERO
var _hover_ok := false
var _eval: Dictionary = {}
var _hammer_t := 1.0
var _strike_at := Vector3.ZERO


func _start() -> void:
	outline_mi = MeshInstance3D.new()
	var om := StandardMaterial3D.new()
	om.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	om.albedo_color = Color(1.0, 0.97, 0.88, 0.75)
	om.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	om.no_depth_test = false
	outline_mi.material_override = om
	outline_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(outline_mi)
	marker = MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.0035
	sm.height = 0.007
	marker.mesh = sm
	var mm := StandardMaterial3D.new()
	mm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mm.albedo_color = Color(1.0, 0.75, 0.35)
	marker.material_override = mm
	add_child(marker)
	hammer = MeshInstance3D.new()
	hammer.mesh = ProcMesh.stone(4242)
	hammer.material_override = Models.material_for("Stone")
	hammer.scale = Vector3.ONE * 0.8
	add_child(hammer)
	_rebuild_outline()
	_reeval()


func camera_xf() -> Transform3D:
	return xf_from(Vector3(0.0, 0.3, 0.2), Vector3(0.0, 0.02, 0.0))


func camera_fov() -> float:
	return 40.0


func hint_text() -> String:
	return "Aim at the edge  ·  tap LMB: fine flake (sharpen)  ·  hold LMB: heavy blow (reshape)  ·  RMB: turn over  ·  1 2 3: choose form  ·  Enter: finish  ·  Esc: step away"


func _params() -> Dictionary:
	return Knap.params(int(data().get("seed", 1)))


func _thickness_c() -> float:
	return float(_params()["c"])


func _to_stone(local: Vector3) -> Vector2:
	var flipped := bool(data().get("flipped", false))
	return Vector2(local.x, -local.z if flipped else local.z)


func _from_stone(p: Vector2, y: float) -> Vector3:
	var flipped := bool(data().get("flipped", false))
	return Vector3(p.x, y, -p.y if flipped else p.y)


func _rebuild_outline() -> void:
	var d := data()
	var target := String(d.get("target", "blade"))
	var poly := Knap.target_poly(_params(), target)
	var im := ImmediateMesh.new()
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	var n := poly.size()
	for i in n:
		var a := poly[i]
		var b := poly[(i + 1) % n]
		# dashed chalk line
		var segs := 6
		for s in segs:
			if s % 2 == 1:
				continue
			var p0 := a.lerp(b, float(s) / segs)
			var p1 := a.lerp(b, float(s + 1) / segs)
			im.surface_add_vertex(_from_stone(p0, 0.0015))
			im.surface_add_vertex(_from_stone(p1, 0.0015))
	# working edge highlighted
	for seg in Knap.TARGETS[target]["edge"]:
		var pa := Vector2(seg[0][0] * _params()["a"] * 0.95, seg[0][1] * _params()["b"] * 0.95)
		var pb := Vector2(seg[1][0] * _params()["a"] * 0.95, seg[1][1] * _params()["b"] * 0.95)
		for k in 3:
			var off := float(k) * 0.0007
			im.surface_add_vertex(_from_stone(pa, 0.0018 + off))
			im.surface_add_vertex(_from_stone(pb, 0.0018 + off))
	im.surface_end()
	outline_mi.mesh = im


func _reeval() -> void:
	var d := data()
	_eval = Knap.evaluate(int(d.get("seed", 1)), d.get("cuts", []), String(d.get("target", "blade")), 18)


func _changed(keys: Array) -> void:
	if keys.has("target") or keys.has("flipped"):
		_rebuild_outline()
	if keys.has("cuts") or keys.has("target"):
		_reeval()


func handle_input(event: InputEvent) -> bool:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed and _hover_ok:
				_charging = true
				_charge = 0.0
			elif not event.pressed and _charging:
				_charging = false
				_strike()
			return true
		if event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
			send(["flip"])
			return true
		if event.pressed and (event.button_index == MOUSE_BUTTON_WHEEL_UP or event.button_index == MOUSE_BUTTON_WHEEL_DOWN):
			var order := ["blade", "axe", "digger"]
			var i := order.find(String(data().get("target", "blade")))
			i = (i + (1 if event.button_index == MOUSE_BUTTON_WHEEL_DOWN else 2)) % 3
			send(["target", order[i]])
			return true
	if event is InputEventKey and event.pressed and not event.echo:
		match event.physical_keycode:
			KEY_1:
				send(["target", "blade"])
				return true
			KEY_2:
				send(["target", "axe"])
				return true
			KEY_3:
				send(["target", "digger"])
				return true
	return false


func _strike() -> void:
	var power := clampf(_charge / CHARGE_TIME, 0.0, 1.0)
	var sp := _to_stone(_hover)
	send(["strike", sp.x, sp.y, power])
	_hammer_t = 0.0
	_strike_at = _hover


func _tick(delta: float) -> void:
	var c := _thickness_c()
	var hit = ray_plane_local(c)
	_hover_ok = false
	if hit != null:
		var local: Vector3 = hit
		var sp := _to_stone(local)
		var p := _params()
		var cuts: Array = data().get("cuts", [])
		var dir := sp.normalized() if sp.length() > 0.001 else Vector2.RIGHT
		var edge := Knap.outline_point(p, cuts, dir)
		var dist := sp.length() - edge.length()
		if dist > -0.022 and dist < 0.025:
			_hover_ok = true
			_hover = _from_stone(edge, c)
	marker.visible = _hover_ok
	if _hover_ok:
		marker.position = _hover + Vector3(0, 0.004, 0)
		var s := 1.0 + (_charge / CHARGE_TIME) * 1.6 if _charging else 1.0
		marker.scale = Vector3.ONE * s
	if _charging:
		_charge = minf(_charge + delta, CHARGE_TIME * 1.2)
	# the hammerstone hovers over the aim point, then strikes
	_hammer_t = minf(1.0, _hammer_t + delta * 5.0)
	var rest := (_hover if _hover_ok else Vector3(0.05, c, 0.05)) + Vector3(0.0, 0.05 + (0.025 * _charge / CHARGE_TIME if _charging else 0.0), 0.035)
	var target := rest
	if _hammer_t < 1.0:
		var k := sin(_hammer_t * PI)
		target = rest.lerp(_strike_at + Vector3(0, 0.012, 0.01), k)
	hammer.position = hammer.position.lerp(target, 1.0 - exp(-30.0 * delta))
	hammer.rotation = Vector3(0.4, 0.3, 0.2)


func _draw_overlay() -> void:
	var vs := overlay.get_viewport_rect().size
	var d := data()
	var target := String(d.get("target", "blade"))
	var at := Vector2(vs.x - 250, vs.y * 0.5 - 70)
	draw_text(at + Vector2(0, -26), String(Knap.TARGETS[target]["name"]), 20, UITheme.ACCENT)
	if not _eval.is_empty():
		draw_meter(at + Vector2(0, 16), "Outline", float(_eval["shape"]))
		draw_meter(at + Vector2(0, 52), "Working edge", float(_eval["edge"]))
		var tip := ""
		if float(_eval["coverage"]) < 0.8:
			tip = "Too much stone knocked away."
		elif float(_eval["excess"]) > 0.12:
			tip = "Knock away stone outside the chalk line (hold for heavy blows)."
		elif float(_eval["edge"]) < 0.6:
			tip = "Thin the working edge with light taps - from both faces."
		else:
			tip = "Looks usable. Press Enter to finish, or keep refining."
		draw_text(at + Vector2(0, 84), tip, 14, UITheme.TEXT, 230)
	draw_text(at + Vector2(0, 150), "Strikes: %d%s" % [int(d.get("strikes", 0)), "   (turned over)" if bool(d.get("flipped", false)) else ""], 13, UITheme.TEXT_DIM)
	if _charging:
		var mp := overlay.get_viewport().get_mouse_position()
		var f := clampf(_charge / CHARGE_TIME, 0.0, 1.0)
		overlay.draw_arc(mp, 16, -PI * 0.5, -PI * 0.5 + TAU * f, 32, Color(1, 0.75, 0.35, 0.9), 3.0, true)
		draw_text(mp + Vector2(22, 4), "heavy blow" if f > 0.6 else "light tap", 13)
