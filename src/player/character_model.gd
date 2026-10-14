class_name CharacterModel
extends Node3D
## A player's body, assembled from rigid parts with joints at their origins and
## animated procedurally (walk/run/crouch/air + upper-body actions).  Uses the
## Blender model (assets/models/character/body.glb) when available.

const BODY := "res://assets/models/character/body.glb"
const HIERARCHY := {
	"Torso": "Pelvis", "Head": "Torso",
	"UpperArm_L": "Torso", "LowerArm_L": "UpperArm_L", "Hand_L": "LowerArm_L",
	"UpperArm_R": "Torso", "LowerArm_R": "UpperArm_R", "Hand_R": "LowerArm_R",
	"UpperLeg_L": "Pelvis", "LowerLeg_L": "UpperLeg_L", "Foot_L": "LowerLeg_L",
	"UpperLeg_R": "Pelvis", "LowerLeg_R": "UpperLeg_R", "Foot_R": "LowerLeg_R",
}
const JOINTS := {
	"Pelvis": Vector3(0, 0.95, 0), "Torso": Vector3(0, 1.0, 0), "Head": Vector3(0, 1.47, 0),
	"UpperArm_L": Vector3(0.2, 1.4, 0), "LowerArm_L": Vector3(0.22, 1.12, 0), "Hand_L": Vector3(0.23, 0.88, 0),
	"UpperArm_R": Vector3(-0.2, 1.4, 0), "LowerArm_R": Vector3(-0.22, 1.12, 0), "Hand_R": Vector3(-0.23, 0.88, 0),
	"UpperLeg_L": Vector3(0.1, 0.92, 0), "LowerLeg_L": Vector3(0.1, 0.5, 0), "Foot_L": Vector3(0.1, 0.08, 0),
	"UpperLeg_R": Vector3(-0.1, 0.92, 0), "LowerLeg_R": Vector3(-0.1, 0.5, 0), "Foot_R": Vector3(-0.1, 0.08, 0),
}

var rig: Node3D
var parts: Dictionary = {}
var rest: Dictionary = {}       # part -> rest local Transform3D
var held: Node3D
var held_id := ""
var cloth_mat: ShaderMaterial
var first_person := false

var _phase := 0.0
var _w := 0.0
var _crouch := 0.0
var _air := 0.0
var _action := ""
var _action_t := 1.0
var _action_len := 0.6
var _sleep := 0.0
var _dead := 0.0
var _craft := 0.0


func build(color: Color) -> void:
	rig = Node3D.new()
	rig.name = "Rig"
	rig.rotation.y = PI
	add_child(rig)
	var src := Models.instance(BODY)
	if src:
		_assemble_from(src, color)
	else:
		_assemble_procedural(color)
	for nm in parts:
		rest[nm] = parts[nm].transform


func _assemble_from(src: Node3D, color: Color) -> void:
	rig.add_child(src)
	var found: Dictionary = {}
	for nm in JOINTS:
		var n: Node3D = src.find_child(nm, true, false)
		if n:
			found[nm] = n
	if not found.has("Pelvis"):
		src.queue_free()
		_assemble_procedural(color)
		return
	# Rebuild the joint hierarchy while keeping rest positions.
	for nm in ["Pelvis", "Torso", "Head", "UpperArm_L", "LowerArm_L", "Hand_L", "UpperArm_R", "LowerArm_R", "Hand_R",
			"UpperLeg_L", "LowerLeg_L", "Foot_L", "UpperLeg_R", "LowerLeg_R", "Foot_R"]:
		if not found.has(nm):
			continue
		var n: Node3D = found[nm]
		var parent_name: String = HIERARCHY.get(nm, "")
		var xf := Models._rel_xf(src, n)
		if parent_name != "" and found.has(parent_name):
			var pxf := Models._rel_xf(src, found[parent_name])
			n.get_parent().remove_child(n)
			found[parent_name].add_child(n)
			n.transform = pxf.affine_inverse() * xf
		parts[nm] = n
	cloth_mat = Models.unique_material("Cloth")
	cloth_mat.set_shader_parameter("tint", color.lightened(0.15))
	for mi in Models.mesh_instances(src):
		if mi.mesh == null:
			continue
		for s in mi.mesh.get_surface_count():
			var m := mi.mesh.surface_get_material(s)
			if m and m.resource_name.begins_with("Cloth") and not m.resource_name.begins_with("ClothDark"):
				Models.set_surface_unique(mi, s, cloth_mat)


