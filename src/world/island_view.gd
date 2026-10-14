class_name IslandView
extends Node3D
## Renders TerrainData: a smooth (non-voxel) ground mesh whose vertices are the
## terrain grid points inside the island outline plus the outline itself
## (Delaunay-triangulated once; heights/colours rebuilt after edits), cliffs and
## a craggy underside stitched exactly to the outline, the pond surface and
## instanced grass.  Also owns the ground/cliff collision.

const MARGIN_E := 0.026   # interior points must be this far inside the outline (edge-factor units)
const CLIFF_RINGS := [  # [y offset below lip, radial scale, noise amplitude]
	[0.0, 1.0, 0.0], [-0.13, 1.012, 0.02], [-0.42, 1.0, 0.09], [-1.0, 0.985, 0.16], [-1.8, 0.95, 0.22],
	[-2.8, 0.89, 0.26], [-4.0, 0.80, 0.3], [-5.6, 0.68, 0.32], [-7.6, 0.54, 0.3], [-10.0, 0.38, 0.26],
	[-12.6, 0.23, 0.2], [-15.0, 0.1, 0.12], [-16.8, 0.025, 0.04],
]

var terrain: TerrainData
var interactive := true

var top_mi: MeshInstance3D
var top_mesh := ArrayMesh.new()
var top_shape: ConcavePolygonShape3D
var cliff_mi: MeshInstance3D
var water_mi: MeshInstance3D
var water_area: Area3D
var water_mat: ShaderMaterial
var terrain_mat: ShaderMaterial
var grass_mmi: MultiMeshInstance3D
var grass_mat: ShaderMaterial

var _pts := PackedVector2Array()     # xz of top vertices; first _nb are the outline
var _nb := 0
var _vcell := PackedInt32Array()     # grid cell per vertex (-1 for outline vertices)
var _indices := PackedInt32Array()
var _grass_cells := PackedInt32Array()
var _grass_xf: Array[Transform3D] = []
var _noise := FastNoiseLite.new()


func build(t: TerrainData) -> void:
	add_to_group("island_view")
	terrain = t
	_noise.seed = 4242
	_noise.frequency = 0.25
	_noise.fractal_octaves = 3
	_make_materials()
	_build_topology()
	top_mi = MeshInstance3D.new()
	top_mi.name = "Ground"
	top_mi.mesh = top_mesh
	top_mi.material_override = terrain_mat
	add_child(top_mi)
	var body := StaticBody3D.new()
	body.name = "GroundBody"
	body.collision_layer = 1
	body.collision_mask = 0
	body.set_meta("ground", true)
	top_shape = ConcavePolygonShape3D.new()
	top_shape.backface_collision = true
	var cs := CollisionShape3D.new()
	cs.shape = top_shape
	body.add_child(cs)
	add_child(body)
	_rebuild_top(true)
	_build_cliffs()
	_build_water()
	_build_grass()
	set_pond_volume(float(World.env.get("pond_l", terrain.pond_capacity() * 0.86)) if not World.env.is_empty() else terrain.pond_capacity() * 0.86)


func _make_materials() -> void:
	terrain_mat = ShaderMaterial.new()
	terrain_mat.shader = Tex.shader("res://assets/shaders/terrain.gdshader")
	terrain_mat.set_shader_parameter("noise_a", Tex.noise_a())
	terrain_mat.set_shader_parameter("noise_b", Tex.noise_b())
	terrain_mat.set_shader_parameter("noise_n", Tex.noise_normal())


# ---------------------------------------------------------------------------
# Top surface
# ---------------------------------------------------------------------------

