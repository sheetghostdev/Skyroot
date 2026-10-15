class_name ChunkMesher
extends RefCounted
## Builds the mesh arrays of one 16^3 chunk.  Pure function of the block data, so
## it runs on worker threads: it reads a padded copy of the surrounding blocks
## (16 + 2 * MARGIN cells each way) and works out skylight there first.
##
## Lighting: a cell open to the sky has skylight 15; light spreads sideways and
## down into overhangs, caves and canopies losing 2 per step (3 through leaves or
## water).  Each vertex takes the average skylight of the cells around it plus
## classic corner ambient occlusion; the shader applies that to ambient light
## only, so the sun still lights what it reaches (with real shadows).

const CS := 16
const MARGIN := 8
const R := CS + 2 * MARGIN       # region edge (32)
const DY := 1
const DX := R
const DZ := R * R

const AO_F := [0.52, 0.7, 0.85, 1.0]
const TOP_F := 1.0

# faces: normal, 4 corners (CCW seen from outside), uv per corner, tangent axes
const FACES := [
	{"n": Vector3i(0, 1, 0), "c": [Vector3(0, 1, 0), Vector3(0, 1, 1), Vector3(1, 1, 1), Vector3(1, 1, 0)],
		"uv": [Vector2(0, 0), Vector2(0, 1), Vector2(1, 1), Vector2(1, 0)], "t": [0, 2]},
	{"n": Vector3i(0, -1, 0), "c": [Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(1, 0, 1), Vector3(0, 0, 1)],
		"uv": [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)], "t": [0, 2]},
	{"n": Vector3i(0, 0, -1), "c": [Vector3(0, 0, 0), Vector3(0, 1, 0), Vector3(1, 1, 0), Vector3(1, 0, 0)],
		"uv": [Vector2(1, 1), Vector2(1, 0), Vector2(0, 0), Vector2(0, 1)], "t": [0, 1]},
	{"n": Vector3i(0, 0, 1), "c": [Vector3(1, 0, 1), Vector3(1, 1, 1), Vector3(0, 1, 1), Vector3(0, 0, 1)],
		"uv": [Vector2(1, 1), Vector2(1, 0), Vector2(0, 0), Vector2(0, 1)], "t": [0, 1]},
	{"n": Vector3i(1, 0, 0), "c": [Vector3(1, 0, 0), Vector3(1, 1, 0), Vector3(1, 1, 1), Vector3(1, 0, 1)],
		"uv": [Vector2(1, 1), Vector2(1, 0), Vector2(0, 0), Vector2(0, 1)], "t": [2, 1]},
	{"n": Vector3i(-1, 0, 0), "c": [Vector3(0, 0, 1), Vector3(0, 1, 1), Vector3(0, 1, 0), Vector3(0, 0, 0)],
		"uv": [Vector2(1, 1), Vector2(1, 0), Vector2(0, 0), Vector2(0, 1)], "t": [2, 1]},
]

static var _tables_ready := false
static var _face_off := PackedInt32Array()     # region offset of the neighbour per face
static var _ao_off := PackedInt32Array()       # [face*8 + corner*2 + {0,1}] tangent offsets
static var _zeros := PackedByteArray()
static var _lit := PackedByteArray()
static var _under := PackedByteArray()


static func _tables() -> void:
	if _tables_ready:
		return
	var strides := [DX, DY, DZ]
	_face_off.resize(6)
	_ao_off.resize(48)
	for f in 6:
		var n: Vector3i = FACES[f]["n"]
		_face_off[f] = n.x * DX + n.y * DY + n.z * DZ
		var t: Array = FACES[f]["t"]
		for k in 4:
			var p: Vector3 = FACES[f]["c"][k]
			_ao_off[f * 8 + k * 2] = (1 if p[t[0]] > 0.5 else -1) * int(strides[t[0]])
			_ao_off[f * 8 + k * 2 + 1] = (1 if p[t[1]] > 0.5 else -1) * int(strides[t[1]])
	_zeros.resize(R)
	_zeros.fill(0)
	_lit.resize(R)
	_lit.fill(15)
	_under.resize(R)
	_under.fill(13)
	_tables_ready = true


