class_name FPHands
extends Node3D
## First-person arms and held item.  Animations are short procedural keyframe
## tracks (position/rotation offsets) layered over idle sway, walk bob and look
## lag.  Each animation has an "impact" moment; the Interactor sends the world
## request at that instant so hits land in sync with the motion.

signal impact(anim: String)
signal finished(anim: String)

const ARM_R := "res://assets/models/character/fp_arm_r.glb"
const ARM_L := "res://assets/models/character/fp_arm_l.glb"
const REST_R := Vector3(0.24, -0.29, -0.16)
const REST_L := Vector3(-0.25, -0.31, -0.18)
const GRIP_POINT := Vector3(0.0, -0.01, -0.355)

# name: [duration, impact_t, left_arm_used, keys: [[t, pos_offset, rot_offset(euler)], ...]]
const ANIMS := {
	"swing": [0.62, 0.56, false, [[0.0, Vector3.ZERO, Vector3.ZERO], [0.38, Vector3(0.04, 0.14, 0.12), Vector3(1.1, 0.15, 0.25)],
		[0.56, Vector3(-0.05, -0.12, -0.16), Vector3(-0.75, -0.1, -0.1)], [1.0, Vector3.ZERO, Vector3.ZERO]]],
	"cut": [0.46, 0.5, false, [[0.0, Vector3.ZERO, Vector3.ZERO], [0.3, Vector3(0.12, 0.03, 0.02), Vector3(0.2, 0.7, -0.3)],
		[0.55, Vector3(-0.12, -0.04, -0.1), Vector3(-0.2, -0.6, 0.2)], [1.0, Vector3.ZERO, Vector3.ZERO]]],
	"dig": [0.7, 0.58, true, [[0.0, Vector3.ZERO, Vector3.ZERO], [0.32, Vector3(0.0, 0.08, 0.08), Vector3(0.8, 0.0, 0.0)],
		[0.58, Vector3(-0.02, -0.17, -0.2), Vector3(-0.9, 0.0, 0.1)], [0.8, Vector3(0.0, -0.05, -0.05), Vector3(0.3, 0, 0)], [1.0, Vector3.ZERO, Vector3.ZERO]]],
	"pick": [0.48, 0.45, false, [[0.0, Vector3.ZERO, Vector3.ZERO], [0.45, Vector3(-0.04, -0.17, -0.24), Vector3(-0.7, 0.1, 0.0)], [1.0, Vector3.ZERO, Vector3.ZERO]]],
	"place": [0.45, 0.5, false, [[0.0, Vector3.ZERO, Vector3.ZERO], [0.5, Vector3(-0.05, -0.12, -0.26), Vector3(-0.5, 0.0, 0.0)], [1.0, Vector3.ZERO, Vector3.ZERO]]],
	"drink": [1.1, 0.55, true, [[0.0, Vector3.ZERO, Vector3.ZERO], [0.35, Vector3(-0.14, 0.2, 0.06), Vector3(1.0, 0.3, 0.4)],
		[0.75, Vector3(-0.15, 0.22, 0.08), Vector3(1.25, 0.3, 0.5)], [1.0, Vector3.ZERO, Vector3.ZERO]]],
	"eat": [1.0, 0.5, false, [[0.0, Vector3.ZERO, Vector3.ZERO], [0.4, Vector3(-0.15, 0.2, 0.1), Vector3(1.1, 0.4, 0.3)],
		[0.6, Vector3(-0.14, 0.18, 0.12), Vector3(1.0, 0.4, 0.3)], [1.0, Vector3.ZERO, Vector3.ZERO]]],
	"pour": [1.0, 0.55, false, [[0.0, Vector3.ZERO, Vector3.ZERO], [0.35, Vector3(-0.04, -0.06, -0.2), Vector3(-0.2, 0.0, -1.1)],
		[0.8, Vector3(-0.04, -0.06, -0.2), Vector3(-0.2, 0.0, -1.2)], [1.0, Vector3.ZERO, Vector3.ZERO]]],
	"strike": [0.32, 0.55, false, [[0.0, Vector3.ZERO, Vector3.ZERO], [0.4, Vector3(0.0, 0.07, 0.03), Vector3(0.5, 0, 0)],
		[0.55, Vector3(-0.02, -0.06, -0.08), Vector3(-0.35, 0, 0)], [1.0, Vector3.ZERO, Vector3.ZERO]]],
	"hammer": [0.5, 0.55, false, [[0.0, Vector3.ZERO, Vector3.ZERO], [0.35, Vector3(0.02, 0.1, 0.05), Vector3(0.9, 0, 0.1)],
		[0.55, Vector3(-0.02, -0.08, -0.12), Vector3(-0.5, 0, 0)], [1.0, Vector3.ZERO, Vector3.ZERO]]],
	"bind": [0.8, 0.7, true, [[0.0, Vector3.ZERO, Vector3.ZERO], [0.25, Vector3(-0.08, -0.08, -0.2), Vector3(-0.4, 0.4, 0.6)],
		[0.5, Vector3(-0.1, -0.12, -0.22), Vector3(-0.5, -0.4, -0.6)], [0.75, Vector3(-0.08, -0.08, -0.2), Vector3(-0.4, 0.4, 0.6)], [1.0, Vector3.ZERO, Vector3.ZERO]]],
	"pack": [0.6, 0.55, true, [[0.0, Vector3.ZERO, Vector3.ZERO], [0.3, Vector3(0.0, 0.0, -0.1), Vector3(0.3, 0, 0)],
		[0.55, Vector3(-0.03, -0.16, -0.3), Vector3(-0.7, 0, 0)], [1.0, Vector3.ZERO, Vector3.ZERO]]],
	"throw": [0.5, 0.45, false, [[0.0, Vector3.ZERO, Vector3.ZERO], [0.3, Vector3(0.05, 0.12, 0.14), Vector3(1.2, 0, 0)],
		[0.45, Vector3(-0.04, 0.0, -0.3), Vector3(-0.6, 0, 0)], [1.0, Vector3.ZERO, Vector3.ZERO]]],
	"knead": [0.55, 0.5, true, [[0.0, Vector3.ZERO, Vector3.ZERO], [0.5, Vector3(-0.06, -0.14, -0.22), Vector3(-0.8, 0, 0)], [1.0, Vector3.ZERO, Vector3.ZERO]]],
	"twist": [0.5, 0.5, true, [[0.0, Vector3.ZERO, Vector3.ZERO], [0.5, Vector3(-0.06, -0.06, -0.16), Vector3(-0.3, 0.0, 1.3)], [1.0, Vector3.ZERO, Vector3.ZERO]]],
	"till": [0.75, 0.6, true, [[0.0, Vector3.ZERO, Vector3.ZERO], [0.35, Vector3(0.0, 0.14, 0.1), Vector3(1.0, 0, 0)],
		[0.6, Vector3(0.0, -0.18, -0.24), Vector3(-1.0, 0, 0)], [1.0, Vector3.ZERO, Vector3.ZERO]]],
}

