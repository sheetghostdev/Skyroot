class_name ActionsBuild
extends RefCounted
## Host handlers for construction: placing a frame, installing parts one at a
## time, taking pieces apart again (every part comes back), and bed rolls.

const REACH_EXTRA := 2.5


static func register(a: Actions) -> void:
	for nm in ["build_place", "build_install", "build_dismantle", "bed_set"]:
		a.register(nm, Callable(ActionsBuild, "_" + nm).bind(a))


static func check_place(bp_id: String, xf: Transform3D, sy: float, ignore: int = -1) -> String:
	## Why a piece can't go here, or "" if it can.  (Used by the client ghost too.)
	var bp := ItemDB.blueprint(bp_id)
	if bp.is_empty():
		return "Unknown blueprint."
	var box := StructureSim.world_box(bp_id, xf, sy)
	var mine := StructureSim.obb(bp_id, xf, sy, 0.06)
	for e in World.entities_of("structure"):
		if int(e["id"]) == ignore:
			continue
		var d: Dictionary = e["d"]
		var obp := String(d["bp"])
		var osy := float(d.get("sy", 1.0))
		if e["xf"].origin.distance_to(xf.origin) > 6.0:
			continue
		if StructureSim.obb_intersect(mine, StructureSim.obb(obp, e["xf"], osy, 0.06)) \
				and not _compatible(bp_id, xf, sy, obp, e["xf"], osy):
			return "Something is already built there."
	for e in World.entities_near(xf.origin, 2.5):
		var t := String(e["t"])
		if t in ["tree", "outcrop", "boulder", "flat_stone"]:
			var r: float = {"tree": 0.7, "outcrop": 1.3, "boulder": 0.6, "flat_stone": 0.55}.get(t, 0.5)
			var p: Vector3 = e["xf"].origin
			if Vector2(p.x - xf.origin.x, p.z - xf.origin.z).length() < r and box.position.y < p.y + 1.0:
				return "There's no room for it here."
	# the ground mustn't swallow it
	var kind := String(bp.get("kind", ""))
	var c := xf * StructureSim.local_box(bp_id, sy).get_center()
	if World.terrain.is_inside(c.x, c.z) and kind in ["floor", "furniture"]:
		var gh := World.terrain.height(c.x, c.z)
		if box.end.y < gh - 0.05:
			return "That would be buried in the ground."
	var span := StructureSim.would_hold(bp_id, xf, sy)
	if span > StructureSim.CREAK_SPAN:
		return "Nothing would hold it up there. Build out from the island, or brace it."
	return ""


static func _compatible(bp_a: String, xf_a: Transform3D, sy_a: float, bp_b: String, xf_b: Transform3D, sy_b: float) -> bool:
	## Some pieces are meant to overlap a little: railings and walls stand on
	## decks, roofs rest on walls, furniture and ladders sit on floors, and two
	## walls may meet at a corner - but not stand inside one another.
	var ka := String(ItemDB.blueprint(bp_a).get("kind", ""))
	var kb := String(ItemDB.blueprint(bp_b).get("kind", ""))
	if ka == "floor" and kb == "floor":
		return false
	if ka == kb and ka in ["wall", "post", "edge", "roof"]:
		return not StructureSim.obb_intersect(StructureSim.obb(bp_a, xf_a, sy_a, 0.16), StructureSim.obb(bp_b, xf_b, sy_b, 0.16))
	return true


static func _build_place(pid: int, args: Dictionary, a: Actions) -> void:
	var bp_id := String(args.get("bp", ""))
	var xf: Transform3D = args.get("xf", Transform3D())
	var sy := clampf(float(args.get("sy", 1.0)), 0.3, 1.6)
	if ItemDB.blueprint(bp_id).is_empty():
		return
	if not a.in_reach(pid, args, xf.origin, REACH_EXTRA):
		World.notify(pid, "Too far away to build there.")
		return
	xf = Transform3D(xf.basis.orthonormalized(), xf.origin)
	var why := check_place(bp_id, xf, sy)
	if why != "":
		World.notify(pid, why, "warn")
		return
	World.spawn("structure", xf, {"bp": bp_id, "installed": 0, "used": [], "sy": snappedf(sy, 0.001), "by": Net.player_name(pid), "stress": 0.0})
	World.fx("build", xf.origin, {"amount": 4})
	World.hint_to(pid, "frame_placed")
	if StructureSim.would_hold(bp_id, xf, sy) == StructureSim.CREAK_SPAN:
		World.notify(pid, "This will creak once it's built - a post or brace beneath would steady it.", "warn")


