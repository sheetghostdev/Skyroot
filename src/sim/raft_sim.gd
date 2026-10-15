class_name RaftSim
extends RefCounted
## The host's rafts: floating a first section, building on, taking apart, and
## moving them.  A raft drifts with what pushes it - paddle strokes (which also
## turn it when made off to one side), the wind in a raised sail, the helmsman's
## steering oar - and water drag slows it; a dropped anchor holds it.  It runs
## aground where the bottom comes up to the surface.

const DRAG := 0.35               # per second, linear
const TURN_DRAG := 1.2
const STROKE := 0.55             # speed one paddle stroke gives a one-section raft
const SAIL := 0.6                # how quickly a raised sail brings the raft up to speed
const SAIL_WIND := 1.6           # the wind out on the water, against the weather's wind
const HELM_TURN := 0.55          # rad/s at full helm (more when moving)
const SEND_EVERY := 4            # physics frames between transform updates to others

var a: Actions
var sea := 30
var _frame := 0
var _helm: Dictionary = {}       # raft id -> {"pid", "turn", "t"}


func _init(actions: Actions) -> void:
	a = actions
	sea = int(World.geo.get("sea", 30))


func rafts() -> Array:
	return World.entities_of("raft")


# ---------------------------------------------------------------------------
# Building
# ---------------------------------------------------------------------------

func new_raft(pid: int, args: Dictionary) -> void:
	## A first raft section laid on the sea.
	var p: Vector3 = args.get("point", Vector3.ZERO)
	var slot := int(args.get("slot", -1))
	var s := a.held(pid, slot)
	if s.is_empty() or String(s["i"]) != "raft_floor":
		return
	var cell := VoxelData.cell_of(Vector3(p.x, sea + 0.5, p.z))
	var at := World.block(cell)
	if (at != Blocks.sea and Blocks.waterlog[at] == 0) or World.block(cell + Vector3i.UP) != 0:
		World.notify(pid, "Float it on open sea water.", "warn")
		return
	if a.eye_pos(pid).distance_to(p) > Actions.REACH + 0.5:
		return
	if not a._rate(pid, "place", 150):
		return
	var yaw := float(args.get("yaw", 0.0))
	var basis := Basis(Vector3.UP, yaw)
	var origin := Vector3(p.x, Raft.origin_y(sea), p.z) - basis * Vector3(0.5, 0, 0.5)
	if _hits_land(Transform3D(basis, origin), {Vector3i.ZERO: Vector2i(Blocks.id_of("raft_floor"), 0)}):
		World.notify(pid, "Too shallow there.", "warn")
		return
	World.inventory_of(pid).take_from(slot, 1)
	World.mark_inventory(pid)
	var cells := {Vector3i.ZERO: Vector2i(Blocks.id_of("raft_floor"), 0)}
	World.spawn("raft", Transform3D(basis, origin), {"cells": cells, "v": Vector3.ZERO, "w": 0.0, "anchor": false})
	World.fx("splash", p, {})
	a.flag_player(pid, "raft_built")
	Survival.hint_once(pid, "raft")


func place(pid: int, args: Dictionary) -> void:
	## Add to a raft: a floor section beside the floor, or anything you could
	## build on the ground, standing on it.
	var e := _raft(args)
	if e.is_empty():
		return
	var c: Vector3i = args.get("cell", Vector3i.ZERO)
	var slot := int(args.get("slot", -1))
	var face: Vector3i = args.get("face", Vector3i.UP)
	var s := a.held(pid, slot)
	if s.is_empty() or not _in_reach(pid, e, c):
		return
	if not a._rate(pid, "place", 120):
		return
	var id := ItemDB.block_of(String(s["i"]))
	if id < 0:
		return
	var cells: Dictionary = (e["d"]["cells"] as Dictionary).duplicate()
	if cells.has(c):
		return
	var m := 0
	if id == Blocks.id_of("raft_floor"):
		if not Raft.floor_ok(cells, c):
			World.notify(pid, "A new section goes beside the raft's floor.", "warn")
			return
		if _hits_land(e["xf"], {c: Vector2i(id, 0)}):
			World.notify(pid, "Too shallow there.", "warn")
			return
	else:
		if c.y < 1 or c.y > Raft.MAX_LAYER or not Raft.supported(cells, c):
			World.notify(pid, "That needs to stand on the raft.", "warn")
			return
		if Blocks.has_flag(id, "raft_only") and c.y != 1:
			World.notify(pid, "That goes on the deck.", "warn")
			return
		if Blocks.solid[id] == 1 and _player_in(e, c):
			return
		if Blocks.facing[id] == 1:
			# sails and oars face the way you look, turned into the raft's frame
			var yaw := float((Net.poses.get(pid, {}) as Dictionary).get("y", 0.0))
			m = Blocks.facing_meta(yaw - (e["xf"] as Transform3D).basis.get_euler().y)
		elif Blocks.wall[id] == 1 and face.y == 0 and cells.has(c - face):
			m = Blocks.wall_meta(-face)
		elif Blocks.axis[id] == 1:
			m = 1 if face.x != 0 else (2 if face.z != 0 else 0)
	cells[c] = Vector2i(id, m)
	World.inventory_of(pid).take_from(slot, 1)
	World.mark_inventory(pid)
	World.update(e["id"], {"cells": cells})
	World.fx("place", _cell_world(e, c), {"b": id})