func _build_topology() -> void:
	_pts = PackedVector2Array()
	_vcell = PackedInt32Array()
	for p in terrain.outline:
		_pts.append(p)
		_vcell.append(-1)
	_nb = _pts.size()
	for k in TerrainData.N * TerrainData.N:
		var p := TerrainData.cell_pos(k)
		if terrain.edge_factor(p) < 1.0 - MARGIN_E:
			_pts.append(p)
			_vcell.append(k)
	var tris := Geometry2D.triangulate_delaunay(_pts)
	_indices = PackedInt32Array()
	for i in range(0, tris.size(), 3):
		var a := tris[i]
		var b := tris[i + 1]
		var c := tris[i + 2]
		var cen := (_pts[a] + _pts[b] + _pts[c]) / 3.0
		if terrain.edge_factor(cen) > 1.0:
			continue
		if a < _nb and b < _nb and c < _nb:
			# a sliver made only of outline points: keep only if it lies inside
			if not Geometry2D.is_point_in_polygon(cen, terrain.outline):
				continue
		# make every triangle front-facing upward (Godot: clockwise from the front)
		var ab := _pts[b] - _pts[a]
		var ac := _pts[c] - _pts[a]
		if ab.x * ac.y - ab.y * ac.x < 0.0:
			_indices.append_array([a, c, b])
		else:
			_indices.append_array([a, b, c])


func _vertex_height(i: int) -> float:
	var k := _vcell[i]
	if k >= 0:
		return terrain.surface(k)
	return terrain.height(_pts[i].x, _pts[i].y)


func _splat(k: int) -> Color:
	var s := terrain.soil[k]
	var c := terrain.clay[k]
	var rock_w := 1.0 - smoothstep(0.0, 0.05, s + c)
	var clay_w := (1.0 - rock_w) * (1.0 - smoothstep(0.0, 0.035, s))
	var soil_w := maxf(0.0, 1.0 - rock_w - clay_w)
	var grass_w := soil_w * terrain.grass[k] * (1.0 - terrain.tilled[k])
	soil_w -= grass_w
	if terrain.in_pond(TerrainData.cell_pos(k)):
		clay_w = maxf(clay_w, 0.6)
		grass_w = 0.0
	return Color(grass_w, soil_w, clay_w, rock_w)


func _rebuild_top(with_collision: bool) -> void:
	var n := _pts.size()
	var verts := PackedVector3Array()
	verts.resize(n)
	var cols := PackedColorArray()
	cols.resize(n)
	var uv2 := PackedVector2Array()
	uv2.resize(n)
	for i in n:
		var p := _pts[i]
		verts[i] = Vector3(p.x, _vertex_height(i), p.y)
		var k := _vcell[i]
		if k < 0:
			var c := TerrainData.cell_at(p)
			k = TerrainData.cell_index(c.x, c.y)
		cols[i] = _splat(k)
		uv2[i] = Vector2(terrain.moist[k], float(terrain.tilled[k]))
	var normals := PackedVector3Array()
	normals.resize(n)
	normals.fill(Vector3.ZERO)
	var faces := PackedVector3Array()
	if with_collision:
		faces.resize(_indices.size())
	for t in range(0, _indices.size(), 3):
		var a := _indices[t]
		var b := _indices[t + 1]
		var c := _indices[t + 2]
		var fnrm := (verts[c] - verts[a]).cross(verts[b] - verts[a])
		normals[a] += fnrm
		normals[b] += fnrm
		normals[c] += fnrm
		if with_collision:
			faces[t] = verts[a]
			faces[t + 1] = verts[b]
			faces[t + 2] = verts[c]
	for i in n:
		normals[i] = normals[i].normalized() if normals[i].length_squared() > 0.0 else Vector3.UP
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = cols
	arrays[Mesh.ARRAY_TEX_UV2] = uv2
	arrays[Mesh.ARRAY_INDEX] = _indices
	top_mesh.clear_surfaces()
	top_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	if with_collision:
		top_shape.set_faces(faces)


func on_terrain_changed(rect: Rect2i) -> void:
	_rebuild_top(true)
	_update_grass(rect)


func on_soil_changed() -> void:
	_rebuild_top(false)
	_update_grass(Rect2i(0, 0, TerrainData.N, TerrainData.N))


# ---------------------------------------------------------------------------
# Cliffs and underside
# ---------------------------------------------------------------------------

