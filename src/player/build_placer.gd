class_name BuildPlacer
extends Node3D
## Build mode (B): position a blueprint's ghost in the world and set down its
## frame, or take finished pieces apart again.
##
## Pieces snap to what is already built where that makes sense - platforms to
## platform edges, railings and walls along edges, posts under corners (or,
## where a corner hangs over the abyss, as a brace slanting back to the cliff),
## roofs onto the tops of walls - and otherwise follow the ground.
##   LMB place / hold to take apart   R rotate   RMB or Esc leave build mode

const RAY := 6.0

var player: LocalPlayer
var active := false
var mode := "place"
var bp_id := ""
var ghost: Node3D
var rot := 0.0
var xf := Transform3D.IDENTITY
var sy := 1.0
var why := ""
var target := -1
var _ok_mat: StandardMaterial3D
var _bad_mat: StandardMaterial3D
var _hold_t := 0.0


func _ready() -> void:
	_ok_mat = StandardMaterial3D.new()
	_ok_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_ok_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_ok_mat.albedo_color = Color(0.7, 0.9, 1.0, 0.38)
	_ok_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_bad_mat = _ok_mat.duplicate()
	_bad_mat.albedo_color = Color(1.0, 0.45, 0.35, 0.38)
	top_level = true


func start_place(id: String) -> void:
	stop()
	bp_id = id
	mode = "place"
	active = true
	rot = 0.0
	var bp := ItemDB.blueprint(id)
	ghost = Models.instance(String(bp.get("model", "")))
	if ghost == null:
		var box := StructureSim.local_box(id)
		ghost = Node3D.new()
		var mi := Models.placeholder(box.size, Color.WHITE)
		mi.position = box.get_center()
		ghost.add_child(mi)
	for mi in Models.mesh_instances(ghost):
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(ghost)
	player.set_mode("build")
	Sfx.ui("ui_open", -10.0)


func start_dismantle() -> void:
	stop()
	mode = "dismantle"
	active = true
	player.set_mode("build")


func stop() -> void:
	if ghost:
		ghost.queue_free()
		ghost = null
	if active and player.mode == "build":
		player.set_mode("play")
	active = false
	target = -1
	Game.game_world.hud.set_work_hint("")


func _unhandled_input(event: InputEvent) -> void:
	if not active:
		return
	if event.is_action_pressed("pause") or event.is_action_pressed("secondary") or event.is_action_pressed("build"):
		stop()
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("rotate") or (event is InputEventKey and event.pressed and event.physical_keycode == KEY_R):
		rot += PI * 0.5 if _snapped else deg_to_rad(15.0)
		get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			rot += deg_to_rad(15.0)
			get_viewport().set_input_as_handled()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			rot -= deg_to_rad(15.0)
			get_viewport().set_input_as_handled()
	if event.is_action_pressed("primary") and mode == "place":
		if why == "":
			World.request("build_place", {"bp": bp_id, "xf": xf, "sy": sy, "eye": player.eye_position()})
			player.hands.play("place")
			# stay in build mode for the next piece
		else:
			Events.toast.emit(why, "warn")
			Sfx.ui("ui_error", -14.0)
		get_viewport().set_input_as_handled()


var _snapped := false


func _physics_process(delta: float) -> void:
	if not active:
		return
	if player.mode != "build":
		active = false
		if ghost:
			ghost.queue_free()
			ghost = null
		return
	var cam := player.active_camera()
	var from := cam.global_position
	var dir := -cam.global_transform.basis.z
	var space := player.get_world_3d().direct_space_state
	var mask := EntityView.LAYER_TERRAIN | EntityView.LAYER_STRUCT | (EntityView.LAYER_INTERACT if mode == "dismantle" else 0)
	var q := PhysicsRayQueryParameters3D.create(from, from + dir * RAY, mask, [player.get_rid()])
	q.collide_with_areas = mode == "dismantle"
	var hit := space.intersect_ray(q)
	if mode == "dismantle":
		_dismantle_tick(hit, delta)
		return
	if hit.is_empty():
		ghost.visible = false
		why = "Aim at the ground or something built."
		_hint()
		return
	ghost.visible = true
	_compute(hit)
	why = ActionsBuild.check_place(bp_id, xf, sy)
	if why == "" and player.eye_position().distance_to(xf.origin) > LocalPlayer.REACH + ActionsBuild.REACH_EXTRA:
		why = "Too far away."
	ghost.global_transform = xf
	ghost.scale = Vector3(1.0, sy, 1.0)
	for mi in Models.mesh_instances(ghost):
		mi.material_override = _ok_mat if why == "" else _bad_mat
	_hint()


