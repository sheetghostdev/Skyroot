class_name CharacterModel
extends Node3D
## A blocky person to match the world: head, body, arms and legs built from
## textured boxes (cloth tinted in the player's colour).  Swings its limbs as it
## walks, crouches when sneaking, swings the right arm when working, and holds
## the item in hand.

const SKIN := Color(1, 1, 1)
const TROUSERS := Color(0.55, 0.42, 0.3)

var head: Node3D
var body: Node3D
var arm_l: Node3D
var arm_r: Node3D
var leg_l: Node3D
var leg_r: Node3D
var shin_l: Node3D          # knees: the lower legs hang from the thighs
var shin_r: Node3D
var hand: Node3D
var held_mi: MeshInstance3D
var _walk := 0.0
var _swing := 0.0
var _swing_kind := ""
var _held_key := ""
var _torch: TorchModel
var carry_light := false   # a remote player's torch lights the ground for you
var _mat: ShaderMaterial
var _first_person := false


func build(color: Color) -> void:
	_mat = ShaderMaterial.new()
	_mat.shader = load("res://assets/shaders/voxel_solid.gdshader")
	_mat.set_shader_parameter("atlas", BlockTex.array())
	_mat.set_shader_parameter("ao_light", 0.0)
	var skin := BlockTex.layer("skin")
	var cloth := BlockTex.layer("cloth")
	var leather := BlockTex.layer("leather")
	var hair := BlockTex.layer("hair")
	var shirt := color
	# legs: thighs pivot at the hip, shins at the knee, a shoe at the foot
	# (woven trousers: light enough to see in your own shadow when you look down)
	var trousers := TROUSERS.lerp(Color.WHITE, 0.25)
	leg_l = _limb(Vector3(-0.11, 0.72, 0), Vector3(0.21, 0.37, 0.22), cloth, trousers, Vector3(0, -0.18, 0))
	leg_r = _limb(Vector3(0.11, 0.72, 0), Vector3(0.21, 0.37, 0.22), cloth, trousers, Vector3(0, -0.18, 0))
	shin_l = Node3D.new()
	shin_r = Node3D.new()
	for pair in [[leg_l, shin_l], [leg_r, shin_r]]:
		var sh: Node3D = pair[1]
		sh.position = Vector3(0, -0.36, 0)
		(pair[0] as Node3D).add_child(sh)
		_box(sh, Vector3(0, -0.15, 0), Vector3(0.2, 0.3, 0.21), cloth, trousers)
		_box(sh, Vector3(0, -0.32, -0.025), Vector3(0.21, 0.08, 0.26), leather, Color(0.55, 0.45, 0.36))
	body = _limb(Vector3(0, 0.72, 0), Vector3(0.44, 0.62, 0.24), cloth, shirt, Vector3(0, 0.31, 0))
	# arms hang from the shoulders
	arm_l = _limb(Vector3(-0.32, 1.3, 0), Vector3(0.17, 0.42, 0.19), cloth, shirt.darkened(0.12), Vector3(0, -0.17, 0))
	arm_r = _limb(Vector3(0.32, 1.3, 0), Vector3(0.17, 0.42, 0.19), cloth, shirt.darkened(0.12), Vector3(0, -0.17, 0))
	_box(arm_l, Vector3(0, -0.47, 0), Vector3(0.15, 0.2, 0.17), skin, SKIN)
	_box(arm_r, Vector3(0, -0.47, 0), Vector3(0.15, 0.2, 0.17), skin, SKIN)
	# a belt
	_box(body, Vector3(0, 0.03, 0), Vector3(0.45, 0.06, 0.25), leather, Color(0.7, 0.6, 0.5))
	head = Node3D.new()
	head.position = Vector3(0, 1.34, 0)
	add_child(head)
	_box(head, Vector3(0, 0.21, 0), Vector3(0.42, 0.42, 0.42), skin, SKIN)
	_box(head, Vector3(0, 0.39, 0.03), Vector3(0.44, 0.1, 0.44), hair, Color.WHITE)
	_box(head, Vector3(0, 0.25, 0.19), Vector3(0.44, 0.3, 0.08), hair, Color.WHITE)
	_box(head, Vector3(0, 0.36, -0.19), Vector3(0.44, 0.07, 0.06), hair, Color.WHITE)
	for sx in [-0.2, 0.2]:
		_box(head, Vector3(sx, 0.3, 0.06), Vector3(0.06, 0.2, 0.3), hair, Color.WHITE)
	# eyes look forward (-Z)
	for x in [-0.09, 0.09]:
		_box(head, Vector3(x, 0.22, -0.213), Vector3(0.07, 0.05, 0.01), hair, Color(0.25, 0.25, 0.3))
	hand = Node3D.new()
	hand.position = Vector3(0, -0.56, -0.08)
	arm_r.add_child(hand)
	held_mi = MeshInstance3D.new()
	hand.add_child(held_mi)