func _assemble_procedural(color: Color) -> void:
	var skin := Color(0.88, 0.68, 0.53)
	var cloth := Color(0.82, 0.8, 0.76)
	var dark := Color(0.32, 0.29, 0.27)
	var leather := Color(0.45, 0.31, 0.21)
	var specs := {
		"Pelvis": [Vector3(0.3, 0.2, 0.2), Vector3(0, -0.02, 0), dark, "capsule"],
		"Torso": [Vector3(0.36, 0.48, 0.22), Vector3(0, 0.22, 0), cloth, "capsule"],
		"Head": [Vector3(0.21, 0.25, 0.22), Vector3(0, 0.15, 0.0), skin, "sphere"],
		"UpperArm_L": [Vector3(0.1, 0.3, 0.1), Vector3(0.01, -0.13, 0), cloth, "capsule"],
		"LowerArm_L": [Vector3(0.085, 0.27, 0.085), Vector3(0.005, -0.12, 0), skin, "capsule"],
		"Hand_L": [Vector3(0.08, 0.13, 0.05), Vector3(0, -0.06, 0), skin, "capsule"],
		"UpperArm_R": [Vector3(0.1, 0.3, 0.1), Vector3(-0.01, -0.13, 0), cloth, "capsule"],
		"LowerArm_R": [Vector3(0.085, 0.27, 0.085), Vector3(-0.005, -0.12, 0), skin, "capsule"],
		"Hand_R": [Vector3(0.08, 0.13, 0.05), Vector3(0, -0.06, 0), skin, "capsule"],
		"UpperLeg_L": [Vector3(0.14, 0.44, 0.14), Vector3(0, -0.2, 0), dark, "capsule"],
		"LowerLeg_L": [Vector3(0.12, 0.44, 0.12), Vector3(0, -0.2, 0), dark, "capsule"],
		"Foot_L": [Vector3(0.11, 0.1, 0.24), Vector3(0, -0.03, 0.06), leather, "box"],
		"UpperLeg_R": [Vector3(0.14, 0.44, 0.14), Vector3(0, -0.2, 0), dark, "capsule"],
		"LowerLeg_R": [Vector3(0.12, 0.44, 0.12), Vector3(0, -0.2, 0), dark, "capsule"],
		"Foot_R": [Vector3(0.11, 0.1, 0.24), Vector3(0, -0.03, 0.06), leather, "box"],
	}
	cloth_mat = Models.unique_material("Cloth")
	cloth_mat.set_shader_parameter("tint", color.lightened(0.15))
	for nm in JOINTS:
		var pivot := Node3D.new()
		pivot.name = nm
		parts[nm] = pivot
	for nm in JOINTS:
		var pivot: Node3D = parts[nm]
		var parent_name: String = HIERARCHY.get(nm, "")
		if parent_name == "":
			rig.add_child(pivot)
			pivot.position = JOINTS[nm]
		else:
			parts[parent_name].add_child(pivot)
			pivot.position = JOINTS[nm] - JOINTS[parent_name]
		var sp: Array = specs[nm]
		var prim: PrimitiveMesh
		match sp[3]:
			"sphere":
				var s := SphereMesh.new()
				s.radius = sp[0].x * 0.5
				s.height = sp[0].y
				prim = s
			"box":
				var b := BoxMesh.new()
				b.size = sp[0]
				prim = b
			_:
				var c := CapsuleMesh.new()
				c.radius = minf(sp[0].x, sp[0].z) * 0.5
				c.height = maxf(sp[0].y, c.radius * 2.0)
				prim = c
		var mi := MeshInstance3D.new()
		mi.mesh = ProcMesh.painted(prim, sp[2])
		mi.position = sp[1]
		if nm == "Torso":
			mi.scale = Vector3(1.0, 1.0, 0.62)
			mi.material_override = cloth_mat
		elif sp[2] == cloth:
			mi.material_override = cloth_mat
		else:
			mi.material_override = Models.material_for("Skin" if sp[2] == skin else "ClothDark")
		pivot.add_child(mi)


