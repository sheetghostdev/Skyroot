class_name Models
extends RefCounted
## Loads Blender-made .glb models, swaps their role-named materials ("Bark",
## "Leaves", "Stone"...) for Skyroot's shaders, and provides placeholders while
## an asset is missing.

static var _scenes: Dictionary = {}
static var _mats: Dictionary = {}

const ROLE_PARAMS := {
	# role: [detail_scale, detail_strength, normal_strength, roughness, specular]
	"Bark": [4.0, 0.32, 1.1, 0.93, 0.3],
	"Wood": [5.0, 0.16, 0.5, 0.8, 0.35],
	"WoodEnd": [7.0, 0.14, 0.4, 0.8, 0.35],
	"Stone": [2.2, 0.2, 0.45, 0.93, 0.18],
	"Moss": [6.0, 0.3, 0.6, 0.96, 0.25],
	"Skin": [9.0, 0.05, 0.12, 0.62, 0.32],
	"Cloth": [16.0, 0.14, 0.5, 0.96, 0.25],
	"ClothDark": [16.0, 0.12, 0.5, 0.96, 0.25],
	"Leather": [10.0, 0.16, 0.5, 0.75, 0.35],
	"Hair": [20.0, 0.18, 0.4, 0.8, 0.3],
	"Rope": [24.0, 0.2, 0.7, 0.92, 0.25],
	"Straw": [14.0, 0.22, 0.6, 0.9, 0.3],
	"Daub": [3.0, 0.24, 0.9, 0.95, 0.25],
	"Soil": [5.0, 0.3, 0.8, 0.97, 0.2],
	"Clay": [4.0, 0.15, 0.4, 0.6, 0.45],
	"Charcoal": [8.0, 0.25, 0.9, 0.9, 0.3],
	"Ash": [6.0, 0.2, 0.4, 0.98, 0.15],
	"Ceramic": [5.0, 0.12, 0.3, 0.7, 0.4],
	"Fruit": [8.0, 0.1, 0.25, 0.55, 0.5],
	"Eyes": [1.0, 0.0, 0.0, 0.3, 0.6],
}


static var _held: Array = []   # [material, WeakRef(mesh instance)]


static func set_surface_unique(mi: MeshInstance3D, s: int, mat: Material) -> void:
	## A surface material made just for this mesh.  Freeing a mesh together with
	## the last reference to one of its surface materials trips the renderer, so
	## such materials are held here until the mesh is gone (see sweep_held).
	mi.set_surface_override_material(s, mat)
	_held.append([mat, weakref(mi)])


static func sweep_held() -> void:
	var keep: Array = []
	for h in _held:
		if (h[1] as WeakRef).get_ref() != null:
			keep.append(h)
	_held = keep


static func exists(path: String) -> bool:
	return path != "" and ResourceLoader.exists(path)


static func instance(path: String) -> Node3D:
	if not exists(path):
		return null
	var ps: PackedScene = _scenes.get(path)
	if ps == null:
		ps = load(path)
		_scenes[path] = ps
	if ps == null:
		return null
	var n := ps.instantiate() as Node3D
	apply_materials(n)
	return n


static func apply_materials(root: Node) -> void:
	for mi in mesh_instances(root):
		if mi.mesh == null:
			continue
		for s in mi.mesh.get_surface_count():
			var m := mi.mesh.surface_get_material(s)
			var role := m.resource_name if m else ""
			mi.set_surface_override_material(s, material_for(role))


