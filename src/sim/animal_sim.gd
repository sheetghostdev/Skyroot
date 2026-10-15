class_name AnimalSim
extends RefCounted
## The host's animals: crabs on the beaches, junglefowl in the woods and
## meadows, goats on the rocks.  They wander about their home, run from anyone
## who comes too close (or hurts them), and follow whoever leads them on twine -
## onto a raft, across the sea and off again, to make a new home where they're
## let go.  Fed by hand two at a time, they have young.  Animals far from
## everyone stand still until someone comes.
##
## An animal is an entity ("animal"): {"s" species, "hp" (1 = unhurt), "home",
## "isl" (its island), "lead" (who leads it, or -1), "raft" (the raft it stands
## on, or -1) with "rp"/"ry" its place and heading on that raft's deck, "born"
## (game hours; young ones grow up), "fed", "bred"}.

const TICK := 0.1                # seconds between steps
const ACTIVE := 56.0             # animals further than this from everyone rest
const WANDER := 7.0              # how far from home they wander
const LEAD_GAP := 1.5            # a led animal keeps this far behind
const LEAD_BREAK := 14.0         # further than this and the lead slips
const GROW_H := 48.0             # hours for a young one to grow up
const BREED_H := 36.0            # hours between young for one animal
const FED_H := 1.0               # fed this recently, it's ready to breed
const DAMAGE := {"": 0.1, "knife": 0.3, "axe": 0.36, "spear": 0.6, "shovel": 0.22, "hoe": 0.2, "paddle": 0.18}

var a: Actions
var sea := 30
var _t := 0.0
var _mind: Dictionary = {}       # id -> what it's doing now (not saved)
var paused := false              # (debug pictures) everyone holds still


func _init(actions: Actions) -> void:
	a = actions
	sea = int(World.geo.get("sea", 30))


static func species(e: Dictionary) -> Dictionary:
	return ItemDB.animals.get(String(e["d"].get("s", "")), {})


static func grown(d: Dictionary) -> float:
	## 0 for a newborn, 1 for a grown animal.
	var born := float(d.get("born", -1000.0))
	return clampf((World.hours() - born) / GROW_H, 0.0, 1.0)


# ---------------------------------------------------------------------------
# Populating the islands
# ---------------------------------------------------------------------------

func populate() -> void:
	## Once per archipelago: the animals each island starts with.
	if World.kind != "sea" or bool(World.geo.get("fauna", false)):
		return
	World.geo["fauna"] = true
	var isl: Array = World.geo.get("islands", [])
	var rng := RandomNumberGenerator.new()
	rng.seed = int(World.world_seed) * 31 + 7
	for i in isl.size():
		var b := String(isl[i]["b"])
		for s in ItemDB.animals:
			var rr: Array = (ItemDB.animals[s].get("isles", {}) as Dictionary).get(b, [])
			if rr.is_empty():
				continue
			for k in rng.randi_range(int(rr[0]), int(rr[1])):
				var p := land_point(i, bool(ItemDB.animals[s].get("shore", false)), rng)
				if p != Vector3.INF:
					spawn(s, p, i, rng.randf() * TAU)


func spawn(s: String, p: Vector3, isl: int, yaw := 0.0, born := -1000.0) -> int:
	return World.spawn("animal", Transform3D(Basis(Vector3.UP, yaw), p), {
		"s": s, "hp": 1.0, "home": p, "isl": isl, "lead": -1, "raft": -1, "born": born, "fed": -1000.0, "bred": -1000.0,
	})


func land_point(i: int, shore: bool, rng: RandomNumberGenerator) -> Vector3:
	## Somewhere an animal could stand on island i (on the beach, for shore animals).
	var it: Dictionary = World.geo["islands"][i]
	var c: Vector2 = it["c"]
	var r := float(it["r"])
	var vd := World.vox
	for k in 80:
		var ang := rng.randf() * TAU
		var dist := rng.randf_range(r * 0.7, r * 1.25) if shore else sqrt(rng.randf()) * r * 0.85
		var x := int(c.x + cos(ang) * dist)
		var z := int(c.y + sin(ang) * dist)
		var y := vd.surface_y(x, z)
		if y <= sea - 1 or y < 0:
			continue
		var top := vd.get_id(x, y, z)
		if Blocks.has_flag(top, "tree") or Blocks.has_flag(top, "leaves") or not Blocks.is_opaque(top):
			continue
		if shore and (Blocks.name_of(top) != "sand" or y > sea + 2):
			continue
		if vd.get_id(x, y + 1, z) != 0 and not Blocks.is_replaceable(vd.get_id(x, y + 1, z)):
			continue
		if Blocks.is_solid(vd.get_id(x, y + 2, z)) or vd.liquid_at(Vector3(x + 0.5, y + 1.2, z + 0.5)):
			continue
		return Vector3(x + 0.5, y + 1.0, z + 0.5)
	return Vector3.INF