func set_first_person(on: bool) -> void:
	first_person = on
	for mi in Models.mesh_instances(rig):
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY if on else GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	if held:
		for mi in Models.mesh_instances(held):
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY if on else GeometryInstance3D.SHADOW_CASTING_SETTING_ON


func set_held(item_id: String, d: Dictionary = {}) -> void:
	if item_id == held_id:
		return
	held_id = item_id
	if held:
		held.queue_free()
		held = null
	if item_id == "" or not parts.has("Hand_R"):
		return
	held = ItemVisual.make(item_id, d, 1)
	var hold := String(ItemDB.def(item_id).get("hold", "hand"))
	var s := ItemVisual.fit_scale(held, 1.0 if hold != "hand" else 0.25)
	held.scale = Vector3.ONE * s
	parts["Hand_R"].add_child(held)
	held.position = Vector3(0, -0.1, 0.02)
	if hold == "grip" or hold == "two":
		held.rotation = Vector3(0, 0, PI * 0.5)
	set_first_person(first_person)


func play_action(nm: String) -> void:
	_action = nm
	_action_t = 0.0
	_action_len = {"swing": 0.62, "chop": 0.62, "cut": 0.45, "dig": 0.7, "pick": 0.5, "place": 0.45, "eat": 1.1,
		"drink": 1.1, "pour": 1.0, "strike": 0.35, "hammer": 0.5, "bind": 0.8, "throw": 0.5, "pack": 0.6, "till": 0.7}.get(nm, 0.6)


func _rot(nm: String, e: Vector3) -> void:
	if parts.has(nm):
		var r: Transform3D = rest[nm]
		parts[nm].transform = Transform3D(r.basis * Basis.from_euler(e), r.origin)


