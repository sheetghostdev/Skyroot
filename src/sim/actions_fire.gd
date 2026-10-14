class_name ActionsFire
extends RefCounted
## Host handlers for fires and process sites: lighting, feeding, covering with
## earth, poking and closing vents, digging a mound open, carrying fire on a
## stick, scooping ash - and the fire drill.

const DRILL_HEAT_K := 0.42       # heat gained per unit of spin per second
const DRILL_COOL := 0.35         # fraction of heat lost per second
const EMBER_HOLD := 1.4          # seconds at full heat for an ember to form
const EMBER_LIFE := 30.0
const TINDER := {"straw": 2, "fiber": 3}

static var _drill_t: Dictionary = {}   # work id -> last op time (ms), host only


static func register(a: Actions) -> void:
	for nm in ["ignite", "fire_cover", "fire_vent", "fire_uncover", "fire_torch", "fire_add", "fire_ash", "pot_add"]:
		a.register(nm, Callable(ActionsFire, "_" + nm).bind(a))


static func _site_of(args: Dictionary) -> Dictionary:
	## The site an action is aimed at: the site itself, or the item in it.
	var eid := int(args.get("eid", -1))
	var e := World.get_entity(eid)
	if e.is_empty():
		return {}
	if e["t"] == "site":
		return e
	if e["t"] == "item":
		var sid := int(e["d"].get("site", -1))
		if sid != -1 and World.has_entity(sid):
			return World.get_entity(sid)
	return {}


# ---------------------------------------------------------------------------
# Lighting
# ---------------------------------------------------------------------------

static func _ignite(pid: int, args: Dictionary, a: Actions) -> void:
	var eid := int(args.get("eid", -1))
	var e := World.get_entity(eid)
	if e.is_empty() or e["t"] != "item" or not a.in_reach(pid, args, e["xf"].origin):
		return
	if a.held_id(pid, args) != "torch":
		return
	if FireSim.ignite(eid, 560.0):
		World.fx("sparks", e["xf"].origin + Vector3(0, 0.05, 0), {"sound": "fire_ignite", "amount": 8})
		World.hint_to(pid, "first_fire")


static func _fire_torch(pid: int, args: Dictionary, a: Actions) -> void:
	## Light a stick from a burning fire to carry the flame.
	var site := _site_of(args)
	if site.is_empty() or not bool(site["d"].get("lit", false)) or not a.in_reach(pid, args, site["xf"].origin, 0.6):
		return
	if a.held_id(pid, args) != "stick":
		return
	var s := a.held(pid, args)
	if not s["d"].is_empty() and s["d"].has("fm"):
		return
	var td := {"mass": ItemDB.unit_mass("stick")}
	if int(s["n"]) > 1 and a.inv(pid).space_for("torch", td) <= 0:
		# (a burning stick needs a hand of its own: it can't go back in a full pack)
		World.notify(pid, "No room to hold a burning stick. Free up a slot first.")
		return
	a.take_held(pid, args, 1)
	a.inv(pid).add("torch", 1, td, int(args.get("slot", -1)))
	World.mark_inventory(pid)
	World.fx("sparks", site["xf"].origin + Vector3(0, 0.3, 0), {"sound": "fire_ignite", "amount": 6})
	World.hint_to(pid, "item:torch")


static func on_item_placed(eid: int) -> void:
	var e := World.get_entity(eid)
	if e.is_empty():
		return
	var sid := FireSim.site_at(e["xf"].origin)
	if sid != -1:
		World.update(eid, {"site": sid})
		FireSim.mark_dirty(sid)


