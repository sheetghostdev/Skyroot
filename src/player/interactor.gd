class_name Interactor
extends Node
## Finds what the player is looking at, asks InteractionRules what can be done
## with the held item, shows it via the HUD, and performs the chosen action:
## local feedback immediately, the world request at the animation's impact.

const MASK := EntityView.LAYER_TERRAIN | EntityView.LAYER_STRUCT | EntityView.LAYER_ITEMS | EntityView.LAYER_INTERACT | EntityView.LAYER_WATER

var player: LocalPlayer
var target: Dictionary = {}
var options: Dictionary = {}
var place_yaw := 0.0
var ghost: Node3D
var ghost_key := ""
var _pending: Dictionary = {}
var _last_sig := ""
var _hold_sig := ""                 # an option that needs holding before it happens...
var _hold_t := 0.0                  # ...and how long it has been held


func setup(p: LocalPlayer) -> void:
	player = p
	player.hands.impact.connect(_on_impact)
	player.hands.finished.connect(_on_finished)


func busy() -> bool:
	return player.hands.is_playing()


func _physics_process(delta: float) -> void:
	if player.mode != "play":
		if not target.is_empty():
			target = {}
			options = {}
			_emit()
		_update_ghost()
		return
	target = raycast()
	options = InteractionRules.options(player, target)
	_emit()
	_update_ghost()
	var holding := ""
	if not busy():
		for key in ["interact", "primary", "secondary"]:
			var opt: Dictionary = options.get(key, {})
			if not Input.is_action_pressed(key) or not opt.get("enabled", true):
				continue
			if opt.has("confirm_s"):
				# something that can't be undone happens only once the button has been held a moment
				holding = "%s|%s|%s" % [key, opt.get("label", ""), target.get("eid", -1)]
				if holding != _hold_sig:
					_hold_sig = holding
					_hold_t = 0.0
				_hold_t += delta
				if _hold_t >= float(opt["confirm_s"]):
					_start(opt)
					_hold_t = -INF   # once per hold
				break
			if opt.get("hold", false):
				_start(opt)
				break
	if holding == "":
		_hold_sig = ""
		_hold_t = 0.0


func _emit() -> void:
	var sig := "%s|%s|%s|%s" % [target.get("eid", -1), target.get("part", ""), str(options.keys()), _labels()]
	if sig != _last_sig:
		_last_sig = sig
		Events.interaction_target_changed.emit({"target": target, "options": options})


func _labels() -> String:
	var s := ""
	for k in options:
		s += String(options[k].get("label", "")) + String(options[k].get("text", ""))
	return s


func raycast() -> Dictionary:
	var cam := player.active_camera()
	var space := player.get_world_3d().direct_space_state
	var from := cam.global_position
	var dir := -cam.global_transform.basis.z
	var eye := player.eye_position()
	var length := LocalPlayer.REACH + (from.distance_to(eye) if player.third_person else 0.0) + 0.1
	var q := PhysicsRayQueryParameters3D.create(from, from + dir * length, MASK, [player.get_rid()])
	q.collide_with_areas = true
	q.hit_back_faces = false
	var hit := space.intersect_ray(q)
	if hit.is_empty():
		return {}
	var pos: Vector3 = hit["position"]
	var dist := pos.distance_to(eye)
	if dist > LocalPlayer.REACH:
		return {}
	var col: Object = hit["collider"]
	var out := {"pos": pos, "normal": hit["normal"], "dist": dist, "collider": col}
	if col.has_meta("eid"):
		var eid := int(col.get_meta("eid"))
		var ent := World.get_entity(eid)
		if ent.is_empty():
			return {}
		out["kind"] = "entity"
		out["eid"] = eid
		out["etype"] = String(ent["t"])
		out["part"] = String(col.get_meta("part", ""))
		out["ent"] = ent
	elif col.has_meta("water"):
		out["kind"] = "water"
	elif col.has_meta("ground"):
		out["kind"] = "ground"
	elif col.has_meta("cliff"):
		out["kind"] = "cliff"
	else:
		out["kind"] = "other"
	return out


