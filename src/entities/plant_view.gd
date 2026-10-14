extends EntityView
## Crops and wild plants: four visual growth stages per species, wilting when
## thirsty, yellowing when the soil is spent.

var model: Node3D
var _stage := -1
var _species := ""


func _build() -> void:
	var cyl := CylinderShape3D.new()
	cyl.radius = 0.2
	cyl.height = 0.6
	make_body(cyl, LAYER_INTERACT, "plant", Transform3D(Basis(), Vector3(0, 0.3, 0)))


func stage_of(g: float) -> int:
	return clampi(int(g * 3.999), 0, 3)


func _refresh(_keys: Array) -> void:
	var d := data()
	var sp := String(d.get("sp", "grain"))
	var g := float(d.get("g", 0.0))
	var st := stage_of(g)
	if st != _stage or sp != _species:
		_stage = st
		_species = sp
		if model:
			model.queue_free()
		var models: Array = ItemDB.plant(sp).get("models", [])
		var path := String(models[st]) if st < models.size() else ""
		if bool(d.get("wild", false)) and sp == "grain" and st == 3:
			path = "res://assets/models/nature/wild_grain.glb"
		model = Models.instance(path)
		if model == null:
			model = _fallback(sp, st)
		add_child(model)
	# growth within a stage, thirst and hunger
	var within := g * 4.0 - st
	model.scale = Vector3.ONE * (0.85 + 0.15 * clampf(within, 0.0, 1.0))
	var stress := float(d.get("thirst", 0.0))
	var hungry := float(d.get("hunger", 0.0))
	Models.set_role_param(model, "Plant", "dry", clampf(stress * 0.7 + hungry * 0.4, 0.0, 0.85))


func _fallback(sp: String, st: int) -> Node3D:
	var root := Node3D.new()
	var h: float = [0.08, 0.22, 0.45, 0.6][st] * (1.6 if sp == "fiber" else 1.0)
	var col := Color(0.35, 0.55, 0.2)
	if sp == "grain" and st == 3:
		col = Color(0.8, 0.68, 0.33)
	var blades := 6 if sp != "tuber" else 4
	for i in blades:
		var mi := MeshInstance3D.new()
		var cm := CylinderMesh.new()
		cm.top_radius = 0.003 if sp != "tuber" else 0.05
		cm.bottom_radius = 0.008
		cm.height = h
		cm.radial_segments = 5
		mi.mesh = ProcMesh.painted(cm, col)
		mi.material_override = Models.material_for("Plant")
		var a := i * TAU / blades
		mi.position = Vector3(cos(a) * 0.04, h * 0.5, sin(a) * 0.04)
		mi.rotation = Vector3(sin(a) * 0.25, 0, cos(a) * 0.25)
		root.add_child(mi)
	return root
