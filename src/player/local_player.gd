class_name LocalPlayer
extends CharacterBody3D
## The player on this machine.  Owns its own movement (relayed to others via
## Net.send_pose); everything that changes the world goes through requests.

const WALK := 3.7
const SPRINT := 6.1
const CROUCH := 1.8
const ACCEL := 11.0
const DECEL := 14.0
const AIR_ACCEL := 2.2
const GRAVITY := 15.5
const JUMP_V := 5.5
const STAND_H := 1.74
const CROUCH_H := 1.15
const EYE_STAND := 1.6
const EYE_CROUCH := 1.04
const REACH := 2.6
const ABYSS_Y := -40.0

var pid := 1
var yaw_pivot: Node3D
var head: Node3D
var cam_fp: Camera3D
var tp_arm: SpringArm3D
var cam_tp: Camera3D
var col_shape: CollisionShape3D
var capsule: CapsuleShape3D
var model: CharacterModel
var hands: FPHands
var interactor: Interactor

var yaw := 0.0
var pitch := 0.0
var third_person := false
var crouching := false
var sprinting := false
var mode := "play"           # play | ui | craft | dead | sleep | cinematic
var hotbar := 0
var stamina := 1.0           # client-predicted; host holds the authoritative copy
var speed_mult := 1.0
var facing_yaw := 0.0
var action_name := ""
var action_seq := 0

var _eye := EYE_STAND
var _bob_t := 0.0
var _bob_amt := 0.0
var _land := 0.0
var _land_v := 0.0
var _roll := 0.0
var _fov_extra := 0.0
var _step := 0.0
var _pose_t := 0.0
var _fall_v := 0.0
var _in_water := false
var _shake := 0.0
var _falling_abyss := false
var _last_floor_pos := Vector3.ZERO


func _ready() -> void:
	add_to_group("local_player")
	collision_layer = EntityView.LAYER_PLAYERS
	collision_mask = EntityView.LAYER_TERRAIN | EntityView.LAYER_STRUCT
	floor_max_angle = deg_to_rad(48.0)
	floor_snap_length = 0.35
	floor_block_on_wall = true
	wall_min_slide_angle = deg_to_rad(12.0)
	capsule = CapsuleShape3D.new()
	capsule.radius = 0.3
	capsule.height = STAND_H
	col_shape = CollisionShape3D.new()
	col_shape.shape = capsule
	col_shape.position.y = STAND_H * 0.5
	add_child(col_shape)

	model = CharacterModel.new()
	model.name = "Model"
	add_child(model)
	model.build(Net.player_color(pid))
	model.set_first_person(true)

	yaw_pivot = Node3D.new()
	yaw_pivot.name = "Yaw"
	add_child(yaw_pivot)
	head = Node3D.new()
	head.name = "Head"
	head.position.y = EYE_STAND
	yaw_pivot.add_child(head)
	cam_fp = Camera3D.new()
	cam_fp.name = "FPCamera"
	cam_fp.fov = Settings.fov
	cam_fp.near = 0.03
	cam_fp.far = 1600.0
	head.add_child(cam_fp)
	hands = FPHands.new()
	hands.name = "Hands"
	cam_fp.add_child(hands)
	hands.setup(self)

	tp_arm = SpringArm3D.new()
	tp_arm.name = "TPArm"
	tp_arm.spring_length = 3.1
	tp_arm.margin = 0.25
	tp_arm.collision_mask = EntityView.LAYER_TERRAIN | EntityView.LAYER_STRUCT
	tp_arm.position = Vector3(0.38, 0.12, 0.0)
	var probe := SphereShape3D.new()
	probe.radius = 0.2
	tp_arm.shape = probe
	tp_arm.add_excluded_object(get_rid())
	head.add_child(tp_arm)
	cam_tp = Camera3D.new()
	cam_tp.name = "TPCamera"
	cam_tp.fov = Settings.fov
	cam_tp.near = 0.05
	cam_tp.far = 1600.0
	tp_arm.add_child(cam_tp)

	interactor = Interactor.new()
	interactor.name = "Interactor"
	add_child(interactor)
	interactor.setup(self)

	cam_fp.current = true
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_last_floor_pos = global_position
	Events.local_player_spawned.emit(self)