class Surf:
	var v := PackedVector3Array()
	var n := PackedVector3Array()
	var c := PackedColorArray()
	var uv := PackedVector2Array()
	var uv2 := PackedVector2Array()
	var i := PackedInt32Array()

	func arrays() -> Array:
		if v.is_empty():
			return []
		var a := []
		a.resize(Mesh.ARRAY_MAX)
		a[Mesh.ARRAY_VERTEX] = v
		a[Mesh.ARRAY_NORMAL] = n
		a[Mesh.ARRAY_COLOR] = c
		a[Mesh.ARRAY_TEX_UV] = uv
		a[Mesh.ARRAY_TEX_UV2] = uv2
		a[Mesh.ARRAY_INDEX] = i
		return a


static func build(vd: VoxelData, cx: int, cy: int, cz: int) -> Dictionary:
	## Mesh a chunk right here (menu backdrop, screenshots, tests).
	var reg := region(vd, cx, cy, cz)
	if reg.is_empty():
		return {}
	return mesh_region(reg, cx, cy, cz)


static func region(vd: VoxelData, cx: int, cy: int, cz: int) -> Dictionary:
	## Copy what a chunk's mesh depends on (its blocks plus MARGIN all round,
	## and where each column's sky-blocking run lies) so a worker thread can
	## mesh it while the world goes on changing.  {} if the chunk is all air.
	_tables()
	var sxy := vd.sy
	var bx := cx * CS - MARGIN
	var by := cy * CS - MARGIN
	var bz := cz * CS - MARGIN
	var ids := vd.ids
	var meta := vd.meta
	# quick reject: nothing but air in the chunk itself
	var any := false
	for z in range(cz * CS, cz * CS + CS):
		for x in range(cx * CS, cx * CS + CS):
			if x < 0 or z < 0 or x >= vd.sx or z >= vd.sz:
				# beyond the edge: whatever lies out there (open sea, or nothing)
				var osl := vd.outside.slice(cy * CS, mini(cy * CS + CS, sxy))
				if osl.count(0) != osl.size():
					any = true
					break
				continue
			var col := x * sxy + z * sxy * vd.sx
			var h := vd.height[x + z * vd.sx]
			if h >= cy * CS and vd.low[x + z * vd.sx] < cy * CS + CS:
				any = true
				break
			# below-ground air columns can still hold leaves/plants above h: scan the slice
			var sl := ids.slice(col + cy * CS, col + mini(cy * CS + CS, sxy))
			if sl.count(0) != sl.size():
				any = true
				break
		if any:
			break
	if not any:
		return {}
	var rid := PackedByteArray()
	var rmeta := PackedByteArray()
	var rl := PackedByteArray()
	# per region column: the dark run [dlo, dhi) between the lowest and highest
	# sky-blocking blocks; above it is lit by the sky, below it by the open air
	# under the island
	var dlo := PackedInt32Array()
	var dhi := PackedInt32Array()
	dlo.resize(R * R)
	dhi.resize(R * R)
	var outside := vd.outside
	var out_ids := PackedByteArray()
	out_ids.resize(R)
	for ry in R:
		var wy := by + ry
		out_ids[ry] = outside[wy] if wy >= 0 and wy < sxy else 0
	for rz in R:
		var wz := bz + rz
		for rx in R:
			var wx := bx + rx
			if wx < 0 or wz < 0 or wx >= vd.sx or wz >= vd.sz:
				# beyond the edge: the abyss, or open sea
				rid.append_array(out_ids)
				rmeta.append_array(_zeros)
				dlo[rx + rz * R] = 0
				dhi[rx + rz * R] = 0
				rl.append_array(_lit)
				continue
			var col := wx * sxy + wz * sxy * vd.sx
			var y0 := by
			var y1 := by + R
			var pre := clampi(-y0, 0, R)
			var post := clampi(y1 - sxy, 0, R)
			if pre > 0:
				rid.append_array(_zeros.slice(0, pre))
				rmeta.append_array(_zeros.slice(0, pre))
			var a := col + maxi(y0, 0)
			var b := col + mini(y1, sxy)
			if b > a:
				rid.append_array(ids.slice(a, b))
				rmeta.append_array(meta.slice(a, b))
			if post > 0:
				rid.append_array(_zeros.slice(0, post))
				rmeta.append_array(_zeros.slice(0, post))
			var h := vd.height[wx + wz * vd.sx]
			var lo := vd.low[wx + wz * vd.sx]
			var hi_r := clampi(h - by + 1, 0, R)
			var lo_r := clampi(lo - by, 0, hi_r)
			if h < 0:
				lo_r = 0
				hi_r = 0
			dlo[rx + rz * R] = lo_r
			dhi[rx + rz * R] = hi_r
			if lo_r > 0:
				rl.append_array(_under.slice(0, lo_r))
			if hi_r > lo_r:
				rl.append_array(_zeros.slice(0, hi_r - lo_r))
			if hi_r < R:
				rl.append_array(_lit.slice(0, R - hi_r))
	return {"rid": rid, "rmeta": rmeta, "rl": rl, "dlo": dlo, "dhi": dhi}


