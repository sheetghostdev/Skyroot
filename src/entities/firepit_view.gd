extends EntityView
class_name FirepitView
## A fire pit.  Each stick lies across the ones before it - the first two make
## an X, the next two a cross over that, and so on - with the tinder tucked into
## the middle underneath and firewood stacked on top.  Lit, it flickers, glows,
## smokes and warms; burnt down, a bed of ash.  Food roasts on sticks leaning
## over it; a pot sits in the middle.

const STICK_ANGLES := [45.0, -45.0, 0.0, 90.0, 22.5, -67.5, 67.5, -22.5]
const SPIT_ANGLES := [35.0, 125.0, 215.0, 305.0]

var fuel_mi: MeshInstance3D
var food_root: Node3D
var pot_root: Node3D
var _bobbers: Array = []
var _fuel_top := 0.12
var flames: Array[MeshInstance3D] = []
var flame_mat: ShaderMaterial
var ember_mi: MeshInstance3D
var light: OmniLight3D
var smoke: GPUParticles3D
var sparks: GPUParticles3D
var snd: AudioStreamPlayer3D
var _t := 0.0
var _heat := 0.0
var _sig := ""


func _build() -> void:
	fuel_mi = add_mesh(null)
	food_root = Node3D.new()
	add_child(food_root)
	pot_root = Node3D.new()
	add_child(pot_root)
	flame_mat = EntityModels.get_or_build("mat:flame", func():
		var m := ShaderMaterial.new()
		m.shader = load("res://assets/shaders/flame.gdshader")
		m.set_shader_parameter("atlas", BlockTex.array())
		m.set_shader_parameter("layer", float(BlockTex.layer("flame")))
		return m)
	var quad := QuadMesh.new()
	quad.size = Vector2(0.42, 0.62)
	quad.center_offset = Vector3(0, 0.31, 0)
	for i in 3:
		var mi := MeshInstance3D.new()
		mi.mesh = quad
		mi.material_override = flame_mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.position = Vector3(0.5, 0.06, 0.5)
		mi.rotation.y = i * PI / 3.0
		mi.visible = false
		add_child(mi)
		flames.append(mi)
	ember_mi = add_mesh(boxes_mesh([[Vector3(0.3, 0.005, 0.3), Vector3(0.7, 0.05, 0.7), "embers"]], _ember_mat()), Transform3D.IDENTITY, false)
	ember_mi.visible = false
	light = OmniLight3D.new()
	light.position = Vector3(0.5, 1.0, 0.5)
	light.light_color = Color(1.0, 0.62, 0.3)
	light.omni_range = 8.0
	light.omni_attenuation = 1.4
	light.light_energy = 0.0
	light.shadow_enabled = true
	add_child(light)
	smoke = _particles(Color(0.55, 0.55, 0.55, 0.35), 0.18, 1.2, 3.6, 24)
	sparks = _particles(Color(1.0, 0.65, 0.25), 0.02, 2.2, 1.0, 12)
	sparks.emitting = false
	smoke.emitting = false


func _ember_mat() -> ShaderMaterial:
	return EntityModels.get_or_build("mat:embers", func():
		var m := ShaderMaterial.new()
		m.shader = load("res://assets/shaders/embers.gdshader")
		m.set_shader_parameter("atlas", BlockTex.array())
		m.set_shader_parameter("layer", float(BlockTex.layer("embers")))
		return m)


func _particles(col: Color, size: float, speed: float, life: float, amount: int) -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.amount = amount
	p.lifetime = life
	p.position = Vector3(0.5, 0.35, 0.5)
	p.visibility_aabb = AABB(Vector3(-2, -1, -2), Vector3(4, 8, 4))
	var pm := ParticleProcessMaterial.new()
	pm.direction = Vector3(0, 1, 0)
	pm.spread = 12.0
	pm.initial_velocity_min = speed * 0.6
	pm.initial_velocity_max = speed
	pm.gravity = Vector3(0.15, 0.25, 0.05)
	pm.scale_min = 0.6
	pm.scale_max = 1.4
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = 0.12
	var curve := CurveTexture.new()
	var cv := Curve.new()
	cv.add_point(Vector2(0, 0.4))
	cv.add_point(Vector2(0.4, 1.0))
	cv.add_point(Vector2(1, 1.6))
	curve.curve = cv
	pm.scale_curve = curve
	var grad := Gradient.new()
	grad.set_color(0, col)
	grad.set_color(1, Color(col.r, col.g, col.b, 0.0))
	var gt := GradientTexture1D.new()
	gt.gradient = grad
	pm.color_ramp = gt
	p.process_material = pm
	var quad := QuadMesh.new()
	quad.size = Vector2(size, size)
	quad.material = puff_material()
	p.draw_pass_1 = quad
	add_child(p)
	return p