func island_at(p: Vector3) -> int:
	var best := -1
	var bd := INF
	var isl: Array = World.geo.get("islands", [])
	for i in isl.size():
		var d := Vector2(p.x, p.z).distance_to(isl[i]["c"]) - float(isl[i]["r"])
		if d < bd:
			bd = d
			best = i
	return best


# ---------------------------------------------------------------------------
# Hours passing: eggs, and new animals where they've been hunted out
# ---------------------------------------------------------------------------

func tick(hours: float) -> void:
	if World.kind != "sea":
		return
	var counts := {}
	for e in World.entities_of("animal"):
		var d: Dictionary = e["d"]
		var k := "%d:%s" % [int(d.get("isl", -1)), String(d["s"])]
		counts[k] = int(counts.get(k, 0)) + 1
		var sp := species(e)
		if bool(sp.get("eggs", false)) and int(d.get("raft", -1)) < 0 and grown(d) >= 1.0 and randf() < hours / 14.0:
			var p: Vector3 = (e["xf"] as Transform3D).origin
			if _items_near(p, 3.0, "egg") < 3:
				a.drop_item("egg", 1, {}, p + Vector3(0, 0.2, 0))
	# a hunted-out island slowly fills again, while nobody is there to see
	var isl: Array = World.geo.get("islands", [])
	for i in isl.size():
		var b := String(isl[i]["b"])
		for s in ItemDB.animals:
			var rr: Array = (ItemDB.animals[s].get("isles", {}) as Dictionary).get(b, [])
			if rr.is_empty() or int(counts.get("%d:%s" % [i, s], 0)) >= int(rr[0]):
				continue
			if randf() > hours * 0.06 or _player_near(Vector3(isl[i]["c"].x, sea, isl[i]["c"].y), float(isl[i]["r"]) + 24.0):
				continue
			var rng := RandomNumberGenerator.new()
			rng.randomize()
			var p := land_point(i, bool(ItemDB.animals[s].get("shore", false)), rng)
			if p != Vector3.INF:
				spawn(s, p, i, rng.randf() * TAU)


func _items_near(p: Vector3, r: float, id: String) -> int:
	var n := 0
	for e in World.entities_near(p, r, "item"):
		if String(e["d"]["i"]) == id:
			n += int(e["d"]["n"])
	return n


func _player_near(p: Vector3, r: float) -> bool:
	for pid in Net.players:
		if a.player_pos(pid).distance_to(p) < r:
			return true
	return false


# ---------------------------------------------------------------------------
# Moving (every TICK seconds)
# ---------------------------------------------------------------------------

func step(delta: float) -> void:
	if paused:
		return
	_t += delta
	if _t < TICK:
		return
	var dt := minf(_t, 0.3)
	_t = 0.0
	var players: Array = []
	for pid in Net.players:
		var pose: Dictionary = Net.poses.get(pid, {})
		if String(pose.get("m", "play")) == "dead":
			continue
		players.append({"pid": pid, "p": a.player_pos(pid), "rv": int(pose.get("rv", -1)), "sp": bool(pose.get("sp", false))})
	for e in World.entities_of("animal"):
		var p: Vector3 = (e["xf"] as Transform3D).origin
		var near := false
		for pl in players:
			if (pl["p"] as Vector3).distance_to(p) < ACTIVE:
				near = true
				break
		if near or int(e["d"].get("lead", -1)) >= 0:
			_step_one(e, dt, players)


func mind(id: int) -> Dictionary:
	if not _mind.has(id):
		_mind[id] = {"st": "idle", "t": randf_range(0.5, 4.0), "goal": Vector3.INF, "from": Vector3.ZERO}
	return _mind[id]


