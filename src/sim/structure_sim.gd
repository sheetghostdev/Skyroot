class_name StructureSim
extends RefCounted
## What holds what up (host).  A finished piece is supported if it rests on the
## island or touches something that is.  Floors are the load-carrying spans:
## every platform away from a grounded support adds one step of overhang.  One
## step (a 2 m cantilever) is fine, two creaks and sags, three cannot hold - it
## shakes, groans and then falls, scattering its parts.  Posts standing on the
## ground (or braced against the cliff) carry load without any overhang.
##
## Deliberately simple and readable: no engineering maths, just "how far from
## something solid is this deck?"

const GROUND_EPS := 0.22       # m: how close to the ground counts as resting on it
const TOUCH := 0.09            # m: pieces closer than this are joined
const OK_SPAN := 1
const CREAK_SPAN := 2
const COLLAPSE_AFTER := 10.0   # seconds of warning before something gives way

static var _dirty := true
static var _warn: Dictionary = {}    # structure id -> seconds it has been failing
static var _creak_t := 0.0
static var _settle: Array = []       # [physics frame, box, pass]: places that lost what held things up


static func reset() -> void:
	_dirty = true
	_warn.clear()
	_settle.clear()


static func resettle_later(box: AABB) -> void:
	## Whatever lay on a piece that was taken apart or fell comes down once its
	## colliders have gone (a couple of physics frames later).
	var b := box.grow(0.08)
	b.size.y += 0.6
	var due := Engine.get_physics_frames() + 2
	for s in _settle:
		if (s[1] as AABB).is_equal_approx(b):
			s[0] = maxi(int(s[0]), due)
			return
	_settle.append([due, b, 0])


static func settle_step() -> void:
	## Every physics frame on the host: what lost its support comes down, a
	## layer at a time (a pile settles over a few frames).
	if _settle.is_empty() or World.actions == null:
		return
	var now := Engine.get_physics_frames()
	var due: Array = []
	var keep: Array = []
	for s in _settle:
		(due if now >= int(s[0]) else keep).append(s)
	_settle = keep
	for s in due:
		# something that came down may have been holding something else up
		if World.actions.resettle(s[1]) > 0 and int(s[2]) < 30:
			_settle.append([now + 2, s[1], int(s[2]) + 1])


static func mark_dirty() -> void:
	_dirty = true


static func is_complete(d: Dictionary) -> bool:
	var parts: Array = ItemDB.blueprint(String(d.get("bp", ""))).get("parts", [])
	return parts.size() > 0 and int(d.get("installed", 0)) >= parts.size()


static func local_box(bp_id: String, sy: float = 1.0) -> AABB:
	## The piece's bounds in its own space.
	var bp := ItemDB.blueprint(bp_id)
	var size: Array = bp.get("size", [1.0, 1.0, 1.0])
	var off: Array = bp.get("offset", [0.0, 0.0, 0.0])
	var sz := Vector3(float(size[0]), float(size[1]) * sy, float(size[2]))
	var c := Vector3(float(off[0]), float(off[1]) * sy, float(off[2]))
	return AABB(c - sz * 0.5, sz)


static func world_corners(bp_id: String, xf: Transform3D, sy: float = 1.0) -> PackedVector3Array:
	var b := local_box(bp_id, sy)
	var out := PackedVector3Array()
	for i in 8:
		out.append(xf * (b.position + Vector3(b.size.x * (i & 1), b.size.y * ((i >> 1) & 1), b.size.z * ((i >> 2) & 1))))
	return out


static func world_box(bp_id: String, xf: Transform3D, sy: float = 1.0) -> AABB:
	var cs := world_corners(bp_id, xf, sy)
	var bb := AABB(cs[0], Vector3.ZERO)
	for p in cs:
		bb = bb.expand(p)
	return bb


