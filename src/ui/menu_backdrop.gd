extends Node3D
## The title screen's live background: the island, slowly turning, at golden hour.

var vd := VoxelData.new()
var cam: Camera3D
var sky: SkyEnv
var view: VoxelView
var _a := 0.6


func _ready() -> void:
	IslandGen.generate(vd)
	sky = SkyEnv.new()
	add_child(sky)
	sky.set_time(17.6)
	view = VoxelView.new()
	add_child(view)
	view.build(vd, true)
	cam = Camera3D.new()
	cam.fov = 62
	cam.far = 1200
	add_child(cam)
	cam.current = true
	_place_camera()


func _process(delta: float) -> void:
	_a += delta * 0.035
	_place_camera()


func _place_camera() -> void:
	var c := Vector3(32, 38, 32)
	cam.look_at_from_position(c + Vector3(cos(_a) * 58.0, 18.0, sin(_a) * 58.0), c + Vector3(-12, 2, 0))
