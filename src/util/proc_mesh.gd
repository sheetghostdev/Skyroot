class_name ProcMesh
extends RefCounted
## Procedurally generated meshes for things whose shape is data: stones (from a
## seed), logs and split wood (from a cross-section polygon), boards, firewood,
## clay lumps.  All coloured through vertex colours for the vcol shader.

static var _cache: Dictionary = {}

const BARK := Color(0.42, 0.33, 0.26)
const BARK_DARK := Color(0.28, 0.22, 0.18)
const WOOD := Color(0.78, 0.62, 0.45)
const WOOD_RING := Color(0.62, 0.45, 0.31)


static func stone(seed_value: int) -> ArrayMesh:
	var key := "stone_%d" % seed_value
	if _cache.has(key):
		return _cache[key]
	var m := Knap.build_mesh(seed_value, [])
	_cache[key] = m
	return m


static func log_mesh(radius: float = 0.16, length: float = 2.0) -> ArrayMesh:
	var key := "log_%.3f_%.3f" % [radius, length]
	if _cache.has(key):
		return _cache[key]
	var poly := PackedVector2Array()
	var segs := 14
	for i in segs:
		var a := float(i) / segs * TAU
		poly.append(Vector2(cos(a), sin(a)) * radius)
	var m := wood_piece(poly, length, radius, Vector2.ZERO)
	_cache[key] = m
	return m


static func wood_piece(poly: PackedVector2Array, length: float, orig_radius: float, orig_center: Vector2) -> ArrayMesh:
	## Extrude a cross-section polygon (in the YZ plane) along X.  Faces lying on
	## the original log surface get bark; cut faces get pale wood; the end faces
	## show growth rings measured from the original log centre.
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var hx := length * 0.5
	var n := poly.size()
	var rng := RandomNumberGenerator.new()
	rng.seed = int(orig_radius * 1000.0) + n
	for i in n:
		var a := poly[i]
		var b := poly[(i + 1) % n]
		var mid := (a + b) * 0.5
		var on_bark := absf(mid.distance_to(orig_center) - orig_radius) < orig_radius * 0.12
		var col := BARK.lerp(BARK_DARK, rng.randf() * 0.5) if on_bark else WOOD * (0.92 + rng.randf() * 0.1)
		var e := b - a
		var nrm := Vector3(0.0, e.y, -e.x).normalized()
		var segs := 4
		for s in segs:
			var x0 := -hx + length * s / segs
			var x1 := -hx + length * (s + 1) / segs
			var bulge := 0.0
			var v0 := Vector3(x0, a.x, a.y)
			var v1 := Vector3(x1, a.x, a.y)
			var v2 := Vector3(x1, b.x, b.y)
			var v3 := Vector3(x0, b.x, b.y)
			for v in [[v0, v1, v2], [v0, v2, v3]]:
				for p in v:
					st.set_normal(nrm)
					st.set_color(col * (0.96 + 0.08 * sin(p.x * 7.0 + bulge)))
					st.add_vertex(p)
	# end caps (triangle fans with ring colouring)
	var cen := Geo.polygon_centroid(poly)
	for side in [-1.0, 1.0]:
		var nrm := Vector3(side, 0, 0)
		for i in n:
			var a := poly[i]
			var b := poly[(i + 1) % n]
			var tri := [cen, a, b] if side > 0.0 else [cen, b, a]
			for p in tri:
				var r: float = p.distance_to(orig_center) / maxf(orig_radius, 0.001)
				var ring := 0.5 + 0.5 * sin(r * 38.0)
				var c := WOOD.lerp(WOOD_RING, ring * 0.55)
				if r > 0.93:
					c = BARK_DARK
				st.set_normal(nrm)
				st.set_color(c)
				st.add_vertex(Vector3(side * hx, p.x, p.y))
	# subdivide the caps' ring colouring by adding an inner ring fan: good enough at item scale
	return st.commit()


static func board() -> ArrayMesh:
	if _cache.has("board"):
		return _cache["board"]
	var poly := PackedVector2Array([Vector2(-0.02, -0.125), Vector2(0.02, -0.12), Vector2(0.021, 0.124), Vector2(-0.019, 0.126)])
	var m := wood_piece(poly, 2.0, 0.5, Vector2(0.3, 0.0))
	_cache["board"] = m
	return m


static func firewood() -> ArrayMesh:
	if _cache.has("firewood"):
		return _cache["firewood"]
	var r := 0.085
	var poly := PackedVector2Array([Vector2(0, 0)])
	for i in 6:
		var a := deg_to_rad(-10.0 + i * 20.0)
		poly.append(Vector2(cos(a), sin(a)) * r)
	var m := wood_piece(poly, 0.5, r, Vector2.ZERO)
	_cache["firewood"] = m
	return m


static func clay_lump(radius: float = 0.05, seed_value: int = 1, color: Color = Color(0.55, 0.33, 0.24)) -> ArrayMesh:
	var key := "clay_%.3f_%d" % [radius, seed_value]
	if _cache.has(key):
		return _cache[key]
	var ico := Geo.icosphere(2)
	var v: PackedVector3Array = ico["v"].duplicate()
	var noise := FastNoiseLite.new()
	noise.seed = seed_value
	noise.frequency = 2.2
	var cols := PackedColorArray()
	for i in v.size():
		var d := v[i]
		var r := radius * (1.0 + 0.16 * noise.get_noise_3dv(d * 1.5))
		v[i] = Vector3(d.x * r * 1.1, (d.y * 0.72 + 0.72) * r, d.z * r)
		cols.append(color * (0.92 + 0.12 * noise.get_noise_3dv(d * 4.0)))
	var m := Geo.smooth_mesh(v, ico["t"], cols)
	_cache[key] = m
	return m


static func blob(radius: float, color: Color, seed_value: int = 3, squash: float = 0.7) -> ArrayMesh:
	var key := "blob_%.3f_%s_%d_%.2f" % [radius, color.to_html(), seed_value, squash]
	if _cache.has(key):
		return _cache[key]
	var ico := Geo.icosphere(2)
	var v: PackedVector3Array = ico["v"].duplicate()
	var noise := FastNoiseLite.new()
	noise.seed = seed_value
	noise.frequency = 1.8
	var cols := PackedColorArray()
	for i in v.size():
		var d := v[i]
		var r := radius * (1.0 + 0.22 * noise.get_noise_3dv(d * 1.3))
		v[i] = Vector3(d.x * r, (d.y * squash + squash) * r, d.z * r)
		cols.append(color * (0.85 + 0.25 * noise.get_noise_3dv(d * 3.0)))
	var m := Geo.flat_mesh(v, ico["t"], cols)
	_cache[key] = m
	return m


static func painted(prim: PrimitiveMesh, col: Color) -> ArrayMesh:
	## A primitive mesh with a uniform vertex colour (for the vcol shaders).
	var arrays := prim.get_mesh_arrays()
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var cols := PackedColorArray()
	cols.resize(verts.size())
	cols.fill(col)
	arrays[Mesh.ARRAY_COLOR] = cols
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return m


static func vcol_material(role: String = "Wood") -> Material:
	return Models.material_for(role)
