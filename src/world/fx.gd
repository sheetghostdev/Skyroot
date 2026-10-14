class_name FX
extends Node3D
## One-shot effects requested by the host (World.fx) or played locally: little
## cubes of whatever broke, chips, sparks, splashes, smoke - and their sounds.

const BLOCK_SOUNDS := {
	"stone": ["stone_break", "stone_drop"], "dirt": ["dig_soil", "place_soil"], "grass": ["cut_grass", "place_soil"],
	"clay": ["dig_clay", "clay_slap"], "gravel": ["dig_soil", "stone_drop"], "wood": ["wood_split", "wood_drop"],
	"leaves": ["rustle", "rustle"],
}

var _pool: Array[GPUParticles3D] = []
var _next := 0


func _ready() -> void:
	add_to_group("fx")
	for i in 20:
		var p := GPUParticles3D.new()
		p.one_shot = true
		p.emitting = false
		p.explosiveness = 0.95
		p.local_coords = false
		p.visibility_aabb = AABB(Vector3(-4, -4, -4), Vector3(8, 8, 8))
		var pm := ParticleProcessMaterial.new()
		pm.direction = Vector3(0, 1, 0)
		pm.spread = 70.0
		pm.damping_min = 0.4
		pm.damping_max = 1.2
		pm.angular_velocity_min = -400.0
		pm.angular_velocity_max = 400.0
		pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
		pm.emission_box_extents = Vector3(0.3, 0.3, 0.3)
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


func burst(pos: Vector3, col: Color, amount: int, size: float, speed: float, gravity: float, life: float, extent := 0.3) -> void:
	if amount <= 0:
		return
	var p := _pool[_next]
	_next = (_next + 1) % _pool.size()
	p.emitting = false
	p.amount = amount
	p.lifetime = life
	var pm: ParticleProcessMaterial = p.process_material
	pm.color = col
	pm.initial_velocity_min = speed * 0.4
	pm.initial_velocity_max = speed
	pm.gravity = Vector3(0, -gravity, 0)
	pm.scale_min = size * 0.6
	pm.scale_max = size * 1.3
	pm.emission_box_extents = Vector3(extent, extent, extent)
	p.global_position = pos
	p.restart()
	p.emitting = true


func _block_col(b: int) -> Color:
	return BlockTex.avg_color(Blocks.face_tex[b * 6 + 2]) if b > 0 else Color(0.5, 0.45, 0.4)


func _snd(b: int, which: int) -> String:
	var s := String(Blocks.def(b).get("sound", "dirt"))
	return BLOCK_SOUNDS.get(s, BLOCK_SOUNDS["dirt"])[which]


