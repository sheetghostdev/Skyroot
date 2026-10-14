class_name Pottery
extends RefCounted
## Hand-built pottery as a lathed profile.
##
## A vessel is N rings stacked over height H; each ring has an outer radius
## (ro) and an inner radius (ri, 0 = solid).  The cavity is contiguous from the
## rim down to the floor.  Every sculpting gesture moves clay around and then
## `conserve()` restores the original clay volume by thickening or thinning the
## walls - pulling up thins, pressing down thickens, hollowing pushes clay
## outward - so a lump of clay becomes a vessel instead of being "edited".
## Evaluation reads functional properties straight from the geometry.

const N := 26
const SEG := 44
const LUMP_L := 0.25          # litres of clay per lump item
const MIN_WALL := 0.0018
const DENSITY := 1.8          # kg per litre of wet clay

const COL_WET := Color(0.40, 0.25, 0.18)
const COL_LEATHER := Color(0.52, 0.36, 0.26)
const COL_DRY := Color(0.76, 0.64, 0.52)
const COL_FIRED := Color(0.72, 0.38, 0.23)
const COL_FIRED_LIGHT := Color(0.83, 0.52, 0.33)
const COL_SMOKE := Color(0.16, 0.13, 0.12)


static func new_lump(volume_l: float, moist: float, seed_value: int) -> Dictionary:
	var h := 0.045 + volume_l * 0.07
	var r := sqrt(volume_l / 1000.0 / (PI * h)) * 1.02
	var ro := PackedFloat32Array()
	var ri := PackedFloat32Array()
	var wob := PackedFloat32Array()
	var rough := PackedFloat32Array()
	for i in N:
		var f := float(i) / (N - 1)
		# a soft dome: slightly narrower at the bottom and rounded on top
		var shape := 0.88 + 0.12 * sin(f * PI * 0.85 + 0.25)
		if f > 0.8:
			shape *= sqrt(maxf(0.05, 1.0 - pow((f - 0.8) / 0.2, 2.0)) * 0.65 + 0.35)
		ro.append(r * shape)
		ri.append(0.0)
		wob.append(0.12)
		rough.append(1.0)
	var d := {"ro": ro, "ri": ri, "h": h, "wob": wob, "rough": rough, "rim": 0.0,
		"vol": volume_l, "moist": moist, "state": "wet", "fired": 0.0, "crack": 0.0,
		"seed": seed_value, "water": 0.0, "pierced": false, "smoke": 0.0, "heat": 20.0}
	conserve(d)
	return d


# ---------------------------------------------------------------------------
# Geometry helpers
# ---------------------------------------------------------------------------

static func dy(d: Dictionary) -> float:
	return float(d["h"]) / (N - 1)


static func volume(d: Dictionary) -> float:
	var ro: PackedFloat32Array = d["ro"]
	var ri: PackedFloat32Array = d["ri"]
	var step := dy(d)
	var v := 0.0
	for i in N - 1:
		var a0 := ro[i] * ro[i] - ri[i] * ri[i]
		var a1 := ro[i + 1] * ro[i + 1] - ri[i + 1] * ri[i + 1]
		v += (a0 + a1) * 0.5 * step
	# rounded rim adds a sliver; ignore
	return v * PI * 1000.0


static func floor_index(d: Dictionary) -> int:
	var ri: PackedFloat32Array = d["ri"]
	var k := N
	for i in range(N - 1, -1, -1):
		if ri[i] > 0.0005:
			k = i
		else:
			break
	return k


static func is_hollow(d: Dictionary) -> bool:
	return floor_index(d) < N - 2


static func _enforce(d: Dictionary) -> void:
	var ro: PackedFloat32Array = d["ro"]
	var ri: PackedFloat32Array = d["ri"]
	var k := floor_index(d)
	for i in N:
		if i < k:
			ri[i] = 0.0
		ro[i] = clampf(ro[i], 0.008, 0.13)
		if ri[i] > 0.0:
			ri[i] = clampf(ri[i], 0.0025, ro[i] - MIN_WALL)
	d["ro"] = ro
	d["ri"] = ri
	d["h"] = clampf(float(d["h"]), 0.015, 0.32)