static func obb(bp_id: String, xf: Transform3D, sy: float = 1.0, shrink: float = 0.0) -> Dictionary:
	## The piece as an oriented box (centre, half extents, axes), each face pulled
	## in by `shrink` (never past 40% of that extent, so thin pieces stay boxes).
	var b := local_box(bp_id, sy)
	var half := b.size * 0.5
	half -= Vector3(minf(shrink, half.x * 0.8), minf(shrink, half.y * 0.8), minf(shrink, half.z * 0.8))
	return {"c": xf * b.get_center(), "h": half,
		"a": [xf.basis.x.normalized(), xf.basis.y.normalized(), xf.basis.z.normalized()]}


static func obb_intersect(p: Dictionary, q: Dictionary) -> bool:
	## Separating-axis test for two oriented boxes.
	var axes: Array = []
	axes.append_array(p["a"])
	axes.append_array(q["a"])
	for i in 3:
		for j in 3:
			var cr: Vector3 = (p["a"][i] as Vector3).cross(q["a"][j])
			if cr.length_squared() > 1e-6:
				axes.append(cr.normalized())
	var d: Vector3 = (q["c"] as Vector3) - (p["c"] as Vector3)
	var ph: Vector3 = p["h"]
	var qh: Vector3 = q["h"]
	for ax in axes:
		var a3: Vector3 = ax
		var ra := ph.x * absf((p["a"][0] as Vector3).dot(a3)) + ph.y * absf((p["a"][1] as Vector3).dot(a3)) + ph.z * absf((p["a"][2] as Vector3).dot(a3))
		var rb := qh.x * absf((q["a"][0] as Vector3).dot(a3)) + qh.y * absf((q["a"][1] as Vector3).dot(a3)) + qh.z * absf((q["a"][2] as Vector3).dot(a3))
		if absf(d.dot(a3)) > ra + rb:
			return false
	return true


static func grounded(bp_id: String, xf: Transform3D, sy: float = 1.0) -> bool:
	## Does the piece's underside rest on the island?
	var b := local_box(bp_id, sy)
	var kind := String(ItemDB.blueprint(bp_id).get("kind", ""))
	var pts: Array = []
	var y := b.position.y
	for fx in [0.1, 0.5, 0.9]:
		for fz in [0.1, 0.5, 0.9]:
			pts.append(Vector3(b.position.x + b.size.x * fx, y, b.position.z + b.size.z * fz))
	var touching := 0
	for lp in pts:
		var wp: Vector3 = xf * (lp as Vector3)
		if not World.terrain.is_inside(wp.x, wp.z):
			continue
		var gh := World.terrain.height(wp.x, wp.z)
		if wp.y - gh < GROUND_EPS and wp.y - gh > -0.6:
			touching += 1
	return touching >= (2 if kind == "floor" else 1)


static func _neighbours(a: Dictionary, others: Array) -> Array:
	var out: Array = []
	var ba: AABB = a["box"].grow(TOUCH)
	for o in others:
		if o["id"] != a["id"] and ba.intersects(o["box"]):
			out.append(o)
	return out


static func _nodes(extra: Dictionary = {}) -> Array:
	var nodes: Array = []
	for e in World.entities_of("structure"):
		var d: Dictionary = e["d"]
		if not is_complete(d):
			continue
		var bp := String(d["bp"])
		var sy := float(d.get("sy", 1.0))
		nodes.append({"id": int(e["id"]), "bp": bp, "kind": String(ItemDB.blueprint(bp).get("kind", "")),
			"box": world_box(bp, e["xf"], sy), "ground": grounded(bp, e["xf"], sy), "xf": e["xf"]})
	if not extra.is_empty():
		nodes.append(extra)
	return nodes


static func solve(nodes: Array) -> Dictionary:
	## id -> span (0 = carried by the ground; floors add one per step out).
	var span := {}
	var queue: Array = []
	for n in nodes:
		if n["ground"]:
			span[n["id"]] = 0
			queue.append(n)
	while not queue.is_empty():
		# expand the cheapest first so every piece gets its shortest route
		var bi := 0
		for i in queue.size():
			if int(span[queue[i]["id"]]) < int(span[queue[bi]["id"]]):
				bi = i
		var n: Dictionary = queue[bi]
		queue.remove_at(bi)
		var s: int = span[n["id"]]
		for m in _neighbours(n, nodes):
			# a deck sitting on grounded posts or walls is carried; any other step out is overhang
			var cost := 0
			if m["kind"] == "floor":
				cost = 0 if (n["kind"] in ["post", "wall"] and n["ground"]) else 1
			var ns := s + cost
			# only floors and grounded/carried uprights pass load on
			if not (n["kind"] in ["floor", "post", "wall"] or n["ground"]):
				continue
			if not span.has(m["id"]) or ns < int(span[m["id"]]):
				span[m["id"]] = ns
				queue.append(m)
	return span


