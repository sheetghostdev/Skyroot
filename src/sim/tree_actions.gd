class_name TreeActions
extends RefCounted
## Harvesting the tree and processing wood.  Small branches are cut with a
## blade, limbs and the trunk need an axe.  Cut wood is processed physically:
## branches are cut into sticks and twigs, limbs chopped into poles and
## firewood, logs split along the line you strike.

const WOOD_DENSITY := 435.0     # kg per m^3 (log: 70 kg for 0.161 m^3)
const FIREWOOD_M3 := 0.003
const BOARD_M3 := 0.016


static func _tree_nutr_out(id: String, n: int) -> void:
	World.pools["tree_nutr"] = float(World.pools.get("tree_nutr", 0.0)) - ItemDB.nutrients(id) * n


static func cut_small(a: Actions, pid: int, args: Dictionary) -> void:
	var eid := int(args.get("eid", -1))
	var ent := World.get_entity(eid)
	var part := String(args.get("part", ""))
	if ent.is_empty() or ent["t"] != "tree" or not part.begins_with("sb:"):
		return
	var tool := ItemDB.tool_kind(a.held_id(pid, args))
	if tool != "cut" and tool != "chop":
		return
	var i := int(part.get_slice(":", 1))
	var d: Dictionary = ent["d"]
	if i < 0 or i >= TreeSim.SMALL or float(d["sb"][i]) < 0.98 or bool(d.get("felled", false)):
		return
	var v := a.entity_view(eid)
	var at: Vector3 = v.interaction_point(part) if v else ent["xf"].origin + Vector3(0, 2, 0)
	if not a.in_reach(pid, args, at, 0.8):
		return
	var shp: Array = d["shp"].duplicate()
	shp[i] = float(shp[i]) - (0.36 if tool == "cut" else 0.5) * Tools.power(a.held(pid, args))
	World.fx("leaves", at, {"sound": "cut_grass" if tool == "cut" else "chop", "amount": 6})
	if v:
		v.call("shake", 0.3)
	Tools.wear(pid, args, 0.006)
	a.exert(pid, 0.02)
	if float(shp[i]) <= 0.0:
		shp[i] = 1.0
		var sb: Array = d["sb"].duplicate()
		sb[i] = 0.0
		World.update(eid, {"sb": sb, "shp": shp})
		a.spawn_item("branch", 1, {"moist": 0.45}, at)
		_tree_nutr_out("branch", 1)
		World.fx("leaves", at, {"sound": "branch_snap"})
		World.hint_to(pid, "branch_cut")
	else:
		World.update(eid, {"shp": shp})


static func chop_limb(a: Actions, pid: int, args: Dictionary) -> void:
	var eid := int(args.get("eid", -1))
	var ent := World.get_entity(eid)
	var part := String(args.get("part", ""))
	if ent.is_empty() or ent["t"] != "tree" or not part.begins_with("lb:"):
		return
	if ItemDB.tool_kind(a.held_id(pid, args)) != "chop":
		return
	var j := int(part.get_slice(":", 1))
	var d: Dictionary = ent["d"]
	if j < 0 or j >= TreeSim.LARGE or float(d["lb"][j]) < 0.98 or bool(d.get("felled", false)):
		return
	var v := a.entity_view(eid)
	var at: Vector3 = v.interaction_point(part) if v else ent["xf"].origin + Vector3(0, 2.8, 0)
	if not a.in_reach(pid, args, at, 1.0):
		return
	var lhp: Array = d["lhp"].duplicate()
	lhp[j] = float(lhp[j]) - 0.15 * Tools.power(a.held(pid, args))
	World.fx("wood_chips", at)
	if v:
		v.call("shake", 0.5)
	Tools.wear(pid, args, 0.008)
	a.exert(pid, 0.035)
	if float(lhp[j]) <= 0.0:
		lhp[j] = 1.0
		var lb: Array = d["lb"].duplicate()
		lb[j] = 0.0
		World.update(eid, {"lb": lb, "lhp": lhp})
		a.spawn_item("limb", 1, {"moist": 0.45}, at)
		_tree_nutr_out("limb", 1)
		World.fx("leaves", at, {"sound": "branch_snap", "amount": 24})
	else:
		World.update(eid, {"lhp": lhp})