func take(pid: int, args: Dictionary) -> void:
	## Break a block off a raft (the floor last, and never so the raft splits).
	var e := _raft(args)
	if e.is_empty():
		return
	var c: Vector3i = args.get("cell", Vector3i.ZERO)
	if not _in_reach(pid, e, c) or not a._rate(pid, "break", 60):
		return
	var cells: Dictionary = (e["d"]["cells"] as Dictionary).duplicate()
	if not cells.has(c):
		return
	var v: Vector2i = cells[c]
	if cells.has(c + Vector3i.UP):
		World.notify(pid, "Take off what stands on it first.", "warn")
		return
	cells.erase(c)
	if not Raft.connected(cells):
		World.notify(pid, "That would split the raft in two.", "warn")
		return
	var item := ItemDB.item_of_block(v.x)
	var at := _cell_world(e, c)
	if item != "":
		a.give(pid, item, 1, {}, at + Vector3(0, 0.6, 0))
	World.fx("break", at, {"b": v.x})
	if Raft.floor_count(cells) == 0:
		_spill(e, {})
		World.despawn(e["id"])
		return
	World.update(e["id"], {"cells": cells})
	_spill(e, cells)


# ---------------------------------------------------------------------------
# Moving
# ---------------------------------------------------------------------------

func paddle(pid: int, args: Dictionary) -> void:
	## A paddle stroke: pushes the raft the way you look, and turns it if you
	## paddle off to one side.
	var e := _raft(args)
	if e.is_empty():
		return
	var slot := int(args.get("slot", -1))
	if a.held_kind(pid, slot) != "paddle":
		return
	if not a._rate(pid, "paddle", 380):
		return
	var xf: Transform3D = e["xf"]
	var pp := a.player_pos(pid)
	var com_w := xf * Raft.com(e["d"]["cells"])
	if Vector2(pp.x - com_w.x, pp.z - com_w.z).length() > Raft.MAX_SPAN + 3.0:
		return
	var dir: Vector3 = args.get("dir", Vector3.FORWARD)
	dir.y = 0.0
	if dir.length() < 0.1:
		return
	dir = dir.normalized()
	var n := float(Raft.floor_count(e["d"]["cells"]))
	var d: Dictionary = e["d"]
	var v: Vector3 = d.get("v", Vector3.ZERO)
	v += dir * STROKE / sqrt(n)
	# off-centre strokes turn the raft (pushing at r from the middle)
	var r := Vector3(pp.x - com_w.x, 0, pp.z - com_w.z)
	var torque := r.cross(dir * STROKE).y
	var inertia := maxf(1.0, n * 0.6)
	d["v"] = v
	d["w"] = float(d.get("w", 0.0)) + torque / inertia * 0.25
	a.wear_tool(pid, slot, 1)
	World.fx_except(pid, "paddle", pp + dir * 0.8, {})


func use(pid: int, args: Dictionary) -> void:
	## Right-click on a raft's sail, anchor or steering oar.
	var e := _raft(args)
	if e.is_empty():
		return
	var c: Vector3i = args.get("cell", Vector3i.ZERO)
	if not _in_reach(pid, e, c):
		return
	var cells: Dictionary = (e["d"]["cells"] as Dictionary).duplicate()
	if not cells.has(c):
		return
	var v: Vector2i = cells[c]
	if Blocks.has_flag(v.x, "sail"):
		cells[c] = Vector2i(v.x, v.y ^ 4)
		World.update(e["id"], {"cells": cells})
		World.fx("sail", _cell_world(e, c) + Vector3(0, 1.5, 0), {"up": (v.y & 4) == 0})
	elif Blocks.has_flag(v.x, "anchor"):
		var down := not bool(e["d"].get("anchor", false))
		World.update(e["id"], {"anchor": down})
		World.fx("splash" if down else "pickup", _cell_world(e, c), {})
		World.notify(pid, "Anchor dropped: the raft holds still." if down else "Anchor up.")
	elif Blocks.has_flag(v.x, "helm"):
		_helm[e["id"]] = {"pid": pid, "turn": 0.0, "t": Time.get_ticks_msec()}


