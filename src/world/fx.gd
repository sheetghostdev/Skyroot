class_name FX
extends Node3D
## One-shot effects requested by the host (World.fx) or locally: particles + sound.

const SPECS := {
	# kind: [sound, color, amount, size, speed, gravity, lifetime]
	"chips": ["knap", Color(0.55, 0.54, 0.52), 14, 0.012, 2.4, 9.0, 0.9],
	"stone_break": ["stone_break", Color(0.5, 0.49, 0.46), 22, 0.02, 2.0, 9.0, 1.0],
	"dust": ["dig_soil", Color(0.35, 0.26, 0.18), 18, 0.03, 1.4, 6.0, 0.9],
	"clay_dig": ["dig_clay", Color(0.55, 0.32, 0.22), 12, 0.03, 1.2, 7.0, 0.8],
	"wood_chips": ["chop", Color(0.78, 0.62, 0.45), 14, 0.018, 2.6, 9.0, 1.0],
	"wood_split": ["wood_split", Color(0.8, 0.65, 0.48), 18, 0.02, 2.2, 9.0, 1.0],
	"leaves": ["rustle", Color(0.35, 0.55, 0.22), 16, 0.035, 1.0, 1.6, 2.2],
	"grass": ["cut_grass", Color(0.45, 0.62, 0.28), 12, 0.025, 1.4, 4.0, 1.2],
	"splash": ["water_splash", Color(0.7, 0.82, 0.9, 0.7), 16, 0.025, 2.0, 7.0, 0.7],
	"pour": ["water_fill", Color(0.7, 0.82, 0.9, 0.7), 10, 0.02, 0.6, 9.0, 0.6],
	"sparks": ["fire_ignite", Color(1.0, 0.6, 0.2), 20, 0.012, 2.0, -1.0, 0.8],
	"smoke_puff": ["", Color(0.6, 0.6, 0.6, 0.5), 8, 0.12, 0.5, -0.6, 2.4],
	"ash": ["", Color(0.6, 0.6, 0.58), 10, 0.02, 0.7, 2.0, 1.5],
	"soil_place": ["place_soil", Color(0.33, 0.24, 0.17), 10, 0.03, 0.9, 7.0, 0.7],
	"clay_squish": ["clay_squish", Color(0.5, 0.31, 0.22), 6, 0.015, 0.6, 7.0, 0.5],
	"build": ["hammer_wood", Color(0.75, 0.6, 0.45), 8, 0.015, 1.4, 8.0, 0.7],
	"bind": ["rope_tighten", Color(0.75, 0.66, 0.45), 4, 0.01, 0.5, 6.0, 0.5],
	"pickup": ["pickup", Color(1, 1, 1, 0), 0, 0.0, 0.0, 0.0, 0.1],
	"drop": ["drop_item", Color(1, 1, 1, 0), 0, 0.0, 0.0, 0.0, 0.1],
	"eat": ["eat", Color(1, 1, 1, 0), 0, 0.0, 0.0, 0.0, 0.1],
	"drink": ["drink", Color(1, 1, 1, 0), 0, 0.0, 0.0, 0.0, 0.1],
	"harvest": ["harvest_pop", Color(0.45, 0.35, 0.25), 8, 0.02, 1.0, 6.0, 0.6],
	"berries": ["berry_pick", Color(0.75, 0.2, 0.25), 4, 0.015, 0.6, 7.0, 0.5],
	"pottery_crack": ["pottery_crack", Color(0.7, 0.4, 0.25), 10, 0.015, 1.4, 8.0, 0.8],
	"creak": ["creak_warn", Color(1, 1, 1, 0), 0, 0.0, 0.0, 0.0, 0.1],
	"collapse": ["collapse", Color(0.7, 0.58, 0.42), 26, 0.04, 2.5, 9.0, 1.4],
	"complete": ["build_complete", Color(0.95, 0.85, 0.5), 14, 0.015, 1.2, -0.5, 1.2],
	"sizzle": ["sizzle", Color(0.8, 0.8, 0.8, 0.5), 8, 0.08, 0.6, -0.8, 1.5],
}

var _pool: Array[GPUParticles3D] = []
var _next := 0


func _ready() -> void:
	add_to_group("fx")
	for i in 16:
		var p := GPUParticles3D.new()
		p.one_shot = true
		p.emitting = false
		p.explosiveness = 0.92
		p.local_coords = false
		var pm := ParticleProcessMaterial.new()
		pm.direction = Vector3(0, 1, 0)
		pm.spread = 55.0
		pm.collision_mode = ParticleProcessMaterial.COLLISION_DISABLED
		pm.damping_min = 0.5
		pm.damping_max = 1.5
		pm.angular_velocity_min = -300.0
		pm.angular_velocity_max = 300.0
		p.process_material = pm
		var mesh := BoxMesh.new()
		mesh.size = Vector3.ONE
		var mat := StandardMaterial3D.new()
		mat.vertex_color_use_as_albedo = true
		mat.roughness = 0.9
		mesh.material = mat
		p.draw_pass_1 = mesh
		add_child(p)
		_pool.append(p)


func play(kind: String, pos: Vector3, params: Dictionary = {}) -> void:
	var spec: Array = SPECS.get(kind, ["", Color.WHITE, 0, 0.0, 0.0, 0.0, 0.1])
	var snd := String(params.get("sound", spec[0]))
	if snd != "":
		Sfx.play(snd, pos, float(params.get("vol", 0.0)), float(params.get("pitch", 1.0)))
	var amount := int(params.get("amount", spec[2]))
	if amount <= 0:
		return
	var p := _pool[_next]
	_next = (_next + 1) % _pool.size()
	p.emitting = false
	p.amount = amount
	p.lifetime = float(spec[6])
	var pm: ParticleProcessMaterial = p.process_material
	pm.color = params.get("color", spec[1])
	pm.scale_min = float(spec[3]) * 0.6
	pm.scale_max = float(spec[3]) * 1.4
	pm.initial_velocity_min = float(spec[4]) * 0.5
	pm.initial_velocity_max = float(spec[4])
	pm.gravity = Vector3(0, -float(spec[5]), 0)
	var dir: Vector3 = params.get("dir", Vector3.UP)
	pm.direction = dir
	var mat: StandardMaterial3D = (p.draw_pass_1 as BoxMesh).material
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA if pm.color.a < 0.99 else BaseMaterial3D.TRANSPARENCY_DISABLED
	p.global_position = pos
	p.restart()
	p.emitting = true