func _step_one(e: Dictionary, dt: float, players: Array) -> void:
	var d: Dictionary = e["d"]
	var sp := species(e)
	if sp.is_empty():
		return
	var m := mind(e["id"])
	var lead := int(d.get("lead", -1))
	if lead >= 0 and not Net.players.has(lead):
		_untie(e)
		lead = -1
	if int(d.get("raft", -1)) >= 0:
		_step_aboard(e, dt, players, sp, m)
		return
	var xf: Transform3D = e["xf"]
	var p := xf.origin
	var goal := Vector3.INF
	var speed := float(sp.get("speed", 1.0))
	# in the water (its raft gone from under it): it swims for home
	var wet := World.vox.liquid_at(p + Vector3(0, 0.15, 0))
	if wet and lead < 0 and m["st"] != "flee":
		m["st"] = "walk"
		m["goal"] = d.get("home", p)
		m["t"] = 8.0
	if lead >= 0:
		var lp := a.player_pos(lead)
		var dist := Vector2(lp.x - p.x, lp.z - p.z).length()
		var rv := -1
		for pl in players:
			if int(pl["pid"]) == lead:
				rv = int(pl["rv"])
		if dist > LEAD_BREAK:
			_untie(e)
			World.notify(lead, "The lead slipped: the %s is loose." % String(sp["label"]).to_lower(), "warn")
			return
		if rv >= 0 and _board(e, rv):
			return
		if dist > LEAD_GAP:
			goal = lp
			speed = clampf(dist - LEAD_GAP + 0.8, 0.8, float(sp.get("run", 3.0)))
		m["st"] = "led"
	else:
		# run from people too close (unless it has just been fed by hand) or who hurt it
		var tame := World.hours() - float(d.get("fed", -1000.0)) < 0.25
		if m["st"] != "flee" and not tame:
			var shy := float(sp.get("shy", 3.0))
			for pl in players:
				var pp: Vector3 = pl["p"]
				var reach := shy * (1.6 if bool(pl["sp"]) else 1.0)
				if Vector2(pp.x - p.x, pp.z - p.z).length() < reach and absf(pp.y - p.y) < 3.0:
					_scare(e, pp, 2.0)
					break
		match String(m["st"]):
			"flee":
				m["t"] = float(m["t"]) - dt
				var away: Vector3 = p - (m["from"] as Vector3)
				away.y = 0.0
				if float(m["t"]) <= 0.0:
					_idle(m)
				elif away.length() > 0.01:
					goal = p + away.normalized() * 3.0
					speed = float(sp.get("run", 3.0))
			"walk":
				goal = m["goal"]
			_:
				m["t"] = float(m["t"]) - dt
				if float(m["t"]) <= 0.0:
					var home: Vector3 = d.get("home", p)
					var ang := randf() * TAU
					var g := home + Vector3(cos(ang), 0, sin(ang)) * randf_range(1.0, WANDER)
					# wander a little at a time
					var to := g - p
					if to.length() > 4.0:
						g = p + to.normalized() * 4.0
					m["st"] = "walk"
					m["goal"] = g
					m["t"] = 8.0
	if goal == Vector3.INF:
		return
	var to := goal - p
	to.y = 0.0
	if to.length() < 0.2:
		if m["st"] == "walk":
			_idle(m)
		return
	var stepv := to.normalized() * minf(speed * dt, to.length())
	var swim := lead >= 0 or wet
	var np := _walk(p, stepv, sp, swim)
	if np == p:
		# blocked: try a little to either side, else give up on that way
		for side in [0.7, -0.7]:
			np = _walk(p, stepv.rotated(Vector3.UP, side), sp, swim)
			if np != p:
				break
	if np == p:
		if m["st"] == "walk" or m["st"] == "flee":
			_idle(m)
		return
	if m["st"] == "walk":
		m["t"] = float(m["t"]) - dt
		if float(m["t"]) <= 0.0:
			_idle(m)
	_move(e, np, np - p, sp)


func _move(e: Dictionary, np: Vector3, dir: Vector3, sp: Dictionary) -> void:
	var yaw := atan2(-dir.x, -dir.z)
	if bool(sp.get("shore", false)):
		yaw += PI * 0.5            # crabs go sideways
	var old: Transform3D = e["xf"]
	var cur := old.basis.get_euler().y
	var nyaw := lerp_angle(cur, yaw, 0.45)
	World.move_entity(e["id"], Transform3D(Basis(Vector3.UP, nyaw), np), true)