static func fell(a: Actions, pid: int, args: Dictionary) -> void:
	var eid := int(args.get("eid", -1))
	var ent := World.get_entity(eid)
	if ent.is_empty() or ent["t"] != "tree" or ItemDB.tool_kind(a.held_id(pid, args)) != "chop":
		return
	var d: Dictionary = ent["d"].duplicate(true)
	if bool(d.get("felled", false)):
		return
	var base: Vector3 = ent["xf"].origin + Vector3(0, 0.9, 0)
	if not a.in_reach(pid, args, base, 0.8):
		return
	d["trunk"] = float(d.get("trunk", 1.0)) - 0.034 * Tools.power(a.held(pid, args))
	World.fx("wood_chips", base)
	var v := a.entity_view(eid)
	if v:
		v.call("shake", 0.8)
	Tools.wear(pid, args, 0.01)
	a.exert(pid, 0.04)
	if float(d["trunk"]) > 0.0:
		World.update(eid, {"trunk": d["trunk"]})
		if float(d["trunk"]) < 0.25:
			World.fx("creak", base, {"sound": "tree_creak"})
		return
	var drops := TreeSim.on_felled(d)
	World.update(eid, d)
	var p := a.player_pos(pid)
	var away: Vector3 = (ent["xf"].origin - p)
	away.y = 0.0
	away = away.normalized() if away.length() > 0.01 else Vector3.FORWARD
	var k := 0
	for drop in drops:
		var id := String(drop[0])
		for n in int(drop[1]):
			var dist := 1.4 + k * 0.7
			var side: Vector3 = away.cross(Vector3.UP) * sin(k * 2.3) * 0.8
			var pos: Vector3 = ent["xf"].origin + away * dist + side + Vector3(0, 1.5, 0)
			var yaw := atan2(away.x, away.z) + PI * 0.5
			a.spawn_item(id, 1, {"moist": 0.45} if ItemDB.material(id) == "wood" else {}, pos, yaw)
			_tree_nutr_out(id, 1)
			k += 1
	World.discover("tree_felled", pid)
	World.notify(pid, "The tree comes down. Its roots are still alive - in a few days a new tree will grow.", "info")


static func process_item(a: Actions, pid: int, args: Dictionary) -> void:
	var eid := int(args.get("eid", -1))
	var ent := World.get_entity(eid)
	if ent.is_empty() or ent["t"] != "item":
		return
	var id := String(ent["d"]["i"])
	var proc: Dictionary = ItemDB.def(id).get("process", {})
	if proc.is_empty() or not a.in_reach(pid, args, ent["xf"].origin):
		return
	var need := String(proc["tool"])
	var tool := ItemDB.tool_kind(a.held_id(pid, args))
	if need != "hand" and not (tool == need or (need == "cut" and tool == "chop")):
		return
	var prog := float(ent["d"].get("prog", 0.0)) + 0.34 * (Tools.power(a.held(pid, args)) if tool != "" else 0.7)
	World.fx("wood_chips" if need == "chop" else "leaves", ent["xf"].origin + Vector3(0, 0.1, 0), {"sound": "chop" if need == "chop" else "cut_grass", "amount": 6})
	if tool != "":
		Tools.wear(pid, args, 0.004)
	a.exert(pid, 0.02)
	if prog < 1.0:
		World.update(eid, {"prog": prog})
		return
	var n := int(ent["d"].get("n", 1))
	var pos: Vector3 = ent["xf"].origin
	World.despawn(eid)
	_emit_yields(a, id, n, proc["yields"], pos, float(ent["d"].get("x", {}).get("moist", ItemDB.default_moist(id))))
	World.fx("leaves", pos, {"sound": "branch_snap"})


