class_name SkyEnv
extends Node3D
## Sky, sun & moon, fog, the cloud sea of the abyss and rain.  Driven by the
## replicated environment (World.env) in game, or by set_time() in the menu.

var env: Environment
var world_env: WorldEnvironment
var sun: DirectionalLight3D
var moon: DirectionalLight3D
var sky_mat: ShaderMaterial
var sea_mats: Array[ShaderMaterial] = []
var seas: Array[MeshInstance3D] = []
var rain_fx: GPUParticles3D
var follow: Node3D = null

var hour := 9.5
var cloud := 0.25
var overcast := 0.0
var rain := 0.0
var fog_extra := 0.0
var wind := Vector2(1.2, 0.4)
var use_world := true

var current_day := 1.0
var current_rain := 0.0
var _drift := Vector2.ZERO
var _smooth := {}


func _ready() -> void:
	sky_mat = ShaderMaterial.new()
	sky_mat.shader = Tex.shader("res://assets/shaders/sky.gdshader")
	sky_mat.set_shader_parameter("cloud_noise", Tex.clouds())
	sky_mat.set_shader_parameter("cloud_detail", Tex.clouds_detail())
	var sky := Sky.new()
	sky.sky_material = sky_mat
	# realtime sky radiance must be 256 (the only size the realtime path supports)
	sky.radiance_size = Sky.RADIANCE_SIZE_256
	sky.process_mode = Sky.PROCESS_MODE_REALTIME
	env = Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	var tm := String(Game.cli.get("tonemap", "aces"))
	env.tonemap_mode = {"agx": Environment.TONE_MAPPER_AGX, "filmic": Environment.TONE_MAPPER_FILMIC, "aces": Environment.TONE_MAPPER_ACES}.get(tm, Environment.TONE_MAPPER_ACES)
	env.tonemap_exposure = 1.0
	env.tonemap_white = 6.0
	env.glow_enabled = true
	env.glow_intensity = 0.55
	env.glow_bloom = 0.06
	env.glow_hdr_threshold = 1.1
	env.ssao_enabled = Settings.ssao
	env.ssao_radius = 0.9
	env.ssao_intensity = 1.8
	env.ssao_power = 1.4
	env.ssao_detail = 0.6
	env.fog_enabled = true
	env.fog_density = 0.0035
	env.fog_sky_affect = 0.0
	env.fog_sun_scatter = 0.18
	env.fog_height = -10.0
	env.fog_height_density = 0.05
	env.adjustment_enabled = true
	env.adjustment_saturation = 1.06
	env.adjustment_contrast = 1.03
	world_env = WorldEnvironment.new()
	world_env.environment = env
	add_child(world_env)

	sun = DirectionalLight3D.new()
	sun.name = "Sun"
	sun.shadow_enabled = true
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	sun.directional_shadow_max_distance = 48.0
	sun.directional_shadow_split_1 = 0.22
	sun.directional_shadow_blend_splits = true
	sun.light_angular_distance = 0.6
	sun.shadow_bias = 0.04
	sun.shadow_normal_bias = 1.2
	sun.shadow_blur = 1.2
	add_child(sun)
	moon = DirectionalLight3D.new()
	moon.name = "Moon"
	moon.light_color = Color(0.55, 0.66, 0.95)
	moon.shadow_enabled = false
	moon.light_energy = 0.0
	moon.sky_mode = DirectionalLight3D.SKY_MODE_LIGHT_ONLY
	add_child(moon)

	for layer in [[-95.0, 0.62, 1.0], [-170.0, 0.75, 0.55]]:
		var m := ShaderMaterial.new()
		m.shader = Tex.shader("res://assets/shaders/cloud_sea.gdshader")
		m.set_shader_parameter("noise_a", Tex.clouds())
		m.set_shader_parameter("noise_b", Tex.clouds_detail())
		m.set_shader_parameter("density", layer[1])
		m.render_priority = -1 if layer[0] < -100.0 else 0
		var pm := PlaneMesh.new()
		pm.size = Vector2(2600, 2600)
		var mi := MeshInstance3D.new()
		mi.mesh = pm
		mi.material_override = m
		mi.position.y = layer[0]
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mi)
		seas.append(mi)
		sea_mats.append(m)
	_build_rain()
	Events.env_changed.connect(_on_env_changed)
	_on_env_changed()
	_apply(1.0)


