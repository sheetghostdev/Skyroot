class_name Geo
extends RefCounted
## Small geometry toolkit shared by procedural meshes and crafting systems.
## Colours passed in are authored in sRGB; meshes store linear vertex colours
## (the same convention as the Blender exports).

static var _ico_cache: Dictionary = {}


static func icosphere(subdiv: int) -> Dictionary:
	## Unit icosphere: {"v": PackedVector3Array, "t": PackedInt32Array}.
	if _ico_cache.has(subdiv):
		return _ico_cache[subdiv]
	var t := (1.0 + sqrt(5.0)) / 2.0
	var verts: Array[Vector3] = [
		Vector3(-1, t, 0), Vector3(1, t, 0), Vector3(-1, -t, 0), Vector3(1, -t, 0),
		Vector3(0, -1, t), Vector3(0, 1, t), Vector3(0, -1, -t), Vector3(0, 1, -t),
		Vector3(t, 0, -1), Vector3(t, 0, 1), Vector3(-t, 0, -1), Vector3(-t, 0, 1)]
	for i in verts.size():
		verts[i] = verts[i].normalized()
	var faces: Array = [[0, 11, 5], [0, 5, 1], [0, 1, 7], [0, 7, 10], [0, 10, 11], [1, 5, 9], [5, 11, 4],
		[11, 10, 2], [10, 7, 6], [7, 1, 8], [3, 9, 4], [3, 4, 2], [3, 2, 6], [3, 6, 8], [3, 8, 9],
		[4, 9, 5], [2, 4, 11], [6, 2, 10], [8, 6, 7], [9, 8, 1]]
	for s in subdiv:
		var mid := {}
		var nf: Array = []
		for f in faces:
			var a := _mid(verts, mid, f[0], f[1])
			var b := _mid(verts, mid, f[1], f[2])
			var c := _mid(verts, mid, f[2], f[0])
			nf.append([f[0], a, c])
			nf.append([f[1], b, a])
			nf.append([f[2], c, b])
			nf.append([a, b, c])
		faces = nf
	var pv := PackedVector3Array(verts)
	var pt := PackedInt32Array()
	for f in faces:
		# Godot front faces are clockwise; icosphere faces above are CCW from outside
		pt.append_array([f[0], f[2], f[1]])
	var out := {"v": pv, "t": pt}
	_ico_cache[subdiv] = out
	return out


static func _mid(verts: Array[Vector3], cache: Dictionary, a: int, b: int) -> int:
	var key := mini(a, b) * 100000 + maxi(a, b)
	if cache.has(key):
		return cache[key]
	verts.append(((verts[a] + verts[b]) * 0.5).normalized())
	cache[key] = verts.size() - 1
	return verts.size() - 1


static func flat_mesh(verts: PackedVector3Array, tris: PackedInt32Array, colors: PackedColorArray = PackedColorArray()) -> ArrayMesh:
	## Unindexed, flat-shaded mesh from an indexed triangle list.
	var pv := PackedVector3Array()
	var pn := PackedVector3Array()
	var pc := PackedColorArray()
	pv.resize(tris.size())
	pn.resize(tris.size())
	var use_col := colors.size() == verts.size()
	if use_col:
		pc.resize(tris.size())
	for i in range(0, tris.size(), 3):
		var a := verts[tris[i]]
		var b := verts[tris[i + 1]]
		var c := verts[tris[i + 2]]
		var n := (c - a).cross(b - a)
		n = n.normalized() if n.length_squared() > 1e-14 else Vector3.UP
		pv[i] = a
		pv[i + 1] = b
		pv[i + 2] = c
		pn[i] = n
		pn[i + 1] = n
		pn[i + 2] = n
		if use_col:
			pc[i] = colors[tris[i]].srgb_to_linear()
			pc[i + 1] = colors[tris[i + 1]].srgb_to_linear()
			pc[i + 2] = colors[tris[i + 2]].srgb_to_linear()
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = pv
	arrays[Mesh.ARRAY_NORMAL] = pn
	if use_col:
		arrays[Mesh.ARRAY_COLOR] = pc
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return m


static func smooth_mesh(verts: PackedVector3Array, tris: PackedInt32Array, colors: PackedColorArray = PackedColorArray()) -> ArrayMesh:
	var normals := PackedVector3Array()
	normals.resize(verts.size())
	normals.fill(Vector3.ZERO)
	for i in range(0, tris.size(), 3):
		var a := tris[i]
		var b := tris[i + 1]
		var c := tris[i + 2]
		var n := (verts[c] - verts[a]).cross(verts[b] - verts[a])
		normals[a] += n
		normals[b] += n
		normals[c] += n
	for i in normals.size():
		normals[i] = normals[i].normalized() if normals[i].length_squared() > 1e-16 else Vector3.UP
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	if colors.size() == verts.size():
		var lin := PackedColorArray()
		lin.resize(colors.size())
		for i in colors.size():
			lin[i] = colors[i].srgb_to_linear()
		arrays[Mesh.ARRAY_COLOR] = lin
	arrays[Mesh.ARRAY_INDEX] = tris
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return m


static func fib_dirs(n: int) -> PackedVector3Array:
	## Evenly spread unit directions (Fibonacci sphere).
	var out := PackedVector3Array()
	var ga := PI * (3.0 - sqrt(5.0))
	for i in n:
		var y := 1.0 - (float(i) + 0.5) / n * 2.0
		var r := sqrt(maxf(0.0, 1.0 - y * y))
		var th := ga * i
		out.append(Vector3(cos(th) * r, y, sin(th) * r))
	return out


static func polygon_area(poly: PackedVector2Array) -> float:
	var a := 0.0
	for i in poly.size():
		var p := poly[i]
		var q := poly[(i + 1) % poly.size()]
		a += p.x * q.y - q.x * p.y
	return abs(a) * 0.5


static func clip_polygon(poly: PackedVector2Array, n: Vector2, d: float) -> PackedVector2Array:
	## Keep the part of a convex polygon where dot(p, n) <= d.
	var out := PackedVector2Array()
	var cnt := poly.size()
	for i in cnt:
		var a := poly[i]
		var b := poly[(i + 1) % cnt]
		var da := a.dot(n) - d
		var db := b.dot(n) - d
		if da <= 0.0:
			out.append(a)
		if (da <= 0.0) != (db <= 0.0):
			var t := da / (da - db)
			out.append(a.lerp(b, t))
	return out


static func polygon_min_width(poly: PackedVector2Array) -> float:
	## Smallest caliper width of a convex polygon.
	var best := INF
	var cnt := poly.size()
	for i in cnt:
		var e := (poly[(i + 1) % cnt] - poly[i])
		if e.length() < 1e-6:
			continue
		var nrm := Vector2(-e.y, e.x).normalized()
		var lo := INF
		var hi := -INF
		for p in poly:
			var v := p.dot(nrm)
			lo = minf(lo, v)
			hi = maxf(hi, v)
		best = minf(best, hi - lo)
	return best


static func polygon_max_width(poly: PackedVector2Array) -> float:
	var best := 0.0
	for a in poly:
		for b in poly:
			best = maxf(best, a.distance_to(b))
	return best


static func polygon_centroid(poly: PackedVector2Array) -> Vector2:
	var c := Vector2.ZERO
	for p in poly:
		c += p
	return c / maxf(1.0, poly.size())