static func prepare_pickup(eid: int) -> void:
	## An item leaving a fire: half-burnt fuel becomes charred wood; anything
	## barely touched is plain fuel again.
	var e := World.get_entity(eid)
	if e.is_empty():
		return
	var d: Dictionary = e["d"]
	var x: Dictionary = d.get("x", {})
	var sid := int(d.get("site", -1))
	if sid != -1:
		FireSim.mark_dirty(sid)
	if not x.has("fm"):
		if sid != -1:
			World.update(eid, {"site": -1})
		return
	var iid := String(d.get("i", ""))
	var fm := float(x["fm"])
	var ch := float(x.get("ch", 0.0))
	var nu := float(x.get("nu", 0.0))
	var m0 := float(x.get("m0", fm + ch))
	var n := int(d.get("n", 1))
	var site := World.get_entity(sid)
	if iid != "charred_wood" and iid != "torch" and iid != "charcoal" and fm >= 0.97 * m0 and ch <= 0.01 * m0 and nu >= 0.999 * n * ItemDB.nutrients(iid):
		World.pools["atmo_carbon_kg"] = float(World.pools.get("atmo_carbon_kg", 0.0)) - (n * ItemDB.unit_mass(iid) - fm - ch)
		var extra := nu - n * ItemDB.nutrients(iid)
		if not site.is_empty():
			site["d"]["ash_n"] = float(site["d"].get("ash_n", 0.0)) + extra
		else:
			World.pools["lost_nutr"] = float(World.pools.get("lost_nutr", 0.0)) + extra
		World.update(eid, {"x": {"moist": float(x.get("moist", ItemDB.default_moist(iid)))}, "site": -1, "char": 0.0})
	elif iid == "charcoal" and fm <= 0.0:
		var unit := ItemDB.unit_mass("charcoal")
		var k := int(floor(ch / unit + 1e-6))
		var rest := ch - k * unit
		if not site.is_empty():
			site["d"]["ash_c"] = float(site["d"].get("ash_c", 0.0)) + rest
			site["d"]["ash_n"] = float(site["d"].get("ash_n", 0.0)) + nu
		else:
			World.pools["atmo_carbon_kg"] = float(World.pools.get("atmo_carbon_kg", 0.0)) + rest
			World.pools["lost_nutr"] = float(World.pools.get("lost_nutr", 0.0)) + nu
		if k <= 0:
			World.despawn(eid)
		else:
			World.update(eid, {"n": k, "x": {}, "site": -1, "char": 0.0})
	elif iid == "torch":
		# a burning stick taken back out of a fire burns on in the hand with
		# whatever the fire left of it
		World.update(eid, {"site": -1, "x": {"mass": fm + ch, "nu": nu, "moist": float(x.get("moist", 0.1))}})
	elif iid != "charred_wood":
		World.update(eid, {"i": "charred_wood", "n": 1, "site": -1, "char": snappedf(ch / maxf(fm + ch, 1e-6), 0.01),
			"x": {"fm": fm, "ch": ch, "nu": nu, "m0": m0, "from": iid, "moist": float(x.get("moist", 0.1))}})
	else:
		World.update(eid, {"site": -1})


static func on_item_removed(eid: int) -> void:
	prepare_pickup(eid)


static func on_terrain_dug(pos: Vector3) -> void:
	var sid := FireSim.site_at(pos, 0.8)
	if sid != -1:
		FireSim.mark_dirty(sid)


static func douse(eid: int, litres: float) -> void:
	FireSim.douse(eid, litres)


# ---------------------------------------------------------------------------
# Feeding
# ---------------------------------------------------------------------------

static func _fire_add(pid: int, args: Dictionary, a: Actions) -> void:
	## Put the held fuel, food or pot into the fire - fuel on top, food at the edge.
	var site := _site_of(args)
	if site.is_empty() or not a.in_reach(pid, args, site["xf"].origin, 0.6):
		return
	var s := a.held(pid, args)
	if s.is_empty():
		return
	var id := String(s["i"])
	if FireSim.shell_coverage(site["d"]) > 0.5:
		World.notify(pid, "It's packed with earth - dig it open first.")
		return
	var c: Vector3 = site["xf"].origin
	var r := float(site["d"].get("r", 0.25))
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var ang := rng.randf() * TAU
	var dist := rng.randf_range(0.0, r * 0.6)
	if not ItemDB.food(id).is_empty() and ItemDB.fuel(id).is_empty():
		dist = r * 0.85
		var to := a.player_pos(pid) - c
		ang = atan2(to.z, to.x) + rng.randf_range(-0.5, 0.5)
	var p := c + Vector3(cos(ang) * dist, 0.6, sin(ang) * dist)
	var taken := a.take_held(pid, args, 1)
	if taken.is_empty():
		return
	var eid := a.spawn_item(id, 1, taken["d"], p)
	if eid != -1:
		World.update(eid, {"site": int(site["id"])})
		FireSim.mark_dirty(int(site["id"]))
	World.fx("drop", p, {"vol": -6.0})