static func _emit_yields(a: Actions, id: String, n: int, yields: Dictionary, pos: Vector3, moist: float) -> void:
	var m_in := ItemDB.unit_mass(id) * n
	var nu_in := ItemDB.nutrients(id) * n
	var m_out := 0.0
	var nu_out := 0.0
	var k := 0
	for yid in yields:
		var c := int(yields[yid]) * n
		m_out += ItemDB.unit_mass(yid) * c
		nu_out += ItemDB.nutrients(yid) * c
		var dd := {"moist": moist} if ItemDB.material(yid) == "wood" else ({"moist": ItemDB.default_moist(yid)} if ItemDB.default_moist(yid) > 0.0 else {})
		var off := Vector3(cos(k * 2.1), 0.25, sin(k * 2.1)) * 0.35
		a.spawn_item(yid, c, dd, pos + off)
		k += 1
	# bark, crumbs and chaff stay behind and rot into the soil
	World.pools["soil_organic_kg"] = float(World.pools.get("soil_organic_kg", 0.0)) + maxf(0.0, m_in - m_out)
	var cells := World.terrain.cells_in_radius(Vector2(pos.x, pos.z), 0.4)
	for c in cells:
		World.terrain.nutr[c] += maxf(0.0, nu_in - nu_out) / maxf(1.0, cells.size())


static func process_held(a: Actions, pid: int, args: Dictionary) -> void:
	var s := a.held(pid, args)
	var id := String(s.get("i", ""))
	var proc: Dictionary = ItemDB.def(id).get("process", {})
	if proc.is_empty() or String(proc.get("tool", "")) != "hand":
		return
	a.take_held(pid, args, 1)
	var p := a.player_pos(pid)
	for yid in proc["yields"]:
		a.give(pid, yid, int(proc["yields"][yid]))
	var m_out := 0.0
	var nu_out := 0.0
	for yid in proc["yields"]:
		m_out += ItemDB.unit_mass(yid) * int(proc["yields"][yid])
		nu_out += ItemDB.nutrients(yid) * int(proc["yields"][yid])
	World.pools["soil_organic_kg"] = float(World.pools.get("soil_organic_kg", 0.0)) + maxf(0.0, ItemDB.unit_mass(id) - m_out)
	var k := a.cell_index_at(p)
	World.terrain.nutr[k] += maxf(0.0, ItemDB.nutrients(id) - nu_out)
	World.fx("grass", p + Vector3(0, 1.0, 0), {"sound": "rustle"})


# ---------------------------------------------------------------------------
# Splitting logs
# ---------------------------------------------------------------------------

static func piece_poly(x: Dictionary, id: String) -> PackedVector2Array:
	if x.has("poly"):
		return PackedVector2Array(x["poly"])
	var poly := PackedVector2Array()
	var r := 0.16
	for i in 14:
		var ang := float(i) / 14.0 * TAU
		poly.append(Vector2(cos(ang), sin(ang)) * r)
	return poly