static func mesh_region(reg: Dictionary, cx: int, cy: int, cz: int) -> Dictionary:
	## The worker half: skylight, then faces.
	var rl: PackedByteArray = reg["rl"]
	_skylight(reg["rid"], rl, reg["dlo"], reg["dhi"])
	return _mesh(reg["rid"], reg["rmeta"], rl, cx, cy, cz)


static func _skylight(rid: PackedByteArray, rl: PackedByteArray, dlo: PackedInt32Array, dhi: PackedInt32Array) -> void:
	var q := PackedInt32Array()
	var opaque := Blocks.opaque
	var cost := Blocks.sky_cost
	for rz in range(1, R - 1):
		for rx in range(1, R - 1):
			var k := rx + rz * R
			var lo := dlo[k]
			var hi := dhi[k]
			var base := rx * DX + rz * DZ
			# the lit cells just above and below this column's dark run...
			if hi < R and hi > lo:
				q.append(base + hi)
			if lo > 0 and hi > lo:
				q.append(base + lo - 1)
			# ...and lit cells of this column beside a neighbour's dark run
			for nk in [k + 1, k - 1, k + R, k - R]:
				var nlo := dlo[nk]
				var nhi := dhi[nk]
				for ry in range(nlo, nhi):
					if ry < lo or ry >= hi:
						q.append(base + ry)
	var head := 0
	while head < q.size():
		var ci := q[head]
		head += 1
		var l := rl[ci]
		if l <= 2:
			continue
		var ry := ci % R
		var rx := (ci / R) % R
		var rz := ci / DZ
		# six neighbours
		for k in 6:
			var ni := ci
			match k:
				0:
					if ry == R - 1: continue
					ni = ci + DY
				1:
					if ry == 0: continue
					ni = ci - DY
				2:
					if rx == R - 1: continue
					ni = ci + DX
				3:
					if rx == 0: continue
					ni = ci - DX
				4:
					if rz == R - 1: continue
					ni = ci + DZ
				5:
					if rz == 0: continue
					ni = ci - DZ
			var nid := rid[ni]
			if opaque[nid] == 1:
				continue
			var nl := l - 2 - cost[nid]
			if nl > rl[ni]:
				rl[ni] = nl
				q.append(ni)


static func _hash(x: int, y: int, z: int) -> int:
	var h := x * 73856093 ^ y * 19349663 ^ z * 83492791
	h = (h ^ (h >> 13)) * 1274126177
	return h & 0x7fffffff


static func _light_f(l: float) -> float:
	return 0.06 + 0.94 * pow(clampf(l / 15.0, 0.0, 1.0), 1.5)