func _unhandled_input(event: InputEvent) -> void:
	if player == null or player.mode != "play":
		return
	if event.is_action_pressed("interact"):
		var oi: Dictionary = options.get("interact", {})
		if not oi.get("hold", false) and not oi.has("confirm_s"):
			_start(oi)
	elif event.is_action_pressed("primary"):
		var o: Dictionary = options.get("primary", {})
		if not o.get("hold", false) and not o.has("confirm_s"):
			_start(o)
	elif event.is_action_pressed("secondary"):
		var o2: Dictionary = options.get("secondary", {})
		if not o2.get("hold", false) and not o2.has("confirm_s"):
			_start(o2)
	elif event.is_action_pressed("drop"):
		_drop()
	elif event.is_action_pressed("rotate"):
		place_yaw += PI / 8.0


func _start(opt: Dictionary) -> void:
	if opt.is_empty() or busy():
		return
	if not opt.get("enabled", true):
		if opt.has("why"):
			Events.toast.emit(String(opt["why"]), "info")
		Sfx.ui("ui_error", -16.0)
		return
	if opt.has("local"):
		(opt["local"] as Callable).call()
		return
	var anim := String(opt.get("anim", ""))
	if anim != "":
		var speed := float(opt.get("speed", 1.0)) * (0.7 if player.stamina < 0.1 else 1.0)
		player.hands.play(anim, speed)
		player.play_action(anim)
		_pending = opt
		if opt.has("sound_start"):
			Sfx.play(String(opt["sound_start"]), player.global_position, -6.0)
	else:
		_send(opt)


func _on_impact(_anim: String) -> void:
	if _pending.is_empty():
		return
	var opt := _pending
	_pending = {}
	# re-validate the target still makes sense (it may have moved/been taken)
	_send(opt)
	if opt.has("shake"):
		player.shake_camera(float(opt["shake"]))


func _on_finished(_anim: String) -> void:
	player.action_name = ""


func _send(opt: Dictionary) -> void:
	var args: Dictionary = opt.get("args", {}).duplicate()
	args["slot"] = player.hotbar
	args["eye"] = player.eye_position()
	World.request(String(opt["action"]), args)


func _drop() -> void:
	var stack := player.held_stack()
	if stack.is_empty():
		return
	var all := Input.is_key_pressed(KEY_CTRL)
	player.hands.play("throw")
	player.play_action("throw")
	World.request("drop", {"slot": player.hotbar, "n": int(stack["n"]) if all else 1,
		"from": player.eye_position(), "dir": player.look_dir(), "eye": player.eye_position()})


func _update_ghost() -> void:
	var opt: Dictionary = options.get("secondary", {})
	var show := player.mode == "play" and String(opt.get("action", "")) == "place"
	if not show:
		if ghost:
			ghost.visible = false
		return
	var stack := player.held_stack()
	var key := String(stack.get("i", "")) + str(hash(stack.get("d", {})))
	if ghost == null or ghost_key != key:
		if ghost:
			ghost.queue_free()
		ghost = ItemVisual.make(String(stack.get("i", "")), stack.get("d", {}), 1)
		ghost_key = key
		player.get_parent().add_child(ghost)
		var gm := StandardMaterial3D.new()
		gm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		gm.albedo_color = Color(0.85, 0.95, 1.0, 0.35)
		gm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		gm.no_depth_test = false
		for mi in Models.mesh_instances(ghost):
			mi.material_override = gm
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	ghost.visible = true
	var xf: Transform3D = opt.get("args", {}).get("xf", Transform3D())
	ghost.global_transform = xf


func placement_xf(hit_pos: Vector3, normal: Vector3, item_id: String) -> Transform3D:
	## Rest an item on the aimed surface, facing the player plus manual rotation.
	var yaw := player.yaw + place_yaw
	var b := Basis(Vector3.UP, yaw)
	var up := normal.normalized()
	if up.y > 0.55:
		var axis := Vector3.UP.cross(up)
		if axis.length() > 0.001:
			b = Basis(axis.normalized(), Vector3.UP.angle_to(up) * 0.6) * b
	var lift := 0.0
	var vis := ItemVisual.single(item_id, {})
	if vis:
		var aabb := Models.aabb_of(vis)
		lift = -aabb.position.y
		vis.free()
	return Transform3D(b, hit_pos + Vector3(0, lift + 0.003, 0))