static func _fire_ash(pid: int, args: Dictionary, a: Actions) -> void:
	var site := _site_of(args)
	if site.is_empty() or not a.in_reach(pid, args, site["xf"].origin, 0.6):
		return
	var d: Dictionary = site["d"]
	if int(d.get("T", 15)) > 70 or bool(d.get("lit", false)):
		World.notify(pid, "Too hot to touch.", "warn")
		return
	var an := float(d.get("ash_n", 0.0))
	var ac := float(d.get("ash_c", 0.0))
	var unit_n := ItemDB.nutrients("ash")
	var unit_c := ItemDB.unit_mass("ash")
	var n := int(floor(minf(an / unit_n, ac / unit_c) + 1e-6))
	n = mini(n, 6)
	if n <= 0:
		World.notify(pid, "Only a dusting of ash - not enough to gather.")
		return
	World.update(int(site["id"]), {"ash_n": an - n * unit_n, "ash_c": ac - n * unit_c})
	a.give(pid, "ash", n)
	World.fx("ash", site["xf"].origin + Vector3(0, 0.05, 0))
	FireSim._maybe_remove(World.get_entity(int(site["id"])))


static func _pot_add(pid: int, args: Dictionary, a: Actions) -> void:
	WaterActions.pot_add(a, pid, args)


# ---------------------------------------------------------------------------
# Covering: the earth shell and its vents
# ---------------------------------------------------------------------------

static func _aim_cell(site: Dictionary, pos: Vector3) -> int:
	var c: Vector3 = site["xf"].origin
	var rr := FireSim.dome_radii(site["d"])
	var rel := pos - c
	var dir := Vector3(rel.x / rr.x, rel.y / rr.y, rel.z / rr.x)
	if dir.length() < 0.001:
		dir = Vector3.UP
	return FireSim.cell_of_dir(dir)


static func _neighbours_by_angle(k0: int) -> Array:
	var d0 := FireSim.cell_dir(k0)
	var order: Array = range(FireSim.CELLS)
	order.sort_custom(func(p, q):
		# earth packed high slides down: lower cells first among equals
		var dp := FireSim.cell_dir(p).angle_to(d0) + FireSim.cell_dir(p).y * 0.15
		var dq := FireSim.cell_dir(q).angle_to(d0) + FireSim.cell_dir(q).y * 0.15
		return dp < dq)
	return order