static func _mesh(rid: PackedByteArray, rmeta: PackedByteArray, rl: PackedByteArray, cx: int, cy: int, cz: int) -> Dictionary:
	var solid := Surf.new()
	var cut := Surf.new()
	var water := Surf.new()
	var lights := PackedVector3Array()
	var fixtures: Array = []
	var opaque := Blocks.opaque
	var shape := Blocks.shape
	var face_tex := Blocks.face_tex
	var cutout := Blocks.cutout
	for rz in range(MARGIN, MARGIN + CS):
		for rx in range(MARGIN, MARGIN + CS):
			var cbase := rx * DX + rz * DZ
			for ry in range(MARGIN, MARGIN + CS):
				var ci := cbase + ry
				var id := rid[ci]
				if id == 0:
					continue
				var lp := Vector3(rx - MARGIN, ry - MARGIN, rz - MARGIN)
				var wx := cx * CS + rx - MARGIN
				var wy := cy * CS + ry - MARGIN
				var wz := cz * CS + rz - MARGIN
				var sh := shape[id]
				if Blocks.fixture[id] == 1:
					# a torch: its own model (and light) instead of chunk faces
					fixtures.append([lp, id, rmeta[ci]])
					continue
				if Blocks.light[id] > 0:
					lights.append(lp + Vector3(0.5, 0.75, 0.5))
				if sh == Blocks.Shape.CUBE:
					var s: Surf = cut if cutout[id] == 1 else solid
					var tint := _tint(id, wx, wy, wz)
					var m := rmeta[ci]
					for f in 6:
						var ni := ci + _face_off[f]
						var nid := rid[ni]
						if opaque[nid] == 1:
							continue
						if cutout[id] == 1 and nid == id and (f == 1 or f == 3 or f == 5):
							# leaf against leaf: one face of the pair is enough
							continue
						var tex := face_tex[id * 6 + _axis_face(f, m, id)]
						_cube_face(s, rid, rl, ci, f, lp, tex, tint, _axis_rot(f, m, id), Blocks.sway[id] * 0.25)
				elif sh == Blocks.Shape.CROSS:
					_cross(cut, id, rmeta[ci], rl[ci], lp, wx, wy, wz)
					if Blocks.waterlog[id] == 1 and Blocks.sea > 0:
						_liquid(water, rid, rmeta, rl, ci, Blocks.sea, lp)
				elif sh == Blocks.Shape.BUSH:
					_bush(cut, rid, rl, ci, id, rmeta[ci], lp, wx, wy, wz)
				elif sh == Blocks.Shape.BOXES:
					_boxes(solid, rid, rl, ci, id, rmeta[ci], lp)
				elif sh == Blocks.Shape.LIQUID:
					_liquid(water, rid, rmeta, rl, ci, id, lp)
	var out := {}
	for k in [["solid", solid], ["cutout", cut], ["water", water]]:
		var arr: Array = (k[1] as Surf).arrays()
		if not arr.is_empty():
			out[k[0]] = arr
	if not lights.is_empty():
		out["lights"] = lights
	if not fixtures.is_empty():
		out["fixtures"] = fixtures
	return out


static func _tint(id: int, x: int, y: int, z: int) -> Color:
	var amt := Blocks.tint[id]
	if amt <= 0.0:
		return Color.WHITE
	var h := _hash(x, y, z)
	var a := (float(h % 1000) / 1000.0 - 0.5) * 2.0 * amt
	var b := (float((h / 1000) % 1000) / 1000.0 - 0.5) * 2.0 * amt
	return Color(1.0 + a * 0.6 + b * 0.4, 1.0 + a * 0.3, 1.0 - a * 0.5, 1.0)


static func _axis_face(f: int, m: int, id: int) -> int:
	## Logs lying along X or Z show their rings on those faces instead.
	m = m & 3
	if Blocks.axis[id] == 0 or m == 0:
		return f
	if m == 1:   # along X
		match f:
			4, 5: return 0
			0, 1: return 2
	elif m == 2: # along Z
		match f:
			2, 3: return 0
			0, 1: return 4
	return f


static func _axis_rot(f: int, m: int, id: int) -> bool:
	m = m & 3
	if Blocks.axis[id] == 0 or m == 0:
		return false
	if m == 1:
		return f == 0 or f == 1 or f == 2 or f == 3
	return f == 4 or f == 5