func _idle(m: Dictionary) -> void:
	m["st"] = "idle"
	m["t"] = randf_range(2.0, 7.0)
	m["goal"] = Vector3.INF


func _scare(e: Dictionary, from: Vector3, secs: float) -> void:
	var m := mind(e["id"])
	m["st"] = "flee"
	m["from"] = from
	m["t"] = secs


func _walk(p: Vector3, stepv: Vector3, sp: Dictionary, swim_ok: bool) -> Vector3:
	## Where a step takes an animal: up a block or down a few, never into a
	## wall or off a cliff; into the water only when led (it swims).
	var vd := World.vox
	var np := p + stepv
	var h: float = (sp.get("size", [0.5, 0.5]) as Array)[1]
	var top := vd.rest_height(Vector3(np.x, p.y + 1.1, np.z))
	if top == -INF or top < p.y - 3.2:
		return p
	var wet := vd.liquid_at(Vector3(np.x, top + 0.15, np.z))
	if wet:
		if not swim_ok:
			return p
		var surf := _water_surface(Vector3(np.x, top + 0.15, np.z))
		var y := surf - h * 0.55
		if not vd.box_free(AABB(Vector3(np.x - 0.18, y, np.z - 0.18), Vector3(0.36, h * 0.9, 0.36))):
			return p
		return Vector3(np.x, y, np.z)
	var hw := minf(0.2, (sp.get("size", [0.5, 0.5]) as Array)[0] * 0.4)
	if not vd.box_free(AABB(Vector3(np.x - hw, top + 0.02, np.z - hw), Vector3(hw * 2.0, maxf(0.2, h - 0.05), hw * 2.0))):
		return p
	if bool(sp.get("shore", false)) and not swim_ok:
		var under := vd.get_idv(VoxelData.cell_of(Vector3(np.x, top - 0.5, np.z)))
		if Blocks.name_of(under) != "sand":
			return p
	return Vector3(np.x, top, np.z)


func _water_surface(p: Vector3) -> float:
	var c := VoxelData.cell_of(p)
	var vd := World.vox
	while c.y < vd.sy - 1 and Blocks.is_water(vd.get_idv(c + Vector3i.UP)):
		c.y += 1
	return float(c.y) + ChunkMesher.liquid_h(vd.get_m(c.x, c.y, c.z), false)


# ---------------------------------------------------------------------------
# Rafts
# ---------------------------------------------------------------------------

func _board(e: Dictionary, raft_id: int) -> bool:
	## Led up to the leader's raft: hop aboard if the deck is close.
	var r: Dictionary = World.entities.get(raft_id, {})
	if r.is_empty():
		return false
	var rxf: Transform3D = r["xf"]
	var lp := rxf.affine_inverse() * (e["xf"] as Transform3D).origin
	var cells: Dictionary = r["d"]["cells"]
	var best := Vector3.INF
	var bd := 2.2
	for c in cells:
		var cc: Vector3i = c
		if cc.y != 0 or _deck_blocked(cells, cc):
			continue
		var top := Vector3(cc.x + 0.5, Raft.DECK, cc.z + 0.5)
		var dd := Vector2(top.x - lp.x, top.z - lp.z).length()
		if dd < bd:
			bd = dd
			best = top
	if best == Vector3.INF:
		return false
	e["d"]["raft"] = raft_id
	var ry := (e["xf"] as Transform3D).basis.get_euler().y - rxf.basis.get_euler().y
	World.update(e["id"], {"raft": raft_id, "rp": best, "ry": ry})
	World.move_entity(e["id"], rxf * Transform3D(Basis(Vector3.UP, ry), best), true)
	World.fx("animal_hop", rxf * best, {"s": e["d"]["s"]})
	return true


static func _deck_blocked(cells: Dictionary, c: Vector3i) -> bool:
	var above = cells.get(c + Vector3i.UP)
	return above != null and Blocks.solid[(above as Vector2i).x] == 1