func eye_position() -> Vector3:
	return head.global_position


func active_camera() -> Camera3D:
	return cam_tp if third_person else cam_fp


func look_dir() -> Vector3:
	return -active_camera().global_transform.basis.z


func held_stack() -> Dictionary:
	return World.my_inventory.get_slot(hotbar)


func held_id() -> String:
	return String(held_stack().get("i", ""))


func can_act() -> bool:
	return mode == "play"


func set_mode(m: String) -> void:
	mode = m
	if m == "play":
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	elif m == "ui" or m == "craft":
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	Events.ui_mode_changed.emit(m)


func set_third_person(on: bool) -> void:
	third_person = on
	cam_tp.current = on
	cam_fp.current = not on
	model.set_first_person(not on)
	hands.visible = not on


# ---------------------------------------------------------------------------
# Input
# ---------------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and (mode == "play" or mode == "sleep"):
		var s := Settings.mouse_sensitivity
		yaw -= event.relative.x * s
		pitch -= event.relative.y * s * (-1.0 if Settings.invert_y else 1.0)
		pitch = clampf(pitch, deg_to_rad(-88.0), deg_to_rad(88.0))
		return
	if mode != "play":
		return
	if event.is_action_pressed("camera_toggle"):
		set_third_person(not third_person)
	elif event.is_action_pressed("hotbar_next"):
		select_hotbar((hotbar + 1) % Inventory.HOTBAR)
	elif event.is_action_pressed("hotbar_prev"):
		select_hotbar((hotbar + Inventory.HOTBAR - 1) % Inventory.HOTBAR)
	else:
		for i in Inventory.HOTBAR:
			if event.is_action_pressed("hotbar_%d" % (i + 1)):
				select_hotbar(i)
				break


func select_hotbar(i: int) -> void:
	if interactor.busy():
		return
	hotbar = i
	Events.hotbar_selected.emit(i)
	hands.set_held(held_stack())
	Sfx.ui("ui_click", -18.0)


# ---------------------------------------------------------------------------
# Movement
# ---------------------------------------------------------------------------

func _physics_process(delta: float) -> void:
	var moving_allowed := mode == "play" or mode == "ui"
	var input := Vector2.ZERO
	if moving_allowed and mode == "play":
		input = Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var want_crouch := mode == "play" and Input.is_action_pressed("crouch")
	if mode == "craft":
		want_crouch = true
	if want_crouch:
		crouching = true
	elif crouching and _can_stand():
		crouching = false
	_apply_crouch_shape(delta)
	var st := float(World.my_stats.get("stamina", stamina))
	stamina = lerpf(stamina, st, 0.1)
	sprinting = mode == "play" and Input.is_action_pressed("sprint") and input.y < -0.2 and not crouching and stamina > 0.04
	var speed := CROUCH if crouching else (SPRINT if sprinting else WALK)
	speed *= speed_mult * (0.62 if _in_water else 1.0) * (0.75 if stamina < 0.08 else 1.0)
	var basis := Basis(Vector3.UP, yaw)
	var wish := basis * Vector3(input.x, 0.0, input.y)
	if wish.length() > 1.0:
		wish = wish.normalized()
	var target := wish * speed
	var hv := Vector3(velocity.x, 0.0, velocity.z)
	var on_floor := is_on_floor()
	var rate := (ACCEL if wish.length() > 0.01 else DECEL) if on_floor else AIR_ACCEL
	hv = hv.lerp(target, 1.0 - exp(-rate * delta))
	if crouching and on_floor:
		hv = _edge_guard(hv, delta)
	velocity.x = hv.x
	velocity.z = hv.z
	if not on_floor:
		velocity.y -= GRAVITY * delta
		_fall_v = minf(_fall_v, velocity.y)
	elif mode == "play" and Input.is_action_just_pressed("jump") and not crouching and stamina > 0.05:
		velocity.y = JUMP_V
		World.request("exert", {"kind": "jump"})
		Sfx.play("step_grass", global_position, -8.0)
	move_and_slide()
	if is_on_floor():
		if not on_floor:
			_on_land(-_fall_v)
		_fall_v = 0.0
		_last_floor_pos = global_position
	_in_water = _check_water()
	if global_position.y < ABYSS_Y and not _falling_abyss:
		_fell_into_abyss()
	_footsteps(delta, hv.length(), on_floor)
	_update_camera(delta, input, hv.length())
	_update_model(delta, hv)
	_pose_t -= delta
	if _pose_t <= 0.0:
		_pose_t = 0.05
		_send_pose(hv)