static func _cube_face(s: Surf, rid: PackedByteArray, rl: PackedByteArray, ci: int, f: int, lp: Vector3, tex: int, tint: Color, rot_uv: bool, sway: float) -> void:
	var fc := ci + _face_off[f]
	var opaque := Blocks.opaque
	var face: Dictionary = FACES[f]
	var corners: Array = face["c"]
	var uvs: Array = face["uv"]
	var n := Vector3(face["n"])
	var base := s.v.size()
	var aos := [0, 0, 0, 0]
	var l0 := float(rl[fc])
	for k in 4:
		var o1 := _ao_off[f * 8 + k * 2]
		var o2 := _ao_off[f * 8 + k * 2 + 1]
		var s1 := opaque[rid[fc + o1]]
		var s2 := opaque[rid[fc + o2]]
		var cc := opaque[rid[fc + o1 + o2]]
		var ao := 0 if (s1 == 1 and s2 == 1) else 3 - (s1 + s2 + cc)
		aos[k] = ao
		var lsum := l0
		var cnt := 1.0
		if s1 == 0:
			lsum += rl[fc + o1]
			cnt += 1.0
		if s2 == 0:
			lsum += rl[fc + o2]
			cnt += 1.0
		if cc == 0 and not (s1 == 1 and s2 == 1):
			lsum += rl[fc + o1 + o2]
			cnt += 1.0
		var shade: float = AO_F[ao] * _light_f(lsum / cnt)
		s.v.append(lp + (corners[k] as Vector3))
		s.n.append(n)
		s.c.append(Color(tint.r, tint.g, tint.b, shade))
		var uv: Vector2 = uvs[k]
		s.uv.append(Vector2(uv.y, 1.0 - uv.x) if rot_uv else uv)
		s.uv2.append(Vector2(tex, sway * (corners[k] as Vector3).y))
	if aos[0] + aos[2] < aos[1] + aos[3]:
		s.i.append_array([base, base + 3, base + 1, base + 1, base + 3, base + 2])
	else:
		s.i.append_array([base, base + 2, base + 1, base, base + 3, base + 2])


static func _quad(s: Surf, a: Vector3, b: Vector3, c: Vector3, d: Vector3, n: Vector3, tex: int, col: Color, uv_a := Vector2(0, 1), uv_c := Vector2(1, 0), sway_bottom := 0.0, sway_top := 0.0) -> void:
	## Quad a-b-c-d (CCW seen from the front), a bottom-left .. c top-right.
	var base := s.v.size()
	s.v.append_array([a, b, c, d])
	s.n.append_array([n, n, n, n])
	s.c.append_array([col, col, col, col])
	s.uv.append_array([uv_a, Vector2(uv_a.x, uv_c.y), uv_c, Vector2(uv_c.x, uv_a.y)])
	s.uv2.append_array([Vector2(tex, sway_bottom), Vector2(tex, sway_top), Vector2(tex, sway_top), Vector2(tex, sway_bottom)])
	s.i.append_array([base, base + 2, base + 1, base, base + 3, base + 2])


static func _cross(s: Surf, id: int, m: int, l: int, lp: Vector3, wx: int, wy: int, wz: int) -> void:
	var tex := Blocks.face_tex[id * 6]
	if Blocks.meta_tex.has(id):
		var mt: PackedInt32Array = Blocks.meta_tex[id]
		tex = mt[clampi(m, 0, mt.size() - 1)]
	var h := _hash(wx, wy, wz)
	var sc := Blocks.scale[id]
	var jx := 0.0
	var jz := 0.0
	if Blocks.jitter[id] == 1:
		jx = (float(h % 100) / 100.0 - 0.5) * 0.24
		jz = (float((h / 100) % 100) / 100.0 - 0.5) * 0.24
	var hh := 1.0 * sc
	var w := 0.38 * sc
	var cxp := 0.5 + jx
	var czp := 0.5 + jz
	var yb := Blocks.y_off[id]
	var tint := _tint(id, wx, wy, wz)
	var col := Color(tint.r, tint.g, tint.b, _light_f(l) * 0.95)
	var sw := Blocks.sway[id]
	var sb := 0.0
	var st := sw
	if sw < 0.0:
		# hanging from the block above: the free end is at the bottom
		sb = -sw
		st = 0.0
	var up := Vector3.UP
	var o := lp + Vector3(cxp, yb, czp)
	if Blocks.hang[id] == 1:
		o.y = lp.y + 1.0 - hh
	_quad(s, o + Vector3(-w, 0, -w), o + Vector3(-w, hh, -w), o + Vector3(w, hh, w), o + Vector3(w, 0, w), up, tex, col,
		Vector2(0, 1), Vector2(1, 0), sb, st)
	_quad(s, o + Vector3(-w, 0, w), o + Vector3(-w, hh, w), o + Vector3(w, hh, -w), o + Vector3(w, 0, -w), up, tex, col,
		Vector2(0, 1), Vector2(1, 0), sb, st)


