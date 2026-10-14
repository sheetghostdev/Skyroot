extends EntityView
## An item stack lying in the world.

var model: Node3D
var body: CollisionObject3D
var _key := ""
var _fall: Tween


func _build() -> void:
	_rebuild()


func on_changed(ent: Dictionary, keys: Array) -> void:
	var was := transform.origin
	super.on_changed(ent, keys)
	if not keys.has("xf") or model == null:
		return
	# moved straight down (what held it up has gone): it falls there
	var drop := was.y - transform.origin.y
	if drop > 0.12 and Vector2(was.x - transform.origin.x, was.z - transform.origin.z).length() < 0.05:
		if _fall:
			_fall.kill()
		model.position = transform.basis.inverse() * Vector3(0, drop, 0)
		_fall = create_tween()
		_fall.tween_property(model, "position", Vector3.ZERO, sqrt(2.0 * drop / 9.8)).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)


func _refresh(keys: Array) -> void:
	var d := data()
	var key := ItemVisual.visual_key(String(d.get("i", "")), int(d.get("n", 1)), d.get("x", {}))
	var rebuilt := key != _key
	if rebuilt:
		_rebuild()
	var heat := float(d.get("heat", 20.0))
	if model and (keys.has("heat") or keys.has("char") or (rebuilt and (heat > 400.0 or float(d.get("char", 0.0)) > 0.0))):
		var glow := clampf((heat - 450.0) / 400.0, 0.0, 1.0)
		var charred := clampf(float(d.get("char", 0.0)), 0.0, 1.0)
		for mi in Models.mesh_instances(model):
			var m := mi.material_override
			if m == null:
				continue
			if not mi.has_meta("unique_mat"):
				m = m.duplicate()
				mi.material_override = m
				mi.set_meta("unique_mat", true)
			if m is ShaderMaterial:
				m.set_shader_parameter("char_amount", charred)
				m.set_shader_parameter("emission_strength", glow * 1.1)
		_override_surfaces(charred, glow)


func _override_surfaces(charred: float, glow: float) -> void:
	for mi in Models.mesh_instances(model):
		if mi.mesh == null:
			continue
		for s in mi.mesh.get_surface_count():
			var m := mi.get_surface_override_material(s)
			if m is ShaderMaterial:
				if not mi.has_meta("unique_surf_%d" % s):
					m = m.duplicate()
					Models.set_surface_unique(mi, s, m)
					mi.set_meta("unique_surf_%d" % s, true)
				m.set_shader_parameter("char_amount", charred)
				m.set_shader_parameter("emission_strength", glow * 1.1)


func _rebuild() -> void:
	var d := data()
	_key = ItemVisual.visual_key(String(d.get("i", "")), int(d.get("n", 1)), d.get("x", {}))
	if _fall:
		_fall.kill()
		_fall = null
	if model:
		model.queue_free()
	if body:
		body.queue_free()
	var x: Dictionary = d.get("x", {}).duplicate()
	if String(d.get("i", "")) == "stone" and not x.has("seed"):
		x["seed"] = (entity_id * 7919) % 100003
	model = ItemVisual.make(String(d.get("i", "")), x, int(d.get("n", 1)))
	add_child(model)
	var aabb := Models.aabb_of(model)
	if aabb.size.length() < 0.001:
		aabb = AABB(Vector3(-0.05, 0, -0.05), Vector3(0.1, 0.08, 0.1))
	var box := BoxShape3D.new()
	box.size = Vector3(maxf(aabb.size.x, 0.06), maxf(aabb.size.y, 0.05), maxf(aabb.size.z, 0.06))
	body = make_body(box, LAYER_ITEMS, "item", Transform3D(Basis(), aabb.get_center()))


func top_height() -> float:
	var aabb := Models.aabb_of(model) if model else AABB()
	return global_position.y + aabb.end.y