func _can_stand() -> bool:
	var space := get_world_3d().direct_space_state
	var q := PhysicsShapeQueryParameters3D.new()
	var probe := CapsuleShape3D.new()
	probe.radius = 0.28
	probe.height = STAND_H - 0.1
	q.shape = probe
	q.transform = Transform3D(Basis(), global_position + Vector3(0, STAND_H * 0.5 + 0.06, 0))
	q.collision_mask = collision_mask
	q.exclude = [get_rid()]
	return space.intersect_shape(q, 1).is_empty()


func _apply_crouch_shape(delta: float) -> void:
	var h := CROUCH_H if crouching else STAND_H
	capsule.height = move_toward(capsule.height, h, delta * 4.0)
	col_shape.position.y = capsule.height * 0.5
	_eye = lerpf(_eye, EYE_CROUCH if crouching else EYE_STAND, 1.0 - exp(-10.0 * delta))


func _edge_guard(hv: Vector3, delta: float) -> Vector3:
	## While crouching you won't walk off a ledge (handy on a floating island).
	var space := get_world_3d().direct_space_state
	for axis in [Vector3(hv.x, 0, 0), Vector3(0, 0, hv.z)]:
		if axis.length() < 0.01:
			continue
		var ahead: Vector3 = global_position + axis.normalized() * 0.34 + Vector3(0, 0.3, 0)
		var q := PhysicsRayQueryParameters3D.create(ahead, ahead + Vector3(0, -0.95, 0), collision_mask, [get_rid()])
		if space.intersect_ray(q).is_empty():
			if axis.x != 0.0:
				hv.x = 0.0
			else:
				hv.z = 0.0
	return hv


func _check_water() -> bool:
	var gw := Game.game_world
	if gw == null or gw.island == null:
		return false
	var lvl: float = gw.island.water_level()
	var p := Vector2(global_position.x, global_position.z)
	return World.terrain.in_pond(p) and global_position.y < lvl - 0.05


func _on_land(impact: float) -> void:
	_land_v = -clampf(impact * 0.018, 0.0, 0.16)
	if impact > 3.0:
		Sfx.play("step_dirt", global_position, -2.0 + clampf(impact - 3.0, 0.0, 6.0))
	if impact > 9.5:
		var dmg := pow((impact - 9.5) / 8.0, 1.5) * 0.9
		World.request("hurt", {"amount": dmg, "cause": "fall"})
		_shake = 0.6
		Sfx.play("hurt", global_position)


func _fell_into_abyss() -> void:
	_falling_abyss = true
	Sfx.play("fall_whoosh", null, -2.0)
	World.request("fell", {})
	Events.player_died.emit("abyss")


func respawn_at(pos: Vector3, yaw_v: float) -> void:
	global_position = pos
	velocity = Vector3.ZERO
	yaw = yaw_v
	pitch = 0.0
	_falling_abyss = false
	_fall_v = 0.0
	if mode == "dead":
		set_mode("play")


func _footsteps(delta: float, hspeed: float, on_floor: bool) -> void:
	if not on_floor or hspeed < 0.5:
		_step = 0.0
		return
	_step += hspeed * delta
	var stride := 0.62 if crouching else (0.95 if sprinting else 0.78)
	if _step >= stride:
		_step = 0.0
		Sfx.play("step_" + surface_kind(), global_position, (-14.0 if crouching else -7.0) + (2.0 if sprinting else 0.0))


