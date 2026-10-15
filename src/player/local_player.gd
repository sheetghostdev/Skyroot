class_name LocalPlayer
extends Node3D
## The player on this machine.  Owns its own movement (relayed to others via
## Net.send_pose); everything that changes the world goes through requests.

const WALK := 4.0
const SPRINT := 5.7
const SNEAK := 1.6
const ACCEL := 14.0
const AIR_ACCEL := 3.0
const GRAVITY := 27.0
const JUMP_V := 8.3
const STAND_H := 1.8
const SNEAK_H := 1.5
const EYE_STAND := 1.62
const EYE_SNEAK := 1.32
const EYE_SIT := 0.92            # sitting on the ground, close over your work
const ABYSS_Y := -20.0
const TP_DIST := 3.6

var pid := 1
var body := VoxelBody.new()
var velocity := Vector3.ZERO
var yaw_pivot: Node3D
var head: Node3D
var cam_fp: Camera3D
var cam_tp: Camera3D
var model: CharacterModel
var fp: FPView
var interactor: Interactor
var torch_light: OmniLight3D

var yaw := 0.0
var pitch := 0.0
var third_person := false
var sneaking := false
var sprinting := false
var mode := "play"           # play | ui | dead | sleep
var hotbar := 0
var facing_yaw := 0.0
var action_name := ""
var action_seq := 0
var in_water := false
var sleeping_at := Vector3i(-1, -1, -1)

var _eye := EYE_STAND
var sitting := false
var _water_y := -INF        # feet height when last in water (for climbing out)
var _hblocked := false      # last move ran into a wall
var _sit_told := false
var _lean := 0.0
var _bob_t := 0.0
var _bob_amt := 0.0
var _land := 0.0
var _land_v := 0.0
var _fall_from := 0.0
var _step := 0.0
var _pose_t := 0.0
var _shake := 0.0
var _dead_falling := false
var _was_ground := true
var _edge_t := 0.0
var _edge_hinted := false


func _ready() -> void:
	add_to_group("local_player")
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
	cam_fp.near = 0.04
	cam_fp.far = 1400.0
	head.add_child(cam_fp)
	fp = FPView.new()
	fp.name = "FP"
	cam_fp.add_child(fp)
	cam_tp = Camera3D.new()
	cam_tp.name = "TPCamera"
	cam_tp.fov = Settings.fov
	cam_tp.near = 0.05
	cam_tp.far = 1400.0
	add_child(cam_tp)
	torch_light = OmniLight3D.new()
	torch_light.light_color = Color(1.0, 0.68, 0.38)
	torch_light.omni_range = 9.0
	torch_light.light_energy = 0.0
	torch_light.shadow_enabled = false
	torch_light.position = Vector3(0.3, 1.4, -0.3)
	add_child(torch_light)
	interactor = Interactor.new()
	interactor.name = "Interactor"
	add_child(interactor)
	interactor.setup(self)
	cam_fp.current = true
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_fall_from = global_position.y
	Events.inventory_changed.connect(_on_inventory)
	Events.local_player_spawned.emit(self)
	_on_inventory()


func eye_position() -> Vector3:
	return head.global_position


func active_camera() -> Camera3D:
	return cam_tp if third_person else cam_fp


func look_dir() -> Vector3:
	return -cam_fp.global_transform.basis.z


func held_stack() -> Dictionary:
	return World.my_inventory.get_slot(hotbar)


func held_id() -> String:
	return String(held_stack().get("i", ""))


func set_mode(m: String) -> void:
	mode = m
	if m == "play":
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	elif m == "ui":
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	Events.ui_mode_changed.emit(m)


func set_third_person(on: bool) -> void:
	third_person = on
	cam_tp.current = on
	cam_fp.current = not on
	model.set_first_person(not on)
	fp.visible = not on


func _on_inventory() -> void:
	var s := held_stack()
	fp.set_held(String(s.get("i", "")), s.get("d", {}))
	model.set_held(String(s.get("i", "")), s.get("d", {}))
	torch_light.light_energy = 1.3 if String(s.get("i", "")) == "torch_lit" else 0.0