func _build_rain() -> void:
	rain_fx = GPUParticles3D.new()
	rain_fx.amount = 1800
	rain_fx.lifetime = 1.1
	rain_fx.visibility_aabb = AABB(Vector3(-14, -12, -14), Vector3(28, 24, 28))
	rain_fx.emitting = false
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(12, 1, 12)
	pm.direction = Vector3(0.1, -1, 0)
	pm.spread = 3.0
	pm.initial_velocity_min = 13.0
	pm.initial_velocity_max = 16.0
	pm.gravity = Vector3(0, -6, 0)
	rain_fx.process_material = pm
	var quad := QuadMesh.new()
	quad.size = Vector2(0.012, 0.42)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(0.75, 0.82, 0.92, 0.35)
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_FIXED_Y
	mat.billboard_keep_scale = true
	quad.material = mat
	rain_fx.draw_pass_1 = quad
	rain_fx.position = Vector3(0, 9, 0)
	add_child(rain_fx)


func set_time(h: float) -> void:
	use_world = false
	hour = h


func _on_env_changed() -> void:
	if not use_world or World.env.is_empty():
		return
	hour = World.hour_of_day()
	cloud = float(World.env.get("cloud", 0.25))
	rain = float(World.env.get("rain", 0.0))
	overcast = clampf(cloud * 1.2 - 0.35, 0.0, 1.0) if rain <= 0.0 else clampf(0.55 + rain * 0.45, 0.0, 1.0)
	fog_extra = float(World.env.get("fog", 0.0))
	wind = World.env.get("wind", Vector2(1.2, 0.4))
	env.ssao_enabled = Settings.ssao


var _island: Node = null


func _process(delta: float) -> void:
	if use_world and not World.env.is_empty():
		# advance time smoothly between host updates (host advances it authoritatively)
		hour = World.hour_of_day()
	_apply(clampf(delta * 0.6, 0.0, 1.0))
	_drift += wind * delta * 0.0004
	sky_mat.set_shader_parameter("cloud_drift", _drift)
	for m in sea_mats:
		m.set_shader_parameter("drift", _drift * 0.6)
	var cam := get_viewport().get_camera_3d()
	if cam:
		for s in seas:
			s.global_position.x = cam.global_position.x
			s.global_position.z = cam.global_position.z
		rain_fx.global_position = cam.global_position + Vector3(0, 9, 0)


func _lerp_s(key: String, target: float, t: float) -> float:
	var v: float = _smooth.get(key, target)
	v = lerpf(v, target, t)
	_smooth[key] = v
	return v