func _limb(pivot: Vector3, size: Vector3, tex: int, tint: Color, center: Vector3) -> Node3D:
	var n := Node3D.new()
	n.position = pivot
	add_child(n)
	_box(n, center, size, tex, tint)
	return n


func _box(parent: Node3D, center: Vector3, size: Vector3, tex: int, tint: Color) -> void:
	var s := ChunkMesher.Surf.new()
	# (vertex colours are linear: convert, or the colours come out washed out)
	var lin := tint.srgb_to_linear()
	ChunkMesher.box_faces(s, -size * 0.5, size * 0.5, 0.0, Vector3.ZERO, tex, tex, Color(lin.r, lin.g, lin.b, 1.0))
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, s.arrays())
	m.surface_set_material(0, _mat)
	var mi := MeshInstance3D.new()
	mi.mesh = m
	mi.position = center
	parent.add_child(mi)


func set_first_person(on: bool) -> void:
	## In first person you see your legs and feet when you look down (and your
	## lap when you sit); head, chest and arms only cast shadows - from the eyes
	## the top of your own shoulders just reads as a slab.  The arm you see is
	## the first-person one.
	_first_person = on
	for c in [head, body, arm_l, arm_r]:
		_set_shadow_only(c, on)
	for c in [leg_l, leg_r]:
		_set_shadow_only(c, false)
	if _torch:
		_torch.visible = not on