static func conserve(d: Dictionary, weights: PackedFloat32Array = PackedFloat32Array()) -> void:
	## Restore d["vol"] by scaling wall thickness (optionally weighted per ring).
	_enforce(d)
	var target := float(d["vol"])
	var ro: PackedFloat32Array = d["ro"]
	var ri: PackedFloat32Array = d["ri"]
	if weights.size() != N:
		weights = PackedFloat32Array()
		weights.resize(N)
		weights.fill(1.0)
	var base_t := PackedFloat32Array()
	for i in N:
		base_t.append(ro[i] - ri[i])
	var lo := 0.05
	var hi := 6.0
	for it in 30:
		var s := (lo + hi) * 0.5
		for i in N:
			var f := 1.0 + (s - 1.0) * weights[i]
			ro[i] = ri[i] + maxf(MIN_WALL, base_t[i] * f)
		d["ro"] = ro
		var v := volume(d)
		if v > target:
			hi = s
		else:
			lo = s
		if absf(v - target) < target * 0.0005:
			break
	_enforce(d)


static func gauss_weights(center_frac: float, sigma: float) -> PackedFloat32Array:
	var w := PackedFloat32Array()
	for i in N:
		var f := float(i) / (N - 1)
		w.append(exp(-pow((f - center_frac) / sigma, 2.0)))
	return w


# ---------------------------------------------------------------------------
# Sculpting operations (deterministic; host and sculptor apply the same ops)
# ---------------------------------------------------------------------------

static func apply_op(d: Dictionary, op: Array) -> Dictionary:
	## op = [kind, a, b, c].  Returns side results (e.g. trimmed clay).
	var kind: String = op[0]
	var res := {}
	match kind:
		"shape":
			_op_shape(d, op[1], op[2], op[3])
		"hollow":
			_op_hollow(d, op[1], op[2])
		"smooth":
			_op_smooth(d, op[1], op[2])
		"rim":
			_op_rim(d, op[1], op[2])
		"trim":
			res = _op_trim(d, op[1])
		"add":
			_op_add(d, op[1])
	d["moist"] = clampf(float(d["moist"]), 0.0, 0.4)
	return res


static func _op_shape(d: Dictionary, y_frac: float, inward: float, up: float) -> void:
	## inward > 0 narrows at that height; up > 0 pulls clay upward (taller, thinner walls).
	var ro: PackedFloat32Array = d["ro"]
	var ri: PackedFloat32Array = d["ri"]
	var w := gauss_weights(clampf(y_frac, 0.0, 1.0), 0.13)
	var dr := clampf(-inward, -0.006, 0.006)
	for i in N:
		ro[i] += dr * w[i]
		if ri[i] > 0.0:
			ri[i] = maxf(0.0028, ri[i] + dr * w[i])
	d["ro"] = ro
	d["ri"] = ri
	var wob: PackedFloat32Array = d["wob"]
	var rough: PackedFloat32Array = d["rough"]
	for i in N:
		wob[i] = minf(0.35, wob[i] + absf(dr) * 2.0 * w[i])
		rough[i] = minf(1.0, rough[i] + absf(dr) * 25.0 * w[i])
	d["wob"] = wob
	d["rough"] = rough
	var cw := PackedFloat32Array()
	cw.resize(N)
	cw.fill(1.0)
	if absf(up) > 0.0:
		var hgt := float(d["h"])
		d["h"] = hgt * (1.0 + clampf(up, -0.08, 0.08))
		for i in N:
			var f := float(i) / (N - 1)
			cw[i] = 0.35 + 0.65 * smoothstep(y_frac - 0.15, y_frac + 0.1, f) if up > 0.0 else 1.0
	conserve(d, cw)