static func _build_install(pid: int, args: Dictionary, a: Actions) -> void:
	var eid := int(args.get("eid", -1))
	var e := World.get_entity(eid)
	if e.is_empty() or e["t"] != "structure" or not a.in_reach(pid, args, e["xf"].origin, REACH_EXTRA):
		return
	var d: Dictionary = e["d"]
	var bp := ItemDB.blueprint(String(d["bp"]))
	var parts: Array = bp.get("parts", [])
	var n := int(d.get("installed", 0))
	if n >= parts.size():
		return
	var need := String(parts[n]).split("|")
	var s := a.held(pid, args)
	var id := String(s.get("i", ""))
	if not id in need:
		return
	if s["d"].has("fm"):
		World.notify(pid, "That's been in a fire - it's no good for building.")
		return
	var taken := a.take_held(pid, args, 1)
	if taken.is_empty():
		return
	if id == "clay":
		# the ledger keeps clay parts at the usual dampness; the rest dries off or is drawn from the air
		var m := float(taken["d"].get("moist", ItemDB.default_moist("clay")))
		World.pools["atmo_water_l"] = float(World.pools.get("atmo_water_l", 0.0)) + (m - ItemDB.default_moist("clay")) * Pottery.LUMP_L
	var used: Array = d.get("used", []).duplicate()
	used.append(id)
	var work: Array = bp.get("work", [])
	var w := String(work[n]) if n < work.size() else "hammer"
	World.update(eid, {"installed": n + 1, "used": used})
	var fx: String = {"hammer": "build", "bind": "bind", "weave": "leaves", "daub": "soil_place", "thatch": "grass"}.get(w, "build")
	World.fx(fx, e["xf"].origin + Vector3(0, 0.4, 0), {"amount": 5})
	a.exert(pid, 0.012)
	if n + 1 >= parts.size():
		World.fx("complete", e["xf"].origin + Vector3(0, 0.6, 0))
		StructureSim.mark_dirty()
		World.discover("first_" + String(d["bp"]), pid)
		if bp.get("bed", false):
			World.hint_to(pid, "bed_built")


static func _build_dismantle(pid: int, args: Dictionary, a: Actions) -> void:
	## Take the last part off; every part comes back as the item it was made from.
	var eid := int(args.get("eid", -1))
	var e := World.get_entity(eid)
	if e.is_empty() or e["t"] != "structure" or not a.in_reach(pid, args, e["xf"].origin, REACH_EXTRA):
		return
	var d: Dictionary = e["d"]
	var parts: Array = ItemDB.blueprint(String(d["bp"])).get("parts", [])
	var n := int(d.get("installed", 0))
	var was_complete := n >= parts.size()
	if n > 0 and String(ItemDB.blueprint(String(d["bp"])).get("kind", "")) == "floor":
		# nobody gets the floor pulled out from under them
		var box := StructureSim.world_box(String(d["bp"]), e["xf"], float(d.get("sy", 1.0)))
		for opid in Net.players:
			var pp: Vector3 = a.player_pos(int(opid))
			if pp.x > box.position.x - 0.15 and pp.x < box.end.x + 0.15 and pp.z > box.position.z - 0.15 and pp.z < box.end.z + 0.15 \
					and pp.y > box.position.y - 0.4 and pp.y < box.end.y + 1.0:
				World.notify(pid, "Step off it first." if int(opid) == pid else "%s is standing on it." % Net.player_name(int(opid)), "warn")
				return
	if n <= 0:
		World.despawn(eid)
		World.fx("pickup", e["xf"].origin)
		return
	var used: Array = d.get("used", []).duplicate()
	var id := String(used.pop_back()) if used.size() >= n else String(parts[n - 1]).get_slice("|", 0)
	a.give(pid, id, 1, {}, e["xf"].origin)
	World.update(eid, {"installed": n - 1, "used": used})
	World.fx("build", e["xf"].origin + Vector3(0, 0.3, 0), {"amount": 3})
	a.exert(pid, 0.01)
	if was_complete:
		StructureSim.mark_dirty()
		# anyone who slept here has lost their bed
		for spid in World.stats:
			if int(World.stats[spid].get("bed", -1)) == eid:
				World.stats[spid]["bed"] = -1
				World.mark_stats(spid)


static func _bed_set(pid: int, args: Dictionary, a: Actions) -> void:
	var eid := int(args.get("eid", -1))
	var e := World.get_entity(eid)
	if e.is_empty() or e["t"] != "structure" or not a.in_reach(pid, args, e["xf"].origin, REACH_EXTRA):
		return
	if not bool(ItemDB.blueprint(String(e["d"]["bp"])).get("bed", false)) or not StructureSim.is_complete(e["d"]):
		return
	var st := a.stats(pid)
	if int(st.get("bed", -1)) != eid:
		st["bed"] = eid
		World.mark_stats(pid)
		World.notify(pid, "You'll wake here from now on.")
