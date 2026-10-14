class_name IconCache
extends Node
## Renders item icons from their real 3D models (so a hand-made bowl's icon is
## that bowl) in an off-screen viewport, one per frame, and caches them.

signal icon_ready(key: String)

const SIZE := 96

var vp: SubViewport
var cam: Camera3D
var stage: Node3D
var cache: Dictionary = {}
var queue: Array = []
var queued: Dictionary = {}
var _busy := false
var _enabled := true


func _ready() -> void:
	_enabled = DisplayServer.get_name() != "headless"
	vp = SubViewport.new()
	vp.size = Vector2i(SIZE, SIZE)
	vp.own_world_3d = true
	vp.transparent_bg = true
	vp.msaa_3d = Viewport.MSAA_4X
	vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(vp)
	var env := Environment.new()
	env.background_mode = Environment.BG_CLEAR_COLOR
	env.background_color = Color(0, 0, 0, 0)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.75, 0.78, 0.85)
	env.ambient_light_energy = 0.75
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var we := WorldEnvironment.new()
	we.environment = env
	vp.add_child(we)
	var key := DirectionalLight3D.new()
	key.rotation = Vector3(deg_to_rad(-48), deg_to_rad(35), 0)
	key.light_energy = 1.3
	vp.add_child(key)
	var rim := DirectionalLight3D.new()
	rim.rotation = Vector3(deg_to_rad(-20), deg_to_rad(200), 0)
	rim.light_energy = 0.5
	rim.light_color = Color(0.8, 0.88, 1.0)
	vp.add_child(rim)
	cam = Camera3D.new()
	cam.fov = 30.0
	vp.add_child(cam)
	stage = Node3D.new()
	vp.add_child(stage)


func get_icon(id: String, d: Dictionary = {}) -> Texture2D:
	if id == "":
		return null
	var key := ItemDB.icon_key(id, _icon_data(id, d))
	if cache.has(key):
		return cache[key]
	if _enabled and not queued.has(key):
		queued[key] = true
		queue.append([key, id, _icon_data(id, d)])
	return null


func _icon_data(id: String, d: Dictionary) -> Dictionary:
	# moisture doesn't change how an item looks enough to deserve its own icon
	if d.size() == 1 and d.has("moist"):
		return {}
	if id == "pot":
		var x := d.duplicate()
		x.erase("water")
		x.erase("heat")
		return x
	return d


func _process(_delta: float) -> void:
	if _busy or queue.is_empty() or not _enabled:
		return
	_render(queue.pop_front())


func _render(job: Array) -> void:
	_busy = true
	for c in stage.get_children():
		c.queue_free()
	var model := ItemVisual.single(String(job[1]), job[2])
	if model == null:
		_busy = false
		return
	stage.add_child(model)
	var aabb := Models.aabb_of(model)
	var center := aabb.get_center()
	var radius := maxf(aabb.size.length() * 0.5, 0.02)
	var dir := Vector3(0.55, 0.62, 0.95).normalized()
	var long_item := aabb.size.x > aabb.size.y * 3.0 and aabb.size.x > aabb.size.z * 2.0
	if long_item:
		model.rotation.y = deg_to_rad(38.0)
		aabb = Models.aabb_of(model)
		center = aabb.get_center()
	var dist := radius / tan(deg_to_rad(cam.fov * 0.5)) * 1.08
	cam.position = center + dir * dist
	cam.look_at(center, Vector3.UP)
	cam.near = maxf(0.005, dist - radius * 2.0)
	cam.far = dist + radius * 2.0
	vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	await RenderingServer.frame_post_draw
	var img := vp.get_texture().get_image()
	if img:
		cache[String(job[0])] = ImageTexture.create_from_image(img)
		icon_ready.emit(String(job[0]))
	_busy = false