# ---------------------------------------------------------------------------
# Input
# ---------------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and (mode == "play" or mode == "sleep"):
		var s := Settings.mouse_sensitivity
		yaw -= event.relative.x * s
		pitch -= event.relative.y * s * (-1.0 if Settings.invert_y else 1.0)
		pitch = clampf(pitch, deg_to_rad(-89.0), deg_to_rad(89.0))
		return
	if mode == "sleep" and (event.is_action_pressed("jump") or event.is_action_pressed("sneak") or event.is_action_pressed("pause")):
		wake()
		get_viewport().set_input_as_handled()
		return
	if mode != "play":
		return
	if event.is_action_pressed("sit"):
		set_sitting(not sitting)
	elif event.is_action_pressed("camera_toggle"):
		set_third_person(not third_person)
	elif event.is_action_pressed("hotbar_next"):
		select_hotbar((hotbar + 1) % Inventory.HOTBAR)
	elif event.is_action_pressed("hotbar_prev"):
		select_hotbar((hotbar + Inventory.HOTBAR - 1) % Inventory.HOTBAR)
	elif event.is_action_pressed("drop"):
		World.request("drop", {"slot": hotbar, "all": Input.is_key_pressed(KEY_CTRL), "yaw": yaw})
		model.swing("throw")
		fp.swing()
	else:
		for i in Inventory.HOTBAR:
			if event.is_action_pressed("hotbar_%d" % (i + 1)):
				select_hotbar(i)
				break


func set_sitting(on: bool) -> void:
	## Sit down on the ground for a close look at what you are working on
	## (knapping, shaping clay); any step or a jump gets you up again.
	if on and (not body.on_ground or in_water):
		return
	if on == sitting:
		return
	sitting = on
	if on and not _sit_told:
		_sit_told = true
		Events.toast.emit("You sit down for a closer look. C, a step or Space gets you up.", "info")
	Sfx.play("step_" + surface_kind(), global_position, -14.0)


func select_hotbar(i: int) -> void:
	if interactor.busy():
		interactor.cancel()
	hotbar = i
	Events.hotbar_selected.emit(i)
	_on_inventory()
	Sfx.ui("ui_click", -20.0)


# ---------------------------------------------------------------------------
# Movement
# ---------------------------------------------------------------------------

func _physics_process(delta: float) -> void:
	if mode == "sleep":
		velocity = Vector3.ZERO
		_update_camera(delta, Vector2.ZERO, 0.0)
		_update_model(delta, Vector3.ZERO)
		_pose_tick(delta, Vector3.ZERO)
		return
	var vd := World.vox
	var input := Vector2.ZERO
	var playing := mode == "play"
	if playing:
		input = Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	if sitting:
		if input.length() > 0.3 or (playing and Input.is_action_just_pressed("jump")) or not body.on_ground:
			sitting = false
		input = Vector2.ZERO
	var want_sneak := playing and Input.is_action_pressed("sneak") and not sitting
	if want_sneak:
		sneaking = true
	elif sneaking and body.fits(vd, global_position, STAND_H):
		sneaking = false
	body.height = SNEAK_H if sneaking else STAND_H
	_eye = lerpf(_eye, EYE_SIT if sitting else (EYE_SNEAK if sneaking else EYE_STAND), 1.0 - exp(-(7.0 if sitting else 12.0) * delta))
	_lean = lerpf(_lean, 0.22 if sitting else 0.0, 1.0 - exp(-7.0 * delta))
	sprinting = playing and Input.is_action_pressed("sprint") and input.y < -0.2 and not sneaking
	var speed := SNEAK if sneaking else (SPRINT if sprinting else WALK)
	in_water = vd.liquid_at(global_position + Vector3(0, 0.4, 0))
	if in_water:
		speed *= 0.6
		_water_y = global_position.y
	elif body.on_ground:
		_water_y = -INF
	var basis := Basis(Vector3.UP, yaw)
	var wish := basis * Vector3(input.x, 0.0, input.y)
	if wish.length() > 1.0:
		wish = wish.normalized()
	var target := wish * speed
	var hv := Vector3(velocity.x, 0.0, velocity.z)
	var rate := ACCEL if body.on_ground else AIR_ACCEL
	if in_water:
		rate = 6.0
	hv = hv.lerp(target, 1.0 - exp(-rate * delta))
	velocity.x = hv.x
	velocity.z = hv.z
	# swimming against a bank with jump held: haul yourself up and out
	var climb_out := playing and Input.is_action_pressed("jump") and _hblocked and wish.length() > 0.1 and global_position.y < _water_y + 1.55
	if in_water:
		velocity.y = maxf(velocity.y - GRAVITY * 0.25 * delta, -2.0)
		if playing and Input.is_action_pressed("jump"):
			velocity.y = minf(velocity.y + 18.0 * delta, 3.2)
	else:
		velocity.y -= GRAVITY * delta
		velocity.y = maxf(velocity.y, -55.0)
	if climb_out:
		velocity.y = maxf(velocity.y, 4.2)
	if body.on_ground and playing and Input.is_action_just_pressed("jump") and not in_water and _eye > EYE_SIT + 0.2:
		velocity.y = JUMP_V
	var was_ground := body.on_ground
	var res := body.move(vd, global_position, velocity * delta, sneaking and was_ground)
	var moved: Vector3 = res["motion"]
	global_position = res["pos"]
	if absf(moved.y - velocity.y * delta) > 1e-5:
		if velocity.y < 0.0:
			_on_land()
		velocity.y = 0.0
	_hblocked = false
	if absf(moved.x - velocity.x * delta) > 1e-5:
		velocity.x = 0.0
		_hblocked = true
	if absf(moved.z - velocity.z * delta) > 1e-5:
		velocity.z = 0.0
		_hblocked = true
	if body.on_ground or in_water:
		_fall_from = global_position.y
	elif global_position.y > _fall_from:
		_fall_from = global_position.y
	if global_position.y < ABYSS_Y and not _dead_falling:
		_fell_into_abyss()
	_edge_check(delta)
	_footsteps(delta, hv.length())
	_update_camera(delta, input, hv.length())
	_update_model(delta, hv)
	_pose_tick(delta, hv)