var player: LocalPlayer
var arm_r: Node3D
var arm_l: Node3D
var hand_r_poses: Dictionary = {}
var hand_l_poses: Dictionary = {}
var grip_r: Node3D
var held: Node3D
var held_key := ""
var cloth_mat: ShaderMaterial

var anim := ""
var anim_t := 0.0
var _impact_sent := false
var _sway := Vector2.ZERO
var _last_yaw := 0.0
var _last_pitch := 0.0
var _carry_two := false
var _left_show := 0.0
var _bob := 0.0
var _hidden := false


func setup(p: LocalPlayer) -> void:
	player = p
	cloth_mat = Models.unique_material("Cloth")
	cloth_mat.set_shader_parameter("tint", Net.player_color(p.pid).lightened(0.15))
	arm_r = _make_arm(ARM_R, "R", hand_r_poses)
	arm_l = _make_arm(ARM_L, "L", hand_l_poses)
	add_child(arm_r)
	add_child(arm_l)
	arm_r.position = REST_R
	arm_l.position = REST_L
	arm_r.rotation = Vector3(0.12, 0.08, 0.0)
	arm_l.rotation = Vector3(0.12, -0.08, 0.0)
	grip_r = Node3D.new()
	grip_r.name = "Grip"
	grip_r.position = GRIP_POINT
	arm_r.add_child(grip_r)
	_set_pose("R", "open")
	_set_pose("L", "open")
	for mi in Models.mesh_instances(self):
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.layers = 1