func _step_aboard(e: Dictionary, dt: float, players: Array, sp: Dictionary, m: Dictionary) -> void:
	## On a raft's deck it goes where the raft goes; led, it follows its leader
	## about the deck, and off again onto land.
	var d: Dictionary = e["d"]
	var r: Dictionary = World.entities.get(int(d["raft"]), {})
	var rp: Vector3 = d.get("rp", Vector3(0.5, Raft.DECK, 0.5))
	if r.is_empty() or not (r["d"]["cells"] as Dictionary).has(Vector3i(floori(rp.x), 0, floori(rp.z))):
		_overboard(e)
		return
	var rxf: Transform3D = r["xf"]
	var cells: Dictionary = r["d"]["cells"]
	var ry := float(d.get("ry", 0.0))
	var lead := int(d.get("lead", -1))
	var goal := Vector3.INF
	var speed := float(sp.get("speed", 1.0))
	if lead >= 0:
		var lpw := a.player_pos(lead)
		var on_same := false
		for pl in players:
			if int(pl["pid"]) == lead:
				on_same = int(pl["rv"]) == int(d["raft"])
		var dist := Vector2(lpw.x - (rxf * rp).x, lpw.z - (rxf * rp).z).length()
		if dist > LEAD_BREAK:
			_untie(e)
			World.notify(lead, "The lead slipped: the %s stays on the raft." % String(sp["label"]).to_lower(), "warn")
		elif on_same:
			if dist > LEAD_GAP:
				goal = rxf.affine_inverse() * lpw
				speed = clampf(dist - LEAD_GAP + 0.8, 0.8, 2.5)
		elif _off_raft(e, rxf * rp, lpw):
			return
	else:
		m["t"] = float(m["t"]) - dt
		if float(m["t"]) <= 0.0:
			m["t"] = randf_range(3.0, 9.0)
			var keys := cells.keys()
			var c: Vector3i = keys[randi() % keys.size()]
			if c.y == 0 and not _deck_blocked(cells, c):
				m["goal"] = Vector3(c.x + 0.5, Raft.DECK, c.z + 0.5)
		if m.get("goal", Vector3.INF) != Vector3.INF:
			goal = m["goal"]
	var moved := false
	if goal != Vector3.INF:
		var to := goal - rp
		to.y = 0.0
		if to.length() > 0.15:
			var np := rp + to.normalized() * minf(speed * dt, to.length())
			var cell := Vector3i(floori(np.x), 0, floori(np.z))
			if cells.has(cell) and not _deck_blocked(cells, cell):
				var want := atan2(-to.x, -to.z) + (PI * 0.5 if bool(sp.get("shore", false)) else 0.0)
				ry = lerp_angle(ry, want, 0.45)
				rp = np
				moved = true
		elif lead < 0:
			m["goal"] = Vector3.INF
	if moved:
		d["rp"] = rp
		d["ry"] = ry
		World.update(e["id"], {"rp": rp, "ry": ry})
	World.move_entity(e["id"], rxf * Transform3D(Basis(Vector3.UP, ry), rp), moved)


func _overboard(e: Dictionary) -> void:
	## The deck it stood on is gone: into the sea (it swims).
	var d: Dictionary = e["d"]
	d["raft"] = -1
	World.update(e["id"], {"raft": -1})
	var p: Vector3 = (e["xf"] as Transform3D).origin
	var h: float = (species(e).get("size", [0.5, 0.5]) as Array)[1]
	var top := World.vox.rest_height(p + Vector3(0, 0.5, 0))
	var y := top
	if World.vox.liquid_at(Vector3(p.x, top + 0.15, p.z)):
		y = _water_surface(Vector3(p.x, top + 0.15, p.z)) - h * 0.55
	World.move_entity(e["id"], Transform3D((e["xf"] as Transform3D).basis, Vector3(p.x, y, p.z)), true)
	World.fx("splash", Vector3(p.x, y + h * 0.5, p.z), {})


func on_raft(e: Dictionary) -> int:
	## The raft it stands on (-1 if none, or if that raft is gone).
	var rid := int(e["d"].get("raft", -1))
	return rid if rid >= 0 and World.entities.has(rid) else -1


