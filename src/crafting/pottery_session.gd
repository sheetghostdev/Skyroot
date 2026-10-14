extends CraftSession
## Shaping a vessel by hand.  The gesture depends on where you take hold:
##   outer wall + LMB drag   - left/right: narrow / widen there;  up: pull clay upward (taller, thinner walls)
##   top centre + LMB drag   - press down to open and deepen the hollow; drag outward to widen it
##   rim + LMB drag          - outward flares the rim; down compresses and strengthens it
##   RMB drag                - smooth with wet hands (evens walls, removes lumps)
##   hold T + click          - cut the top off at that height (scraps come back as clay)
##   R                       - add another lump of prepared clay
##   mouse wheel             - turn the pot;  W / S - look from higher / lower

const SEND_HZ := 25.0
const BAT_Y := 0.014

var pot: Dictionary = {}
var _idle := 1.0
var _grab := ""
var _grab_y := 0.5
var _side := 1.0
var _acc := Vector2.ZERO        # accumulated drag (meters / fractions) not yet sent
var _hollow_depth := 0.0
var _hollow_open := 0.3
var _send_t := 0.0
var _hover := {}
var _rot := 0.0
var _elev := 0.0
var _trim_mode := false
var _hands: Array = []          # [right, left]
var _hand_pose := ["", ""]
var _cut_line: MeshInstance3D
var _last_mouse := Vector2.ZERO
var _smooth_speed := 0.0


func _start() -> void:
	pot = data().get("pot", {}).duplicate(true)
	_hands = [_make_hand("R"), _make_hand("L")]
	for h in _hands:
		add_child(h)
		h.visible = false
	_cut_line = MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = 0.98
	tm.outer_radius = 1.0
	tm.rings = 48
	_cut_line.mesh = tm
	var cm := StandardMaterial3D.new()
	cm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	cm.albedo_color = Color(1.0, 0.85, 0.5, 0.9)
	cm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_cut_line.material_override = cm
	_cut_line.visible = false
	add_child(_cut_line)
	var v = view()
	if v and v.has_method("set_local_pot"):
		v.set_local_pot(pot)


func _end() -> void:
	var v = view()
	if v and v.has_method("set_local_pot"):
		v.set_local_pot({})


func _make_hand(side: String) -> Node3D:
	var root := Node3D.new()
	var src := Models.instance("res://assets/models/character/fp_arm_%s.glb" % side.to_lower())
	if src:
		root.add_child(src)
		root.set_meta("poses", {
			"open": src.find_child("HandOpen_%s" % side, true, false),
			"grip": src.find_child("HandGrip_%s" % side, true, false),
			"pinch": src.find_child("HandPinch_%s" % side, true, false)})
	else:
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(0.08, 0.03, 0.1)
		mi.mesh = ProcMesh.painted(bm, Color(0.88, 0.68, 0.53))
		mi.material_override = Models.material_for("Skin")
		mi.position = Vector3(0, 0, -0.32)
		root.add_child(mi)
		root.set_meta("poses", {})
	for mi2 in Models.mesh_instances(root):
		mi2.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return root


func _set_pose(i: int, pose: String) -> void:
	if _hand_pose[i] == pose:
		return
	_hand_pose[i] = pose
	var poses: Dictionary = _hands[i].get_meta("poses", {})
	for k in poses:
		if poses[k]:
			poses[k].visible = k == pose


func camera_xf() -> Transform3D:
	var h := float(pot.get("h", 0.08))
	var look_y := BAT_Y + h * 0.45
	var e := clampf(_elev, -0.15, 0.9)
	var dist := 0.17 + h * 1.7 + float(Pottery.stats(pot).get("max_r", 0.05)) * 2.2
	return xf_from(Vector3(0.0, look_y + 0.06 + e * 0.3 * dist, dist * (1.0 - e * 0.35)), Vector3(0.0, look_y, 0.0))


func camera_fov() -> float:
	return 40.0


func hint_text() -> String:
	return "LMB on wall: narrow / widen / pull up  ·  LMB on top: open & deepen  ·  LMB on rim: shape rim  ·  RMB: smooth  ·  T+click: trim  ·  R: add clay  ·  Wheel: turn  ·  W/S: view  ·  Enter: finish"


# ---------------------------------------------------------------------------
# Hit testing on the surface of revolution
# ---------------------------------------------------------------------------

func _radii_at(h: float) -> Vector2:
	var hh := float(pot["h"])
	var f := clampf(h / hh, 0.0, 1.0) * (Pottery.N - 1)
	var i := clampi(int(floor(f)), 0, Pottery.N - 2)
	var t := f - i
	var ro: PackedFloat32Array = pot["ro"]
	var ri: PackedFloat32Array = pot["ri"]
	return Vector2(lerpf(ro[i], ro[i + 1], t), lerpf(ri[i], ri[i + 1], t))


