extends EntityView
## A pit kiln: the raw pottery, then a mound of dry grass over it, then sticks
## laid across the mound.  Lit, it smoulders - glowing straw, a plume of smoke -
## for three hours.

var mound: MeshInstance3D
var pots: Node3D
var glow: OmniLight3D
var smoke: GPUParticles3D
var snd: AudioStreamPlayer3D
var _sig := ""
var _t := 0.0
var _lit := false


func _build() -> void:
	pots = Node3D.new()
	add_child(pots)
	mound = add_mesh(null)
	glow = OmniLight3D.new()
	glow.position = Vector3(0.5, 0.4, 0.5)
	glow.light_color = Color(1.0, 0.5, 0.22)
	glow.omni_range = 4.5
	glow.light_energy = 0.0
	add_child(glow)
	smoke = GPUParticles3D.new()
	smoke.amount = 40
	smoke.lifetime = 5.0
	smoke.position = Vector3(0.5, 0.5, 0.5)
	smoke.visibility_aabb = AABB(Vector3(-3, -1, -3), Vector3(6, 10, 6))
	var pm := ParticleProcessMaterial.new()
	pm.direction = Vector3(0, 1, 0)
	pm.spread = 15.0
	pm.initial_velocity_min = 0.5
	pm.initial_velocity_max = 0.9
	pm.gravity = Vector3(0.2, 0.15, 0.1)
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(0.3, 0.05, 0.3)
	var grad := Gradient.new()
	grad.set_color(0, Color(0.5, 0.48, 0.45, 0.45))
	grad.set_color(1, Color(0.6, 0.6, 0.6, 0.0))
	var gt := GradientTexture1D.new()
	gt.gradient = grad
	pm.color_ramp = gt
	pm.scale_min = 1.0
	pm.scale_max = 2.4
	smoke.process_material = pm
	var quad := QuadMesh.new()
	quad.size = Vector2(0.3, 0.3)
	quad.material = FirepitView.puff_material()
	smoke.draw_pass_1 = quad
	smoke.emitting = false
	add_child(smoke)


func _refresh(_keys: Array) -> void:
	var d := data()
	var lit := bool(d.get("lit", false))
	var sig := "%s|%d|%d|%s|%d" % [JSON.stringify(d.get("items", [])), int(d.get("grass", 0)), int(d.get("sticks", 0)), lit, int(d.get("stage", 0))]
	if sig == _sig:
		return
	_sig = sig
	_lit = lit
	for ch in pots.get_children():
		ch.queue_free()
	GroundView.place_items(pots, d.get("items", []))
	var grass := int(d.get("grass", 0))
	var sticks := int(d.get("sticks", 0))
	var stage := int(d.get("stage", 0))
	var boxes: Array = []
	var straw := "embers" if lit and stage >= 1 else "dry_grass"
	if lit and stage >= 3:
		straw = "ash"
	for i in grass:
		var k := float(i + 1) / FireActs.KILN_GRASS
		var r := 0.22 + 0.18 * k
		var h := 0.12 + 0.3 * k
		boxes.append([Vector3(0.5 - r, 0.0, 0.5 - r), Vector3(0.5 + r, h, 0.5 + r), straw if i == grass - 1 else "dry_grass", Color.WHITE, i * 0.35])
	var top := 0.12 + 0.3 * float(grass) / FireActs.KILN_GRASS
	for i in sticks:
		var ang := deg_to_rad(FirepitView.STICK_ANGLES[i % 8])
		var y := top - 0.03 + i * 0.022
		var tint := Color(0.4, 0.35, 0.33) if lit else Color.WHITE
		if not (lit and stage >= 2):
			boxes.append([Vector3(0.12, y, 0.475), Vector3(0.88, y + 0.04, 0.525), "stick", tint, ang])
	mound.mesh = boxes_mesh(boxes)
	smoke.emitting = lit
	if lit and snd == null:
		snd = Sfx.make_loop_player("mound_smolder", self, -8.0, 16.0)
		if snd:
			snd.position = Vector3(0.5, 0.3, 0.5)
			snd.play()
	elif not lit and snd:
		snd.queue_free()
		snd = null


func _process(delta: float) -> void:
	_t += delta
	glow.light_energy = (0.38 + sin(_t * 3.0) * 0.08 + sin(_t * 7.3) * 0.05) if _lit else 0.0