static func _op_hollow(d: Dictionary, depth_frac: float, open_frac: float) -> void:
	## Thumb pressed into the top: open a cavity down to depth_frac of the height.
	var ro: PackedFloat32Array = d["ro"]
	var ri: PackedFloat32Array = d["ri"]
	depth_frac = clampf(depth_frac, 0.0, 0.98)
	var floor_f := 1.0 - depth_frac
	for i in N:
		var f := float(i) / (N - 1)
		if f < floor_f:
			continue
		var t := clampf((f - floor_f) / maxf(0.06, depth_frac * 0.45), 0.0, 1.0)
		var shape := sqrt(t)
		var target := clampf(open_frac, 0.05, 0.92) * ro[i] * shape
		if target > ri[i]:
			ri[i] = target
	d["ri"] = ri
	if floor_f * float(d["h"]) < 0.0022:
		d["pierced"] = true
	# displaced clay goes outward into the walls
	var w := PackedFloat32Array()
	for i in N:
		var f := float(i) / (N - 1)
		w.append(0.3 + 0.7 * smoothstep(floor_f - 0.2, floor_f + 0.2, f))
	conserve(d, w)
	var rough: PackedFloat32Array = d["rough"]
	for i in N:
		rough[i] = minf(1.0, rough[i] + 0.05)
	d["rough"] = rough


static func _op_smooth(d: Dictionary, y_frac: float, strength: float) -> void:
	var ro: PackedFloat32Array = d["ro"]
	var ri: PackedFloat32Array = d["ri"]
	var wob: PackedFloat32Array = d["wob"]
	var rough: PackedFloat32Array = d["rough"]
	var w := gauss_weights(clampf(y_frac, 0.0, 1.0), 0.2)
	var k := clampf(strength, 0.0, 1.0)
	var ro2 := ro.duplicate()
	var ri2 := ri.duplicate()
	for i in range(1, N - 1):
		var a := k * 0.35 * w[i]
		ro2[i] = lerpf(ro[i], (ro[i - 1] + ro[i] * 2.0 + ro[i + 1]) * 0.25, a)
		if ri[i] > 0.0 and ri[i - 1] > 0.0 and ri[i + 1] > 0.0:
			ri2[i] = lerpf(ri[i], (ri[i - 1] + ri[i] * 2.0 + ri[i + 1]) * 0.25, a)
	for i in N:
		wob[i] *= 1.0 - 0.22 * k * w[i]
		rough[i] *= 1.0 - 0.3 * k * w[i]
	d["ro"] = ro2
	d["ri"] = ri2
	d["wob"] = wob
	d["rough"] = rough
	d["moist"] = float(d["moist"]) + 0.0004 * k
	conserve(d)


static func _op_rim(d: Dictionary, outward: float, press: float) -> void:
	var ro: PackedFloat32Array = d["ro"]
	var ri: PackedFloat32Array = d["ri"]
	var w := gauss_weights(1.0, 0.08)
	var dr := clampf(outward, -0.004, 0.004)
	for i in N:
		ro[i] += dr * w[i]
		if ri[i] > 0.0:
			ri[i] = maxf(0.0028, ri[i] + dr * w[i])
	d["ro"] = ro
	d["ri"] = ri
	d["rim"] = clampf(float(d["rim"]) + absf(press) * 6.0 + absf(dr) * 20.0, 0.0, 1.0)
	if press > 0.0:
		d["h"] = float(d["h"]) * (1.0 - clampf(press, 0.0, 0.02))
	var wob: PackedFloat32Array = d["wob"]
	wob[N - 1] *= 0.85
	wob[N - 2] *= 0.9
	d["wob"] = wob
	conserve(d, w)