func _pick() -> Dictionary:
	var r := mouse_ray()
	var inv := global_transform.affine_inverse()
	var o: Vector3 = inv * (r[0] as Vector3)
	var d: Vector3 = (inv.basis * (r[1] as Vector3)).normalized()
	var hh := float(pot["h"])
	var maxr := float(Pottery.stats(pot)["max_r"]) + 0.01
	# march across the bounding cylinder
	var t0 := 0.0
	var t1 := o.distance_to(Vector3(0, BAT_Y + hh * 0.5, 0)) + maxr * 2.0 + hh
	var steps := 240
	var prev_inside := false
	for s in steps:
		var t := lerpf(t0, t1, float(s) / steps)
		var p := o + d * t
		var h := p.y - BAT_Y
		if h < 0.0 or h > hh + 0.002:
			continue
		var rho := Vector2(p.x, p.z).length()
		var rr := _radii_at(h)
		var inside := rho <= rr.x and rho >= rr.y
		if inside and not prev_inside:
			var zone := "shape"
			var top_band := h > hh - 0.006
			if top_band:
				if rr.y > 0.0005:
					zone = "rim"
				else:
					zone = "hollow" if rho < rr.x * 0.62 else "rim"
			elif rr.y > 0.0005 and rho < (rr.x + rr.y) * 0.5:
				zone = "inner"
			var n := Vector3(p.x, 0, p.z).normalized() if rho > 0.0005 else Vector3(1, 0, 0)
			return {"pos": p, "h": h, "y_frac": clampf(h / hh, 0.0, 1.0), "zone": zone, "n": n, "rho": rho}
		prev_inside = inside
	# looking into the opening of a hollow pot
	if Pottery.is_hollow(pot):
		var top := o + d * ((BAT_Y + hh - o.y) / d.y) if absf(d.y) > 1e-4 else o
		var rr2 := _radii_at(hh)
		if Vector2(top.x, top.z).length() < rr2.y:
			return {"pos": top, "h": hh, "y_frac": 1.0, "zone": "hollow", "n": Vector3.UP, "rho": 0.0}
	return {}


# ---------------------------------------------------------------------------
# Input
# ---------------------------------------------------------------------------

func handle_input(event: InputEvent) -> bool:
	if event is InputEventKey:
		if event.physical_keycode == KEY_T:
			_trim_mode = event.pressed
			return true
		if event.pressed and not event.echo:
			match event.physical_keycode:
				KEY_R:
					send(["add"])
					return true
				KEY_W:
					_elev = clampf(_elev + 0.25, -0.15, 0.9)
					return true
				KEY_S:
					_elev = clampf(_elev - 0.25, -0.15, 0.9)
					return true
	if event is InputEventMouseButton:
		if event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_rot += 0.25
			return true
		if event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_rot -= 0.25
			return true
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				_hover = _pick()
				if _hover.is_empty():
					return true
				if _trim_mode:
					send(["trim", float(_hover["y_frac"])])
					_idle = 0.0
					return true
				_begin_grab(String(_hover["zone"]))
			else:
				_end_grab()
			return true
		if event.button_index == MOUSE_BUTTON_RIGHT:
			if event.pressed:
				_hover = _pick()
				if not _hover.is_empty():
					_grab = "smooth"
					_grab_y = float(_hover["y_frac"])
			else:
				_end_grab()
			return true
	if event is InputEventMouseMotion and _grab != "":
		_drag(event.relative)
		return true
	return false


func _begin_grab(zone: String) -> void:
	_grab = zone
	_grab_y = float(_hover.get("y_frac", 0.5))
	var axis := to_screen(Vector3(0, BAT_Y + float(pot["h"]) * 0.5, 0))
	var gp := to_screen(_hover["pos"])
	_side = 1.0 if gp.x >= axis.x else -1.0
	_acc = Vector2.ZERO
	if zone == "hollow":
		var s := Pottery.stats(pot)
		_hollow_depth = float(s["depth"]) / maxf(0.001, float(pot["h"])) if s["hollow"] else 0.0
		var ro: PackedFloat32Array = pot["ro"]
		var ri: PackedFloat32Array = pot["ri"]
		_hollow_open = ri[Pottery.N - 1] / maxf(0.001, ro[Pottery.N - 1]) if s["hollow"] else 0.35
	Sfx.play("clay_squish", global_position + Vector3(0, 0.05, 0), -10.0)


func _end_grab() -> void:
	_flush(true)
	_grab = ""


