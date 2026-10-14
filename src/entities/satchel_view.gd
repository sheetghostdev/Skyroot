extends EntityView
## The bag left where someone died, with their things in it.

var label: Label3D


func _build() -> void:
	var mesh := boxes_mesh([
		[Vector3(-0.22, 0, -0.16), Vector3(0.22, 0.3, 0.16), "bag"],
		[Vector3(-0.18, 0.3, -0.12), Vector3(0.18, 0.38, 0.12), "bag", Color(0.85, 0.85, 0.85)],
		[Vector3(-0.03, 0.38, -0.03), Vector3(0.03, 0.44, 0.03), "leather"],
	])
	add_mesh(mesh)
	label = Label3D.new()
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.position.y = 0.75
	label.pixel_size = 0.003
	label.font_size = 36
	label.outline_size = 8
	label.modulate = Color(1, 0.92, 0.75)
	add_child(label)


func _refresh(_keys: Array) -> void:
	label.text = "%s's things" % String(data().get("owner", "Someone"))