static func _op_trim(d: Dictionary, y_frac: float) -> Dictionary:
	## Cut the top off at y_frac.  Whole lumps of removed clay are returned; the
	## crumbs are pressed back into the base so no clay appears or vanishes.
	y_frac = clampf(y_frac, 0.3, 0.98)
	var before := float(d["vol"])
	var ro: PackedFloat32Array = d["ro"]
	var ri: PackedFloat32Array = d["ri"]
	var wob: PackedFloat32Array = d["wob"]
	var rough: PackedFloat32Array = d["rough"]
	var nro := PackedFloat32Array()
	var nri := PackedFloat32Array()
	var nwob := PackedFloat32Array()
	var nrough := PackedFloat32Array()
	for i in N:
		var src := float(i) / (N - 1) * y_frac * (N - 1)
		var i0 := int(floor(src))
		var i1 := mini(i0 + 1, N - 1)
		var t := src - i0
		nro.append(lerpf(ro[i0], ro[i1], t))
		nri.append(lerpf(ri[i0], ri[i1], t))
		nwob.append(lerpf(wob[i0], wob[i1], t))
		nrough.append(lerpf(rough[i0], rough[i1], t))
	d["ro"] = nro
	d["ri"] = nri
	d["wob"] = nwob
	d["rough"] = nrough
	d["h"] = float(d["h"]) * y_frac
	d["rim"] = 0.0
	var after := volume(d)
	var removed := maxf(0.0, before - after)
	var lumps := int(floor(removed / LUMP_L + 0.0001))
	d["vol"] = before - lumps * LUMP_L
	conserve(d)
	return {"lumps": lumps, "removed_l": lumps * LUMP_L}


static func _op_add(d: Dictionary, litres: float) -> void:
	d["vol"] = float(d["vol"]) + litres
	d["h"] = float(d["h"]) * (1.0 + litres / maxf(0.05, float(d["vol"])) * 0.3)
	var rough: PackedFloat32Array = d["rough"]
	var wob: PackedFloat32Array = d["wob"]
	for i in N:
		rough[i] = minf(1.0, rough[i] + 0.4)
		wob[i] = minf(0.35, wob[i] + 0.04)
	d["rough"] = rough
	d["wob"] = wob
	conserve(d)


# ---------------------------------------------------------------------------
# Evaluation
# ---------------------------------------------------------------------------

static func stats(d: Dictionary) -> Dictionary:
	var ro: PackedFloat32Array = d["ro"]
	var ri: PackedFloat32Array = d["ri"]
	var wob: PackedFloat32Array = d["wob"]
	var rough: PackedFloat32Array = d["rough"]
	var step := dy(d)
	var h := float(d["h"])
	var k := floor_index(d)
	var max_ro := 0.0
	for r in ro:
		max_ro = maxf(max_ro, r)
	var out := {"h": h, "max_r": max_ro, "base_r": ro[0], "rim_ro": ro[N - 1], "hollow": k < N - 2}
	var cap := 0.0
	var tmin := 1.0
	var tsum := 0.0
	var tsq := 0.0
	var cnt := 0
	var max_ri := 0.0
	for i in range(k, N):
		var t := ro[i] - ri[i]
		tmin = minf(tmin, t)
		tsum += t
		tsq += t * t
		cnt += 1
		max_ri = maxf(max_ri, ri[i])
		if i < N - 1 and ri[i + 1] > 0.0:
			cap += PI * (ri[i] * ri[i] + ri[i + 1] * ri[i + 1]) * 0.5 * step
	var tmean := tsum / maxf(1.0, cnt)
	var tvar := maxf(0.0, tsq / maxf(1.0, cnt) - tmean * tmean)
	var floor_t := k * step if k < N else h
	var depth := h - floor_t
	var wob_mean := 0.0
	var rough_mean := 0.0
	for i in N:
		wob_mean += wob[i] / N
		rough_mean += rough[i] / N
	out["capacity_l"] = cap * 1000.0
	out["depth"] = depth
	out["floor_t"] = floor_t
	out["wall_min"] = tmin if cnt > 0 else ro[0]
	out["wall_mean"] = tmean if cnt > 0 else ro[0]
	out["uneven"] = sqrt(tvar) / maxf(0.0005, tmean)
	out["wobble"] = wob_mean
	out["rough"] = rough_mean
	out["rim_open"] = ri[N - 1]
	out["neck"] = ri[N - 1] / maxf(0.001, max_ri)
	var rim_t := ro[N - 1] - ri[N - 1]
	out["rim_integrity"] = clampf(rim_t / 0.0055, 0.0, 1.0) * (0.55 + 0.45 * float(d["rim"])) * clampf(1.0 - wob[N - 1] * 2.0, 0.2, 1.0)
	out["stability"] = clampf(ro[0] / maxf(0.001, max_ro * 0.5), 0.0, 1.0) * clampf(1.0 - maxf(0.0, h / maxf(0.001, ro[0] * 2.0) - 2.2) * 0.4, 0.2, 1.0)
	# kind
	var kind := "lump"
	if out["hollow"] and depth > 0.008 and out["capacity_l"] > 0.03:
		var rim_r := ri[N - 1]
		var depth_ratio := depth / maxf(0.002, 2.0 * rim_r)
		if out["neck"] < 0.74 and out["capacity_l"] >= 0.25:
			kind = "jar"
		elif depth_ratio < 0.62:
			kind = "bowl"
		elif depth_ratio <= 2.2 and out["capacity_l"] <= 0.9:
			kind = "cup"
		else:
			kind = "vessel"
	out["kind"] = kind
	if bool(d.get("pierced", false)):
		out["capacity_l"] = 0.0
	# craftsmanship quality
	var wall_ok := clampf(1.0 - absf(tmean - 0.0065) / 0.006, 0.0, 1.0)
	var even := clampf(1.0 - float(out["uneven"]) * 1.6, 0.0, 1.0)
	var smooth := clampf(1.0 - rough_mean * 0.8 - wob_mean * 2.0, 0.0, 1.0)
	out["q"] = clampf(wall_ok * 0.3 + even * 0.2 + smooth * 0.2 + float(out["rim_integrity"]) * 0.15 + float(out["stability"]) * 0.15, 0.0, 1.0)
	# spill: wide openings over small capacity slop water when carried
	var open_area := PI * ri[N - 1] * ri[N - 1]
	out["spill"] = clampf(open_area * 1000.0 / maxf(0.05, out["capacity_l"]) * 0.9, 0.05, 1.0)
	# risk of cracking during drying / firing from form alone
	var risk := 0.02
	if tmin < 0.0035:
		risk += (0.0035 - tmin) / 0.0035 * 0.45
	if tmean > 0.014:
		risk += (tmean - 0.014) / 0.01 * 0.25
	risk += maxf(0.0, float(out["uneven"]) - 0.35) * 0.4
	if floor_t < 0.004 and out["hollow"]:
		risk += 0.2
	out["form_risk"] = clampf(risk, 0.0, 0.95)
	return out