static func split(a: Actions, pid: int, args: Dictionary) -> void:
	var eid := int(args.get("eid", -1))
	var ent := World.get_entity(eid)
	if ent.is_empty() or ent["t"] != "item":
		return
	var id := String(ent["d"]["i"])
	if not ItemDB.has_tag(id, "splittable") or ItemDB.tool_kind(a.held_id(pid, args)) != "chop":
		return
	var pos: Vector3 = args.get("pos", ent["xf"].origin)
	if not a.in_reach(pid, args, pos, 0.4):
		return
	var x: Dictionary = ent["d"].get("x", {})
	var poly := piece_poly(x, id)
	var length := float(x.get("len", 2.0))
	var r0 := float(x.get("r0", 0.16))
	var c0: Vector2 = x.get("c0", Vector2.ZERO)
	var moist := float(x.get("moist", ItemDB.default_moist(id)))
	var xf: Transform3D = ent["xf"]
	var local := xf.affine_inverse() * pos
	Tools.wear(pid, args, 0.008)
	a.exert(pid, 0.045)
	# a poor axe sometimes just bites without splitting
	var power := Tools.power(a.held(pid, args))
	if randf() > clampf(0.45 + power * 0.5, 0.0, 0.98):
		World.fx("wood_chips", pos, {"sound": "chop"})
		return
	var cut := clampf(local.z, -0.5, 0.5)
	var n := Vector2(0.0, 1.0)
	var p1 := Geo.clip_polygon(poly, n, cut)
	var p2 := Geo.clip_polygon(poly, -n, -cut)
	var a1 := Geo.polygon_area(p1) if p1.size() >= 3 else 0.0
	var a2 := Geo.polygon_area(p2) if p2.size() >= 3 else 0.0
	if a1 < 0.0006 or a2 < 0.0006:
		World.fx("wood_chips", pos, {"sound": "chop"})
		World.notify(pid, "Aim nearer the middle - that would only shave off a sliver.")
		return
	World.despawn(eid)
	var mass_in := ItemDB.unit_mass(id) if not x.has("mass") else float(x["mass"])
	var area_in := Geo.polygon_area(poly)
	var mass_out := 0.0
	for pair in [[p1, a1, -1.0], [p2, a2, 1.0]]:
		var pp: PackedVector2Array = pair[0]
		var area: float = pair[1]
		var mass := mass_in * area / area_in
		var cen := Geo.polygon_centroid(pp)
		var centred := PackedVector2Array()
		for q in pp:
			centred.append(q - cen)
		var spot := xf * Vector3(0.0, cen.x, cen.y + float(pair[2]) * 0.08)
		mass_out += _classify_piece(a, centred, area, length, r0, c0 - cen, mass, moist, spot, xf.basis)
	World.pools["soil_organic_kg"] = float(World.pools.get("soil_organic_kg", 0.0)) + maxf(0.0, mass_in - mass_out)
	World.fx("wood_split", pos)
	World.discover("first_split", pid)


static func _classify_piece(a: Actions, poly: PackedVector2Array, area: float, length: float, r0: float, c0: Vector2, mass: float, moist: float, spot: Vector3, basis: Basis) -> float:
	## Turn a split piece into boards, firewood, or keep it as split wood. Returns mass emitted.
	var vol := area * length
	var thin := Geo.polygon_min_width(poly)
	var wide := Geo.polygon_max_width(poly)
	var yaw := basis.get_euler().y
	if thin >= 0.022 and thin <= 0.075 and wide >= 0.15 and vol >= BOARD_M3 * 0.85:
		var boards := maxi(1, int(floor(vol / BOARD_M3 + 0.15)))
		var bm := ItemDB.unit_mass("board") * boards
		if bm <= mass + 0.01:
			a.spawn_item("board", boards, {"moist": moist}, spot + Vector3(0, 0.3, 0), yaw)
			var rest := mass - bm
			var fw := int(floor(rest / ItemDB.unit_mass("firewood")))
			if fw > 0:
				a.spawn_item("firewood", fw, {"moist": moist}, spot + Vector3(0.3, 0.3, 0.2))
			return bm + fw * ItemDB.unit_mass("firewood")
	if area < 0.0105 or mass < 6.0:
		var fwn := int(floor(mass / ItemDB.unit_mass("firewood")))
		if fwn > 0:
			a.spawn_item("firewood", fwn, {"moist": moist}, spot + Vector3(0, 0.3, 0))
		return fwn * ItemDB.unit_mass("firewood")
	var label := "Half log" if area > 0.035 else ("Split wood" if thin > 0.07 else "Slab")
	a.spawn_item("wood_piece", 1, {"poly": poly, "len": length, "r0": r0, "c0": c0, "mass": mass, "moist": moist, "label": label}, spot + Vector3(0, 0.25, 0), yaw)
	return mass
