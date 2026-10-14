extends Node3D
## Behind the title screen: the island floating in the sky, slowly circling.

var cam: Camera3D
var sky: SkyEnv
var _a := 0.6


func _ready() -> void:
	var terrain := TerrainData.new()
	terrain.generate()
	sky = SkyEnv.new()
	add_child(sky)
	sky.set_time(17.6)
	sky.cloud = 0.3
	var island := IslandView.new()
	island.interactive = false
	add_child(island)
	island.build(terrain)
	var scripts := {
		"tree": preload("res://src/entities/tree_view.gd"),
		"outcrop": preload("res://src/entities/rock_view.gd"),
		"flat_stone": preload("res://src/entities/rock_view.gd"),
		"boulder": preload("res://src/entities/rock_view.gd"),
		"mossy_log": preload("res://src/entities/rock_view.gd"),
		"mushrooms": preload("res://src/entities/mushroom_view.gd"),
		"bush": preload("res://src/entities/bush_view.gd"),
		"plant": preload("res://src/entities/plant_view.gd"),
		"item": preload("res://src/entities/item_view.gd"),
	}
	var i := 0
	for e in WorldGen.initial_entities(terrain):
		var sc: Script = scripts.get(e["t"])
		if sc == null:
			continue
		var v: EntityView = sc.new()
		v.entity_id = 100000 + i
		i += 1
		add_child(v)
		v.setup({"id": v.entity_id, "t": e["t"], "xf": e["xf"], "d": e["d"]})
	cam = Camera3D.new()
	cam.fov = 50.0
	cam.far = 2000.0
	add_child(cam)
	cam.current = true
	_place_camera()


func _process(delta: float) -> void:
	_a += delta * 0.035
	_place_camera()


func _place_camera() -> void:
	if cam == null:
		return
	var target := Vector3(-2.2, -1.5, 0.0)
	var r := 27.0
	cam.position = Vector3(cos(_a) * r, 7.5, sin(_a) * r)
	cam.look_at(target, Vector3.UP)