static func capacity(d: Dictionary) -> float:
	if String(d.get("state", "wet")) == "cracked" or bool(d.get("pierced", false)):
		return 0.0
	return float(d.get("cap", stats(d)["capacity_l"]))


static func finalize(d: Dictionary) -> void:
	## Called when the potter finishes: cache the evaluation in the data.
	var s := stats(d)
	d["kind"] = s["kind"]
	d["cap"] = s["capacity_l"]
	d["q"] = s["q"]
	d["spill"] = s["spill"]
	d["risk"] = s["form_risk"]


static func feedback(d: Dictionary) -> PackedStringArray:
	var s := stats(d)
	var out: PackedStringArray = []
	if not s["hollow"]:
		out.append("Still a solid lump - press into the top to open it.")
		return out
	if bool(d.get("pierced", false)):
		out.append("The floor has been pierced: it will leak.")
	if float(s["wall_min"]) < 0.0035:
		out.append("Walls are very thin in places - they may crack while drying or firing.")
	elif float(s["wall_mean"]) > 0.013:
		out.append("Walls are thick and heavy; thick walls trap water and can burst in the fire.")
	if float(s["uneven"]) > 0.45:
		out.append("Wall thickness is uneven.")
	if float(s["rim_integrity"]) < 0.45:
		out.append("The rim is fragile - press and smooth it.")
	if float(s["stability"]) < 0.5:
		out.append("The base is narrow; it may tip over.")
	if float(s["rough"]) > 0.6:
		out.append("The surface is lumpy - smooth it with wet hands (right mouse).")
	return out


# ---------------------------------------------------------------------------
# State & presentation
# ---------------------------------------------------------------------------

static func moisture_state(m: float) -> String:
	if m > 0.15:
		return "wet"
	if m > 0.07:
		return "leather"
	return "dry"


