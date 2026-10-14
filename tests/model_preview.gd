extends Node3D
func _ready() -> void:
	var sky := SkyEnv.new()
	add_child(sky)
	sky.set_time(12.0)
	for i in 4:
		var m := CharacterModel.new()
		add_child(m)
		m.build(Net.COLORS[i])
		m.position = Vector3(i * 1.0 - 1.5, 0, 0)
		m.rotation.y = PI
	var cam := Camera3D.new()
	add_child(cam)
	cam.look_at_from_position(Vector3(0, 1.4, 3.6), Vector3(0, 1.0, 0))
	cam.current = true
	for i in 10:
		await get_tree().process_frame
	get_viewport().get_texture().get_image().save_png("/tmp/claude-0/shots/models.png")
	get_tree().quit()
