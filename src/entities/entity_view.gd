class_name EntityView
extends Node3D
## Base class for the visual representation of a World entity.  Views never
## change world state; they only render it.

var entity_id := -1
var e: Dictionary = {}


func setup(ent: Dictionary) -> void:
	e = ent
	transform = ent["xf"]
	_build()
	_refresh(ent["d"].keys())


func on_changed(ent: Dictionary, keys: Array) -> void:
	e = ent
	if keys.has("xf"):
		_moved(ent["xf"])
	_refresh(keys)


func _moved(xf: Transform3D) -> void:
	transform = xf


func on_removed() -> void:
	queue_free()


func data() -> Dictionary:
	return e.get("d", {})


func _build() -> void:
	pass


func _refresh(_keys: Array) -> void:
	pass


static func block_mat() -> ShaderMaterial:
	return EntityModels.get_or_build("mat:block", func():
		var m := ShaderMaterial.new()
		m.shader = load("res://assets/shaders/voxel_solid.gdshader")
		m.set_shader_parameter("atlas", BlockTex.array())
		m.set_shader_parameter("ao_light", 0.0)
		return m)


static func boxes_mesh(boxes: Array, mat: Material = null) -> ArrayMesh:
	## [[a, b, tile name or layer, tint (Color), rot (radians)], ...] in block units.
	var s := ChunkMesher.Surf.new()
	for b in boxes:
		var tex: int = b[2] if b[2] is int else BlockTex.layer(String(b[2]))
		var col: Color = b[3] if b.size() > 3 else Color.WHITE
		var rot: float = b[4] if b.size() > 4 else 0.0
		ChunkMesher.box_faces(s, b[0], b[1], rot, Vector3.ZERO, tex, tex, Color(col.r, col.g, col.b, 1.0))
	var m := ArrayMesh.new()
	var arr := s.arrays()
	if arr.is_empty():
		return m
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	m.surface_set_material(0, mat if mat else block_mat())
	return m


func add_mesh(mesh: Mesh, xf := Transform3D.IDENTITY, shadow := true) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.transform = xf
	if not shadow:
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	return mi