func _apply(t: float) -> void:
	var h := fmod(hour + 24.0, 24.0)
	# Sun: rises 6:00, sets 20:00
	var dt := (h - 6.0) / 14.0
	var el := sin(clampf(dt, 0.0, 1.0) * PI) * deg_to_rad(64.0)
	if dt < 0.0 or dt > 1.0:
		el = -0.2
	var az := lerpf(deg_to_rad(-105.0), deg_to_rad(105.0), clampf(dt, 0.0, 1.0))
	var sun_dir := Vector3(-sin(az) * cos(el), sin(el), (cos(az) * 0.6 + 0.4) * cos(el)).normalized()
	var night_t := fmod(h - 20.0 + 24.0, 24.0) / 10.0  # 0 at 20:00 .. 1 at 06:00
	var mel := sin(clampf(night_t, 0.0, 1.0) * PI) * deg_to_rad(55.0)
	var maz := lerpf(deg_to_rad(-80.0), deg_to_rad(80.0), clampf(night_t, 0.0, 1.0))
	var moon_dir := Vector3(-sin(maz) * cos(mel), sin(mel), (cos(maz) * 0.6 + 0.4) * cos(mel)).normalized()

	var day := clampf(smoothstep(-0.12, 0.28, sin(el)), 0.0, 1.0)
	if dt < 0.0 or dt > 1.0:
		day = 0.0
	var sunset_k := clampf(1.0 - abs(sin(el)) / 0.32, 0.0, 1.0) * clampf(day * 2.5, 0.0, 1.0)
	day = _lerp_s("day", day, t)
	sunset_k = _lerp_s("sunset", sunset_k, t)
	var oc := _lerp_s("overcast", overcast, t * 0.5)
	var rn := _lerp_s("rain", rain, t * 0.5)

	if sin(el) > -0.02:
		sun.look_at_from_position(Vector3.ZERO, -sun_dir, Vector3.UP if abs(sun_dir.y) < 0.99 else Vector3.FORWARD)
	var warm := Color(1.0, 0.97, 0.9).lerp(Color(1.0, 0.66, 0.4), sunset_k)
	sun.light_color = warm.lerp(Color(0.8, 0.84, 0.9), oc * 0.6)
	sun.light_energy = maxf(0.0, (1.12 - sunset_k * 0.3) * day * (1.0 - oc * 0.5))
	sun.shadow_enabled = sun.light_energy > 0.05
	sun.shadow_opacity = 1.0 - oc * 0.5
	moon.look_at_from_position(Vector3.ZERO, -moon_dir, Vector3.UP if abs(moon_dir.y) < 0.99 else Vector3.FORWARD)
	moon.light_energy = (1.0 - day) * 0.28 * (1.0 - oc * 0.6) * clampf(sin(mel) * 3.0, 0.0, 1.0)
	moon.visible = moon.light_energy > 0.005

	sky_mat.set_shader_parameter("day", day)
	sky_mat.set_shader_parameter("sunset", sunset_k)
	sky_mat.set_shader_parameter("overcast", oc)
	sky_mat.set_shader_parameter("cloud_cover", clampf(cloud, 0.0, 1.0))
	sky_mat.set_shader_parameter("moon_dir", moon_dir)

	env.ambient_light_energy = lerpf(0.5, 0.62, day)
	env.ambient_light_sky_contribution = 0.85
	env.ambient_light_color = Color(0.55, 0.6, 0.7)
	env.background_energy_multiplier = lerpf(0.9, 1.0, day)
	var hor := Color(0.70, 0.80, 0.90).lerp(Color(0.05, 0.07, 0.13), 1.0 - day)
	hor = hor.lerp(Color(0.62, 0.65, 0.7) * lerpf(0.2, 1.0, day), oc * 0.7)
	hor = hor.lerp(Color(1.0, 0.6, 0.35), sunset_k * 0.3)
	env.fog_light_color = hor
	env.fog_density = 0.0028 + oc * 0.004 + rn * 0.006 + fog_extra * 0.03
	env.fog_light_energy = lerpf(0.35, 1.0, day)
	env.tonemap_exposure = lerpf(1.25, 0.95, day)
	for i in sea_mats.size():
		var m := sea_mats[i]
		m.set_shader_parameter("day", day)
		m.set_shader_parameter("fade_col", Color(0.30, 0.42, 0.62).lerp(Color(0.62, 0.65, 0.7), oc * 0.6))
		m.set_shader_parameter("lit_col", Color(0.95, 0.96, 1.0).lerp(Color(1.0, 0.75, 0.55), sunset_k * 0.6))
	rain_fx.emitting = rn > 0.05
	# the pond mirrors a little starlight and moonlight at night
	if _island == null or not is_instance_valid(_island):
		_island = get_tree().get_first_node_in_group("island_view")
	if _island and _island.get("water_mat"):
		var glow := Color(0.055, 0.08, 0.12) * (1.0 - day) * (1.0 - oc * 0.5) + Color(0.03, 0.045, 0.07) * moon.light_energy * 2.0
		(_island.water_mat as ShaderMaterial).set_shader_parameter("sky_glow", glow)
	rain_fx.amount_ratio = clampf(rn, 0.05, 1.0)
	current_day = day
	current_rain = rn
