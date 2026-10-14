extends EntityView
## Mushrooms fruiting from rotting wood in the shade.  Each cap regrows on its own.

var model: Node3D
var caps: Array = []
var cap_areas: Array = []


func _build() -> void:
	model = Models.instance("res://assets/models/nature/mushroom_cluster.glb")
	if model == null:
		model = Node3D.new()
		for i in 4:
			model.add_child(_proc_mushroom(i))
	add_child(model)
	for i in 4:
		var c: Node3D = model.find_child("Mushroom_%d" % i, true, false)
		caps.append(c)
		var sph := SphereShape3D.new()
		sph.radius = 0.07
		var p := Vector3(cos(i * 1.6) * 0.12, 0.08, sin(i * 1.6) * 0.1)
		if c:
			p = model.transform * (Models._rel_xf(model, c) * Models.aabb_of(c).get_center())
		cap_areas.append(make_body(sph, LAYER_INTERACT, "cap:%d" % i, Transform3D(Basis(), p)))


func _refresh(_keys: Array) -> void:
	var g: Array = data().get("caps", [])
	for i in caps.size():
		var gg := float(g[i]) if i < g.size() else 0.0
		if caps[i]:
			caps[i].visible = gg > 0.05
			caps[i].scale = Vector3.ONE * clampf(0.3 + gg * 0.7, 0.3, 1.0)
		cap_areas[i].collision_layer = LAYER_INTERACT if gg > 0.05 else 0


func _proc_mushroom(i: int) -> Node3D:
	var n := Node3D.new()
	n.name = "Mushroom_%d" % i
	n.position = Vector3(cos(i * 1.6) * 0.12, 0.0, sin(i * 1.6) * 0.1)
	var stem := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 0.012
	cm.bottom_radius = 0.016
	cm.height = 0.06
	stem.mesh = cm
	var sm := StandardMaterial3D.new()
	sm.albedo_color = Color(0.9, 0.86, 0.75)
	stem.material_override = sm
	stem.position.y = 0.03
	n.add_child(stem)
	var cap := MeshInstance3D.new()
	cap.mesh = ProcMesh.blob(0.04, Color(0.55, 0.3, 0.2), 70 + i, 0.5)
	cap.material_override = Models.material_for("Fruit")
	cap.position.y = 0.055
	n.add_child(cap)
	return n
