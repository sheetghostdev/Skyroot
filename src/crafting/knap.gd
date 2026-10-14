class_name Knap
extends RefCounted
## Non-voxel stone shaping.
##
## A stone is a noisy ellipsoid defined by a seed (X = length, Z = width,
## Y = thickness).  Every strike removes material with a plane - a flake scar -
## so the complete shape is (seed + list of planes): tiny to store, sync and
## save.  The mesh is the base pebble with every vertex projected back inside
## all planes, which yields crisp knapped facets.  Evaluation is analytic: the
## vertical extent of the stone is computed on a grid and compared with the
## silhouette and edge requirements of a tool.

const TARGETS := {
	"blade": {
		"name": "Cutting blade",
		"poly": [[-0.86, 0.0], [-0.62, 0.42], [0.0, 0.56], [0.55, 0.4], [0.92, 0.0], [0.55, -0.4], [0.0, -0.56], [-0.62, -0.42]],
		"edge": [[[-0.5, 0.44], [0.6, 0.38]], [[-0.5, -0.44], [0.6, -0.38]]],
		"edge_any": true, "sharp": 0.0042, "min_core": 0.006,
		"desc": "A leaf-shaped flake with at least one long, thin edge.",
	},
	"axe": {
		"name": "Axe head",
		"poly": [[-0.8, -0.36], [-0.8, 0.36], [0.55, 0.6], [0.82, 0.42], [0.9, 0.0], [0.82, -0.42], [0.55, -0.6]],
		"edge": [[[0.84, 0.36], [0.9, 0.0]], [[0.9, 0.0], [0.84, -0.36]]],
		"edge_any": false, "sharp": 0.0055, "min_core": 0.012,
		"desc": "A wedge: narrow butt for the handle, wide curved bit thinned from both faces.",
	},
	"digger": {
		"name": "Digging blade",
		"poly": [[-0.76, -0.5], [-0.76, 0.5], [0.5, 0.72], [0.8, 0.52], [0.88, 0.0], [0.8, -0.52], [0.5, -0.72]],
		"edge": [[[0.82, 0.48], [0.88, 0.0]], [[0.88, 0.0], [0.82, -0.48]]],
		"edge_any": false, "sharp": 0.0075, "min_core": 0.01,
		"desc": "A broad, flat blade with a wide working edge.",
	},
}

const STONE_L := 0.346          # litres of stone in one cobble (0.9 kg)
const DENSITY := 2.6            # kg per litre
const CORTEX := Color(0.66, 0.62, 0.54)
const FRESH := Color(0.27, 0.27, 0.3)