static func display_name(d: Dictionary) -> String:
	var kind := String(d.get("kind", "lump"))
	var noun: String = {"bowl": "bowl", "cup": "cup", "jar": "jar", "vessel": "vessel", "lump": "clay shape"}.get(kind, "vessel")
	var st := String(d.get("state", "wet"))
	match st:
		"fired":
			return "Fired %s" % noun
		"cracked":
			return "Cracked %s" % noun
		"dry":
			return ("Dry clay %s" % noun) if kind != "lump" else "Dry clay shape"
		"leather":
			return "Leather-hard %s" % noun
		_:
			return ("Wet clay %s" % noun) if kind != "lump" else "Wet clay shape"


static func describe(d: Dictionary) -> String:
	var lines: PackedStringArray = []
	var st := String(d.get("state", "wet"))
	var cap := capacity(d)
	if String(d.get("kind", "lump")) != "lump":
		lines.append("Holds %.2f L" % cap if cap > 0.0 else "Cannot hold water")
	if float(d.get("water", 0.0)) > 0.0:
		lines.append("Contains %.2f L of water" % float(d["water"]))
	if d.has("contents") and not d["contents"].is_empty():
		var parts: PackedStringArray = []
		for k in d["contents"]:
			parts.append("%s ×%d" % [ItemDB.display_name(k), int(d["contents"][k])])
		lines.append("Contents: " + ", ".join(parts))
	match st:
		"wet", "leather":
			lines.append("Still damp (%d%% water). Let it dry completely before firing." % int(float(d.get("moist", 0.0)) * 100.0))
		"dry":
			lines.append("Bone dry. Ready for the fire.")
		"fired":
			lines.append("Craftsmanship %d%%" % int(float(d.get("q", 0.5)) * 100.0))
			var fq := float(d.get("fq", 1.0))
			if fq < 0.75:
				lines.append("Underfired: it never got hot enough to harden right through, and water slowly seeps out of it. A hotter, longer firing makes a sound pot.")
			elif fq >= 0.95:
				lines.append("Well fired: it rings when you tap it.")
		"cracked":
			lines.append("Cracked in drying or firing. Break it into potsherds.")
	return "\n".join(lines)


static func base_color(d: Dictionary) -> Color:
	var st := String(d.get("state", "wet"))
	var m := float(d.get("moist", 0.2))
	if st == "fired" or st == "cracked":
		return COL_FIRED.lerp(COL_FIRED_LIGHT, clampf(float(d.get("q", 0.5)) * 0.4, 0.0, 0.4))
	var dry_t := clampf(1.0 - (m - 0.02) / 0.2, 0.0, 1.0)
	if dry_t < 0.5:
		return COL_WET.lerp(COL_LEATHER, dry_t * 2.0)
	return COL_LEATHER.lerp(COL_DRY, (dry_t - 0.5) * 2.0)


static func roughness_for(d: Dictionary) -> float:
	var st := String(d.get("state", "wet"))
	if st == "fired" or st == "cracked":
		return 0.72
	var m := float(d.get("moist", 0.2))
	return lerpf(0.95, 0.32, clampf((m - 0.04) / 0.18, 0.0, 1.0))