static func _fire_cover(pid: int, args: Dictionary, a: Actions) -> void:
	var held := a.held_id(pid, args)
	if held != "earth":
		return
	var pos: Vector3 = args.get("pos", Vector3.ZERO)
	if not a.in_reach(pid, args, pos, 0.4):
		return
	var site := _site_of(args)
	if site.is_empty():
		var e := World.get_entity(int(args.get("eid", -1)))
		if e.is_empty() or e["t"] != "item" or ItemDB.fuel(String(e["d"].get("i", ""))).is_empty():
			return
		var sid := FireSim.site_at(e["xf"].origin)
		if sid == -1:
			sid = FireSim.make_site(e["xf"].origin)
		site = World.get_entity(sid)
	var d: Dictionary = site["d"]
	var shell: Array = d.get("shell", []).duplicate()
	shell.resize(FireSim.CELLS)
	for i in shell.size():
		if shell[i] == null:
			shell[i] = 0.0
	var vents: Array = d.get("vents", []).duplicate()
	var k0 := _aim_cell(site, pos)
	# packing earth over a vent closes it
	if k0 in vents and FireSim.coverage(d, k0) > 0.6:
		vents.erase(k0)
		World.update(int(site["id"]), {"vents": vents})
		World.fx("soil_place", pos, {"amount": 4})
		FireSim.mark_dirty(int(site["id"]))
		return
	var left := TerrainActions.EARTH_L
	var order := _neighbours_by_angle(k0)
	# cover first, then thicken
	for limit in [1.0, FireSim.SHELL_MAX]:
		for k in order:
			if left <= 0.0:
				break
			var cap: float = FireSim.cell_full_l(k, d) * float(limit) - float(shell[k])
			if cap <= 0.0:
				continue
			var add := minf(cap, left)
			shell[k] = float(shell[k]) + add
			left -= add
			vents.erase(k)
	if left >= TerrainActions.EARTH_L - 0.001:
		World.notify(pid, "It's already thickly covered.")
		return
	a.take_held(pid, args, 1)
	var used := TerrainActions.EARTH_L - left
	if left > 0.0:
		# the rest falls beside the mound
		var rect := World.terrain.fill(Vector2(pos.x, pos.z), 0.3, left)
		World.terrain_edited(rect)
	var total := 0.0
	for v in shell:
		total += float(v)
	World.update(int(site["id"]), {"shell": shell, "shell_l": total, "vents": vents})
	World.fx("soil_place", pos)
	FireSim.mark_dirty(int(site["id"]))
	if used > 0.0 and FireSim.shell_coverage(World.get_entity(int(site["id"]))["d"]) > 0.95:
		World.hint_to(pid, "mound_sealed")


static func _fire_vent(pid: int, args: Dictionary, a: Actions) -> void:
	## Poke a small vent through the earth with a stick.
	var site := _site_of(args)
	var pos: Vector3 = args.get("pos", Vector3.ZERO)
	if site.is_empty() or not a.in_reach(pid, args, pos, 0.4):
		return
	if a.held_id(pid, args) != "stick":
		return
	var d: Dictionary = site["d"]
	var k := _aim_cell(site, pos)
	if FireSim.coverage(d, k) < 0.6:
		World.notify(pid, "There's no earth there to poke through - it's already open.")
		return
	var vents: Array = d.get("vents", []).duplicate()
	if k in vents:
		return
	if vents.size() >= 8:
		World.notify(pid, "That's plenty of vents.")
		return
	vents.append(k)
	World.update(int(site["id"]), {"vents": vents})
	World.fx("dust", pos, {"amount": 5, "sound": "dig_soil", "vol": -8.0})
	if int(d.get("T", 15)) > 200:
		World.fx("smoke_puff", pos)
	FireSim.mark_dirty(int(site["id"]))


static func _fire_uncover(pid: int, args: Dictionary, a: Actions) -> void:
	## Dig earth off the mound: one earth's worth from around where you dig.
	var site := _site_of(args)
	var pos: Vector3 = args.get("pos", Vector3.ZERO)
	if site.is_empty() or not a.in_reach(pid, args, pos, 0.4):
		return
	var d: Dictionary = site["d"]
	var shell: Array = d.get("shell", []).duplicate()
	var total := float(d.get("shell_l", 0.0))
	if total <= 0.0:
		return
	var vents: Array = d.get("vents", []).duplicate()
	var want := minf(TerrainActions.EARTH_L, total)
	var k0 := _aim_cell(site, pos)
	var got := 0.0
	for k in _neighbours_by_angle(k0):
		if got >= want:
			break
		var have := float(shell[k])
		if have <= 0.0:
			continue
		var take := minf(have, want - got)
		shell[k] = have - take
		got += take
		if float(shell[k]) <= 0.001:
			shell[k] = 0.0
			vents.erase(k)
	total -= got
	if total < 0.05:
		got += total
		total = 0.0
		for i in shell.size():
			shell[i] = 0.0
		vents.clear()
	if got >= TerrainActions.EARTH_L - 1e-6:
		a.give(pid, "earth", 1)
		got -= TerrainActions.EARTH_L
	if got > 1e-9:
		# too little to carry (or the last crumbs of the mound): it goes back on the ground
		var rect := World.terrain.fill(Vector2(pos.x, pos.z), 0.3, got)
		World.terrain_edited(rect)
	World.update(int(site["id"]), {"shell": shell, "shell_l": total, "vents": vents})
	World.fx("dust", pos)
	a.exert(pid, 0.02)
	FireSim.mark_dirty(int(site["id"]))
	if int(d.get("T", 15)) > 250:
		World.fx("smoke_puff", pos)
		if bool(d.get("lit", false)):
			World.hint_to(pid, "charcoal_open")