func helm(pid: int, args: Dictionary) -> void:
	## The helmsman's steering (A/D), sent a few times a second.
	var e := _raft(args)
	if e.is_empty():
		return
	var h: Dictionary = _helm.get(e["id"], {})
	if h.is_empty() or int(h["pid"]) != pid:
		_helm[e["id"]] = {"pid": pid, "turn": 0.0, "t": 0}
		h = _helm[e["id"]]
	h["turn"] = clampf(float(args.get("amount", 0.0)), -1.0, 1.0)
	h["t"] = Time.get_ticks_msec()


func step(delta: float) -> void:
	_frame += 1
	var send := _frame % SEND_EVERY == 0
	var wind: Vector2 = World.env.get("wind", Vector2(1.2, 0.4))
	var now := Time.get_ticks_msec()
	for e in rafts():
		var d: Dictionary = e["d"]
		var cells: Dictionary = d["cells"]
		var xf: Transform3D = e["xf"]
		var v: Vector3 = d.get("v", Vector3.ZERO)
		var w := float(d.get("w", 0.0))
		var n := float(maxi(1, Raft.floor_count(cells)))
		var sails := 0
		var fwd := -xf.basis.z
		for c in cells:
			var cv: Vector2i = cells[c]
			if Blocks.has_flag(cv.x, "sail") and (cv.y & 4) != 0:
				sails += 1
			elif Blocks.has_flag(cv.x, "helm"):
				# the raft's head is the way its steering oar faces
				fwd = xf.basis * Vector3(Blocks.facing_dir(cv.y))
		var h: Dictionary = _helm.get(e["id"], {})
		var steered := not h.is_empty() and now - int(h["t"]) < 600
		if not steered and not h.is_empty():
			_helm.erase(e["id"])
		# the wind in raised sails brings the raft up toward its speed; someone at
		# the helm can hold a course across the wind too (but never into it)
		if sails > 0:
			var push := Vector3(wind.x, 0, wind.y) * SAIL_WIND
			if steered:
				push = fwd * maxf(0.0, push.dot(fwd) + absf(push.cross(fwd).y) * 0.6)
			v += (push - v) * minf(1.0, SAIL * float(sails) / sqrt(n) * delta)
		# the steering oar: turns more the faster the raft moves, and the water
		# turns its drift the way it points
		if steered:
			var target := float(h["turn"]) * HELM_TURN * (0.4 + clampf(v.length() / 2.0, 0.0, 1.2))
			w = lerpf(w, target, 1.0 - exp(-2.5 * delta))
			var along := v.dot(fwd)
			v = v.lerp(fwd * along + (v - fwd * along) * 0.2, 1.0 - exp(-0.8 * delta))
		# water drag; a dropped anchor holds it still
		var drag := DRAG + (3.0 if bool(d.get("anchor", false)) else 0.0)
		v *= exp(-drag * delta)
		w *= exp(-(TURN_DRAG + (3.0 if bool(d.get("anchor", false)) else 0.0)) * delta)
		if v.length() < 0.004 and absf(w) < 0.002:
			d["v"] = Vector3.ZERO
			d["w"] = 0.0
			continue
		# move and turn about the middle of the floor
		var pivot := xf * Raft.com(cells)
		var rot := Basis(Vector3.UP, w * delta)
		var nxf := Transform3D(rot * xf.basis, pivot + rot * (xf.origin - pivot) + v * delta)
		nxf.origin.y = Raft.origin_y(sea)
		# keep to the sea: not up the beach, not off the edge of the world
		if _hits_land(nxf, cells) or not _in_world(nxf, cells):
			v = -v * 0.15
			w = 0.0
			nxf = xf
			World.fx("bump", pivot, {})
		d["v"] = v
		d["w"] = w
		World.move_entity(e["id"], nxf, send)
		_carry_items(e["id"], nxf)
		if send:
			World.update(e["id"], {"v": v, "w": w})


# ---------------------------------------------------------------------------
# Things lying on the deck
# ---------------------------------------------------------------------------

