class_name TorchModel
extends Node3D
## A burning torch: a stick with a glowing head of tow and a flame licking up
## from it.  The head and flame give their own light, so they glow on every
## side.  Placed torches (one per torch block, standing or leaning out from a
## wall), the torch in your hand and the ones other players carry all use it.
## The origin is the foot of the stick; the flame always stands upright.

const HEAD := 0.62           # height of the head's middle above the foot

var body: Node3D
var flame_root: Node3D
var light: OmniLight3D
var _t := 0.0


static func make(with_light: bool) -> TorchModel:
	var t := TorchModel.new()
	t._t = randf() * 10.0
	t.body = Node3D.new()
	t.add_child(t.body)
	var stick := MeshInstance3D.new()
	stick.mesh = EntityModels.get_or_build("mesh:torch_stick", func():
		return EntityView.boxes_mesh([[Vector3(-0.05, 0.0, -0.05), Vector3(0.05, 0.6, 0.05), "stick"]]))
	t.body.add_child(stick)
	var head := MeshInstance3D.new()
	head.mesh = EntityModels.get_or_build("mesh:torch_head", func():
		return EntityView.boxes_mesh([[Vector3(-0.085, 0.53, -0.085), Vector3(0.085, 0.71, 0.085), "embers"]], _ember_mat()))
	head.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	t.body.add_child(head)
	t.flame_root = Node3D.new()
	t.add_child(t.flame_root)
	var quad: QuadMesh = EntityModels.get_or_build("mesh:torch_flame", func():
		var q := QuadMesh.new()
		q.size = Vector2(0.26, 0.42)
		q.center_offset = Vector3(0, 0.19, 0)
		return q)
	for i in 3:
		var mi := MeshInstance3D.new()
		mi.mesh = quad
		mi.material_override = _flame_mat()
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.rotation.y = i * PI / 3.0
		t.flame_root.add_child(mi)
	if with_light:
		t.light = OmniLight3D.new()
		t.light.light_color = Color(1.0, 0.66, 0.34)
		t.light.light_energy = 1.4
		t.light.omni_range = 8.0
		t.light.omni_attenuation = 1.2
		t.light.shadow_enabled = false
		t.light.position = Vector3(0, 0.16, 0)
		t.flame_root.add_child(t.light)
	t.set_lean(Vector3.ZERO, 0.0)
	return t


func set_lean(away: Vector3, angle: float) -> void:
	## Tilt the stick toward `away` (a wall torch leans out from its wall).
	if away == Vector3.ZERO or angle == 0.0:
		body.basis = Basis.IDENTITY
	else:
		body.basis = Basis(Vector3.UP.cross(away).normalized(), angle)
	flame_root.position = body.basis * Vector3(0, HEAD + 0.07, 0)


func place_block(cell_pos: Vector3, m: int) -> void:
	## Stand it in a block cell (cell_pos: the cell's corner), or hang it on the
	## wall its meta names.
	if Blocks.on_wall(Blocks.id_of("torch"), m):
		var w := Vector3(Blocks.wall_dir(m))
		position = cell_pos + Vector3(0.5, 0.12, 0.5) + w * 0.42
		set_lean(-w, deg_to_rad(28))
	else:
		position = cell_pos + Vector3(0.5, 0.0, 0.5)
		set_lean(Vector3.ZERO, 0.0)


static func _ember_mat() -> ShaderMaterial:
	return EntityModels.get_or_build("mat:torch_head", func():
		var m := ShaderMaterial.new()
		m.shader = load("res://assets/shaders/embers.gdshader")
		m.set_shader_parameter("atlas", BlockTex.array())
		m.set_shader_parameter("layer", float(BlockTex.layer("torch_head")))
		return m)


static func _flame_mat() -> ShaderMaterial:
	return EntityModels.get_or_build("mat:flame", func():
		var m := ShaderMaterial.new()
		m.shader = load("res://assets/shaders/flame.gdshader")
		m.set_shader_parameter("atlas", BlockTex.array())
		m.set_shader_parameter("layer", float(BlockTex.layer("flame")))
		return m)


func _process(delta: float) -> void:
	_t += delta
	# the flame stands up whichever way the torch is held, and dances a little
	var s := global_basis.get_scale()
	flame_root.global_basis = Basis.IDENTITY.scaled(s)
	var i := 0
	for f in flame_root.get_children():
		if f is MeshInstance3D:
			(f as Node3D).scale = Vector3(1.0 + sin(_t * 7.0 + i) * 0.06, 1.0 + sin(_t * 9.3 + i * 2.1) * 0.12 + sin(_t * 17.0 + i) * 0.05, 1.0)
			i += 1
	if light:
		light.light_energy = 1.35 + sin(_t * 9.0) * 0.08 + sin(_t * 23.0 + 1.3) * 0.05