func _hint() -> void:
	var bp := ItemDB.blueprint(bp_id)
	var have := _materials_text()
	var line := "%s  ·  LMB: place frame  ·  R / wheel: rotate  ·  RMB: done" % String(bp.get("name", ""))
	if why != "":
		line += "\n" + why
	elif have != "":
		line += "\n" + have
	Game.game_world.hud.set_work_hint(line)


func _materials_text() -> String:
	var totals := ItemDB.blueprint_totals(bp_id)
	var bits: PackedStringArray = []
	for k in totals:
		var have := 0
		for id in String(k).split("|"):
			have += World.my_inventory.count(id)
		var names: PackedStringArray = []
		for id in String(k).split("|"):
			names.append(ItemDB.display_name(id).to_lower())
		bits.append("%s %d/%d" % [" or ".join(names), mini(have, int(totals[k])), int(totals[k])])
	return "Materials (deliver them to the frame): " + ", ".join(bits)


# ---------------------------------------------------------------------------
# Where the piece goes
# ---------------------------------------------------------------------------

func _yaw_basis() -> Basis:
	var yaw := snappedf(player.yaw, deg_to_rad(15.0)) + rot
	return Basis(Vector3.UP, yaw)


func _structures_near(p: Vector3, r: float, kinds: Array) -> Array:
	var out: Array = []
	for e in World.entities_near(p, r, "structure"):
		if String(ItemDB.blueprint(String(e["d"]["bp"])).get("kind", "")) in kinds:
			out.append(e)
	return out


func _compute(hit: Dictionary) -> void:
	var p: Vector3 = hit["position"]
	var bp := ItemDB.blueprint(bp_id)
	var kind := String(bp.get("kind", ""))
	sy = 1.0
	_snapped = false
	var basis := _yaw_basis()
	xf = Transform3D(basis, p)
	match kind:
		"floor":
			var best := INF
			for f in _structures_near(p, 3.6, ["floor"]):
				var fx: Transform3D = f["xf"]
				for off in [Vector3(2, 0, 0), Vector3(-2, 0, 0), Vector3(0, 0, 2), Vector3(0, 0, -2)]:
					var c: Vector3 = fx * off
					var dd := Vector2(c.x - p.x, c.z - p.z).length()
					if dd < 1.3 and dd < best:
						best = dd
						xf = Transform3D(fx.basis.rotated(Vector3.UP, rot - fposmod(rot, PI * 0.5)), c)
						_snapped = true
			if not _snapped:
				var top := -INF
				var any := false
				for o in [Vector3.ZERO, Vector3(0.9, 0, 0.9), Vector3(-0.9, 0, 0.9), Vector3(0.9, 0, -0.9), Vector3(-0.9, 0, -0.9)]:
					var w: Vector3 = Transform3D(basis, p) * (o as Vector3)
					if World.terrain.is_inside(w.x, w.z):
						top = maxf(top, World.terrain.height(w.x, w.z))
						any = true
				xf = Transform3D(basis, Vector3(p.x, (top + 0.04) if any else p.y, p.z))
		"edge", "wall":
			var best2 := INF
			for f in _structures_near(p, 3.0, ["floor"]):
				var fx2: Transform3D = f["xf"]
				for e in [[Vector3(1, 0, 0), PI * 0.5], [Vector3(-1, 0, 0), PI * 0.5], [Vector3(0, 0, 1), 0.0], [Vector3(0, 0, -1), 0.0]]:
					var inset: Vector3 = (e[0] as Vector3) * (0.93 if kind == "edge" else 0.93)
					var c2: Vector3 = fx2 * inset
					var dd2 := Vector2(c2.x - p.x, c2.z - p.z).length()
					if dd2 < 1.1 and dd2 < best2:
						best2 = dd2
						xf = Transform3D(fx2.basis.rotated(Vector3.UP, float(e[1]) + (PI if fposmod(rot, TAU) >= PI else 0.0)), c2)
						_snapped = true
			if not _snapped:
				xf = Transform3D(basis.rotated(Vector3.UP, PI * 0.5), Vector3(p.x, _ground_or(p), p.z))
		"post":
			_compute_post(p, basis)
		"roof":
			var best3 := INF
			for f in _structures_near(p, 3.5, ["floor"]):
				var fx3: Transform3D = f["xf"]
				var c3: Vector3 = fx3 * Vector3(0, 2.2, 0)
				var dd3 := Vector2(c3.x - p.x, c3.z - p.z).length()
				if dd3 < 1.6 and dd3 < best3:
					best3 = dd3
					xf = Transform3D(fx3.basis.rotated(Vector3.UP, rot - fposmod(rot, PI * 0.5)), c3)
					_snapped = true
			if not _snapped:
				for w in _structures_near(p, 3.0, ["wall"]):
					var wx: Transform3D = w["xf"]
					var top3: Vector3 = wx * Vector3(0, 2.2 * float(w["d"].get("sy", 1.0)), 0)
					if top3.distance_to(p) < 2.6:
						xf = Transform3D(basis, Vector3(p.x, top3.y, p.z))
						_snapped = true
						break
			if not _snapped:
				xf = Transform3D(basis, p + Vector3(0, 2.25, 0))
		"ladder":
			var n: Vector3 = hit["normal"]
			if absf(n.y) < 0.5:
				# against a wall or a deck edge: stand it on the ground in front, facing out
				var base := p + Vector3(n.x, 0, n.z).normalized() * 0.18
				base.y = _ground_or(base)
				xf = Transform3D(Basis(Vector3.UP, atan2(n.x, n.z)), base)
			else:
				var face := player.global_position - p
				xf = Transform3D(Basis(Vector3.UP, atan2(face.x, face.z) + rot), p)
		_:
			xf = Transform3D(basis, p)