func _off_raft(e: Dictionary, at: Vector3, leader: Vector3) -> bool:
	## Its leader went ashore: jump down onto the land beside the raft.
	var to := leader - at
	to.y = 0.0
	if to.length() < 0.3:
		return false
	var dir := to.normalized()
	for k in [1.2, 1.8, 2.4]:
		var q: Vector3 = at + dir * float(k)
		var top := World.vox.rest_height(Vector3(q.x, at.y + 1.6, q.z))
		if top == -INF or top < sea + 0.5 or World.vox.liquid_at(Vector3(q.x, top + 0.15, q.z)):
			continue
		var sp := species(e)
		var h: float = (sp.get("size", [0.5, 0.5]) as Array)[1]
		if not World.vox.box_free(AABB(Vector3(q.x - 0.18, top + 0.02, q.z - 0.18), Vector3(0.36, maxf(0.2, h - 0.05), 0.36))):
			continue
		e["d"]["raft"] = -1
		World.update(e["id"], {"raft": -1})
		World.move_entity(e["id"], Transform3D(Basis(Vector3.UP, atan2(-dir.x, -dir.z)), Vector3(q.x, top, q.z)), true)
		World.fx("animal_hop", Vector3(q.x, top, q.z), {"s": e["d"]["s"]})
		return true
	return false


# ---------------------------------------------------------------------------
# What players do to them
# ---------------------------------------------------------------------------

func _animal(args: Dictionary) -> Dictionary:
	var e: Dictionary = World.entities.get(int(args.get("eid", -1)), {})
	if e.is_empty() or String(e["t"]) != "animal":
		return {}
	return e


func _reach_ok(pid: int, e: Dictionary, extra: float) -> bool:
	var sp := species(e)
	var h: float = (sp.get("size", [0.5, 0.5]) as Array)[1]
	var p: Vector3 = (e["xf"] as Transform3D).origin + Vector3(0, h * 0.5, 0)
	return a.eye_pos(pid).distance_to(p) <= Actions.REACH + extra


func hit(pid: int, args: Dictionary) -> void:
	var e := _animal(args)
	if e.is_empty():
		return
	var slot := int(args.get("slot", -1))
	var kind := a.held_kind(pid, slot)
	if not _reach_ok(pid, e, 1.2 if kind == "spear" else 0.5):
		return
	if not a._rate(pid, "hit", 380):
		return
	var d: Dictionary = e["d"]
	var sp := species(e)
	var held := a.held(pid, slot)
	var dmg := float(DAMAGE.get(kind, 0.1))
	if String(held.get("d", {}).get("mat", "")) == "flint":
		dmg *= 1.25
	var hp := float(d.get("hp", 1.0)) - dmg / maxf(0.05, float(sp.get("hp", 1.0)))
	if kind != "":
		a.wear_tool(pid, slot, 1)
	var p: Vector3 = (e["xf"] as Transform3D).origin
	var h: float = (sp.get("size", [0.5, 0.5]) as Array)[1]
	World.fx("animal_hit", p + Vector3(0, h * 0.5, 0), {"s": d["s"]})
	if hp <= 0.0:
		_die(pid, e)
		return
	World.update(e["id"], {"hp": hp})
	if int(d.get("lead", -1)) < 0:
		_scare(e, a.player_pos(pid), 3.5)
		# a hurt animal jumps away from the blow
		var away := p - a.player_pos(pid)
		away.y = 0.0
		if away.length() > 0.01 and int(d.get("raft", -1)) < 0:
			var np := _walk(p, away.normalized() * 0.6, sp, false)
			if np != p:
				_move(e, np, np - p, sp)


func _die(pid: int, e: Dictionary) -> void:
	var d: Dictionary = e["d"]
	var sp := species(e)
	var p: Vector3 = (e["xf"] as Transform3D).origin
	var young := grown(d) < 1.0
	for dr in sp.get("drops", []):
		var n := randi_range(int(dr["n"][0]), int(dr["n"][1]))
		if young:
			n = mini(n, 1) if String(dr["item"]).begins_with("meat") or String(dr["item"]).begins_with("crab") else 0
		if n > 0:
			a.drop_item(String(dr["item"]), n, {}, p + Vector3(0, 0.3, 0), Vector3(randf_range(-0.6, 0.6), 2.0, randf_range(-0.6, 0.6)))
	if int(d.get("lead", -1)) >= 0:
		a.drop_item("twine", 1, {}, p + Vector3(0, 0.3, 0))
	World.fx("animal_die", p + Vector3(0, 0.2, 0), {"s": d["s"]})
	_mind.erase(e["id"])
	World.despawn(e["id"])
	a.flag_player(pid, "hunted:" + String(d["s"]))
	a.flag_player(pid, "hunted")