func _make_arm(path: String, side: String, poses: Dictionary) -> Node3D:
	var root := Node3D.new()
	root.name = "Arm" + side
	var src := Models.instance(path)
	if src:
		root.add_child(src)
		for pose in ["Open", "Grip", "Pinch"]:
			var n: Node3D = src.find_child("Hand%s_%s" % [pose, side], true, false)
			if n:
				poses[pose.to_lower()] = n
		for mi in Models.mesh_instances(src):
			for s in mi.mesh.get_surface_count():
				var m := mi.mesh.surface_get_material(s)
				if m and m.resource_name.begins_with("Cloth") and not m.resource_name.begins_with("ClothDark"):
					mi.set_surface_override_material(s, cloth_mat)
		return root
	# procedural fallback: sleeve + forearm + hand
	var skin := Color(0.88, 0.68, 0.53)
	var sleeve := MeshInstance3D.new()
	var sc := CapsuleMesh.new()
	sc.radius = 0.048
	sc.height = 0.2
	sleeve.mesh = ProcMesh.painted(sc, Color(0.82, 0.8, 0.76))
	sleeve.material_override = cloth_mat
	sleeve.rotation.x = PI * 0.5
	sleeve.position = Vector3(0, 0, -0.04)
	root.add_child(sleeve)
	var fore := MeshInstance3D.new()
	var fc := CapsuleMesh.new()
	fc.radius = 0.036
	fc.height = 0.26
	fore.mesh = ProcMesh.painted(fc, skin)
	fore.material_override = Models.material_for("Skin")
	fore.rotation.x = PI * 0.5
	fore.position = Vector3(0, 0, -0.16)
	root.add_child(fore)
	for pose in ["open", "grip", "pinch"]:
		var h := MeshInstance3D.new()
		var hb := BoxMesh.new()
		hb.size = Vector3(0.085, 0.035, 0.1) if pose == "open" else Vector3(0.08, 0.06, 0.08)
		h.mesh = ProcMesh.painted(hb, skin)
		h.material_override = Models.material_for("Skin")
		h.position = Vector3(0, 0, -0.32)
		root.add_child(h)
		poses[pose] = h
	return root


func _set_pose(side: String, pose: String) -> void:
	var poses := hand_r_poses if side == "R" else hand_l_poses
	for k in poses:
		poses[k].visible = k == pose


func set_held(stack: Dictionary) -> void:
	var id := String(stack.get("i", ""))
	var key := id + str(hash(stack.get("d", {})))
	if key == held_key:
		return
	held_key = key
	if held:
		held.queue_free()
		held = null
	_carry_two = false
	if id == "":
		_set_pose("R", "open")
		return
	held = ItemVisual.make(id, stack.get("d", {}), 1)
	var hold := String(ItemDB.def(id).get("hold", "hand"))
	grip_r.add_child(held)
	for mi in Models.mesh_instances(held):
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	match hold:
		"grip":
			_set_pose("R", "grip")
			held.scale = Vector3.ONE
			var aabb := Models.aabb_of(held)
			# hold near the end of the handle, extending forward & up
			held.transform = Transform3D(Basis.from_euler(Vector3(0.0, PI * 0.5, PI * 0.42)), Vector3(0, 0.0, 0.0))
			held.translate_object_local(Vector3(aabb.size.x * 0.32, 0, 0))
		"two":
			_set_pose("R", "grip")
			_carry_two = true
			var s := ItemVisual.fit_scale(held, 0.9)
			held.scale = Vector3.ONE * s
			held.transform.basis = Basis.from_euler(Vector3(0, PI * 0.5, 0)).scaled(Vector3.ONE * s)
			held.position = Vector3(-0.2, 0.02, 0.05)
		_:
			_set_pose("R", "pinch" if ItemDB.unit_volume(id) < 0.3 else "open")
			var s2 := ItemVisual.fit_scale(held, 0.16)
			held.scale = Vector3.ONE * s2
			held.position = Vector3(0, 0.03, 0.04)


func play(nm: String, speed: float = 1.0) -> float:
	if not ANIMS.has(nm):
		return 0.0
	anim = nm
	anim_t = 0.0
	_impact_sent = false
	set_meta("speed", speed)
	return float(ANIMS[nm][0]) / speed


