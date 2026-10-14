extends EntityView
## A fired storage jar standing on the ground.


func _build() -> void:
	var mi := add_mesh(Icons.mesh("jar"))
	mi.scale = Vector3.ONE * 0.85
	mi.position = Vector3(0.5, 0.36, 0.5)
	# a second, crossed copy so it reads as round from any side
	var mi2 := add_mesh(Icons.mesh("jar"))
	mi2.scale = Vector3.ONE * 0.85
	mi2.position = Vector3(0.5, 0.36, 0.5)
	mi2.rotation.y = PI * 0.5