static func params(seed_value: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var a := rng.randf_range(0.062, 0.078)
	var b := rng.randf_range(0.044, 0.054)
	# thickness chosen so every cobble holds exactly STONE_L of stone
	var c := (STONE_L / 1000.0) / (4.0 / 3.0 * PI * a * b)
	return {"a": a, "b": b, "c": c, "tint": rng.randf_range(-1.0, 1.0), "seed": seed_value}


static func _noise(seed_value: int) -> FastNoiseLite:
	var n := FastNoiseLite.new()
	n.seed = seed_value
	n.frequency = 1.4
	n.fractal_octaves = 2
	return n


static func base_vertex(dir: Vector3, p: Dictionary, n: FastNoiseLite) -> Vector3:
	var r := 1.0 + 0.09 * n.get_noise_3dv(dir * 1.7)
	return Vector3(dir.x * p["a"], dir.y * p["c"], dir.z * p["b"]) * r


static func cut_vertices(seed_value: int, cuts: Array) -> Dictionary:
	var p := params(seed_value)
	var ico := Geo.icosphere(3)
	var n := _noise(seed_value)
	var verts := PackedVector3Array()
	var moved := PackedFloat32Array()
	for d in ico["v"]:
		verts.append(base_vertex(d, p, n))
		moved.append(0.0)
	if not cuts.is_empty():
		for it in 3:
			for c in cuts:
				var nn := Vector3(c[0], c[1], c[2])
				for i in verts.size():
					var s := verts[i].dot(nn) - cut_offset(c, verts[i].x, verts[i].z)
					if s > 0.0:
						verts[i] -= nn * s
						moved[i] = 1.0
	return {"v": verts, "t": ico["t"], "moved": moved, "p": p}


static func build_mesh(seed_value: int, cuts: Array) -> ArrayMesh:
	var r := cut_vertices(seed_value, cuts)
	var p: Dictionary = r["p"]
	var cols := PackedColorArray()
	var tint := float(p["tint"])
	var cortex := CORTEX * (1.0 + tint * 0.06)
	var fresh := FRESH * (1.0 + tint * 0.08)
	var nz := _noise(seed_value + 7)
	for i in r["v"].size():
		var v: Vector3 = r["v"][i]
		var c := fresh if r["moved"][i] > 0.5 else cortex
		c *= 0.9 + 0.18 * (nz.get_noise_3dv(v * 60.0) * 0.5 + 0.5)
		cols.append(c)
	return Geo.flat_mesh(r["v"], r["t"], cols)


# ---------------------------------------------------------------------------
# Analysis
# ---------------------------------------------------------------------------

static func cut_offset(c: Array, x: float, z: float) -> float:
	## A flake scar is local: the cutting surface curves outward away from the
	## point of impact (a scallop), so each blow shapes only a short stretch of edge.
	## c = [nx, ny, nz, d] (unbounded: a snap) or [nx, ny, nz, d, tx, tz, cx, cz, half_width, depth].
	if c.size() < 10:
		return c[3]
	var l: float = (x - float(c[6])) * float(c[4]) + (z - float(c[7])) * float(c[5])
	var w: float = c[8]
	return float(c[3]) + (l * l) / (w * w) * float(c[9]) * 1.4


static func extent(p: Dictionary, cuts: Array, x: float, z: float) -> Vector2:
	## Vertical extent (bottom, top) of the stone above point (x, z); top < bottom means empty.
	var a: float = p["a"]
	var b: float = p["b"]
	var c: float = p["c"]
	var e := 1.0 - (x * x) / (a * a) - (z * z) / (b * b)
	if e <= 0.0:
		return Vector2(1.0, -1.0)
	var ye := c * sqrt(e)
	var lo := -ye
	var hi := ye
	for cut in cuts:
		var nx: float = cut[0]
		var ny: float = cut[1]
		var nz: float = cut[2]
		var d: float = cut_offset(cut, x, z)
		var rest := d - nx * x - nz * z
		if absf(ny) < 1e-5:
			if rest < 0.0:
				return Vector2(1.0, -1.0)
		elif ny > 0.0:
			hi = minf(hi, rest / ny)
		else:
			lo = maxf(lo, rest / ny)
	return Vector2(lo, hi)


static func thickness_at(p: Dictionary, cuts: Array, x: float, z: float) -> float:
	var e := extent(p, cuts, x, z)
	return maxf(0.0, e.y - e.x)


static func volume_l(seed_value: int, cuts: Array) -> float:
	var p := params(seed_value)
	var a: float = p["a"]
	var b: float = p["b"]
	var res := 28
	var dx := 2.0 * a / res
	var dz := 2.0 * b / res
	var v := 0.0
	for i in res:
		for j in res:
			var x := -a + (i + 0.5) * dx
			var z := -b + (j + 0.5) * dz
			v += thickness_at(p, cuts, x, z) * dx * dz
	return v * 1000.0


static func outline_point(p: Dictionary, cuts: Array, dir2: Vector2) -> Vector2:
	## Walk outward from the centre along dir2 until the stone ends (mid-thickness test).
	var step := 0.0015
	var r := 0.0
	var last := Vector2.ZERO
	while r < 0.12:
		var q := dir2 * r
		if thickness_at(p, cuts, q.x, q.y) < 0.0008:
			return last
		last = q
		r += step
	return last


static func target_poly(p: Dictionary, shape: String) -> PackedVector2Array:
	var out := PackedVector2Array()
	for pt in TARGETS[shape]["poly"]:
		out.append(Vector2(pt[0] * p["a"] * 0.95, pt[1] * p["b"] * 0.95))
	return out


static func evaluate(seed_value: int, cuts: Array, shape: String, res: int = 40) -> Dictionary:
	var p := params(seed_value)
	var tgt := target_poly(p, shape)
	var spec: Dictionary = TARGETS[shape]
	var a: float = p["a"]
	var b: float = p["b"]
	var in_t := 0
	var hit := 0
	var excess := 0
	for i in res:
		for j in res:
			var x := -a + (i + 0.5) * 2.0 * a / res
			var z := -b + (j + 0.5) * 2.0 * b / res
			var stone := thickness_at(p, cuts, x, z) > 0.0008
			var inside := Geometry2D.is_point_in_polygon(Vector2(x, z), tgt)
			if inside:
				in_t += 1
				if stone:
					hit += 1
			elif stone:
				excess += 1
	var coverage := float(hit) / maxf(1.0, in_t)
	var excess_r := float(excess) / maxf(1.0, in_t)
	var shape_score := clampf((coverage - 0.55) / 0.4, 0.0, 1.0) * clampf(1.0 - maxf(0.0, excess_r - 0.06) * 2.2, 0.0, 1.0)
	# edge sharpness along the working edges
	var edge_scores: Array[float] = []
	for seg in spec["edge"]:
		var p0 := Vector2(seg[0][0] * a * 0.95, seg[0][1] * b * 0.95)
		var p1 := Vector2(seg[1][0] * a * 0.95, seg[1][1] * b * 0.95)
		var good := 0.0
		var n := 7 if res >= 30 else 4
		for k in n:
			var q := p0.lerp(p1, (k + 0.5) / n)
			var inward := -q.normalized()
			var edge := outline_point(p, cuts, q.normalized())
			# compare the stone's actual edge with the target edge position
			var at_edge := edge + inward * 0.0028
			var t1 := thickness_at(p, cuts, at_edge.x, at_edge.y)
			var deeper := edge + inward * 0.008
			var t2 := thickness_at(p, cuts, deeper.x, deeper.y)
			var s1 := clampf(1.0 - (t1 - spec["sharp"]) / 0.006, 0.0, 1.0)
			var s2 := clampf(1.0 - (t2 - spec["sharp"] * 2.1) / 0.01, 0.0, 1.0)
			var reach := clampf(1.0 - (q.length() - edge.length()) / 0.008, 0.0, 1.0)
			good += (s1 * 0.65 + s2 * 0.35) * reach
		edge_scores.append(good / n)
	var edge_score := 0.0
	if spec["edge_any"]:
		for s in edge_scores:
			edge_score = maxf(edge_score, s)
	else:
		for s in edge_scores:
			edge_score += s / edge_scores.size()
	var core := thickness_at(p, cuts, 0.0, 0.0)
	var core_ok := clampf(core / spec["min_core"], 0.0, 1.0)
	var q := clampf(shape_score * 0.5 + edge_score * 0.42 + core_ok * 0.08, 0.0, 1.0)
	var usable: bool = coverage > 0.6 and edge_score > 0.12 and core > spec["min_core"] * 0.5
	var notes: PackedStringArray = []
	if coverage < 0.8:
		notes.append("Too much was knocked away - the outline is smaller than the %s needs." % spec["name"].to_lower())
	if excess_r > 0.15:
		notes.append("Excess stone remains outside the outline.")
	if edge_score < 0.5:
		notes.append("The working edge is still thick: use light taps along it, from both faces.")
	if core < spec["min_core"]:
		notes.append("The body is thin and may snap.")
	return {"q": q, "shape": shape_score, "coverage": coverage, "excess": excess_r, "edge": edge_score,
		"usable": usable, "notes": notes, "core": core}


static func best_shape(seed_value: int, cuts: Array) -> String:
	var best := "blade"
	var best_q := -1.0
	for s in TARGETS:
		var e := evaluate(seed_value, cuts, s)
		if e["q"] > best_q:
			best_q = e["q"]
			best = s
	return best


# ---------------------------------------------------------------------------
# Strikes
# ---------------------------------------------------------------------------

static func strike(seed_value: int, cuts: Array, flipped: bool, click: Vector2, power: float, rng_seed: int) -> Dictionary:
	## Returns {"cut": [nx,ny,nz,d] or [], "broke": bool, "contact": Vector2, "removed_l": float}.
	## `click` is in stone-local XZ; power 0 (light pressure flake) .. 1 (hard percussion).
	var p := params(seed_value)
	var dir := click.normalized() if click.length() > 0.001 else Vector2(1, 0)
	var edge := outline_point(p, cuts, dir)
	var to_click := click.length() - edge.length()
	if to_click > 0.02:
		return {"cut": [], "broke": false, "contact": edge, "removed_l": 0.0, "miss": true}
	# outward normal of the outline near the contact point (finite difference)
	var perp := Vector2(-dir.y, dir.x)
	var e1 := outline_point(p, cuts, (dir + perp * 0.12).normalized())
	var e2 := outline_point(p, cuts, (dir - perp * 0.12).normalized())
	var tangent := (e1 - e2).normalized()
	var m := Vector2(tangent.y, -tangent.x)
	if m.dot(dir) < 0.0:
		m = -m
	# light pressure flakes are shallow (thin the edge); heavy blows take a steep
	# flake that carries through the edge and trims the outline
	var bite := lerpf(0.0016, 0.0085, power)
	var alpha := deg_to_rad(lerpf(64.0, 14.0, power))
	var up := -1.0 if flipped else 1.0
	var n3 := Vector3(m.x * cos(alpha), up * sin(alpha), m.y * cos(alpha)).normalized()
	var p0 := Vector3(edge.x - m.x * bite, 0.0, edge.y - m.y * bite)
	var d := p0.dot(n3)
	var half_w := lerpf(0.009, 0.02, power)
	var vol_before := volume_l(seed_value, cuts)
	var rng := RandomNumberGenerator.new()
	rng.seed = rng_seed
	# Hard blows near a narrow section can snap the stone.
	var width_here := edge.length() + outline_point(p, cuts, -dir).length()
	var broke := false
	var new_cuts := cuts.duplicate()
	if power > 0.7 and width_here < 0.05 and rng.randf() < (power - 0.6) * 0.9:
		broke = true
		var snap_d := Vector3(edge.x - m.x * width_here * 0.42, 0.0, edge.y - m.y * width_here * 0.42).dot(Vector3(m.x, 0, m.y))
		new_cuts.append([m.x, 0.0, m.y, snap_d])
	else:
		# a little natural variation in the flake
		n3 = (n3 + Vector3(rng.randf_range(-0.05, 0.05), 0.0, rng.randf_range(-0.05, 0.05))).normalized()
		d = p0.dot(n3)
		new_cuts.append([n3.x, n3.y, n3.z, d, tangent.x, tangent.y, edge.x, edge.y, half_w * rng.randf_range(0.85, 1.15), bite])
	var removed := maxf(0.0, vol_before - volume_l(seed_value, new_cuts))
	var cut: Array = new_cuts[new_cuts.size() - 1]
	return {"cut": cut, "broke": broke, "contact": edge, "removed_l": removed, "miss": false}