func _build_cliffs() -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var nb := terrain.outline.size()
	var rings: Array = []
	var center := Vector2(0.3, 0.2)
	for r in CLIFF_RINGS.size():
		var spec: Array = CLIFF_RINGS[r]
		var ring := PackedVector3Array()
		for s in nb:
			var p := terrain.outline[s]
			var top_y := terrain.height(p.x, p.y)
			var dir := (p - center)
			var th := float(s) / nb * TAU
			var n3 := _noise.get_noise_3d(cos(th) * 6.0, float(r) * 0.9, sin(th) * 6.0)
			var n4 := _noise.get_noise_3d(cos(th) * 14.0, float(r) * 2.3 + 40.0, sin(th) * 14.0)
			var radial: float = spec[1]
			# a few hanging lobes reach deeper than the rest
			var lobe := maxf(0.0, sin(th * 3.0 + 1.1)) * maxf(0.0, sin(th * 5.0 + 0.3))
			if r >= 6:
				radial = minf(1.0, radial + lobe * 0.18 * (r - 5) / 6.0)
			radial *= 1.0 + spec[2] * (n3 * 0.8 + n4 * 0.35)
			var q := center + dir * radial
			var y: float = top_y + spec[0] * (1.0 + 0.25 * lobe * float(r >= 4)) + n4 * 0.08 * float(r > 0)
			if r == 0:
				q = p
				y = top_y
			ring.append(Vector3(q.x, y, q.y))
		rings.append(ring)
	var tip := Vector3(center.x, rings[rings.size() - 1][0].y - 1.6, center.y)
	# vertices
	for r in rings.size():
		for s in nb:
			var v: Vector3 = rings[r][s]
			var soil_band := 1.0 if r <= 1 else (0.55 if r == 2 else 0.0)
			var moss := clampf(1.0 - float(r) / 6.0, 0.0, 1.0) * (0.6 + 0.4 * _noise.get_noise_2d(s * 0.7, r * 3.0))
			var ao := clampf(1.0 - float(r) / 16.0, 0.35, 1.0)
			st.set_color(Color(soil_band, moss, 0.0, ao))
			st.add_vertex(v)
	st.set_color(Color(0, 0, 0, 0.3))
	st.add_vertex(tip)
	var tip_i := rings.size() * nb
	for r in rings.size() - 1:
		for s in nb:
			var s2 := (s + 1) % nb
			var a := r * nb + s
			var b := r * nb + s2
			var c := (r + 1) * nb + s
			var d := (r + 1) * nb + s2
			# outward facing (outline is CCW in xz)
			st.add_index(a)
			st.add_index(c)
			st.add_index(b)
			st.add_index(b)
			st.add_index(c)
			st.add_index(d)
	var last := (rings.size() - 1) * nb
	for s in nb:
		st.add_index(last + s)
		st.add_index(tip_i)
		st.add_index(last + (s + 1) % nb)
	st.generate_normals()
	var mesh := st.commit()
	_fix_winding_if_needed(mesh)
	cliff_mi = MeshInstance3D.new()
	cliff_mi.name = "Cliffs"
	cliff_mi.mesh = mesh
	var m := ShaderMaterial.new()
	m.shader = Tex.shader("res://assets/shaders/cliff.gdshader")
	m.set_shader_parameter("noise_a", Tex.noise_a())
	m.set_shader_parameter("noise_b", Tex.noise_b())
	m.set_shader_parameter("noise_n", Tex.noise_normal())
	cliff_mi.material_override = m
	add_child(cliff_mi)
	if interactive:
		var body := StaticBody3D.new()
		body.name = "CliffBody"
		body.collision_layer = 1
		body.collision_mask = 0
		body.set_meta("cliff", true)
		var cs := CollisionShape3D.new()
		cs.shape = mesh.create_trimesh_shape()
		body.add_child(cs)
		add_child(body)


func _fix_winding_if_needed(mesh: ArrayMesh) -> void:
	## Make sure generated normals point away from the island's axis.
	var arr := mesh.surface_get_arrays(0)
	var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var nrm: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
	var probe := terrain.outline.size() * 3 + 5
	if probe >= v.size():
		return
	var outward := Vector3(v[probe].x - 0.3, 0.0, v[probe].z - 0.2).normalized()
	if nrm[probe].dot(outward) < 0.0:
		var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
		for i in range(0, idx.size(), 3):
			var tmp := idx[i + 1]
			idx[i + 1] = idx[i + 2]
			idx[i + 2] = tmp
		for i in nrm.size():
			nrm[i] = -nrm[i]
		arr[Mesh.ARRAY_INDEX] = idx
		arr[Mesh.ARRAY_NORMAL] = nrm
		mesh.clear_surfaces()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)