static func puff_material() -> StandardMaterial3D:
	## Soft round particles (smoke, sparks).
	return EntityModels.get_or_build("mat:puff", func():
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.vertex_color_use_as_albedo = true
		mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
		var g := Gradient.new()
		g.set_color(0, Color(1, 1, 1, 1))
		g.set_color(1, Color(1, 1, 1, 0))
		var gt := GradientTexture2D.new()
		gt.gradient = g
		gt.fill = GradientTexture2D.FILL_RADIAL
		gt.fill_from = Vector2(0.5, 0.5)
		gt.fill_to = Vector2(1.0, 0.5)
		gt.width = 32
		gt.height = 32
		mat.albedo_texture = gt
		return mat)


func _refresh(_keys: Array) -> void:
	var d := data()
	var lit := bool(d.get("lit", false))
	var sig := "%d|%d|%d|%s|%s" % [int(d.get("tinder", 0)), int(d.get("sticks", 0)), int(d.get("logs", 0)), lit, bool(d.get("ash", false))]
	if sig != _sig:
		_sig = sig
		fuel_mi.mesh = _fuel_mesh(d)
	_heat = float(d.get("heat", 0.0)) if lit else 0.0
	for f in flames:
		f.visible = lit
	ember_mi.visible = lit
	smoke.emitting = lit
	sparks.emitting = lit and _heat > 0.6
	if lit and snd == null:
		snd = Sfx.make_loop_player("fire_small", self, -6.0, 18.0)
		if snd:
			snd.position = Vector3(0.5, 0.3, 0.5)
			snd.play()
	elif not lit and snd:
		snd.queue_free()
		snd = null
	_build_food(d)
	_build_pot(d)


func _fuel_mesh(d: Dictionary) -> ArrayMesh:
	var boxes: Array = []
	var lit := bool(d.get("lit", false))
	var ash := bool(d.get("ash", false))
	var c := Vector3(0.5, 0, 0.5)
	if ash or lit:
		boxes.append([Vector3(0.14, 0.0, 0.14), Vector3(0.86, 0.02, 0.86), "ash"])
	var tinder := int(d.get("tinder", 0))
	if tinder > 0:
		var r := 0.08 + 0.035 * tinder
		boxes.append([c - Vector3(r, -0.005, r), c + Vector3(r, 0.05 + 0.02 * tinder, r), "dry_grass", Color.WHITE, 0.3])
		boxes.append([c - Vector3(r * 0.7, -0.03, r * 0.7), c + Vector3(r * 0.7, 0.08 + 0.02 * tinder, r * 0.7), "dry_grass", Color(1.05, 1.0, 0.9), 1.1])
	var sticks := int(d.get("sticks", 0))
	var base_y := 0.05 + (0.03 * tinder if tinder > 0 else 0.0)
	for i in sticks:
		var ang := deg_to_rad(STICK_ANGLES[i % STICK_ANGLES.size()])
		var y := base_y + i * 0.032
		var half := 0.36
		boxes.append([c + Vector3(-half, y, -0.024), c + Vector3(half, y + 0.045, 0.024), "charred" if lit and i < 2 else "stick", Color(0.6, 0.55, 0.52) if lit else Color.WHITE, ang])
	var logs := int(d.get("logs", 0))
	var top := base_y + sticks * 0.032 + 0.04
	# the highest point of the fuel: a pot sits on top of it, not inside it
	_fuel_top = top + (0.0 if logs == 0 else (0.11 if logs <= 2 else 0.21))
	for i in logs:
		var along_x := i < 2
		var off := (-0.17 if i % 2 == 0 else 0.17)
		var y := top + (0.0 if i < 2 else 0.1)
		var tint2 := Color(0.5, 0.45, 0.42) if lit else Color.WHITE
		if along_x:
			boxes.append([c + Vector3(-0.34, y, off - 0.06), c + Vector3(0.34, y + 0.11, off + 0.06), "firewood", tint2])
		else:
			boxes.append([c + Vector3(off - 0.06, y, -0.34), c + Vector3(off + 0.06, y + 0.11, 0.34), "firewood", tint2])
	return boxes_mesh(boxes)