func _on_land() -> void:
	var fall := _fall_from - global_position.y
	_fall_from = global_position.y
	_land_v = -clampf(fall * 0.02, 0.0, 0.14)
	if fall > 1.2:
		Sfx.play("step_" + surface_kind(), global_position, -6.0 + clampf(fall, 0.0, 6.0))
	if fall > 3.6 and not in_water:
		var dmg := (fall - 3.4) * 0.065
		World.request("hurt", {"amount": dmg, "cause": "fall"})
		_shake = 0.6
		Sfx.play("hurt", global_position)


func _fell_into_abyss() -> void:
	_dead_falling = true
	Sfx.play("fall_whoosh", null, -2.0)
	World.request("fell", {})
	Events.player_died.emit("abyss")


func _edge_check(delta: float) -> void:
	## The first time you come near the edge, a word of warning.
	if _edge_hinted:
		return
	_edge_t -= delta
	if _edge_t > 0.0:
		return
	_edge_t = 0.4
	if not body.on_ground:
		return
	var p := global_position
	for i in 8:
		var a := i * TAU / 8.0
		var q := p + Vector3(cos(a), 0, sin(a)) * 1.3
		if World.vox.rest_height(q + Vector3(0, 0.5, 0)) == -INF:
			_edge_hinted = true
			Events.hint.emit("edge")
			return


func respawn_at(pos: Vector3, yaw_v: float) -> void:
	global_position = pos
	velocity = Vector3.ZERO
	yaw = yaw_v
	pitch = 0.0
	_dead_falling = false
	_fall_from = pos.y
	if mode == "dead" or mode == "sleep":
		set_mode("play")


func lie_down(c: Vector3i) -> void:
	if not World.is_night() and World.hour_of_day() > 6.5:
		Events.toast.emit("You can only sleep at night.", "info")
		return
	World.request("bed_set", {"c": c})
	sleeping_at = c
	# lie along the bed, head on the pillow
	var id := World.block(c)
	var m := World.block_meta(c)
	var head := c
	var dir := Vector3i(0, 0, -1)
	if id >= 0 and Blocks.facing[id] == 1:
		dir = Blocks.facing_dir(m)
		var other := BlockActs.bed_partner(c, id, m)
		if Blocks.name_of(id) == "straw_bed" and other.x >= 0:
			head = other
	global_position = Vector3(head) + Vector3(0.5, 0.45, 0.5) + Vector3(dir) * 0.15
	facing_yaw = atan2(-float(dir.x), -float(dir.z))
	model.rotation.y = facing_yaw
	velocity = Vector3.ZERO
	set_mode("sleep")
	Events.toast.emit("Sleeping... the night passes when everyone sleeps. (Space to get up)", "info")


func wake() -> void:
	if mode != "sleep":
		return
	sleeping_at = Vector3i(-1, -1, -1)
	global_position += Vector3(0, 0.3, 0)
	set_mode("play")


func _process(_delta: float) -> void:
	if mode == "sleep" and not World.is_night() and World.hour_of_day() > 6.0 and World.hour_of_day() < 12.0:
		wake()
		Events.toast.emit("Morning.", "info")


func _footsteps(delta: float, hspeed: float) -> void:
	if not body.on_ground or hspeed < 0.6:
		_step = 0.0
		return
	_step += hspeed * delta
	var stride := 0.55 if sneaking else (1.0 if sprinting else 0.82)
	if _step >= stride:
		_step = 0.0
		Sfx.play("step_" + surface_kind(), global_position, (-16.0 if sneaking else -8.0) + (2.0 if sprinting else 0.0))


