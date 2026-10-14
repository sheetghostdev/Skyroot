extends EntityView
## The berry bush: berries ripen again over time if the bush has water.

var model: Node3D
var berries: Node3D


func _build() -> void:
	model = Models.instance("res://assets/models/nature/berry_bush.glb")
	if model == null:
		model = Node3D.new()
		var b := MeshInstance3D.new()
		b.mesh = ProcMesh.blob(0.5, Color(0.28, 0.45, 0.2), 81, 0.85)
		b.material_override = Models.material_for("Leaves")
		model.add_child(b)
		var br := Node3D.new()
		br.name = "Berries"
		for i in 18:
			var dot := MeshInstance3D.new()
			dot.mesh = ProcMesh.blob(0.025, Color(0.75, 0.15, 0.22), i, 1.0)
			dot.material_override = Models.material_for("Fruit")
			var a := i * 2.4
			var y := 0.25 + fmod(i * 0.37, 0.5)
			dot.position = Vector3(cos(a) * 0.45, y, sin(a) * 0.45)
			br.add_child(dot)
		model.add_child(br)
	add_child(model)
	berries = model.find_child("Berries", true, false)
	var sph := SphereShape3D.new()
	sph.radius = 0.55
	make_body(sph, LAYER_INTERACT, "bush", Transform3D(Basis(), Vector3(0, 0.45, 0)))


func _refresh(_keys: Array) -> void:
	var b := float(data().get("berries", 0.0))
	if berries:
		berries.visible = b > 0.2
		berries.scale = Vector3.ONE * clampf(0.75 + b * 0.25, 0.75, 1.0)