# ---------------------------------------------------------------------------
# Pond
# ---------------------------------------------------------------------------

func _build_water() -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var rx := TerrainData.POND_RADII.x * 1.3
	var rz := TerrainData.POND_RADII.y * 1.3
	var segs := 48
	var rings := 8
	st.set_normal(Vector3.UP)
	st.add_vertex(Vector3.ZERO)
	for r in range(1, rings + 1):
		for s in segs:
			var a := float(s) / segs * TAU
			var f := float(r) / rings
			st.set_normal(Vector3.UP)
			st.add_vertex(Vector3(cos(a) * rx * f, 0.0, sin(a) * rz * f))
	# wound to face up (front faces are clockwise seen from above)
	for s in segs:
		st.add_index(0)
		st.add_index(1 + s)
		st.add_index(1 + (s + 1) % segs)
	for r in range(1, rings):
		for s in segs:
			var a := 1 + (r - 1) * segs + s
			var b := 1 + (r - 1) * segs + (s + 1) % segs
			var c := 1 + r * segs + s
			var d := 1 + r * segs + (s + 1) % segs
			st.add_index(a)
			st.add_index(c)
			st.add_index(b)
			st.add_index(b)
			st.add_index(c)
			st.add_index(d)
	water_mi = MeshInstance3D.new()
	water_mi.name = "Pond"
	water_mi.mesh = st.commit()
	water_mat = ShaderMaterial.new()
	water_mat.shader = Tex.shader("res://assets/shaders/water.gdshader")
	water_mat.set_shader_parameter("wave_a", Tex.wave_a())
	water_mat.set_shader_parameter("wave_b", Tex.wave_b())
	water_mi.material_override = water_mat
	water_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	water_mi.position = Vector3(TerrainData.POND_CENTER.x, 0.0, TerrainData.POND_CENTER.y)
	add_child(water_mi)
	if interactive:
		water_area = Area3D.new()
		water_area.name = "PondArea"
		water_area.collision_layer = 1 << 5
		water_area.collision_mask = 0
		water_area.monitoring = false
		water_area.set_meta("water", true)
		var cs := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(TerrainData.POND_RADII.x * 2.1, 0.06, TerrainData.POND_RADII.y * 2.1)
		cs.shape = box
		cs.position.y = -0.03
		water_area.add_child(cs)
		water_mi.add_child(water_area)


func set_pond_volume(litres: float) -> void:
	if water_mi == null:
		return
	var lvl := terrain.pond_level_for(litres)
	water_mi.position.y = lvl
	water_mi.visible = litres > 1.0


func water_level() -> float:
	return water_mi.position.y if water_mi else -100.0


# ---------------------------------------------------------------------------
# Grass
# ---------------------------------------------------------------------------

func _tuft_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var rng := RandomNumberGenerator.new()
	rng.seed = 99
	var blades := 12
	var vi := 0
	for b in blades:
		var ang := rng.randf() * TAU
		var dir := Vector3(cos(ang), 0, sin(ang))
		var side := Vector3(-dir.z, 0, dir.x)
		var base := dir * rng.randf_range(0.0, 0.08)
		var hgt := rng.randf_range(0.09, 0.2)
		var lean := rng.randf_range(0.03, 0.09)
		var w := rng.randf_range(0.007, 0.013)
		var segs := 3
		for s in segs + 1:
			var f := float(s) / segs
			var p := base + dir * lean * f * f + Vector3(0, hgt * f, 0)
			var ww := w * (1.0 - f * 0.92)
			st.set_uv(Vector2(0.0, f))
			st.set_normal(Vector3(0, 0.3, 0) + dir.cross(Vector3.UP).normalized() * 0.0 + -dir * 0.0 + Vector3.UP)
			st.add_vertex(p - side * ww)
			st.set_uv(Vector2(1.0, f))
			st.set_normal(Vector3.UP)
			st.add_vertex(p + side * ww)
		for s in segs:
			var a := vi + s * 2
			st.add_index(a)
			st.add_index(a + 2)
			st.add_index(a + 1)
			st.add_index(a + 1)
			st.add_index(a + 2)
			st.add_index(a + 3)
		vi += (segs + 1) * 2
	return st.commit()


