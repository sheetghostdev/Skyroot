extends Node3D
## Quick look at the island: generates it, meshes it and saves screenshots from
## a few viewpoints.  godot --path . res://tests/vox_preview.tscn -- --out=dir

var views := [
	["overview", Vector3(70, 62, 70), Vector3(32, 38, 32)],
	["ground", Vector3(28, 46.6, 38), Vector3(36, 45, 26)],
	["pond", Vector3(30, 47, 44), Vector3(23, 43, 38)],
	["under", Vector3(60, 18, 64), Vector3(32, 30, 32)],
]
var cam: Camera3D
var sky: SkyEnv
var vv: VoxelView
var out := "/tmp/claude-0/vox"
var hour := 10.0


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			out = arg.substr(6)
		if arg.begins_with("--hour="):
			hour = float(arg.substr(7))
	DirAccess.make_dir_recursive_absolute(out)
	var t0 := Time.get_ticks_msec()
	World.new_world("Preview")
	World.env["t"] = 24.0 + hour
	print("gen ms ", Time.get_ticks_msec() - t0)
	sky = SkyEnv.new()
	add_child(sky)
	vv = VoxelView.new()
	add_child(vv)
	t0 = Time.get_ticks_msec()
	vv.build(World.vox, true)
	print("mesh ms ", Time.get_ticks_msec() - t0, " chunks ", vv.chunks.size())
	cam = Camera3D.new()
	cam.fov = 75
	cam.far = 1000
	add_child(cam)
	cam.current = true
	_shoot.call_deferred()


func _shoot() -> void:
	for v in views:
		cam.look_at_from_position(v[1], v[2])
		for i in 12:
			await get_tree().process_frame
		var img := get_viewport().get_texture().get_image()
		img.save_png("%s/%s.png" % [out, v[0]])
		print("SHOT ", v[0])
	get_tree().quit()