func deck_under(p: Vector3) -> Dictionary:
	## Something let go at p over a raft lands on its deck: {"eid", "rp" (on the
	## deck, raft-local), "world"}, or {} if there's no raft deck under p.
	for e in rafts():
		var xf: Transform3D = e["xf"]
		var lp := xf.affine_inverse() * p
		if lp.y < Raft.DECK - 0.4:
			continue
		var cells: Dictionary = e["d"]["cells"]
		var c := Vector3i(floori(lp.x), 0, floori(lp.z))
		if not cells.has(c):
			continue
		var rp := Vector3(lp.x, Raft.DECK, lp.z)
		# on top of a block standing there, if it's solid
		var above = cells.get(c + Vector3i.UP)
		if above != null and Blocks.solid[(above as Vector2i).x] == 1:
			var top := 0.0
			for b in Raft.cell_boxes((above as Vector2i).x, (above as Vector2i).y):
				top = maxf(top, (b as AABB).end.y)
			rp.y = Raft.DECK + top
		return {"eid": e["id"], "rp": rp, "world": xf * rp}
	return {}


func _carry_items(rid: int, nxf: Transform3D) -> void:
	## The raft moved: what lies on its deck moves with it (others place it from
	## the raft as they see it, so this isn't sent).
	for it in World.entities_of("item"):
		if int(it["d"].get("raft", -1)) != rid:
			continue
		var rp: Vector3 = it["d"].get("rp", Vector3.ZERO)
		World.move_entity(it["id"], Transform3D((it["xf"] as Transform3D).basis, nxf * rp), false)


func _spill(e: Dictionary, cells: Dictionary) -> void:
	## Sections taken away: what lay on them falls into the sea.
	for it in World.entities_of("item"):
		var d: Dictionary = it["d"]
		if int(d.get("raft", -1)) != int(e["id"]):
			continue
		var rp: Vector3 = d.get("rp", Vector3.ZERO)
		if cells.has(Vector3i(floori(rp.x), 0, floori(rp.z))):
			continue
		var p: Vector3 = (it["xf"] as Transform3D).origin
		World.despawn(it["id"])
		a.drop_item(String(d["i"]), int(d["n"]), d.get("d", {}), p + Vector3(0, 0.3, 0))


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func _raft(args: Dictionary) -> Dictionary:
	var e: Dictionary = World.entities.get(int(args.get("eid", -1)), {})
	if e.is_empty() or String(e["t"]) != "raft":
		return {}
	return e


func _cell_world(e: Dictionary, c: Vector3i) -> Vector3:
	return (e["xf"] as Transform3D) * (Vector3(c) + Vector3(0.5, 0.5, 0.5))


func _in_reach(pid: int, e: Dictionary, c: Vector3i) -> bool:
	return a.eye_pos(pid).distance_to(_cell_world(e, c)) <= Actions.REACH + 0.9


func _hits_land(xf: Transform3D, cells: Dictionary) -> bool:
	## Would the floor's logs (just under the water line) touch the bottom or
	## the shore anywhere?
	for c in cells:
		if (c as Vector3i).y != 0:
			continue
		for corner in [Vector3(0.15, 0.7, 0.15), Vector3(0.85, 0.7, 0.15), Vector3(0.15, 0.7, 0.85), Vector3(0.85, 0.7, 0.85)]:
			var p: Vector3 = xf * (Vector3(c) + corner)
			var wc := VoxelData.cell_of(p)
			for y in [wc.y, wc.y + 1]:
				var id := World.block(Vector3i(wc.x, y, wc.z))
				if Blocks.is_solid(id):
					return true
	return false


func _player_in(e: Dictionary, c: Vector3i) -> bool:
	## Is someone standing in this cell of the raft?
	var box := AABB(Vector3(c), Vector3.ONE).grow(-0.02)
	var inv := (e["xf"] as Transform3D).affine_inverse()
	for pid in Net.poses:
		var pp: Vector3 = (Net.poses[pid] as Dictionary).get("p", Vector3.ZERO)
		var lp := inv * pp
		if AABB(lp - Vector3(0.3, 0, 0.3), Vector3(0.6, 1.8, 0.6)).intersects(box):
			return true
	return false


func _in_world(xf: Transform3D, cells: Dictionary) -> bool:
	var p := xf * Raft.com(cells)
	return p.x > 6.0 and p.z > 6.0 and p.x < World.vox.sx - 6.0 and p.z < World.vox.sz - 6.0