func use(pid: int, args: Dictionary) -> void:
	## Right-click: tie a lead on, untie it, or feed it from your hand.
	var e := _animal(args)
	if e.is_empty() or not _reach_ok(pid, e, 0.6):
		return
	if not a._rate(pid, "place", 200):
		return
	var slot := int(args.get("slot", -1))
	var s := a.held(pid, slot)
	var id := String(s.get("i", ""))
	var d: Dictionary = e["d"]
	var sp := species(e)
	var nm := String(sp.get("label", "animal")).to_lower()
	var lead := int(d.get("lead", -1))
	if id in (sp.get("eats", []) as Array):
		_feed(pid, e, slot)
		return
	if lead == pid:
		var from_isl := int(d.get("isl", -1))
		_untie(e)
		a.give(pid, "twine", 1)
		World.notify(pid, "You let the %s go. It'll stay about here." % nm)
		if int(d.get("isl", -1)) != from_isl and int(d.get("raft", -1)) < 0:
			a.flag_player(pid, "brought")
			a.flag_player(pid, "brought:" + String(d["s"]))
		return
	if id == "twine" and bool(sp.get("lead", false)) and lead < 0:
		World.inventory_of(pid).take_from(slot, 1)
		World.mark_inventory(pid)
		d["lead"] = pid
		World.update(e["id"], {"lead": pid})
		mind(e["id"])["st"] = "led"
		World.fx("lead", (e["xf"] as Transform3D).origin, {"s": d["s"]})
		a.flag_player(pid, "led:" + String(d["s"]))
		Survival.hint_once(pid, "animal_lead")


func _feed(pid: int, e: Dictionary, slot: int) -> void:
	var d: Dictionary = e["d"]
	var sp := species(e)
	World.inventory_of(pid).take_from(slot, 1)
	World.mark_inventory(pid)
	var now := World.hours()
	d["fed"] = now
	World.update(e["id"], {"fed": now, "hp": minf(1.0, float(d.get("hp", 1.0)) + 0.25)})
	_idle(mind(e["id"]))
	var p: Vector3 = (e["xf"] as Transform3D).origin
	World.fx("animal_eat", p + Vector3(0, 0.4, 0), {"s": d["s"]})
	a.flag_player(pid, "fed:" + String(d["s"]))
	# two fed grown animals together: a young one
	if grown(d) < 1.0 or now - float(d.get("bred", -1000.0)) < BREED_H:
		return
	for o in World.entities_near(p, 5.0, "animal"):
		var od: Dictionary = o["d"]
		if o["id"] == e["id"] or String(od["s"]) != String(d["s"]) or grown(od) < 1.0:
			continue
		if now - float(od.get("fed", -1000.0)) > FED_H or now - float(od.get("bred", -1000.0)) < BREED_H:
			continue
		if on_raft(o) != on_raft(e):
			continue
		d["bred"] = now
		od["bred"] = now
		World.update(e["id"], {"bred": now})
		World.update(o["id"], {"bred": now})
		var mid: Vector3 = (p + (o["xf"] as Transform3D).origin) * 0.5
		var young := spawn(String(d["s"]), mid, island_at(mid), randf() * TAU, now)
		if on_raft(e) >= 0:
			var rp: Vector3 = (d.get("rp", Vector3.ZERO) as Vector3)
			World.update(young, {"raft": d["raft"], "rp": rp, "ry": 0.0})
		World.fx("animal_born", mid + Vector3(0, 0.5, 0), {"s": d["s"]})
		a.flag_player(pid, "bred:" + String(d["s"]))
		World.notify(pid, "A young %s!" % String(sp.get("label", "animal")).to_lower())
		return


func _untie(e: Dictionary) -> void:
	var d: Dictionary = e["d"]
	d["lead"] = -1
	var ch := {"lead": -1}
	if int(d.get("raft", -1)) < 0:
		# where it's let go is its new home
		var p: Vector3 = (e["xf"] as Transform3D).origin
		ch["home"] = p
		ch["isl"] = island_at(p)
	World.update(e["id"], ch)
	_idle(mind(e["id"]))