func play(kind: String, pos: Vector3, params: Dictionary = {}) -> void:
	var b := int(params.get("b", 0))
	match kind:
		"break":
			burst(pos, _block_col(b), 14 if not params.get("quiet", false) else 6, 0.07, 3.0, 12.0, 0.8)
			Sfx.play(_snd(b, 0), pos, -4.0 if not params.get("quiet", false) else -12.0)
		"place":
			if b > 0:
				Sfx.play(_snd(b, 1), pos, -6.0)
			else:
				Sfx.play("drop_item", pos, -8.0)
		"break_be":
			burst(pos, Color(0.55, 0.45, 0.35), 8, 0.05, 1.8, 10.0, 0.6)
			Sfx.play("wood_drop", pos, -8.0)
		"pickup":
			if int(params.get("pid", -1)) == multiplayer.get_unique_id():
				Sfx.play("pickup", null, -12.0)
		"tool_break":
			burst(pos, Color(0.6, 0.55, 0.5), 10, 0.04, 2.0, 10.0, 0.7)
			Sfx.play("branch_snap", pos, 0.0)
		"lost":
			Sfx.play("fall_whoosh", pos, -14.0)
		"eat":
			Sfx.play("eat", pos, -4.0)
		"drink":
			Sfx.play("drink", pos, -4.0)
		"craft":
			if int(params.get("pid", -1)) == multiplayer.get_unique_id():
				Sfx.play("rope_tighten", null, -10.0)
		"place_fuel":
			var id := String(params.get("i", ""))
			Sfx.play("wood_drop" if id == "stick" or id == "firewood" else "rustle", pos, -6.0)
		"ignite":
			burst(pos, Color(1.0, 0.6, 0.2), 18, 0.025, 2.2, -1.0, 0.8, 0.15)
			Sfx.play("fire_ignite", pos, 0.0)
		"fire_out":
			burst(pos + Vector3(0, 0.3, 0), Color(0.6, 0.6, 0.6), 10, 0.14, 0.6, -0.8, 2.2, 0.2)
			Sfx.play("fire_out", pos, -2.0)
		"splash":
			burst(pos, Color(0.7, 0.82, 0.92), 14, 0.04, 2.0, 9.0, 0.6, 0.2)
			Sfx.play("water_fill", pos, -4.0)
		"spill":
			burst(pos, Color(0.7, 0.82, 0.92), 10, 0.04, 1.2, 9.0, 0.9, 0.3)
			Sfx.play("water_splash", pos, -14.0, 1.0, 0.15)
		"sizzle":
			burst(pos, Color(0.8, 0.8, 0.8), 6, 0.1, 0.5, -0.8, 1.4, 0.1)
			Sfx.play("sizzle", pos, -6.0)
		"knap":
			var col := Color(0.35, 0.38, 0.44) if String(params.get("mat", "")) == "flint" else Color(0.55, 0.53, 0.5)
			burst(pos, col, 5, 0.025, 2.4, 12.0, 0.5, 0.02)
			Sfx.play("knap", pos, -2.0)
		"knap_fall":
			var colf := Color(0.35, 0.38, 0.44) if String(params.get("mat", "")) == "flint" else Color(0.55, 0.53, 0.5)
			burst(pos, colf, clampi(int(params.get("n", 10)) / 3, 6, 30), 0.035, 1.6, 12.0, 0.7, 0.35)
			Sfx.play("stone_drop", pos, -10.0)
		"knap_fail":
			burst(pos, Color(0.5, 0.48, 0.45), 16, 0.05, 2.0, 10.0, 0.8, 0.2)
			Sfx.play("stone_break", pos, 0.0)
		"knap_done":
			burst(pos, Color(0.9, 0.85, 0.6), 10, 0.02, 1.2, -0.5, 1.0, 0.25)
			Sfx.play("discovery", pos, -8.0)
		"clay":
			Sfx.play("clay_squish", pos, -6.0)
		"clay_done":
			burst(pos, Color(0.9, 0.85, 0.6), 10, 0.02, 1.2, -0.5, 1.0, 0.25)
			Sfx.play("clay_smooth", pos, -2.0)
		"kiln_done":
			burst(pos + Vector3(0, 0.3, 0), Color(0.6, 0.6, 0.6), 16, 0.16, 0.7, -0.6, 2.6, 0.3)
			Sfx.play("pottery_tap", pos, 0.0)
		"tree_fall":
			# the tree topples over (TreeFall plays the crash as it lands)
			Sfx.play("tree_creak", pos + Vector3(0.5, 2.0, 0.5), -2.0)
			burst(pos + Vector3(0.5, 0.4, 0.5), Color(0.55, 0.45, 0.32), 10, 0.05, 2.0, 10.0, 0.6, 0.3)
			add_child(TreeFall.make(Vector3i(pos), params))
		"harvest":
			burst(pos, Color(0.3, 0.4, 0.8), 6, 0.03, 1.0, 8.0, 0.6, 0.2)
			Sfx.play("berry_pick", pos, -4.0)
		"till":
			burst(pos, _block_col(Blocks.id_of("dirt")), 10, 0.05, 1.6, 10.0, 0.6, 0.3)
			Sfx.play("dig_soil", pos, -4.0)