# ---------------------------------------------------------------------------
# The fire drill (a "work" entity: hearth board + spindle)
# ---------------------------------------------------------------------------

static func drill_start(a: Actions, pid: int, args: Dictionary, d: Dictionary) -> bool:
	## Called from ActionsCraft._work_start for kind "fire_drill".
	var inv := a.inv(pid)
	var held := a.held(pid, args)
	var hid := String(held.get("i", ""))
	var board := {}
	var board_eid := int(args.get("board", -1))
	if board_eid != -1:
		var be := World.get_entity(board_eid)
		if be.is_empty() or String(be["d"].get("i", "")) != "hearth_board" or hid != "stick":
			return false
		if not a.in_reach(pid, args, be["xf"].origin):
			return false
		board = be["d"].get("x", {}).duplicate()
		if int(be["d"].get("n", 1)) > 1:
			World.update(board_eid, {"n": int(be["d"]["n"]) - 1})
		else:
			World.despawn(board_eid)
		var stick := a.take_held(pid, args, 1)
		d["spindle"] = stick.get("d", {})
	elif hid == "hearth_board":
		if inv.count("stick") < 1:
			World.notify(pid, "You need a straight stick to spin in the hearth board.")
			return false
		board = a.take_held(pid, args, 1).get("d", {})
		var si := -1
		for i in inv.slots.size():
			var s: Dictionary = inv.slots[i]
			if not s.is_empty() and String(s["i"]) == "stick" and not s["d"].has("fm"):
				si = i
				break
		if si == -1:
			a.give(pid, "hearth_board", 1, board)
			return false
		d["spindle"] = inv.take_from(si, 1).get("d", {})
		World.mark_inventory(pid)
	else:
		return false
	d["board"] = board
	d["heat"] = 0.0
	d["ember"] = 0.0
	d["spin"] = 0.0
	d["dust"] = 0.0
	return true


static func drill_op(a: Actions, pid: int, e: Dictionary, op: Array) -> void:
	var d: Dictionary = e["d"]
	var eid := int(e["id"])
	# the crafter says how long it spun for; the host won't accept more than
	# the time that really passed (plus a little network jitter)
	var now := Time.get_ticks_msec()
	var last := int(_drill_t.get(eid, now - 250))
	_drill_t[eid] = now
	var claimed := clampf(float(op[2]) if op.size() > 2 else 0.1, 0.0, 0.25)
	var dt := minf(claimed, (now - last) / 1000.0 + 0.12)
	match String(op[0]):
		"spin":
			var speed := clampf(float(op[1]), 0.0, 1.0)
			var st := a.stats(pid)
			if float(st.get("stamina", 1.0)) < 0.03:
				speed *= 0.25
			var heat := float(d.get("heat", 0.0))
			heat += (speed * DRILL_HEAT_K * (1.0 - heat * 0.35) - heat * DRILL_COOL * (1.0 - speed * 0.85)) * dt
			heat = clampf(heat, 0.0, 1.0)
			var ember := float(d.get("ember", 0.0))
			var hold := float(d.get("hold", 0.0))
			if heat >= 0.96:
				hold += dt
			else:
				hold = maxf(0.0, hold - dt * 0.5)
			var ch := {"heat": snappedf(heat, 0.01), "spin": snappedf(speed, 0.05), "hold": snappedf(hold, 0.05),
				"dust": snappedf(minf(1.0, float(d.get("dust", 0.0)) + speed * dt * 0.05), 0.01)}
			if ember <= 0.0 and hold >= EMBER_HOLD:
				ch["ember"] = EMBER_LIFE
				World.fx("sparks", e["xf"].origin + Vector3(0, 0.03, 0), {"amount": 4, "sound": "ember_blow", "vol": -6.0})
				World.notify(pid, "An ember! Tip it into your tinder (Enter) before it dies.", "craft")
			World.update(eid, ch)
			a.exert(pid, speed * dt * 0.035)
		"stop":
			World.update(eid, {"spin": 0.0})