func animate(delta: float, st: Dictionary) -> void:
	if parts.is_empty():
		return
	var speed := float(st.get("speed", 0.0))
	var target_w := clampf(speed / 3.7, 0.0, 1.7)
	_w = lerpf(_w, target_w, 1.0 - exp(-8.0 * delta))
	_crouch = lerpf(_crouch, 1.0 if st.get("crouch", false) else 0.0, 1.0 - exp(-10.0 * delta))
	_air = lerpf(_air, 1.0 if st.get("air", false) else 0.0, 1.0 - exp(-10.0 * delta))
	var mode := String(st.get("mode", "play"))
	_sleep = lerpf(_sleep, 1.0 if mode == "sleep" else 0.0, 1.0 - exp(-3.0 * delta))
	_dead = lerpf(_dead, 1.0 if mode == "dead" else 0.0, 1.0 - exp(-4.0 * delta))
	_craft = lerpf(_craft, 1.0 if mode == "craft" else 0.0, 1.0 - exp(-6.0 * delta))
	_phase += delta * (5.2 + _w * 2.4) * clampf(_w, 0.0, 1.0) * (0.75 if _crouch > 0.5 else 1.0)
	var t := Time.get_ticks_msec() / 1000.0
	var sw := sin(_phase)
	var cw := cos(_phase)
	var w := clampf(_w, 0.0, 1.0)
	var run := clampf(_w - 1.0, 0.0, 0.7)
	var legamp := 0.5 + run * 0.35
	var crouch := maxf(_crouch, _craft)
	# legs
	var hip_c := -1.05 * crouch
	var knee_c := 1.85 * crouch
	_rot("UpperLeg_L", Vector3(-sw * legamp * w + hip_c - _air * 0.45, 0, 0))
	_rot("UpperLeg_R", Vector3(sw * legamp * w + hip_c - _air * 0.25, 0, 0))
	_rot("LowerLeg_L", Vector3(maxf(0.0, cw) * 0.9 * w + knee_c + _air * 0.7, 0, 0))
	_rot("LowerLeg_R", Vector3(maxf(0.0, -cw) * 0.9 * w + knee_c + _air * 0.5, 0, 0))
	_rot("Foot_L", Vector3(-crouch * 0.75, 0, 0))
	_rot("Foot_R", Vector3(-crouch * 0.75, 0, 0))
	# pelvis & torso
	var pel: Transform3D = rest["Pelvis"]
	var bob := -absf(cw) * 0.035 * w - crouch * 0.36 - _air * 0.02
	parts["Pelvis"].transform = Transform3D(pel.basis * Basis.from_euler(Vector3(0, sw * 0.08 * w, 0)), pel.origin + Vector3(0, bob, 0))
	var lean := 0.06 * w + run * 0.2 + crouch * 0.38 + sin(t * 1.6) * 0.012
	_rot("Torso", Vector3(lean, -sw * 0.1 * w, 0))
	var pitch := float(st.get("pitch", 0.0))
	_rot("Head", Vector3(clampf(-pitch * 0.75, -0.7, 0.75) - lean * 0.6, 0, 0))
	# arms (base swing)
	var arm := 0.42 + run * 0.4
	var rx_l := sw * arm * w - 0.05
	var rx_r := -sw * arm * w - 0.05
	var el_l := -0.25 - 0.35 * w - run * 0.5
	var el_r := -0.25 - 0.35 * w - run * 0.5
	if _craft > 0.05:
		var k := sin(t * 5.0) * 0.12
		rx_l = lerpf(rx_l, -1.0 + k, _craft)
		rx_r = lerpf(rx_r, -1.05 - k, _craft)
		el_l = lerpf(el_l, -0.9, _craft)
		el_r = lerpf(el_r, -0.9, _craft)
	# upper-body action overlay
	if _action_t < 1.0:
		_action_t = minf(1.0, _action_t + delta / _action_len)
		var p := _action_t
		var e := sin(p * PI)
		match _action:
			"swing", "chop", "hammer":
				var wind := smoothstep(0.0, 0.45, p) * (1.0 - smoothstep(0.45, 0.62, p))
				var strike := smoothstep(0.45, 0.62, p) * (1.0 - smoothstep(0.75, 1.0, p))
				rx_r = lerpf(rx_r, -2.7, wind) + strike * -0.7
				el_r = lerpf(el_r, -1.3, wind) * (1.0 - strike * 0.6)
				rx_l = lerpf(rx_l, -0.8, e)
			"dig", "till", "pack":
				rx_r = lerpf(rx_r, -0.9 - sin(p * TAU) * 0.35, e)
				rx_l = lerpf(rx_l, -0.8 - sin(p * TAU) * 0.35, e)
				el_r = lerpf(el_r, -0.3, e)
				el_l = lerpf(el_l, -0.3, e)
				_rot("Torso", Vector3(lean + 0.35 * e, 0, 0))
			"pick", "place":
				rx_r = lerpf(rx_r, -1.1, e)
				el_r = lerpf(el_r, -0.2, e)
				_rot("Torso", Vector3(lean + 0.55 * e, 0, 0))
			"eat", "drink":
				rx_r = lerpf(rx_r, -1.9, e)
				el_r = lerpf(el_r, -2.2, e)
			"pour":
				rx_r = lerpf(rx_r, -1.3, e)
				el_r = lerpf(el_r, -0.4, e)
			"cut", "strike":
				rx_r = lerpf(rx_r, -1.2 + sin(p * PI * 2.0) * 0.3, e)
				el_r = lerpf(el_r, -0.7, e)
			"bind", "throw":
				rx_r = lerpf(rx_r, -1.5 + sin(p * 9.0) * 0.3, e)
				rx_l = lerpf(rx_l, -1.4 - sin(p * 9.0) * 0.3, e)
				el_r = lerpf(el_r, -0.9, e)
				el_l = lerpf(el_l, -0.9, e)
	_rot("UpperArm_L", Vector3(rx_l, 0, -0.06))
	_rot("UpperArm_R", Vector3(rx_r, 0, 0.06))
	_rot("LowerArm_L", Vector3(el_l, 0, 0))
	_rot("LowerArm_R", Vector3(el_r, 0, 0))
	# whole-body states
	rig.rotation = Vector3(-_sleep * PI * 0.5 - _dead * PI * 0.48, PI, 0)
	rig.position = Vector3(0, _sleep * 0.15 + _dead * 0.12, _sleep * 0.8 + _dead * 0.7)
