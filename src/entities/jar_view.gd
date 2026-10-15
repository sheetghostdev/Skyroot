extends EntityView
## A fired storage jar standing on the ground (a wooden lid on it once there's
## something inside).

var mi: MeshInstance3D
var _full := false


func _build() -> void:
	mi = add_mesh(null)
	mi.scale = Vector3.ONE * 1.15
	mi.position = Vector3(0.5, 0.0, 0.5)
	mi.rotation.y = 0.4
	_full = not (data().get("inv", []) as Array).is_empty()
	mi.mesh = ItemModels.mesh("jar", {"inv": data().get("inv", [])})


func _refresh(_keys: Array) -> void:
	var full := not (data().get("inv", []) as Array).is_empty()
	if full != _full:
		_full = full
		mi.mesh = ItemModels.mesh("jar", {"inv": data().get("inv", [])})