static func would_hold(bp_id: String, xf: Transform3D, sy: float = 1.0) -> int:
	## Span a new piece would have (99 = nothing holds it).
	var probe := {"id": -2, "bp": bp_id, "kind": String(ItemDB.blueprint(bp_id).get("kind", "")),
		"box": world_box(bp_id, xf, sy), "ground": grounded(bp_id, xf, sy), "xf": xf}
	var span := solve(_nodes(probe))
	return int(span.get(-2, 99))


static func tick(real_dt: float) -> void:
	if not World.is_host():
		return
	if _dirty:
		_dirty = false
		_recompute()
	_creak_t -= real_dt
	for id in _warn.keys():
		if not World.has_entity(id):
			_warn.erase(id)
			continue
		_warn[id] = float(_warn[id]) + real_dt
		var e := World.get_entity(id)
		if _creak_t <= 0.0:
			World.fx("creak", e["xf"].origin, {"vol": -2.0})
		if float(_warn[id]) >= COLLAPSE_AFTER:
			collapse(id)
	if _creak_t <= 0.0:
		_creak_t = 2.2


static func _recompute() -> void:
	var nodes := _nodes()
	var span := solve(nodes)
	for n in nodes:
		var id: int = n["id"]
		var s := int(span.get(id, 99))
		var e := World.get_entity(id)
		var stress := 0.0
		if s >= CREAK_SPAN + 1:
			stress = 1.0
		elif s == CREAK_SPAN:
			stress = 0.5
		if absf(float(e["d"].get("stress", 0.0)) - stress) > 0.01:
			World.update(id, {"stress": stress})
		if stress >= 1.0:
			if not _warn.has(id):
				_warn[id] = 0.0
				_notify_near(e["xf"].origin, "Something groans and shifts - the %s has lost its support!" % String(ItemDB.blueprint(String(e["d"]["bp"])).get("name", "structure")).to_lower())
		else:
			_warn.erase(id)


static func _notify_near(pos: Vector3, text: String) -> void:
	for pid in Net.players:
		var pp: Vector3 = Net.poses.get(pid, {}).get("p", Vector3.INF)
		if pp.distance_to(pos) < 25.0:
			World.notify(pid, text, "warn")


static func collapse(id: int) -> void:
	## It gives way: every installed part falls where it is.
	var e := World.get_entity(id)
	_warn.erase(id)
	if e.is_empty():
		return
	var d: Dictionary = e["d"]
	var used: Array = d.get("used", [])
	var bp := ItemDB.blueprint(String(d["bp"]))
	var parts: Array = bp.get("parts", [])
	var box := local_box(String(d["bp"]), float(d.get("sy", 1.0)))
	var a: Actions = World.actions
	var gw = Game.game_world
	if gw and gw.entities:
		var v: Node = gw.entities.view(id)
		if v and v.has_method("drop_collision"):
			v.drop_collision()
	World.despawn(id)
	resettle_later(world_box(String(d["bp"]), e["xf"], float(d.get("sy", 1.0))))
	var rng := RandomNumberGenerator.new()
	rng.seed = id
	for i in mini(int(d.get("installed", 0)), parts.size()):
		var item := String(used[i]) if i < used.size() else String(parts[i]).get_slice("|", 0)
		var lp := box.position + Vector3(box.size.x * rng.randf(), box.size.y * 0.5, box.size.z * rng.randf())
		a.spawn_item(item, 1, {}, e["xf"] * lp)
	World.fx("collapse", e["xf"].origin)
	_notify_near(e["xf"].origin, "The %s collapsed!" % String(bp.get("name", "structure")).to_lower())
	_dirty = true
