extends EntityView
## A built piece.  Placed, it is a pale frame showing what it will become; each
## part appears as someone installs it (the next one glows faintly); finished,
## it becomes solid.  An overloaded piece sags; one that has lost its support
## shakes before it falls.

var bp: Dictionary = {}
var model: Node3D
var parts: Array = []           # MeshInstance3D per blueprint part, in order
var area: Area3D
var body: StaticBody3D
var _ghost_mat: StandardMaterial3D
var _next_mat: StandardMaterial3D
var _installed := -1
var _t := 0.0
var _base_xf := Transform3D.IDENTITY


func _build() -> void:
	var d := data()
	bp = ItemDB.blueprint(String(d.get("bp", "")))
	var sy := float(d.get("sy", 1.0))
	model = Models.instance(String(bp.get("model", "")))
	if model == null:
		model = Node3D.new()
		var box := StructureSim.local_box(String(d.get("bp", "")), 1.0)
		var mi := Models.placeholder(box.size, Color(0.6, 0.45, 0.3))
		mi.position = box.get_center()
		mi.name = "Part_00"
		model.add_child(mi)
	model.scale = Vector3(1.0, sy, 1.0)
	add_child(model)
	_base_xf = model.transform
	var found: Array = []
	for c in Models.mesh_instances(model):
		if String(c.name).begins_with("Part_"):
			found.append(c)
	found.sort_custom(func(a, b): return String(a.name) < String(b.name))
	parts = found
	_ghost_mat = StandardMaterial3D.new()
	_ghost_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_ghost_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_ghost_mat.albedo_color = Color(0.85, 0.92, 1.0, 0.12)
	_ghost_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_next_mat = _ghost_mat.duplicate()
	_next_mat.albedo_color = Color(1.0, 0.86, 0.5, 0.35)
	area = Area3D.new()
	area.monitoring = false
	area.monitorable = false
	area.collision_layer = LAYER_INTERACT
	area.collision_mask = 0
	area.set_meta("eid", entity_id)
	area.set_meta("part", "frame")
	var cs := CollisionShape3D.new()
	var bx := BoxShape3D.new()
	var lb := StructureSim.local_box(String(d.get("bp", "")), sy)
	bx.size = lb.size.max(Vector3(0.12, 0.12, 0.12))
	cs.shape = bx
	cs.position = lb.get_center()
	area.add_child(cs)
	add_child(area)


func _refresh(keys: Array) -> void:
	var d := data()
	var n := int(d.get("installed", 0))
	if n != _installed:
		var grew := n > _installed and _installed >= 0
		_installed = n
		for i in parts.size():
			var p: MeshInstance3D = parts[i]
			if i < n:
				p.material_override = null
				p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
			else:
				p.material_override = _next_mat if i == n else _ghost_mat
				p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		if grew and n - 1 < parts.size():
			# the part that just went in settles into place
			var p2: MeshInstance3D = parts[n - 1]
			var to := p2.position
			p2.position = to + Vector3(0, 0.06, 0)
			var tw := create_tween()
			tw.tween_property(p2, "position", to, 0.18).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		_update_body(n >= parts.size())


func _update_body(complete: bool) -> void:
	var kind := String(bp.get("kind", ""))
	if complete and body == null and kind != "ladder":
		body = StaticBody3D.new()
		body.collision_layer = LAYER_STRUCT
		body.collision_mask = 0
		body.set_meta("eid", entity_id)
		body.set_meta("part", "structure")
		for p in parts:
			var mi: MeshInstance3D = p
			if mi.mesh == null:
				continue
			var cs := CollisionShape3D.new()
			cs.shape = mi.mesh.create_trimesh_shape()
			cs.transform = _rel(mi)
			body.add_child(cs)
		add_child(body)
	elif not complete and body != null:
		body.queue_free()
		body = null
	# the frame's aiming volume stays while building (and on ladders, which you climb through)
	area.visible = true
	for c in area.get_children():
		(c as CollisionShape3D).disabled = complete and kind != "ladder"


func _rel(n: Node3D) -> Transform3D:
	var xf := Transform3D.IDENTITY
	var cur: Node = n
	while cur != null and cur != self:
		if cur is Node3D:
			xf = (cur as Node3D).transform * xf
		cur = cur.get_parent()
	return xf


func _process(delta: float) -> void:
	_t += delta
	if _installed < parts.size() and _installed >= 0 and _installed < parts.size():
		_next_mat.albedo_color.a = 0.22 + 0.16 * sin(_t * 4.0)
	var stress := float(data().get("stress", 0.0))
	if stress <= 0.01:
		if model.transform != _base_xf:
			model.transform = _base_xf
		return
	# sagging under load; shaking when it is about to go
	var sag := Transform3D(Basis(Vector3.RIGHT, deg_to_rad(0.8 * stress)), Vector3(0, -0.025 * stress, 0))
	if stress >= 1.0:
		sag.origin += Vector3(sin(_t * 37.0), sin(_t * 23.0 + 1.0), cos(_t * 31.0)) * 0.006
	model.transform = sag * _base_xf


func interaction_point(_part: String) -> Vector3:
	return global_position