func _build_grass() -> void:
	grass_mat = ShaderMaterial.new()
	grass_mat.shader = Tex.shader("res://assets/shaders/grass.gdshader")
	grass_mat.set_shader_parameter("noise_a", Tex.noise_a())
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = _tuft_mesh()
	var spacing := 0.19 / sqrt(clampf(Settings.grass_density, 0.2, 1.0))
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var positions: Array[Vector2] = []
	_grass_cells = PackedInt32Array()
	var x := -10.0
	while x < 10.0:
		var z := -10.0
		while z < 10.0:
			var p := Vector2(x + rng.randf_range(-0.4, 0.4) * spacing, z + rng.randf_range(-0.4, 0.4) * spacing)
			if terrain.edge_factor(p) < 0.985:
				var c := TerrainData.cell_at(p)
				var k := TerrainData.cell_index(c.x, c.y)
				if terrain.grass[k] > 0.05 or terrain.soil[k] > 0.1:
					positions.append(p)
					_grass_cells.append(k)
			z += spacing
		x += spacing
	mm.instance_count = positions.size()
	_grass_xf.resize(positions.size())
	for i in positions.size():
		var p := positions[i]
		var yaw := rng.randf() * TAU
		var hs := rng.randf_range(0.65, 1.2)
		var basis := Basis(Vector3.UP, yaw).scaled(Vector3(1.0, hs, 1.0))
		_grass_xf[i] = Transform3D(basis, Vector3(p.x, 0.0, p.y))
		var tint := 0.88 + rng.randf() * 0.24
		var hue := rng.randf_range(-0.05, 0.05)
		mm.set_instance_custom_data(i, Color(tint + hue, tint, tint - hue * 1.5, clampf(rng.randf() * 0.5 - 0.3, 0.0, 1.0)))
	grass_mmi = MultiMeshInstance3D.new()
	grass_mmi.name = "Grass"
	grass_mmi.multimesh = mm
	grass_mmi.material_override = grass_mat
	grass_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(grass_mmi)
	_update_grass(Rect2i(0, 0, TerrainData.N, TerrainData.N))


func _update_grass(rect: Rect2i) -> void:
	if grass_mmi == null:
		return
	var mm := grass_mmi.multimesh
	var r := rect.grow(1)
	for i in _grass_cells.size():
		var k := _grass_cells[i]
		var c := TerrainData.cell_xy(k)
		if not r.has_point(c):
			continue
		var g := terrain.grass[k] * (1.0 - terrain.tilled[k])
		var xf := _grass_xf[i]
		var p := xf.origin
		p.y = terrain.height(p.x, p.z) - 0.01
		var s := clampf((g - 0.12) / 0.6, 0.0, 1.0)
		if s <= 0.01:
			mm.set_instance_transform(i, Transform3D(Basis().scaled(Vector3(0.001, 0.001, 0.001)), p))
		else:
			mm.set_instance_transform(i, Transform3D(xf.basis.scaled(Vector3(0.5 + 0.5 * s, s, 0.5 + 0.5 * s)), p))


func clear_grass_near(pos: Vector3, radius: float) -> void:
	## Visual only: flatten grass under placed objects.
	var mm := grass_mmi.multimesh
	for i in _grass_xf.size():
		var o := _grass_xf[i].origin
		if Vector2(o.x - pos.x, o.z - pos.z).length() < radius:
			mm.set_instance_transform(i, Transform3D(Basis().scaled(Vector3(0.001, 0.001, 0.001)), o))


func set_weather_visuals(rain: float, wind: Vector2) -> void:
	terrain_mat.set_shader_parameter("rain_wet", rain)
	grass_mat.set_shader_parameter("wetness", rain)
	grass_mat.set_shader_parameter("wind_dir", wind.normalized() if wind.length() > 0.01 else Vector2(1, 0))
	grass_mat.set_shader_parameter("wind_strength", clampf(wind.length() / 4.0, 0.12, 1.2))
	if water_mat:
		water_mat.set_shader_parameter("rain", rain)
		water_mat.set_shader_parameter("wind", clampf(wind.length() / 5.0, 0.0, 1.0))