func surface_kind() -> String:
	if _in_water:
		return "water"
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(global_position + Vector3(0, 0.2, 0), global_position + Vector3(0, -0.4, 0), collision_mask, [get_rid()])
	var hit := space.intersect_ray(q)
	if hit.is_empty():
		return "grass"
	var c: Object = hit["collider"]
	if c.has_meta("eid"):
		var ent := World.get_entity(int(c.get_meta("eid")))
		match String(ent.get("t", "")):
			"structure": return "wood"
			"outcrop", "flat_stone", "boulder": return "stone"
		return "wood"
	if c.has_meta("cliff"):
		return "stone"
	var layer := World.terrain.layer_at(global_position.x, global_position.z)
	var k := TerrainData.cell_at(Vector2(global_position.x, global_position.z))
	var g := World.terrain.grass[TerrainData.cell_index(k.x, k.y)]
	if layer == "rock":
		return "stone"
	if layer == "soil" and g > 0.4:
		return "grass"
	return "dirt"


# ---------------------------------------------------------------------------
# Camera & presentation
# ---------------------------------------------------------------------------

func _update_camera(delta: float, input: Vector2, hspeed: float) -> void:
	yaw_pivot.rotation.y = yaw
	head.rotation.x = pitch
	# landing dip spring
	_land_v += (-_land * 70.0 - _land_v * 12.0) * delta
	_land += _land_v * delta
	var bob := Vector3.ZERO
	var on_floor := is_on_floor()
	var moving := on_floor and hspeed > 0.4
	_bob_amt = lerpf(_bob_amt, clampf(hspeed / WALK, 0.0, 1.6) if moving else 0.0, 1.0 - exp(-8.0 * delta))
	if Settings.head_bob:
		_bob_t += delta * (6.4 if not sprinting else 8.6) * (0.7 if crouching else 1.0) * clampf(hspeed / WALK, 0.3, 1.6)
		bob = Vector3(cos(_bob_t) * 0.011, absf(sin(_bob_t)) * 0.024 - 0.012, 0.0) * _bob_amt
	var breath := sin(Time.get_ticks_msec() / 1000.0 * 1.6) * 0.0035
	head.position = Vector3(0, _eye + _land + breath, 0) + bob
	_roll = lerpf(_roll, -input.x * deg_to_rad(1.1), 1.0 - exp(-6.0 * delta))
	var shake := Vector3.ZERO
	if _shake > 0.0:
		_shake = maxf(0.0, _shake - delta * 2.2)
		var t := Time.get_ticks_msec() / 1000.0
		shake = Vector3(sin(t * 47.0), cos(t * 41.0), 0.0) * 0.012 * _shake
	cam_fp.rotation = Vector3(shake.x, shake.y, _roll)
	_fov_extra = lerpf(_fov_extra, 5.0 if sprinting and hspeed > WALK else 0.0, 1.0 - exp(-5.0 * delta))
	cam_fp.fov = Settings.fov + _fov_extra
	cam_tp.fov = Settings.fov + _fov_extra * 0.6


func shake_camera(amount: float) -> void:
	_shake = maxf(_shake, amount)


func _update_model(delta: float, hv: Vector3) -> void:
	if hv.length() > 0.3:
		facing_yaw = lerp_angle(facing_yaw, atan2(-hv.x, -hv.z), 1.0 - exp(-10.0 * delta))
	if not third_person or interactor.busy() or mode == "craft":
		facing_yaw = lerp_angle(facing_yaw, yaw, 1.0 - exp(-14.0 * delta))
	model.rotation.y = facing_yaw
	model.animate(delta, {
		"speed": hv.length(), "crouch": crouching, "air": not is_on_floor(), "sprint": sprinting,
		"pitch": pitch, "action": action_name, "mode": mode, "swim": _in_water,
	})


func play_action(nm: String) -> void:
	action_name = nm
	action_seq += 1
	model.play_action(nm)


func _send_pose(hv: Vector3) -> void:
	var held := held_stack()
	Net.send_pose({
		"p": global_position, "y": yaw, "x": pitch, "f": facing_yaw, "v": Vector3(hv.x, velocity.y, hv.z),
		"c": crouching, "a": action_name, "s": action_seq, "h": String(held.get("i", "")),
		"m": mode, "w": _in_water, "sp": sprinting,
	})