static func build_mesh(d: Dictionary, seg: int = SEG) -> ArrayMesh:
	## Lathe the profile into a mesh: outer wall, rim, inner wall, floor, base.
	var ro: PackedFloat32Array = d["ro"]
	var ri: PackedFloat32Array = d["ri"]
	var wob: PackedFloat32Array = d["wob"]
	var rough: PackedFloat32Array = d["rough"]
	var h := float(d["h"])
	var step := h / (N - 1)
	var seed_value := int(d.get("seed", 1))
	var noise := FastNoiseLite.new()
	noise.seed = seed_value
	noise.frequency = 3.0
	var base := base_color(d)
	var st := String(d.get("state", "wet"))
	var fired := st == "fired" or st == "cracked"
	var smoke := float(d.get("smoke", 0.0))
	var shrink := 1.0 - clampf(0.24 - float(d.get("moist", 0.24)), 0.0, 0.24) * 0.22
	if fired:
		shrink = 0.947
	var k := floor_index(d)
	var hollow := k < N - 2
	# profile polyline (r, y, which) going: base centre -> base edge -> up outer wall -> rim -> down inner wall -> floor centre
	var prof: Array = []  # [r, y, ring_index_for_wobble, nx, ny]
	prof.append([0.0, 0.0, 0])
	prof.append([ro[0] * 0.82, 0.0, 0])
	prof.append([ro[0] * 0.97, step * 0.35, 0])
	for i in N:
		var ridge := sin(float(i) * 2.6 + seed_value) * rough[i] * 0.0007
		prof.append([ro[i] + ridge, i * step, i])
	if hollow:
		var rim_mid := (ro[N - 1] + ri[N - 1]) * 0.5
		var rim_t := (ro[N - 1] - ri[N - 1])
		prof.append([rim_mid + rim_t * 0.32, h + rim_t * 0.28 * (0.6 + float(d["rim"]) * 0.4), N - 1])
		prof.append([rim_mid - rim_t * 0.32, h + rim_t * 0.28 * (0.6 + float(d["rim"]) * 0.4), N - 1])
		for i in range(N - 1, k - 1, -1):
			prof.append([maxf(ri[i], 0.002), i * step, i])
		var fy := maxf(k * step - step * 0.3, step * 0.5)
		prof.append([ri[k] * 0.55, fy, k])
		prof.append([0.0, fy - step * 0.15, k])
	else:
		prof.append([ro[N - 1] * 0.7, h + step * 0.5, N - 1])
		prof.append([ro[N - 1] * 0.3, h + step * 0.85, N - 1])
		prof.append([0.0, h + step * 0.9, N - 1])
	var verts := PackedVector3Array()
	var cols := PackedColorArray()
	var idx := PackedInt32Array()
	var rows := prof.size()
	for r in rows:
		var pr: Array = prof[r]
		var ring: int = pr[2]
		for s in seg:
			var a := float(s) / seg * TAU
			var w := wob[ring] * 0.06 * (noise.get_noise_2d(cos(a) * 2.0 + ring * 0.15, sin(a) * 2.0) + 0.35 * sin(a * 2.0 + seed_value))
			var rr: float = pr[0] * (1.0 + w)
			var v := Vector3(cos(a) * rr, pr[1], sin(a) * rr) * shrink
			verts.append(v)
			var c := base * (0.94 + 0.1 * noise.get_noise_3d(v.x * 90.0, v.y * 90.0, v.z * 90.0))
			if fired:
				var fc := noise.get_noise_3d(v.x * 22.0 + 7.0, v.y * 22.0, v.z * 22.0) * 0.5 + 0.5
				var cloud := smoothstep(0.55 - smoke * 0.35, 0.85 - smoke * 0.3, fc)
				c = c.lerp(COL_SMOKE, cloud * clampf(0.35 + smoke * 0.6, 0.0, 0.92))
			if r >= rows - 3 and hollow:
				c *= 0.82  # interior floor in shadow
			cols.append(c)
	for r in rows - 1:
		for s in seg:
			var s2 := (s + 1) % seg
			var a := r * seg + s
			var b := r * seg + s2
			var c := (r + 1) * seg + s
			var e := (r + 1) * seg + s2
			idx.append_array([a, b, c, b, e, c])
	var m := Geo.smooth_mesh(verts, idx, cols)
	return m


static func make_instance(d: Dictionary) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = build_mesh(d)
	var mat := Models.unique_material("Clay")
	mat.set_shader_parameter("roughness", roughness_for(d))
	mat.set_shader_parameter("detail_strength", 0.08)
	mat.set_shader_parameter("use_local", 1.0)
	mat.set_shader_parameter("detail_scale", 14.0)
	mi.material_override = mat
	if String(d.get("state", "")) == "cracked":
		mat.set_shader_parameter("char_amount", 0.0)
	return mi


static func clay_water_l(d: Dictionary) -> float:
	return float(d.get("vol", 0.0)) * float(d.get("moist", 0.0))


static func mass(d: Dictionary) -> float:
	return float(d.get("vol", 0.25)) * DENSITY * (1.0 - float(d.get("moist", 0.0)) * 0.5)
