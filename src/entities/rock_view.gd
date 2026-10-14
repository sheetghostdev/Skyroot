extends EntityView
## Static natural features: the rock outcrop (with loose stones you can pry
## out), the flat work stone, boulders and the mossy log.

var model: Node3D
var loose_nodes: Array = []
var loose_areas: Array = []


func _model_path() -> String:
	match String(e["t"]):
		"outcrop": return "res://assets/models/nature/outcrop.glb"
		"flat_stone": return "res://assets/models/nature/flat_stone.glb"
		"mossy_log": return "res://assets/models/nature/mossy_log.glb"
		"boulder": return "res://assets/models/nature/boulder_%s.glb" % String(data().get("model", "a"))
	return ""


func _build() -> void:
	model = Models.instance(_model_path())
	if model == null:
		model = _fallback()
	add_child(model)
	var part: String = {"outcrop": "outcrop", "flat_stone": "surface", "boulder": "rock", "mossy_log": "log"}.get(String(e["t"]), "rock")
	for mi in Models.mesh_instances(model):
		if mi.mesh == null or mi.name.begins_with("Loose"):
			continue
		var shape := mi.mesh.create_convex_shape(true, true)
		make_body(shape, LAYER_STRUCT, part, model.transform * Models._rel_xf(model, mi), true)
	if String(e["t"]) == "outcrop":
		for i in 8:
			var ln: Node3D = model.find_child("Loose_%d" % i, true, false)
			if ln == null:
				ln = _fallback_stone(i)
				model.add_child(ln)
			loose_nodes.append(ln)
			var sph := SphereShape3D.new()
			sph.radius = 0.1
			var p := model.transform * Models._rel_xf(model, ln).origin
			var aabb := Models.aabb_of(ln)
			p = model.transform * (Models._rel_xf(model, ln) * aabb.get_center())
			loose_areas.append(make_body(sph, LAYER_INTERACT, "loose:%d" % i, Transform3D(Basis(), p)))


func _refresh(_keys: Array) -> void:
	if String(e["t"]) != "outcrop":
		return
	var loose: Array = data().get("loose", [])
	for i in loose_nodes.size():
		var present := i < loose.size() and int(loose[i]) > 0
		loose_nodes[i].visible = present
		loose_areas[i].collision_layer = LAYER_INTERACT if present else 0


func interaction_point(part: String) -> Vector3:
	if part.begins_with("loose:"):
		var i := int(part.get_slice(":", 1))
		if i < loose_areas.size():
			return loose_areas[i].global_position
	return global_position + Vector3(0, 0.5, 0)


func work_top() -> float:
	## Height of the flat work surface (world).
	var aabb := Models.aabb_of(model)
	return global_position.y + aabb.end.y


func _fallback() -> Node3D:
	var root := Node3D.new()
	var t := String(e["t"])
	var mi := MeshInstance3D.new()
	match t:
		"outcrop":
			for i in 5:
				var r := MeshInstance3D.new()
				r.mesh = ProcMesh.blob(0.55 - i * 0.06, Color(0.5, 0.48, 0.44), 30 + i, 0.75)
				r.material_override = Models.material_for("Stone")
				r.position = Vector3(cos(i * 1.7) * 0.6, i * 0.12, sin(i * 1.7) * 0.45)
				root.add_child(r)
			return root
		"flat_stone":
			mi.mesh = ProcMesh.blob(0.5, Color(0.55, 0.53, 0.49), 41, 0.45)
			mi.scale = Vector3(1.0, 1.0, 0.75)
		"mossy_log":
			mi.mesh = ProcMesh.log_mesh(0.15, 1.4)
			mi.position.y = 0.12
		_:
			mi.mesh = ProcMesh.blob(0.45, Color(0.52, 0.5, 0.46), 50 + t.length(), 0.7)
	mi.material_override = Models.material_for("Stone" if t != "mossy_log" else "Bark")
	root.add_child(mi)
	return root


func _fallback_stone(i: int) -> Node3D:
	var mi := MeshInstance3D.new()
	mi.name = "Loose_%d" % i
	mi.mesh = ProcMesh.stone(900 + i)
	mi.material_override = Models.material_for("Stone")
	var a := i * 0.785
	mi.position = Vector3(cos(a) * 0.75, 0.42 + 0.1 * sin(i * 2.1), sin(a) * 0.55)
	mi.rotation = Vector3(0.3 * sin(i), a, 0.2)
	return mi