static func drill_tick(e: Dictionary, real_dt: float) -> void:
	## Embers fade and the board cools when nobody is spinning.
	var d: Dictionary = e["d"]
	var ember := float(d.get("ember", 0.0))
	var heat := float(d.get("heat", 0.0))
	var spin := float(d.get("spin", 0.0))
	var ch := {}
	if ember > 0.0:
		ember -= real_dt
		ch["ember"] = maxf(0.0, ember)
		if ember <= 0.0:
			ch["hold"] = 0.0
			ch["heat"] = 0.3
	elif heat > 0.0 and spin <= 0.01:
		ch["heat"] = maxf(0.0, heat - heat * DRILL_COOL * real_dt)
	if not ch.is_empty() and (absf(float(ch.get("heat", heat)) - heat) > 0.02 or ch.has("hold") or int(ch.get("ember", ember)) != int(ember) or ch.get("ember", 1.0) == 0.0):
		World.update(int(e["id"]), ch)
	elif not ch.is_empty():
		for k in ch:
			d[k] = ch[k]


static func drill_finish(a: Actions, pid: int, e: Dictionary) -> void:
	## Tip the ember into a tinder bundle and set it down: fire.
	var d: Dictionary = e["d"]
	if float(d.get("ember", 0.0)) <= 0.0:
		World.craft_result(pid, int(e["id"]), "No ember yet - spin faster and keep going.", "warn")
		return
	var inv := a.inv(pid)
	var tinder := ""
	for t in TINDER:
		var need: int = TINDER[t]
		if inv.count(t) >= need:
			tinder = t
			break
	if tinder == "":
		World.craft_result(pid, int(e["id"]), "You need tinder for the ember: a couple of straw bundles or a few fibers.", "warn")
		return
	var need2: int = TINDER[tinder]
	inv.remove(tinder, need2)
	World.mark_inventory(pid)
	var pos: Vector3 = e["xf"].origin
	World.despawn(int(e["id"]))
	_drill_t.erase(int(e["id"]))
	# the tinder goes down right where the board was; the drill set back to the hands
	var tid := a.spawn_item(tinder, need2, {"moist": 0.08}, pos + Vector3(0, 0.15, 0))
	var b: Dictionary = d.get("board", {}).duplicate()
	b["holes"] = int(b.get("holes", 0)) + 1
	a.give(pid, "hearth_board", 1, b)
	a.give(pid, "stick", 1, d.get("spindle", {}))
	if tid != -1:
		FireSim.ignite(tid, 620.0)
		World.fx("sparks", pos + Vector3(0, 0.1, 0), {"sound": "fire_ignite", "amount": 12})
	World.discover("first_fire", pid)
	World.hint_to(pid, "first_fire")
	World.craft_result(pid, int(e["id"]), "The tinder catches! Feed it twigs, then sticks, then bigger wood.", "craft")


static func drill_cancel(a: Actions, pid: int, d: Dictionary) -> void:
	a.give(pid, "hearth_board", 1, d.get("board", {}))
	a.give(pid, "stick", 1, d.get("spindle", {}))