static func _bush(s: Surf, rid: PackedByteArray, rl: PackedByteArray, ci: int, id: int, m: int, lp: Vector3, wx: int, wy: int, wz: int) -> void:
	var tex := Blocks.face_tex[id * 6]
	if Blocks.meta_tex.has(id):
		var mt: PackedInt32Array = Blocks.meta_tex[id]
		tex = mt[clampi(m, 0, mt.size() - 1)]
	var tint := _tint(id, wx, wy, wz)
	var lo := 0.08
	var hi := 0.92
	var top := 0.88
	var col := Color(tint.r, tint.g, tint.b, _light_f(rl[ci]))
	var colb := Color(tint.r, tint.g, tint.b, _light_f(rl[ci]) * 0.75)
	var sw := Blocks.sway[id]
	var p := lp
	# four sides, a top, and an inner cross for body
	_quad(s, p + Vector3(lo, 0, lo), p + Vector3(lo, top, lo), p + Vector3(hi, top, lo), p + Vector3(hi, 0, lo), Vector3(0, 0, -1), tex, colb, Vector2(0, 1), Vector2(1, 0), 0.0, sw)
	_quad(s, p + Vector3(hi, 0, hi), p + Vector3(hi, top, hi), p + Vector3(lo, top, hi), p + Vector3(lo, 0, hi), Vector3(0, 0, 1), tex, colb, Vector2(0, 1), Vector2(1, 0), 0.0, sw)
	_quad(s, p + Vector3(hi, 0, lo), p + Vector3(hi, top, lo), p + Vector3(hi, top, hi), p + Vector3(hi, 0, hi), Vector3(1, 0, 0), tex, colb, Vector2(0, 1), Vector2(1, 0), 0.0, sw)
	_quad(s, p + Vector3(lo, 0, hi), p + Vector3(lo, top, hi), p + Vector3(lo, top, lo), p + Vector3(lo, 0, lo), Vector3(-1, 0, 0), tex, colb, Vector2(0, 1), Vector2(1, 0), 0.0, sw)
	_quad(s, p + Vector3(lo, top, lo), p + Vector3(lo, top, hi), p + Vector3(hi, top, hi), p + Vector3(hi, top, lo), Vector3.UP, tex, col, Vector2(0, 0), Vector2(1, 1), sw, sw)
	_quad(s, p + Vector3(lo, 0, lo), p + Vector3(lo, top, lo), p + Vector3(hi, top, hi), p + Vector3(hi, 0, hi), Vector3.UP, tex, col, Vector2(0, 1), Vector2(1, 0), 0.0, sw)
	_quad(s, p + Vector3(lo, 0, hi), p + Vector3(lo, top, hi), p + Vector3(hi, top, lo), p + Vector3(hi, 0, lo), Vector3.UP, tex, col, Vector2(0, 1), Vector2(1, 0), 0.0, sw)


static func box_faces(s: Surf, a: Vector3, b: Vector3, rot: float, origin: Vector3, tex: int, top_tex: int, col: Color, cull: Callable = Callable()) -> void:
	## A textured box (block-local corners a..b, rotated by rot about its centre),
	## each face showing the part of the tile it covers.  Shared with block-entity
	## views, which build small models out of the same boxes.
	var ctr := (a + b) * 0.5
	var basis := Basis(Vector3.UP, rot)
	var size := b - a
	for f in 6:
		if cull.is_valid() and rot == 0.0 and cull.call(f, a, b):
			continue
		var face: Dictionary = FACES[f]
		var corners: Array = face["c"]
		var n := basis * Vector3(face["n"])
		var t: Array = face["t"]
		var base := s.v.size()
		var shade := 1.0 if f == 0 else (0.62 if f == 1 else 0.88)
		var cc := Color(col.r, col.g, col.b, col.a * shade)
		for k in 4:
			var cp: Vector3 = corners[k]
			var p := a + Vector3(cp.x * size.x, cp.y * size.y, cp.z * size.z)
			s.v.append(origin + ctr + basis * (p - ctr))
			s.n.append(n)
			s.c.append(cc)
			# sample the tile region this face covers (in block units)
			var u := p[t[0]]
			var v := p[t[1]]
			if f == 0 or f == 1:
				s.uv.append(Vector2(u, v))
			else:
				var uvc: Vector2 = face["uv"][k]
				var uu := u if uvc.x > 0.5 else u
				s.uv.append(Vector2(1.0 - uu if (f == 2 or f == 4) else uu, 1.0 - v))
			s.uv2.append(Vector2(top_tex if f == 0 else tex, 0.0))
		s.i.append_array([base, base + 2, base + 1, base, base + 3, base + 2])