func is_playing() -> bool:
	return anim != ""


func set_hidden(h: bool) -> void:
	_hidden = h
	visible = not h and not player.third_person


func _process(delta: float) -> void:
	if player == null:
		return
	visible = not _hidden and not player.third_person and player.mode != "dead" and player.mode != "sleep"
	# look lag sway
	var dyaw := wrapf(player.yaw - _last_yaw, -PI, PI)
	var dpitch := player.pitch - _last_pitch
	_last_yaw = player.yaw
	_last_pitch = player.pitch
	_sway = _sway.lerp(Vector2(clampf(dyaw * 1.4, -0.08, 0.08), clampf(dpitch * 1.4, -0.08, 0.08)), 1.0 - exp(-10.0 * delta))
	var hspeed := Vector2(player.velocity.x, player.velocity.z).length()
	var moving := player.is_on_floor() and hspeed > 0.4
	_bob += delta * (6.4 if not player.sprinting else 8.6) * clampf(hspeed / LocalPlayer.WALK, 0.3, 1.6)
	var bob_amt := clampf(hspeed / LocalPlayer.WALK, 0.0, 1.5) if moving else 0.0
	var t := Time.get_ticks_msec() / 1000.0
	var idle := Vector3(sin(t * 1.1) * 0.003, sin(t * 1.6) * 0.004, 0.0)
	var bob := Vector3(cos(_bob) * 0.012, -absf(sin(_bob)) * 0.016, 0.0) * bob_amt
	var sprint_drop := Vector3(0.03, -0.07, 0.05) * (1.0 if player.sprinting and hspeed > 4.0 else 0.0)
	var pos_off := Vector3.ZERO
	var rot_off := Vector3.ZERO
	var use_left := _carry_two
	if anim != "":
		var spec: Array = ANIMS[anim]
		var speed: float = get_meta("speed", 1.0)
		anim_t += delta * speed / float(spec[0])
		var p := clampf(anim_t, 0.0, 1.0)
		var keys: Array = spec[3]
		for i in keys.size() - 1:
			var k0: Array = keys[i]
			var k1: Array = keys[i + 1]
			if p >= float(k0[0]) and p <= float(k1[0]):
				var f := (p - float(k0[0])) / maxf(0.0001, float(k1[0]) - float(k0[0]))
				f = f * f * (3.0 - 2.0 * f)
				pos_off = (k0[1] as Vector3).lerp(k1[1], f)
				rot_off = (k0[2] as Vector3).lerp(k1[2], f)
				break
		use_left = use_left or bool(spec[2])
		if not _impact_sent and p >= float(spec[1]):
			_impact_sent = true
			impact.emit(anim)
		if anim_t >= 1.0:
			var done := anim
			anim = ""
			finished.emit(done)
	var base_r := REST_R + idle + bob + sprint_drop + Vector3(-_sway.x * 0.4, _sway.y * 0.4, 0.0)
	arm_r.position = arm_r.position.lerp(base_r + pos_off, 1.0 - exp(-24.0 * delta))
	arm_r.rotation = arm_r.rotation.lerp(Vector3(0.12 + _sway.y, 0.08 + _sway.x, 0.0) + rot_off, 1.0 - exp(-24.0 * delta))
	_left_show = lerpf(_left_show, 1.0 if use_left else 0.0, 1.0 - exp(-10.0 * delta))
	var base_l := REST_L + Vector3(0.0, -0.35 * (1.0 - _left_show), 0.1 * (1.0 - _left_show)) + idle * 0.8 + bob * 0.9
	var lpos := Vector3(-pos_off.x * 0.6, pos_off.y, pos_off.z) * _left_show
	if _carry_two:
		lpos += Vector3(0.12, 0.03, -0.02)
	arm_l.position = arm_l.position.lerp(base_l + lpos, 1.0 - exp(-20.0 * delta))
	arm_l.rotation = arm_l.rotation.lerp(Vector3(0.12 + rot_off.x * _left_show, -0.08 - rot_off.y * 0.5 * _left_show, -rot_off.z * 0.5 * _left_show), 1.0 - exp(-20.0 * delta))
	arm_l.visible = _left_show > 0.05