static func mesh_instances(root: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	if root is MeshInstance3D:
		out.append(root)
	for c in root.get_children():
		out.append_array(mesh_instances(c))
	return out


static func material_for(role: String) -> Material:
	var base_role := role.get_slice(".", 0)
	if _mats.has(base_role):
		return _mats[base_role]
	var m: ShaderMaterial = ShaderMaterial.new()
	if base_role == "Leaves" or base_role == "Plant" or base_role == "Foliage" or base_role == "Grass":
		m.shader = Tex.shader("res://assets/shaders/foliage.gdshader")
		m.set_shader_parameter("noise_a", Tex.noise_a())
		var plant := base_role != "Leaves"
		m.set_shader_parameter("sway_scale", 2.2 if plant else 1.0)
		m.set_shader_parameter("height_ref", 0.6 if plant else 4.0)
		m.set_shader_parameter("translucency", 0.45 if plant else 0.35)
	else:
		m.shader = Tex.shader("res://assets/shaders/vcol.gdshader")
		m.set_shader_parameter("detail", Tex.noise_b())
		m.set_shader_parameter("detail_n", Tex.noise_normal())
		var p: Array = ROLE_PARAMS.get(base_role, [4.0, 0.15, 0.5, 0.85, 0.35])
		m.set_shader_parameter("detail_scale", p[0])
		m.set_shader_parameter("detail_strength", p[1])
		m.set_shader_parameter("normal_strength", p[2])
		m.set_shader_parameter("roughness", p[3])
		m.set_shader_parameter("specular", p[4])
		if base_role == "Stone":
			# real stone is darker than the palette's light greys look under sun and sky
			m.set_shader_parameter("tint", Color(0.78, 0.76, 0.72))
	_mats[base_role] = m
	return m


static func unique_material(role: String) -> ShaderMaterial:
	## A private copy (e.g. per-player cloth tint, charring logs).
	return material_for(role).duplicate()


static func set_role_param(root: Node, role: String, param: String, value: Variant, unique: bool = true) -> void:
	## Change a shader parameter on every surface of `root` using `role`.
	for mi in mesh_instances(root):
		if mi.mesh == null:
			continue
		for s in mi.mesh.get_surface_count():
			var src := mi.mesh.surface_get_material(s)
			var r := src.resource_name.get_slice(".", 0) if src else ""
			if r != role:
				continue
			var cur := mi.get_surface_override_material(s)
			if unique and (cur == null or cur == _mats.get(r)):
				cur = material_for(r).duplicate()
				set_surface_unique(mi, s, cur)
			if cur is ShaderMaterial:
				cur.set_shader_parameter(param, value)


static func aabb_of(root: Node3D) -> AABB:
	var out := AABB()
	var first := true
	var inv := root.global_transform.affine_inverse() if root.is_inside_tree() else Transform3D.IDENTITY
	for mi in mesh_instances(root):
		if mi.mesh == null or not mi.visible:
			continue
		var xf := (inv * mi.global_transform) if root.is_inside_tree() else _rel_xf(root, mi)
		var b: AABB = xf * mi.mesh.get_aabb()
		if first:
			out = b
			first = false
		else:
			out = out.merge(b)
	return out


static func _rel_xf(root: Node3D, n: Node3D) -> Transform3D:
	var xf := Transform3D.IDENTITY
	var cur: Node = n
	while cur != null and cur != root:
		if cur is Node3D:
			xf = (cur as Node3D).transform * xf
		cur = cur.get_parent()
	return xf


static func placeholder(size: Vector3, color: Color, shape: String = "box") -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	match shape:
		"sphere":
			var s := SphereMesh.new()
			s.radius = size.x * 0.5
			s.height = size.y
			s.radial_segments = 12
			s.rings = 6
			mi.mesh = s
		"capsule":
			var c := CapsuleMesh.new()
			c.radius = size.x * 0.5
			c.height = size.y
			mi.mesh = c
		"cylinder":
			var cy := CylinderMesh.new()
			cy.top_radius = size.x * 0.5
			cy.bottom_radius = size.x * 0.5
			cy.height = size.y
			cy.radial_segments = 10
			mi.mesh = cy
		_:
			var b := BoxMesh.new()
			b.size = size
			mi.mesh = b
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = 0.85
	mi.material_override = m
	return mi