func _m_per_px() -> float:
	var cam := ctrl.cam
	var dist := cam.global_position.distance_to(global_position + Vector3(0, float(pot["h"]) * 0.5, 0))
	return 2.0 * dist * tan(deg_to_rad(cam.fov * 0.5)) / maxf(1.0, overlay.get_viewport_rect().size.y)


func _drag(rel: Vector2) -> void:
	var fine := 0.35 if Input.is_key_pressed(KEY_SHIFT) else 1.0
	var mpp := _m_per_px() * fine
	var hh := float(pot["h"])
	match _grab:
		"shape":
			_acc.x += -rel.x * _side * mpp * 0.55       # toward the axis = narrow
			_acc.y += -rel.y * mpp / maxf(hh, 0.02) * 0.45
		"inner":
			_acc.x += -rel.x * _side * mpp * 0.55
			_acc.y += -rel.y * mpp / maxf(hh, 0.02) * 0.45
		"hollow":
			_hollow_depth = clampf(_hollow_depth + rel.y * mpp / maxf(hh, 0.02) * 1.1, 0.0, 0.98)
			_hollow_open = clampf(_hollow_open + absf(rel.x) * mpp / maxf(0.01, float(Pottery.stats(pot)["rim_ro"])) * 0.9, 0.05, 0.92)
			_acc.x = 1.0
		"rim":
			_acc.x += rel.x * _side * mpp * 0.4
			_acc.y += maxf(0.0, rel.y) * mpp * 0.6
		"smooth":
			_smooth_speed += rel.length()
			var hp := _pick()
			if not hp.is_empty():
				_grab_y = float(hp["y_frac"])


func _flush(force: bool) -> void:
	var op: Array = []
	match _grab:
		"shape", "inner":
			if _acc.length() > 0.00005 or force and _acc.length() > 0.0:
				op = ["shape", _grab_y, _acc.x, _acc.y]
		"hollow":
			if _acc.x > 0.0:
				op = ["hollow", _hollow_depth, _hollow_open, 0.0]
		"rim":
			if _acc.length() > 0.00002:
				op = ["rim", _acc.x, _acc.y, 0.0]
		"smooth":
			if _smooth_speed > 1.0:
				op = ["smooth", _grab_y, clampf(_smooth_speed / 60.0, 0.05, 1.0), 0.0]
				_smooth_speed = 0.0
				if randf() < 0.3:
					Sfx.play("clay_smooth", global_position + Vector3(0, 0.06, 0), -12.0)
	_acc = Vector2.ZERO
	if op.is_empty():
		return
	# predict locally for instant feedback; the host applies the same op
	Pottery.apply_op(pot, op)
	var v = view()
	if v and v.has_method("set_local_pot"):
		v.set_local_pot(pot)
	send(op)
	_idle = 0.0


func _changed(keys: Array) -> void:
	if keys.has("pot") and _idle > 0.35:
		pot = data().get("pot", {}).duplicate(true)
		var v = view()
		if v and v.has_method("set_local_pot"):
			v.set_local_pot(pot)


func _tick(delta: float) -> void:
	_idle += delta
	_send_t -= delta
	if _grab != "" and _send_t <= 0.0:
		_send_t = 1.0 / SEND_HZ
		_flush(false)
	if _idle > 0.5 and _idle - delta <= 0.5:
		pot = data().get("pot", {}).duplicate(true)
		var v = view()
		if v and v.has_method("set_local_pot"):
			v.set_local_pot(pot)
	# the bat turns slowly while you work, and with the wheel
	_rot += delta * (0.9 if _grab != "" else 0.15)
	var v2 = view()
	if v2 and v2.has_method("set_turn"):
		v2.set_turn(_rot)
	ctrl.cam.global_transform = ctrl.cam.global_transform.interpolate_with(camera_xf(), 1.0 - exp(-4.0 * delta))
	if _grab == "" or _hover.is_empty():
		_hover = _pick()
	_update_hands(delta)
	_cut_line.visible = _trim_mode and not _hover.is_empty()
	if _cut_line.visible:
		var rr := _radii_at(float(_hover["h"]))
		_cut_line.position = Vector3(0, BAT_Y + float(_hover["h"]), 0)
		_cut_line.scale = Vector3.ONE * (rr.x + 0.004)