func _build_food(d: Dictionary) -> void:
	for ch in food_root.get_children():
		ch.queue_free()
	var food: Array = d.get("food", [])
	for i in food.size():
		var f: Dictionary = food[i]
		var a := deg_to_rad(SPIT_ANGLES[i % 4])
		var root := Node3D.new()
		root.position = Vector3(0.5, 0.0, 0.5)
		root.rotation.y = a
		food_root.add_child(root)
		# a stick pushed into the ground at the edge, leaning in over the fire
		var stick := boxes_mesh([[Vector3(-0.02, 0, -0.02), Vector3(0.02, 0.55, 0.02), "stick"]])
		var smi := MeshInstance3D.new()
		smi.mesh = stick
		smi.position = Vector3(0.44, 0, 0)
		smi.rotation.z = deg_to_rad(38)
		root.add_child(smi)
		var model := ItemModels.mesh(String(f["i"]))
		var mi := MeshInstance3D.new()
		if model:
			# skewered on the end of the stick
			mi.mesh = model
			mi.scale = Vector3.ONE * 1.1
			mi.position = Vector3(0.12, 0.39, 0)
			mi.rotation.z = deg_to_rad(-20)
		else:
			mi.mesh = Icons.mesh(String(f["i"]))
			mi.scale = Vector3.ONE * 0.22
			mi.position = Vector3(0.14, 0.43, 0)
			mi.rotation.y = PI * 0.5
		root.add_child(mi)


func _build_pot(d: Dictionary) -> void:
	for ch in pot_root.get_children():
		ch.queue_free()
	var pot: Dictionary = d.get("pot", {})
	if pot.is_empty():
		return
	var water := int(pot.get("water", 0))
	var stew := int(pot.get("stew", 0))
	var mi := MeshInstance3D.new()
	mi.mesh = ItemModels.mesh("pot", {"w": water} if stew == 0 else {"stew": stew})
	mi.position = Vector3(0.5, 0.0, 0.5)
	pot_root.add_child(mi)
	# resting on the sticks and firewood, not sunk into them
	pot_root.position.y = maxf(0.0, _fuel_top - 0.02)
	# what's in it floats in the water (and bobs once it boils)
	_bobbers.clear()
	var items: Array = pot.get("items", [])
	for i in items.size():
		var bob := ItemModels.node(String(items[i]))
		var a := TAU * i / maxf(1.0, items.size()) + 0.5
		bob.position = Vector3(0.5, 0.29, 0.5) + Vector3(sin(a), 0, cos(a)) * (0.09 if items.size() > 1 else 0.0)
		bob.rotation.y = a
		bob.scale = Vector3.ONE * 0.85
		pot_root.add_child(bob)
		_bobbers.append(bob)


func _process(delta: float) -> void:
	_t += delta
	for i in _bobbers.size():
		var b: Node3D = _bobbers[i]
		if is_instance_valid(b):
			var boil := clampf(_heat, 0.0, 1.0)
			b.position.y = 0.29 + sin(_t * (2.0 + boil * 3.0) + i * 1.9) * (0.004 + boil * 0.012)
			b.rotation.y += delta * (0.1 + boil * 0.4) * (1.0 if i % 2 == 0 else -1.0)
	if _heat <= 0.0:
		if light.light_energy > 0.0:
			light.light_energy = maxf(0.0, light.light_energy - delta * 2.0)
		return
	var flick := 1.0 + sin(_t * 11.0) * 0.08 + sin(_t * 23.0 + 1.3) * 0.06 + sin(_t * 5.3) * 0.05
	light.light_energy = (0.5 + _heat * 0.9) * flick
	light.omni_range = 6.0 + _heat * 4.0
	var hs := 0.45 + _heat * 0.75
	for i in flames.size():
		var f := flames[i]
		f.scale = Vector3(0.7 + _heat * 0.6, hs * (1.0 + sin(_t * 9.0 + i * 2.1) * 0.08), 1.0)
		f.rotation.y = i * PI / 3.0 + sin(_t * 0.7 + i) * 0.1