func surface_kind() -> String:
	if in_water:
		return "water"
	var c := VoxelData.cell_of(global_position - Vector3(0, 0.05, 0))
	var snd := String(Blocks.def(World.block(c)).get("sound", "dirt"))
	match snd:
		"stone": return "stone"
		"wood": return "wood"
		"grass", "leaves": return "grass"
	return "dirt"


# ---------------------------------------------------------------------------
# Camera & presentation
# ---------------------------------------------------------------------------

func _update_camera(delta: float, input: Vector2, hspeed: float) -> void:
	yaw_pivot.rotation.y = yaw
	head.rotation.x = pitch
	_land_v += (-_land * 70.0 - _land_v * 12.0) * delta
	_land += _land_v * delta
	var bob := Vector3.ZERO
	var moving := body.on_ground and hspeed > 0.4
	_bob_amt = lerpf(_bob_amt, clampf(hspeed / WALK, 0.0, 1.5) if moving else 0.0, 1.0 - exp(-8.0 * delta))
	if Settings.head_bob:
		_bob_t += delta * (6.6 if not sprinting else 8.4) * clampf(hspeed / WALK, 0.3, 1.5)
		bob = Vector3(cos(_bob_t) * 0.012, absf(sin(_bob_t)) * 0.026 - 0.013, 0.0) * _bob_amt
	var eye := _eye if mode != "sleep" else 0.25
	head.position = Vector3(0, eye + _land, -_lean) + bob
	var shake := Vector3.ZERO
	if _shake > 0.0:
		_shake = maxf(0.0, _shake - delta * 2.2)
		var t := Time.get_ticks_msec() / 1000.0
		shake = Vector3(sin(t * 47.0), cos(t * 41.0), 0.0) * 0.012 * _shake
	cam_fp.rotation = Vector3(shake.x, shake.y, -input.x * deg_to_rad(0.6))
	var fov_extra := 6.0 if sprinting and hspeed > WALK else 0.0
	cam_fp.fov = lerpf(cam_fp.fov, Settings.fov + fov_extra, 1.0 - exp(-6.0 * delta))
	cam_tp.fov = cam_fp.fov
	fp.animate(delta, _bob_t, _bob_amt, sneaking)
	if third_person:
		# behind the head, pulled in by walls so it never ends up inside a block
		var e := head.global_position
		var back := cam_fp.global_transform.basis.z
		var dist := TP_DIST
		var hit := World.vox.raycast(e, back, TP_DIST + 0.3)
		if not hit.is_empty():
			dist = maxf(0.3, float(hit["dist"]) - 0.3)
		cam_tp.global_transform = Transform3D(cam_fp.global_transform.basis, e + back * dist + cam_fp.global_transform.basis.x * 0.25)
		model.set_first_person(dist < 0.8)


func shake_camera(amount: float) -> void:
	_shake = maxf(_shake, amount)


func _update_model(delta: float, hv: Vector3) -> void:
	if hv.length() > 0.3 and third_person:
		facing_yaw = lerp_angle(facing_yaw, atan2(-hv.x, -hv.z), 1.0 - exp(-10.0 * delta))
	if mode != "sleep" and (not third_person or interactor.busy() or sitting):
		facing_yaw = lerp_angle(facing_yaw, yaw, 1.0 - exp(-14.0 * delta))
	model.rotation.y = facing_yaw
	model.animate(delta, {
		"speed": hv.length(), "crouch": sneaking, "air": not body.on_ground, "pitch": pitch, "sit": sitting,
		"action": action_name, "mode": mode,
	})


func play_action(nm: String) -> void:
	## A one-off swing (seen by everyone), or a held action ("drill", "eat"...)
	## that lasts until cleared with "".
	if nm == "swing":
		model.swing()
		fp.swing()
		action_seq += 1
		return
	action_name = nm
	fp.set_action(nm)


func _pose_tick(delta: float, hv: Vector3) -> void:
	_pose_t -= delta
	if _pose_t > 0.0:
		return
	_pose_t = 0.05
	var held := held_stack()
	Net.send_pose({
		"p": global_position, "y": yaw, "x": pitch, "f": facing_yaw, "v": Vector3(hv.x, velocity.y, hv.z),
		"c": sneaking, "a": action_name, "s": action_seq, "h": String(held.get("i", "")), "hd": held.get("d", {}), "st": sitting,
		"m": mode, "w": in_water, "sp": sprinting, "g": body.on_ground,
	})