func _update_hands(delta: float) -> void:
	var hh := float(pot["h"])
	var zone := _grab if _grab != "" else String(_hover.get("zone", ""))
	var active := _grab != ""
	var y := BAT_Y + clampf(_grab_y if active else float(_hover.get("y_frac", 0.5)), 0.05, 1.0) * hh
	var cam_dir := (global_transform.affine_inverse() * ctrl.cam.global_position)
	var fwd := Vector3(-cam_dir.x, 0, -cam_dir.z).normalized()
	var right := fwd.cross(Vector3.UP).normalized()
	var r := _radii_at(y - BAT_Y)
	var show := not _hover.is_empty() or active
	for i in 2:
		var hand: Node3D = _hands[i]
		var side := 1.0 if i == 0 else -1.0
		var want_vis := show and (zone in ["shape", "inner", "smooth"] or (i == 0 and zone in ["hollow", "rim"]))
		if zone == "smooth" and i == 1:
			want_vis = false
		hand.visible = want_vis
		if not want_vis:
			continue
		var press := 0.004 if active else 0.02
		var p: Vector3
		match zone:
			"hollow":
				_set_pose(i, "pinch")
				p = Vector3(0, BAT_Y + hh + 0.03 - (_hollow_depth * hh * 0.6 if active else 0.0), 0)
			"rim":
				_set_pose(i, "pinch")
				p = right * side * r.x + Vector3(0, BAT_Y + hh + 0.01, 0)
			_:
				_set_pose(i, "open")
				var radius := r.x + press
				if zone == "inner":
					radius = maxf(0.004, r.y - press)
				p = right * side * radius + Vector3(0, y, 0)
		# arms reach in from below the camera, wrist at the contact point
		var cam_local: Vector3 = global_transform.affine_inverse() * ctrl.cam.global_position
		var elbow := cam_local + right * side * 0.2 + Vector3(0, -0.26, 0) + (p - cam_local).normalized() * 0.05
		var dir := (p - elbow).normalized()
		var arm_basis := Basis.looking_at(dir, Vector3.UP)
		# roll the palm toward the pot (or downward when pressing from above)
		var to_axis := Vector3(-p.x, 0, -p.z).normalized() if zone != "hollow" else Vector3.DOWN
		var palm_dir := arm_basis.inverse() * to_axis
		var roll := atan2(palm_dir.x, -palm_dir.y)
		arm_basis = arm_basis * Basis(Vector3(0, 0, 1), roll)
		var palm := Vector3(0, -0.012, -0.33)
		var target := Transform3D(arm_basis, p - arm_basis * palm)
		hand.transform = hand.transform.interpolate_with(target, 1.0 - exp(-18.0 * delta))


func _draw_overlay() -> void:
	var vs := overlay.get_viewport_rect().size
	var s := Pottery.stats(pot)
	var at := Vector2(vs.x - 270, vs.y * 0.5 - 90)
	var kind := String(s["kind"])
	var title: String = {"lump": "A lump of clay", "bowl": "Bowl", "cup": "Cup", "jar": "Jar", "vessel": "Vessel"}.get(kind, "Vessel")
	draw_text(at + Vector2(0, -26), title, 21, UITheme.ACCENT)
	var lines: PackedStringArray = []
	lines.append("Clay %.2f L" % float(pot.get("vol", 0.0)))
	if s["hollow"]:
		lines.append("Holds %.2f L" % float(s["capacity_l"]))
		lines.append("Walls %.1f mm (thinnest %.1f)" % [float(s["wall_mean"]) * 1000.0, float(s["wall_min"]) * 1000.0])
		lines.append("Floor %.1f mm" % (float(s["floor_t"]) * 1000.0))
	draw_text(at + Vector2(0, 2), "\n".join(lines), 14, UITheme.TEXT, 250)
	if s["hollow"]:
		draw_meter(at + Vector2(0, 104), "Evenness", 1.0 - clampf(float(s["uneven"]) * 1.6, 0.0, 1.0))
		draw_meter(at + Vector2(0, 138), "Rim", float(s["rim_integrity"]))
		draw_meter(at + Vector2(0, 172), "Smoothness", clampf(1.0 - float(s["rough"]) * 0.8 - float(s["wobble"]) * 2.0, 0.0, 1.0))
	var fb := Pottery.feedback(pot)
	if fb.size() > 0:
		draw_text(at + Vector2(0, 210), fb[0], 14, Color(1.0, 0.85, 0.6), 250)
	var zone := String(_hover.get("zone", ""))
	if _grab == "" and zone != "":
		var mp := overlay.get_viewport().get_mouse_position()
		var label: String = {"shape": "wall: drag ← → to narrow/widen, ↑ to pull up", "inner": "inside wall: drag to widen",
			"hollow": "top: drag down to open & deepen", "rim": "rim: drag to flare / press down"}.get(zone, "")
		if _trim_mode:
			label = "click to cut here"
		draw_text(mp + Vector2(20, 20), label, 13, Color(1, 1, 1, 0.85), 300)
