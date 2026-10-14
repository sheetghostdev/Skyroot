class_name FPView
extends Node3D
## What you see of yourself in first person: your right arm and whatever it
## holds, bobbing as you walk, swinging as you work, sawing a bow drill, raising
## food to your mouth.

const REST := Vector3(0.34, -0.33, -0.55)
const ARM_REST := Vector3(0.42, -0.44, -0.36)

var item: MeshInstance3D
var arm: Node3D
var _swing := 0.0
var _action := ""
var _t := 0.0
var _bob := Vector3.ZERO
var _sneak := 0.0
var _held := ""
var _change := 0.0
var _base_rot := Vector3.ZERO


func _ready() -> void:
	arm = Node3D.new()
	add_child(arm)
	var mat := ShaderMaterial.new()
	mat.shader = load("res://assets/shaders/voxel_solid.gdshader")
	mat.set_shader_parameter("atlas", BlockTex.array())
	mat.set_shader_parameter("ao_light", 0.0)
	for part in [[Vector3(0, 0, 0.06), Vector3(0.11, 0.11, 0.42), "cloth", Color(0.85, 0.8, 0.7)],
			[Vector3(0, 0, -0.2), Vector3(0.1, 0.1, 0.12), "skin", Color.WHITE]]:
		var s := ChunkMesher.Surf.new()
		var size: Vector3 = part[1]
		var tex := BlockTex.layer(String(part[2]))
		var c: Color = part[3]
		ChunkMesher.box_faces(s, -size * 0.5, size * 0.5, 0.0, Vector3.ZERO, tex, tex, Color(c.r, c.g, c.b, 1.0))
		var m := ArrayMesh.new()
		m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, s.arrays())
		m.surface_set_material(0, mat)
		var mi := MeshInstance3D.new()
		mi.mesh = m
		mi.position = part[0]
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		arm.add_child(mi)
	arm.position = ARM_REST
	arm.rotation = Vector3(deg_to_rad(8), deg_to_rad(-12), 0)
	item = MeshInstance3D.new()
	item.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(item)


func set_held(id: String, d: Dictionary) -> void:
	var key := id + str(d.get("mat", "")) + str(d.get("c", ""))
	if key == _held:
		return
	_held = key
	_change = 1.0
	if id == "":
		item.mesh = null
		arm.visible = true
		return
	arm.visible = false
	item.mesh = Icons.mesh(id, d)
	var b := ItemDB.block_of(id)
	if b >= 0 and Blocks.shape[b] == Blocks.Shape.CUBE:
		item.scale = Vector3.ONE * 0.17
		_base_rot = Vector3(deg_to_rad(10), deg_to_rad(40), 0)
	else:
		item.scale = Vector3.ONE * 0.3
		_base_rot = Vector3(0, deg_to_rad(-80), deg_to_rad(18))


func swing() -> void:
	_swing = 1.0


func set_action(a: String) -> void:
	_action = a


func animate(delta: float, bob_t: float, bob_amt: float, sneak: bool) -> void:
	_t += delta
	_change = maxf(0.0, _change - delta * 5.0)
	_bob = Vector3(cos(bob_t) * 0.012, -absf(sin(bob_t)) * 0.018, 0.0) * bob_amt
	var off := _bob + Vector3(0, -0.12 * _change, 0)
	var rot := Vector3.ZERO
	match _action:
		"drill":
			off += Vector3(-0.14 + sin(_t * 18.0) * 0.07, 0.04, -0.05)
			rot += Vector3(0, 0, deg_to_rad(30))
		"eat", "drink":
			off += Vector3(-0.2, 0.12 + sin(_t * 14.0) * 0.015, 0.14)
			rot += Vector3(deg_to_rad(-30), deg_to_rad(40), 0)
		"hold":
			off += Vector3(-0.05, 0.05, -0.04)
	if _swing > 0.0:
		_swing = maxf(0.0, _swing - delta * 5.5)
		var t := 1.0 - _swing
		var s := sin(t * PI)
		off += Vector3(-0.1 * s, -0.08 * sin(t * TAU) * 0.6, -0.12 * s)
		rot += Vector3(deg_to_rad(-55.0) * s, deg_to_rad(15.0) * s, 0)
	item.position = REST + off
	item.rotation = _base_rot + rot
	arm.position = ARM_REST + off
	arm.rotation = Vector3(deg_to_rad(8), deg_to_rad(-12), 0) + rot