static func _boxes(s: Surf, rid: PackedByteArray, rl: PackedByteArray, ci: int, id: int, m: int, lp: Vector3) -> void:
	var col := Color(1, 1, 1, _light_f(rl[ci]))
	var opaque := Blocks.opaque
	var cull := func(f: int, a: Vector3, b: Vector3) -> bool:
		var on_edge := false
		match f:
			0: on_edge = b.y >= 0.999
			1: on_edge = a.y <= 0.001
			2: on_edge = a.z <= 0.001
			3: on_edge = b.z >= 0.999
			4: on_edge = b.x >= 0.999
			5: on_edge = a.x <= 0.001
		return on_edge and opaque[rid[ci + _face_off[f]]] == 1
	var turned := Blocks.facing[id] == 1
	for bx in Blocks.boxes.get(id, []):
		var top_tex: int = bx["tex"]
		var tops: PackedInt32Array = bx["top"]
		if not tops.is_empty() and not turned:
			top_tex = tops[clampi(m, 0, tops.size() - 1)]
		if turned:
			var tb := Blocks.turn_box(bx["a"], bx["b"], m)
			box_faces(s, tb.position, tb.end, 0.0, lp, bx["tex"], top_tex, col, cull)
		else:
			box_faces(s, bx["a"], bx["b"], bx["rot"], lp, bx["tex"], top_tex, col, cull)


static func liquid_h(m: int, covered: bool) -> float:
	## How high the water in a cell stands (block units): full under more water,
	## otherwise by how many of its 8 units it holds.
	if covered:
		return 1.0
	return 0.875 * float(8 - (m & 7)) / 8.0


static func _liquid(s: Surf, rid: PackedByteArray, rmeta: PackedByteArray, rl: PackedByteArray, ci: int, id: int, lp: Vector3) -> void:
	var tex := Blocks.face_tex[id * 6]
	var opaque := Blocks.opaque
	var wl := Blocks.waterlog
	var covered := rid[ci + DY] == id or wl[rid[ci + DY]] == 1
	var h := liquid_h(0 if wl[rid[ci]] == 1 else rmeta[ci], covered)
	# each top corner stands at the average of the water around it, so a sheet
	# that differs by a part here and there reads as one smooth surface
	var hc := PackedFloat32Array([h, h, h, h])   # corner (x, z) -> hc[x + 2 * z]
	if not covered:
		for k in 4:
			var ox := DX if (k & 1) == 1 else -DX
			var oz := DZ if (k >> 1) == 1 else -DZ
			var sum := 0.0
			var cnt := 0
			var full := false
			for o in [0, ox, oz, ox + oz]:
				var ni: int = ci + o
				var nwl := wl[rid[ni]] == 1
				if rid[ni] != id and not nwl:
					continue
				if rid[ni + DY] == id or wl[rid[ni + DY]] == 1:
					full = true
					break
				sum += liquid_h(0 if nwl else rmeta[ni], false)
				cnt += 1
			hc[k] = 1.0 if full else sum / float(maxi(cnt, 1))
	for f in 6:
		var ni := ci + _face_off[f]
		var nid := rid[ni]
		var same := nid == id or wl[nid] == 1
		if f == 0:
			if covered:
				continue
		elif f == 1:
			if same or Blocks.solid[nid] == 1:
				continue
		elif opaque[nid] == 1 or same:
			continue
		var face: Dictionary = FACES[f]
		var corners: Array = face["c"]
		var uvs: Array = face["uv"]
		var n := Vector3(face["n"])
		var base := s.v.size()
		var col := Color(1, 1, 1, _light_f(maxf(rl[ci], rl[ni])))
		for k in 4:
			var cp: Vector3 = corners[k]
			var y := 0.0
			if cp.y > 0.5:
				y = hc[int(cp.x) + 2 * int(cp.z)]
			s.v.append(lp + Vector3(cp.x, y, cp.z))
			s.n.append(n)
			s.c.append(col)
			s.uv.append(uvs[k])
			s.uv2.append(Vector2(tex, 0.0))
		s.i.append_array([base, base + 2, base + 1, base, base + 3, base + 2])