func _set_shadow_only(n: Node, on: bool) -> void:
	if n is TorchModel:
		return
	if n is GeometryInstance3D:
		(n as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY if on else GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	for c in n.get_children():
		_set_shadow_only(c, on)


func set_held(id: String, d: Dictionary) -> void:
	var key := id + JSON.stringify(d.get("mat", "")) + String(d.get("c", ""))
	if key == _held_key:
		return
	_held_key = key
	if _torch:
		_torch.queue_free()
		_torch = null
	if id == "":
		held_mi.mesh = null
		return
	if id == "torch_lit":
		held_mi.mesh = null
		_torch = TorchModel.make(carry_light)
		_torch.scale = Vector3.ONE * 0.7
		_torch.position = Vector3(0, -0.12, -0.08)
		_torch.rotation = Vector3(deg_to_rad(-70), 0, 0)
		hand.add_child(_torch)
		_torch.visible = not _first_person   # in first person you see the one in your hand
		return
	held_mi.mesh = Icons.mesh(id, d)
	var is_block := ItemDB.block_of(id) >= 0 and Blocks.shape[ItemDB.block_of(id)] == Blocks.Shape.CUBE
	if is_block:
		held_mi.scale = Vector3.ONE * 0.22
		held_mi.position = Vector3(0, -0.02, -0.06)
		held_mi.rotation = Vector3(0.2, 0.6, 0)
	else:
		held_mi.scale = Vector3.ONE * 0.62
		held_mi.position = Vector3(0, 0.02, -0.12)
		held_mi.rotation = Vector3(0, deg_to_rad(90), deg_to_rad(-35))
	_set_shadow_only(held_mi, _first_person)


func _point(shin: Node3D, thigh: Node3D, dir: Vector3) -> void:
	## Turn a shin so it points along dir (model space), whatever its thigh does.
	var local := thigh.basis.inverse() * dir.normalized()
	shin.quaternion = Quaternion(Vector3.DOWN, local)


func swing(kind: String = "hit") -> void:
	_swing = 1.0
	_swing_kind = kind


func animate(delta: float, st: Dictionary) -> void:
	var speed: float = st.get("speed", 0.0)
	var crouch: bool = st.get("crouch", false)
	var air: bool = st.get("air", false)
	var pitch: float = st.get("pitch", 0.0)
	var action := String(st.get("action", ""))
	var mode := String(st.get("mode", "play"))
	_walk += delta * clampf(speed, 0.0, 7.0) * 2.4
	var amp := clampf(speed / 4.0, 0.0, 1.0) * 0.75
	if air:
		amp *= 0.4
	var sw := sin(_walk) * amp
	leg_l.rotation.x = sw
	leg_r.rotation.x = -sw
	# knees bend as each leg swings back through its step
	shin_l.rotation = Vector3(-maxf(0.0, -sin(_walk + 0.6)) * amp * 1.1, 0, 0)
	shin_r.rotation = Vector3(-maxf(0.0, sin(_walk + 0.6)) * amp * 1.1, 0, 0)
	arm_l.rotation.x = -sw * 0.8
	arm_r.rotation.x = sw * 0.8
	arm_l.rotation.z = 0.05
	arm_r.rotation.z = -0.05
	# looking up and down
	head.rotation.x = clampf(pitch, -1.2, 1.2)
	# sneaking: lean in, bend the knees a little
	var sit: bool = st.get("sit", false)
	var lean := 0.38 if crouch else (0.18 if sit else 0.0)
	body.rotation.x = lerpf(body.rotation.x, -lean, 1.0 - exp(-12.0 * delta))
	var drop := 0.18 if crouch else (0.6 if sit else 0.0)
	if sit:
		# cross-legged on the ground: thighs forward and out, shins crossed in
		# front, hands resting on the knees
		leg_l.rotation = Vector3(PI * 0.5, 0.62, 0.0)
		leg_r.rotation = Vector3(PI * 0.5, -0.62, 0.0)
		_point(shin_l, leg_l, Vector3(1.0, 0.1, 0.32))
		_point(shin_r, leg_r, Vector3(-1.0, -0.06, 0.22))
		arm_l.rotation = Vector3(-0.75, 0.0, 0.25)
		arm_r.rotation = Vector3(-0.75, 0.0, -0.25)
	else:
		leg_l.rotation.y = 0.0
		leg_l.rotation.z = 0.0
		leg_r.rotation.y = 0.0
		leg_r.rotation.z = 0.0
	position.y = lerpf(position.y, -drop, 1.0 - exp(-12.0 * delta))
	head.position.z = lerpf(head.position.z, -0.22 if crouch else 0.0, 1.0 - exp(-12.0 * delta))
	# working
	if action != "":
		match action:
			"drill":
				arm_r.rotation.x = -1.1 + sin(Time.get_ticks_msec() * 0.025) * 0.25
				arm_l.rotation.x = -0.9
			"eat", "drink":
				arm_r.rotation.x = -1.9 + sin(Time.get_ticks_msec() * 0.02) * 0.1
				arm_r.rotation.z = 0.4
			"hold":
				arm_r.rotation.x = -0.8
	if _swing > 0.0:
		_swing = maxf(0.0, _swing - delta * 4.5)
		var t := 1.0 - _swing
		arm_r.rotation.x = -1.6 + sin(t * PI) * 1.4 - pitch * 0.5
	if mode == "sleep":
		# lying down, head where the player is (on the pillow), feet behind
		rotation.x = -PI * 0.5
		position = Basis(Vector3.UP, rotation.y) * Vector3(0, 0.12, 1.5)
	else:
		if absf(rotation.x) > 0.01:
			rotation.x = 0.0
		# in first person, standing, the body sits a little behind the eyes (as
		# a real one does), so looking down shows your feet just below you
		var back := 0.1 if _first_person and not sit else 0.0
		var off := Basis(Vector3.UP, rotation.y) * Vector3(0, 0, back)
		position.x = off.x
		position.z = off.z