func _compute_post(p: Vector3, basis: Basis) -> void:
	var best := INF
	var corner := Vector3.INF
	var fbasis := basis
	for f in _structures_near(p, 3.2, ["floor"]):
		var fx: Transform3D = f["xf"]
		for c in [Vector3(0.9, -0.16, 0.9), Vector3(-0.9, -0.16, 0.9), Vector3(0.9, -0.16, -0.9), Vector3(-0.9, -0.16, -0.9),
				Vector3(0.0, -0.16, 0.9), Vector3(0.0, -0.16, -0.9), Vector3(0.9, -0.16, 0.0), Vector3(-0.9, -0.16, 0.0)]:
			var w: Vector3 = fx * (c as Vector3)
			var dd := Vector2(w.x - p.x, w.z - p.z).length()
			if dd < 0.9 and dd < best:
				best = dd
				corner = w
				fbasis = fx.basis
	if corner == Vector3.INF:
		xf = Transform3D(basis, Vector3(p.x, _ground_or(p), p.z))
		sy = 1.0
		return
	_snapped = true
	var base := Vector3.INF
	if World.terrain.is_inside(corner.x, corner.z):
		base = Vector3(corner.x, World.terrain.height(corner.x, corner.z), corner.z)
	else:
		# over the abyss: brace back to the cliff, along a slant
		var toward := Vector3(-corner.x, 0, -corner.z).normalized()
		for i in range(4, 30):
			var cand := corner + toward * (i * 0.06)
			if World.terrain.is_inside(cand.x, cand.z) and World.terrain.edge_factor(Vector2(cand.x, cand.z)) < 0.995:
				var gh := World.terrain.height(cand.x, cand.z) - 0.25
				if gh < corner.y:
					base = Vector3(cand.x, gh, cand.z)
					break
	if base == Vector3.INF or base.y >= corner.y:
		xf = Transform3D(fbasis, corner)
		sy = 0.2
		return
	var axis := corner - base
	var length := axis.length()
	sy = clampf(length / 2.2, 0.3, 1.6)
	var up := axis.normalized()
	var side := up.cross(fbasis.z).normalized()
	if side.length() < 0.1:
		side = Vector3.RIGHT
	xf = Transform3D(Basis(side, up, side.cross(up)).orthonormalized(), base)


func _ground_or(p: Vector3) -> float:
	if World.terrain.is_inside(p.x, p.z):
		var gh := World.terrain.height(p.x, p.z)
		if absf(gh - p.y) < 0.6:
			return gh
	return p.y


# ---------------------------------------------------------------------------
# Taking things apart
# ---------------------------------------------------------------------------

func _dismantle_tick(hit: Dictionary, delta: float) -> void:
	target = -1
	if not hit.is_empty():
		var col: Object = hit["collider"]
		if col.has_meta("eid") and World.get_entity(int(col.get_meta("eid"))).get("t", "") == "structure":
			target = int(col.get_meta("eid"))
	var line := "Take apart  ·  hold LMB on a piece: each part comes back to you  ·  RMB: done"
	if target != -1:
		var d: Dictionary = World.get_entity(target)["d"]
		var bp := ItemDB.blueprint(String(d["bp"]))
		var n := int(d.get("installed", 0))
		line = "%s (%d/%d parts)  ·  hold LMB to take it apart  ·  RMB: done" % [String(bp.get("name", "")), n, bp.get("parts", []).size()]
		if Input.is_action_pressed("primary"):
			_hold_t -= delta
			if _hold_t <= 0.0:
				_hold_t = 0.5
				World.request("build_dismantle", {"eid": target, "eye": player.eye_position()})
				player.hands.play("pick")
		else:
			_hold_t = 0.15
	Game.game_world.hud.set_work_hint(line)
