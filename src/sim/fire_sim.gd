class_name FireSim
extends RefCounted
## Fires and process sites in the world (host side).
##
## A site is created where something is lit.  Every item lying within reach of
## its fuel bed belongs to it: fuel burns, chars or dries; pots heat, steam and
## fire; food roasts and burns.  The site looks at what surrounds the bed - pit
## walls, stones, potsherds, a packed earth shell and any vents poked into it -
## and turns that into the openings, walls and insulation FireModel needs.  So
## a campfire, a pottery pit and a charcoal mound are not separate stations:
## they are whatever the players built, and the physics decides what happens.
##
## Accounting is exact: fuel items carry their wood (fm), charcoal (ch) and
## nutrients (nu) in their data once they have been in a fire.  Gases and burnt
## charcoal go to the atmosphere pool; the minerals of burnt charcoal collect
## in the site as ash (ash_n, ash_c); the earth shell is counted as soil.

const SUBSTEP := 6.0                # game seconds per physics step
const MAX_SUBSTEPS := 60
const JOIN_MARGIN := 0.3            # items this far beyond the bed join the fire
const SHELL_T := 0.025              # m of packed earth for a full seal
const SHELL_MAX := 1.6              # cells can be packed this many times thicker
const VENT_A := 0.004               # m2: a vent poked with a stick
const LEAK_A := 0.0005              # m2: a complete earth shell still breathes
const GAP_K := 0.5                  # how freely air flows through an uncovered gap
const AZ := 16
const BANDS := [0.0, 20.0, 40.0, 60.0, 80.0]
const CELLS := 65                   # 4 bands x 16 + the cap
const ASH_C_PER_N := 2.5            # kg of ash minerals per nutrient unit
const LIT_W := 150.0
const COOK_S := 1800.0              # game seconds of roasting heat to cook food
const FIRE_S := 600.0               # game seconds of >550 C to turn clay to ceramic
const TORCH_HOURS := 2.0

static var _rt: Dictionary = {}     # site id -> runtime state (rebuilt from entity data after a load)
static var _hot: Dictionary = {}    # item id -> true: hot items cooling outside any fire
static var _ext_cache: Dictionary = {}


static func item_extent(iid: String, x: Dictionary = {}) -> Vector2:
	## (horizontal half-length, height) of an item's model, for sizing a pile.
	var key := iid if not iid in ["wood_piece", "charred_wood"] else iid + String(x.get("from", ""))
	if _ext_cache.has(key):
		return _ext_cache[key]
	var out := Vector2(0.06, 0.06)
	var vis := ItemVisual.single(iid, x if iid in ["wood_piece", "charred_wood"] else {})
	if vis:
		var bb := Models.aabb_of(vis)
		out = Vector2(maxf(bb.size.x, bb.size.z) * 0.5, bb.size.y)
		vis.free()
	_ext_cache[key] = out
	return out


static func reset() -> void:
	_rt.clear()
	_hot.clear()
	_ext_cache.clear()


# ---------------------------------------------------------------------------
# Shell geometry (shared with SiteView)
# ---------------------------------------------------------------------------

static func cell_dir(k: int) -> Vector3:
	if k >= CELLS - 1:
		return Vector3.UP
	var band := k / AZ
	var az := (float(k % AZ) + 0.5) / AZ * TAU
	var el := deg_to_rad((float(BANDS[band]) + float(BANDS[band + 1])) * 0.5)
	return Vector3(cos(el) * cos(az), sin(el), cos(el) * sin(az))


static func cell_of_dir(dir: Vector3) -> int:
	var el := rad_to_deg(asin(clampf(dir.normalized().y, -1.0, 1.0)))
	if el >= float(BANDS[4]):
		return CELLS - 1
	var band := clampi(int(maxf(el, 0.0) / 20.0), 0, 3)
	var az := int(fposmod(atan2(dir.z, dir.x), TAU) / TAU * AZ) % AZ
	return band * AZ + az


static func dome_radii(d: Dictionary) -> Vector2:
	## (horizontal, vertical) radii of the shell around the pile.
	return Vector2(float(d.get("r", 0.25)) + 0.08, maxf(float(d.get("h", 0.15)) + 0.08, 0.22))


static func cell_area(k: int, d: Dictionary) -> float:
	var rr := dome_radii(d)
	var R := (2.0 * rr.x + rr.y) / 3.0
	if k >= CELLS - 1:
		return TAU * R * R * (1.0 - sin(deg_to_rad(80.0)))
	var band := k / AZ
	return TAU * R * R * (sin(deg_to_rad(float(BANDS[band + 1]))) - sin(deg_to_rad(float(BANDS[band])))) / AZ


static func cell_full_l(k: int, d: Dictionary) -> float:
	return cell_area(k, d) * SHELL_T * 1000.0


static func cell_point(k: int, d: Dictionary, origin: Vector3) -> Vector3:
	var rr := dome_radii(d)
	var dir := cell_dir(k)
	var hl := Vector2(dir.x, dir.z)
	return origin + Vector3(hl.x * rr.x, dir.y * rr.y, hl.y * rr.x)


static func coverage(d: Dictionary, k: int) -> float:
	var shell: Array = d.get("shell", [])
	if k >= shell.size():
		return 0.0
	return clampf(float(shell[k]) / maxf(0.001, cell_full_l(k, d)), 0.0, 1.0)


static func shell_coverage(d: Dictionary) -> float:
	var a := 0.0
	var c := 0.0
	for k in CELLS:
		var ar := cell_area(k, d)
		a += ar
		c += ar * coverage(d, k)
	return c / maxf(a, 1e-6)


# ---------------------------------------------------------------------------
# Tick
# ---------------------------------------------------------------------------

static func tick(hours: float, real_dt: float) -> void:
	if not World.is_host() or Game.game_world == null:
		return
	var dt := hours * 3600.0
	for e in World.entities_of("site"):
		_tick_site(e, dt, real_dt)
	_sweep_loose(dt)
	_torches(dt)
	for w in World.entities_of("work"):
		if String(w["d"].get("kind", "")) == "fire_drill":
			ActionsFire.drill_tick(w, real_dt)


static func _runtime(e: Dictionary) -> Dictionary:
	var id := int(e["id"])
	if not _rt.has(id):
		_rt[id] = {"T": float(e["d"].get("T", 15.0)), "members": [], "env": {}, "encl_t": 0.0, "vis_t": 0.0,
			"last": {}, "cold_s": 0.0, "dirty": true, "sheltered": false}
	return _rt[id]


static func mark_dirty(site_id: int) -> void:
	if _rt.has(site_id):
		_rt[site_id]["dirty"] = true


static func _tick_site(e: Dictionary, dt: float, real_dt: float) -> void:
	var id := int(e["id"])
	var d: Dictionary = e["d"]
	var rt := _runtime(e)
	_gather(e, rt)
	rt["encl_t"] = float(rt["encl_t"]) - real_dt
	if float(rt["encl_t"]) <= 0.0 or bool(rt["dirty"]):
		_enclosure(e, rt)
		rt["encl_t"] = 2.0
		rt["dirty"] = false
	var members: Array = rt["members"]
	var T_amb := Climate.base_temp()
	var rain := float(World.env.get("rain", 0.0))
	var exposed := 0.0 if bool(rt["sheltered"]) else 1.0
	# a cold pit with nothing smouldering in it needs no physics
	var active := bool(d.get("lit", false)) or float(rt["T"]) > 60.0
	if not active:
		for mid in members:
			if float(World.get_entity(mid)["d"].get("heat", 15.0)) > 60.0:
				active = true
				break
	if not active:
		# a fire that just went cold: settle what's left of everything in it
		for mid in members:
			if _unsettled(World.get_entity(mid)["d"]):
				_finish(e, rt)
				break
		_leach(e, dt, rain * exposed)
		return
	# the model's view of this site
	var s := {"T": float(rt["T"]), "pieces": [], "inert": []}
	var fuel_ids: Array = []
	var inert_ids: Array = []
	var inert_kind: Array = []
	var center: Vector3 = e["xf"].origin
	var r := float(d.get("r", 0.25))
	for mid in members:
		var me := World.get_entity(mid)
		if me.is_empty():
			continue
		var md: Dictionary = me["d"]
		var iid := String(md.get("i", ""))
		var x: Dictionary = md.get("x", {})
		if not md.has("x") or not (md["x"] is Dictionary):
			md["x"] = x
		var Tp := float(md.get("heat", T_amb))
		var fu := _fuel_props(iid, x)
		if not fu.is_empty():
			_init_fuel(md)
			s["pieces"].append(FireModel.piece(float(x["fm"]), float(fu["rate"]), float(fu["ign"]), float(x.get("moist", 0.0)), float(x["ch"]), Tp))
			fuel_ids.append(mid)
			continue
		var dist := Vector2(me["xf"].origin.x - center.x, me["xf"].origin.z - center.z).length()
		var expo := clampf(1.25 - dist / (r + 0.05), 0.25, 1.0)
		var kind := "other"
		var mass := ItemDB.unit_mass(iid) * int(md.get("n", 1))
		var size := 0.8
		var cp := 900.0
		if iid == "pot":
			kind = "pot"
			mass = Pottery.mass(x) + float(x.get("water", 0.0))
			size = 1.0
			cp = (Pottery.mass(x) * 900.0 + float(x.get("water", 0.0)) * 4190.0) / maxf(mass, 0.01)
		elif not ItemDB.food(iid).is_empty():
			kind = "food"
			size = 1.1
			cp = 3000.0
		elif ItemDB.material(iid) == "stone":
			kind = "stone"
			cp = 800.0
		s["inert"].append([maxf(mass, 0.01), size * expo, Tp, cp, expo])
		inert_ids.append(mid)
		inert_kind.append(kind)
	# weather on an open fire
	var p: Dictionary = rt["env"].duplicate()
	if p.is_empty():
		p = {"open_m2": 0.5, "bed_m2": 0.2, "wall_m2": 0.0, "insul": 0.0, "encl": 0.0}
	p["T_amb"] = T_amb
	p["wind"] = (World.env.get("wind", Vector2.ONE) as Vector2).length()
	p["extra_loss_w"] = rain * exposed * float(p.get("open_m2", 0.0)) * 30000.0
	# run the physics
	var n_sub := clampi(int(ceil(dt / SUBSTEP)), 1, MAX_SUBSTEPS)
	var h := dt / n_sub
	var acc := {"heat_w": 0.0, "gas_burn": 0.0, "smoke": 0.0, "steam": 0.0, "char_burn": 0.0, "air": 0.0, "air_need": 0.0, "pyro": 0.0}
	var ext := {"steam_l": 0.0}
	var inert_prev := PackedFloat64Array()
	for j in inert_ids.size():
		inert_prev.append(float(s["inert"][j][2]))
	for k in n_sub:
		var res := FireModel.step(s, p, h)
		for key in acc:
			acc[key] = float(acc[key]) + float(res.get(key, 0.0)) * h
		_inert_substep(s, inert_ids, inert_kind, h, inert_prev, float(p.get("encl", 0.0)), ext)
	for key in acc:
		acc[key] = float(acc[key]) / maxf(dt, 1e-6)
	rt["T"] = float(s["T"])
	rt["last"] = acc
	# write the results back into the world, accounting for every gram
	var ash_n := float(d.get("ash_n", 0.0))
	var ash_c := float(d.get("ash_c", 0.0))
	var atmo_c := 0.0
	var hottest := float(s["T"])
	for i in fuel_ids.size():
		var mid: int = fuel_ids[i]
		var me := World.get_entity(mid)
		var w: Array = s["pieces"][i]
		var md: Dictionary = me["d"]
		var x: Dictionary = md["x"]
		var gas: float = w[FireModel.O_GAS]
		var cb: float = w[FireModel.O_CHAR_BURNED]
		var nu := float(x.get("nu", 0.0))
		var dnu := 0.0
		if cb > 0.0:
			var potential: float = float(w[FireModel.W_CHAR]) + float(w[FireModel.W_MASS]) * 0.3 + cb
			dnu = nu * clampf(cb / maxf(potential, 1e-9), 0.0, 1.0)
		var dac := minf(cb, dnu * ASH_C_PER_N)
		atmo_c += gas + cb - dac
		ash_n += dnu
		ash_c += dac
		x["fm"] = float(w[FireModel.W_MASS])
		x["ch"] = float(w[FireModel.W_CHAR])
		x["nu"] = nu - dnu
		x["moist"] = float(w[FireModel.W_MOIST])
		var Tp: float = w[FireModel.W_T]
		hottest = maxf(hottest, Tp)
		if float(x["fm"]) + float(x["ch"]) < 1e-4:
			ash_n += float(x["nu"])
			ash_c += float(x["fm"]) + float(x["ch"])
			World.despawn(mid)
			continue
		_show_piece(mid, md, Tp, float(x["ch"]) / maxf(1e-6, float(x["fm"]) + float(x["ch"])))
	for j in inert_ids.size():
		var mid2: int = inert_ids[j]
		var me2 := World.get_entity(mid2)
		if me2.is_empty():
			continue
		var Ti := float(s["inert"][j][2])
		hottest = maxf(hottest, Ti)
		var out := _inert_result(me2, String(inert_kind[j]), Ti, dt, float(acc["smoke"]), float(p.get("encl", 0.0)))
		atmo_c += float(out.get("atmo_c", 0.0))
		ash_n += float(out.get("ash_n", 0.0))
		ash_c += float(out.get("ash_c", 0.0))
		if World.has_entity(mid2):
			_show_piece(mid2, World.get_entity(mid2)["d"], Ti, -1.0)
	World.pools["atmo_carbon_kg"] = float(World.pools.get("atmo_carbon_kg", 0.0)) + atmo_c
	World.pools["atmo_water_l"] = float(World.pools.get("atmo_water_l", 0.0)) + float(ext["steam_l"])
	d["ash_n"] = ash_n
	d["ash_c"] = ash_c
	var lit := float(acc["heat_w"]) > LIT_W or hottest > 320.0 and float(acc["char_burn"]) > 0.0
	if lit and not bool(d.get("lit", false)):
		World.update(id, {"lit": true, "t_lit": World.hours()})
	_feedback(e, rt, acc, lit, real_dt)
	if lit and float(acc["heat_w"]) > 2000.0 and not bool(rt.get("scorched", false)):
		# the grass under a real fire burns away (back into the soil, like any torn-up grass)
		rt["scorched"] = true
		var c2: Vector3 = e["xf"].origin
		var cells := World.terrain.cells_in_radius(Vector2(c2.x, c2.z), float(d.get("r", 0.25)) + 0.1)
		TerrainActions.remove_grass(cells, 1.0)
		var ck := TerrainData.cell_at(Vector2(c2.x, c2.z))
		World.terrain_edited(Rect2i(ck - Vector2i(4, 4), Vector2i(9, 9)))
	# going out, cooling down, finishing up
	if not lit and hottest < 55.0 and float(s["T"]) < 55.0:
		rt["cold_s"] = float(rt["cold_s"]) + dt
	else:
		rt["cold_s"] = 0.0
	if float(rt["cold_s"]) > 300.0:
		_finish(e, rt)


static func _unsettled(md: Dictionary) -> bool:
	## Fuel still carrying fire bookkeeping that _finish hasn't settled yet.
	var x: Dictionary = md.get("x", {})
	if not x.has("fm"):
		return false
	var iid := String(md.get("i", ""))
	if iid == "charred_wood":
		return float(x["fm"]) <= 0.1 * float(x.get("m0", 1.0))
	return true


static func _fuel_props(iid: String, x: Dictionary) -> Dictionary:
	if iid == "charred_wood":
		var from := String(x.get("from", "firewood"))
		var f := ItemDB.fuel(from)
		return f if not f.is_empty() else ItemDB.fuel("firewood")
	if iid == "torch":
		return ItemDB.fuel("stick")
	return ItemDB.fuel(iid)


static func _init_fuel(md: Dictionary) -> void:
	var x: Dictionary = md["x"]
	if x.has("fm"):
		return
	var iid := String(md.get("i", ""))
	var n := int(md.get("n", 1))
	if iid == "charcoal":
		x["fm"] = 0.0
		x["ch"] = n * ItemDB.unit_mass("charcoal")
		x["nu"] = n * ItemDB.nutrients("charcoal")
	elif iid == "torch":
		x["fm"] = float(x.get("mass", ItemDB.unit_mass("stick")))
		x["ch"] = 0.0
		x["nu"] = ItemDB.nutrients("stick")
	else:
		x["fm"] = n * ItemDB.unit_mass(iid)
		x["ch"] = 0.0
		x["nu"] = n * ItemDB.nutrients(iid)
	if not x.has("moist"):
		x["moist"] = ItemDB.default_moist(iid)
	x["m0"] = float(x["fm"]) + float(x["ch"])


static func _show_piece(mid: int, md: Dictionary, Tp: float, char_frac: float) -> void:
	## Replicate what others can see: glow and charring.  Small changes stay local.
	var ch := {}
	var old := float(md.get("heat", 15.0))
	if absf(Tp - old) > 25.0 or (Tp > 60.0) != (old > 60.0) or (Tp > 400.0) != (old > 400.0):
		ch["heat"] = int(Tp)
		ch["hot"] = Tp > 70.0
	else:
		md["heat"] = int(Tp)
	if char_frac >= 0.0 and absf(char_frac - float(md.get("char", 0.0))) > 0.08:
		ch["char"] = snappedf(char_frac, 0.01)
	if not ch.is_empty():
		World.update(mid, ch)


static func _inert_substep(s: Dictionary, ids: Array, kinds: Array, h: float, prev: PackedFloat64Array, encl: float, ext: Dictionary) -> void:
	## Pots boil off water and steam out of their clay, and may crack doing it.
	for j in ids.size():
		if String(kinds[j]) != "pot":
			continue
		var me := World.get_entity(ids[j])
		if me.is_empty():
			continue
		var x: Dictionary = me["d"]["x"]
		var it: Array = s["inert"][j]
		var Ti := float(it[2])
		var C := float(it[0]) * float(it[3])
		var water := float(x.get("water", 0.0))
		if water > 0.0 and Ti > 100.0:
			var boil := minf(water, (Ti - 100.0) * C / 2.26e6)
			x["water"] = water - boil
			ext["steam_l"] = float(ext["steam_l"]) + boil
			it[2] = 100.0 + ((Ti - 100.0) * C - boil * 2.26e6) / C
			it[0] = maxf(0.01, float(it[0]) - boil)
			Ti = float(it[2])
		var st := String(x.get("state", "dry"))
		if st != "fired" and st != "cracked":
			var m := float(x.get("moist", 0.0))
			if Ti > 100.0 and m > 0.0:
				# a pot the guide calls dry (Pottery.moisture_state) never bursts; damper ones may
				if m > 0.07 and not bool(x.get("sc", false)):
					x["sc"] = true
					if randf() < clampf((m - 0.07) * 9.0, 0.0, 0.95):
						_crack(me, "The damp clay burst with steam.")
						continue
				var vol := float(x.get("vol", 0.25))
				var dm := minf(m, (Ti - 100.0) * C / 2.26e6 / maxf(vol, 0.01) * 0.25)
				x["moist"] = m - dm
				ext["steam_l"] = float(ext["steam_l"]) + dm * vol
		# thermal shock: very fast heating or cooling of a pot in the open
		var rate := absf(Ti - prev[j]) / maxf(h, 0.01)
		prev[j] = Ti
		if rate > 4.0 and Ti > 120.0 and st != "cracked":
			var p := (rate - 4.0) * h * 0.0004 * (1.0 - encl * 0.7) * (0.6 + float(x.get("risk", 0.1)))
			if randf() < p:
				_crack(me, "A pot cracked from the sudden heat." if st != "fired" else "A pot cracked from the sudden change in heat.")


static func _crack(me: Dictionary, why: String) -> void:
	var x: Dictionary = me["d"]["x"].duplicate(true)
	if String(x.get("state", "")) == "cracked":
		return
	# whatever was in it spills
	var water := float(x.get("water", 0.0))
	if water > 0.0:
		World.pools["atmo_water_l"] = float(World.pools.get("atmo_water_l", 0.0)) + water
		x["water"] = 0.0
	if String(x.get("state", "")) != "fired":
		var vol := float(x.get("vol", 0.25))
		World.pools["atmo_water_l"] = float(World.pools.get("atmo_water_l", 0.0)) + vol * float(x.get("moist", 0.0))
		x["moist"] = 0.0
	x["state"] = "cracked"
	World.update(int(me["id"]), {"x": x})
	World.fx("pottery_crack", me["xf"].origin + Vector3(0, 0.08, 0))
	for pid in Net.players:
		var pp: Vector3 = Net.poses.get(pid, {}).get("p", Vector3.INF)
		if pp.distance_to(me["xf"].origin) < 12.0:
			World.notify(pid, why, "warn")


static func _inert_result(me: Dictionary, kind: String, Ti: float, dt: float, smoke: float, encl: float) -> Dictionary:
	var out := {}
	var md: Dictionary = me["d"]
	var x: Dictionary = md["x"]
	var iid := String(md.get("i", ""))
	match kind:
		"pot":
			var st := String(x.get("state", "dry"))
			if st == "cracked":
				return out
			x["fpk"] = maxf(float(x.get("fpk", 0.0)), Ti)
			if smoke > 0.00005 and Ti > 300.0:
				x["smoke"] = clampf(float(x.get("smoke", 0.0)) + smoke * dt * 0.8 * encl, 0.0, 1.0)
			if st == "fired":
				_cook_contents(me, x, Ti, dt)
				return out
			if Ti > 550.0:
				x["ft"] = float(x.get("ft", 0.0)) + dt * clampf((Ti - 550.0) / 200.0, 0.0, 1.5)
			if float(x.get("ft", 0.0)) >= FIRE_S:
				if randf() < float(x.get("risk", 0.1)) * 0.5:
					_crack(me, "A pot cracked in the fire - its walls were too thin or uneven.")
					return out
				var x2 := x.duplicate(true)
				x2["state"] = "fired"
				var water := float(x2.get("vol", 0.25)) * float(x2.get("moist", 0.0))
				World.pools["atmo_water_l"] = float(World.pools.get("atmo_water_l", 0.0)) + water
				x2["moist"] = 0.0
				x2["fq"] = snappedf(clampf((float(x2["fpk"]) - 500.0) / 350.0, 0.3, 1.0), 0.01)
				x2["smoke"] = snappedf(float(x2.get("smoke", 0.0)), 0.01)
				World.update(int(me["id"]), {"x": x2})
				World.fx("complete", me["xf"].origin + Vector3(0, 0.1, 0), {"sound": "", "amount": 6})
				World.discover("first_fired_pot", _nearest_player(me["xf"].origin))
			elif st != Pottery.moisture_state(float(x.get("moist", 0.0))):
				var x3 := x.duplicate(true)
				x3["state"] = Pottery.moisture_state(float(x.get("moist", 0.0)))
				World.update(int(me["id"]), {"x": x3})
		"food":
			# how cooked it is lives on the thing lying in the fire, not in the item
			# itself, so roasted food picked up stacks with the rest
			var cook := float(md.get("ck", x.get("cook", 0.0))) + dt * clampf((Ti - 90.0) / 150.0, 0.0, 1.6) / COOK_S
			md["ck"] = cook
			var food := ItemDB.food(iid)
			var n := int(md.get("n", 1))
			if cook >= 1.0 and food.has("cooks_to"):
				var to := String(food["cooks_to"])
				out["atmo_c"] = n * (ItemDB.unit_mass(iid) - ItemDB.unit_mass(to))
				out["ash_n"] = n * maxf(0.0, ItemDB.nutrients(iid) - ItemDB.nutrients(to))
				var xc := x.duplicate()
				xc.erase("cook")
				World.update(int(me["id"]), {"i": to, "x": xc, "ck": cook})
			elif cook >= 2.6:
				var nu := n * ItemDB.nutrients(iid)
				var c := n * ItemDB.unit_mass(iid)
				out["ash_n"] = nu
				out["ash_c"] = minf(c, nu * ASH_C_PER_N)
				out["atmo_c"] = c - float(out["ash_c"])
				World.despawn(int(me["id"]))
				World.fx("smoke_puff", me["xf"].origin + Vector3(0, 0.1, 0))
				for pid in Net.players:
					var pp: Vector3 = Net.poses.get(pid, {}).get("p", Vector3.INF)
					if pp.distance_to(me["xf"].origin) < 10.0:
						World.notify(pid, "The %s burnt to a crisp." % ItemDB.display_name(iid).to_lower(), "warn")
	return out


static func _cook_contents(me: Dictionary, x: Dictionary, Ti: float, dt: float) -> void:
	## Grain simmered in water becomes porridge.
	var cont: Dictionary = x.get("contents", {})
	var seeds := int(cont.get("seed_grain", 0))
	var water := float(x.get("water", 0.0))
	if seeds < WaterActions.PORRIDGE_SEEDS or water < WaterActions.PORRIDGE_WATER or Ti < 95.0:
		return
	x["boil"] = float(x.get("boil", 0.0)) + dt
	if float(x["boil"]) < 600.0:
		return
	var portions := mini(seeds / WaterActions.PORRIDGE_SEEDS, int(water / WaterActions.PORRIDGE_WATER))
	var x2 := x.duplicate(true)
	var c2: Dictionary = x2.get("contents", {})
	c2["seed_grain"] = seeds - portions * WaterActions.PORRIDGE_SEEDS
	if int(c2["seed_grain"]) <= 0:
		c2.erase("seed_grain")
	c2["porridge"] = int(c2.get("porridge", 0)) + portions
	x2["contents"] = c2
	x2["water"] = water - portions * WaterActions.PORRIDGE_WATER
	x2["boil"] = 0.0
	World.pools["porridge_water_l"] = float(World.pools.get("porridge_water_l", 0.0)) + portions * WaterActions.PORRIDGE_WATER
	World.update(int(me["id"]), {"x": x2})
	World.discover("first_porridge", _nearest_player(me["xf"].origin))


static func _nearest_player(pos: Vector3) -> int:
	var best := 0
	var bd := INF
	for pid in Net.players:
		var pp: Vector3 = Net.poses.get(pid, {}).get("p", Vector3.INF)
		var dd := pp.distance_to(pos)
		if dd < bd:
			bd = dd
			best = pid
	return best


# ---------------------------------------------------------------------------
# Membership and surroundings
# ---------------------------------------------------------------------------

static func _gather(e: Dictionary, rt: Dictionary) -> void:
	var id := int(e["id"])
	var d: Dictionary = e["d"]
	var c: Vector3 = e["xf"].origin
	var r := float(d.get("r", 0.25))
	var join := maxf(0.5, r + JOIN_MARGIN)
	var members: Array = []
	var cen := Vector3.ZERO
	var nf := 0
	var top := 0.0
	for o in World.entities_near(c, join + 1.2, "item"):
		var od: Dictionary = o["d"]
		var op: Vector3 = o["xf"].origin
		var hd := Vector2(op.x - c.x, op.z - c.z).length()
		var other := int(od.get("site", -1))
		if other != -1 and other != id and World.has_entity(other):
			continue
		if hd > join or op.y < c.y - 0.45 or op.y > c.y + 1.2:
			if other == id:
				World.update(int(o["id"]), {"site": -1})
			continue
		members.append(int(o["id"]))
		if other != id:
			World.update(int(o["id"]), {"site": id})
			_hot.erase(int(o["id"]))
		if not _fuel_props(String(od.get("i", "")), od.get("x", {})).is_empty():
			cen += op
			nf += 1
			top = maxf(top, op.y - c.y + item_extent(String(od.get("i", "")), od.get("x", {})).y * 0.5)
	rt["members"] = members
	if nf > 0:
		cen /= nf
		var rmax := 0.0
		for mid in members:
			var me := World.get_entity(mid)
			if _fuel_props(String(me["d"].get("i", "")), me["d"].get("x", {})).is_empty():
				continue
			var op2: Vector3 = me["xf"].origin
			var ext := item_extent(String(me["d"].get("i", "")), me["d"].get("x", {}))
			rmax = maxf(rmax, Vector2(op2.x - cen.x, op2.z - cen.z).length() + ext.x * 0.8)
		var nr := clampf(rmax + 0.05, 0.2, 1.0)
		var nh := clampf(top, 0.06, 1.0)
		var changes := {}
		if absf(nr - r) > 0.03:
			changes["r"] = snappedf(nr, 0.01)
		if absf(nh - float(d.get("h", 0.1))) > 0.03:
			changes["h"] = snappedf(nh, 0.01)
		if not changes.is_empty():
			World.update(id, changes)
			rt["dirty"] = true
		# an uncovered fire follows its fuel
		var off := Vector2(cen.x - c.x, cen.z - c.z)
		if off.length() > 0.08 and float(d.get("shell_l", 0.0)) <= 0.0:
			var np := Vector3(cen.x, World.terrain.height(cen.x, cen.z), cen.z)
			World.set_xf(id, Transform3D(Basis(), np))
			rt["dirty"] = true


static func _enclosure(e: Dictionary, rt: Dictionary) -> void:
	## Look outward from the fuel bed: what blocks the way out, and how well
	## does it hold heat?  Combine that with the packed earth shell and vents.
	var d: Dictionary = e["d"]
	var gw = Game.game_world
	var space: PhysicsDirectSpaceState3D = gw.get_world_3d().direct_space_state
	var c: Vector3 = e["xf"].origin
	var r := float(d.get("r", 0.25))
	var hgt := float(d.get("h", 0.1))
	var origin := c + Vector3(0, 0.1 + hgt * 0.3, 0)
	var rr := dome_radii(d)
	var reach := rr.x + 0.4
	var exclude: Array[RID] = []
	for mid in rt["members"]:
		var me := World.get_entity(mid)
		if me.is_empty() or ItemDB.has_tag(String(me["d"].get("i", "")), "cover") or ItemDB.material(String(me["d"].get("i", ""))) == "stone":
			continue  # potsherds, earth and stones around a fire are its walls
		var v = gw.entities.view(mid) if gw.entities else null
		if v and v.get("body") and is_instance_valid(v.body):
			exclude.append(v.body.get_rid())
	var a_total := 0.0
	var a_block := 0.0
	var insul_acc := 0.0
	var open := 0.0
	var solids := 0.0
	for k in CELLS:
		var dir := cell_dir(k)
		var target := origin + Vector3(dir.x * reach, dir.y * maxf(rr.y + 0.3, 0.5), dir.z * reach)
		var q := PhysicsRayQueryParameters3D.create(origin, target, EntityView.LAYER_TERRAIN | EntityView.LAYER_STRUCT | EntityView.LAYER_ITEMS, exclude)
		var hit := space.intersect_ray(q)
		var rb := 0.0
		var ins := 0.0
		if not hit.is_empty():
			var cls := _classify(hit)
			rb = cls.x
			ins = cls.y
			if rb >= 0.7:
				solids += 1.0
		var cov := coverage(d, k)
		var b := maxf(rb, cov)
		if cov >= rb:
			# packed earth holds heat well, and a thick layer better still
			var thick := float(d.get("shell", [])[k]) / maxf(0.001, cell_full_l(k, d)) if k < d.get("shell", []).size() else 0.0
			ins = 0.85 + 0.1 * clampf((thick - 1.0) / 0.6, 0.0, 1.0)
		var area := cell_area(k, d)
		a_total += area
		a_block += area * b
		insul_acc += area * b * ins
		open += area * (1.0 - b) * (1.0 - b) * GAP_K
	open += d.get("vents", []).size() * VENT_A + LEAK_A
	var encl := a_block / maxf(a_total, 1e-6)
	rt["env"] = {"open_m2": open, "wall_m2": a_block, "bed_m2": PI * r * r, "insul": insul_acc / maxf(a_block, 1e-6),
		"encl": encl, "wall_mass_kg": float(d.get("shell_l", 0.0)) * 1.3 * 0.35 + solids * 0.6, "windward": 1.0 - encl}
	rt["sheltered"] = Shelter.roof_above(gw.get_world_3d(), c + Vector3(0, 0.6, 0), 5.0)
	var o2 := snappedf(open, 0.001)
	var e2 := snappedf(encl, 0.02)
	if absf(o2 - float(d.get("open", -1.0))) > 0.0005 or absf(e2 - float(d.get("encl", -1.0))) > 0.019:
		World.update(int(e["id"]), {"open": o2, "encl": e2})


static func _classify(hit: Dictionary) -> Vector2:
	## (how much it blocks, how well it holds heat)
	var col: Object = hit["collider"]
	if col.has_meta("eid"):
		var ent := World.get_entity(int(col.get_meta("eid")))
		if ent.is_empty():
			return Vector2.ZERO
		match String(ent["t"]):
			"item":
				var iid := String(ent["d"].get("i", ""))
				match ItemDB.material(iid):
					"stone":
						return Vector2(0.75, 0.5)
					"ceramic":
						return Vector2(0.8, 0.6)
					"soil":
						return Vector2(0.9, 0.85)
					_:
						return Vector2(0.35, 0.25)
			"outcrop", "boulder", "flat_stone":
				return Vector2(0.9, 0.5)
			"structure":
				return Vector2(0.6, 0.35)
			"tree", "mossy_log":
				return Vector2(0.5, 0.3)
			_:
				return Vector2(0.4, 0.3)
	return Vector2(1.0, 0.9)  # the ground itself: pit walls, a bank, a cliff


# ---------------------------------------------------------------------------
# What players see and hear (replicated through the site's data)
# ---------------------------------------------------------------------------

static func _feedback(e: Dictionary, rt: Dictionary, acc: Dictionary, lit: bool, real_dt: float) -> void:
	rt["vis_t"] = float(rt["vis_t"]) - real_dt
	if float(rt["vis_t"]) > 0.0:
		return
	rt["vis_t"] = 0.8
	var d: Dictionary = e["d"]
	var env: Dictionary = rt["env"]
	var encl := float(env.get("encl", 0.0))
	var heat := float(acc["heat_w"])
	var gas_w := float(acc["gas_burn"]) * FireModel.HEAT_GAS
	var char_w := float(acc["char_burn"]) * FireModel.HEAT_CHAR
	var smoke := float(acc["smoke"])
	var steam := float(acc["steam"])
	var flame := clampf(gas_w / 14000.0, 0.0, 1.0) * clampf(1.15 - encl, 0.0, 1.0)
	if gas_w > 100.0:
		flame = maxf(flame, 0.08 * clampf(1.15 - encl, 0.0, 1.0))
	var glow := clampf(char_w / 6000.0 + gas_w / 30000.0, 0.0, 1.0)
	var smoke_amt := clampf(smoke / 0.0006 + steam / 0.0009, 0.0, 1.0)
	var sc := 0.0
	if smoke + steam > 1e-6:
		sc = smoke / (smoke + steam)
	if lit and smoke_amt < 0.15 and heat > 300.0:
		sc = 2.0  # thin, clean, blue-grey
	var phase := _phase(d, lit, heat, encl, smoke, steam, char_w, float(rt["T"]), float(acc["pyro"]))
	var air := float(acc["air"]) / maxf(1e-9, float(acc["air_need"])) if float(acc["air_need"]) > 1e-9 else 1.0
	var T := int(rt["T"])
	var ch := {}
	var vals := {"T": T, "heat": snappedf(heat / 1000.0, 0.1), "flame": snappedf(flame, 0.02), "glow": snappedf(glow, 0.02),
		"smoke": snappedf(smoke_amt, 0.02), "sc": snappedf(sc, 0.05), "phase": phase, "air": snappedf(clampf(air, 0.0, 2.0), 0.05)}
	for k in vals:
		var old = d.get(k)
		var v = vals[k]
		if old == null or (v is String and v != old) or (not v is String and absf(float(v) - float(old)) > (12.0 if k == "T" else 0.019)):
			ch[k] = v
	if bool(d.get("lit", false)) != lit:
		ch["lit"] = lit
	if T > int(d.get("peak", 0)):
		ch["peak"] = T
	if not ch.is_empty():
		World.update(int(e["id"]), ch)


static func _phase(d: Dictionary, lit: bool, heat: float, encl: float, smoke: float, steam: float, char_w: float, T: float, pyro: float) -> String:
	if not lit:
		return "cooling" if T > 70.0 else ("ash" if float(d.get("ash_n", 0.0)) > 0.0005 else "cold")
	if encl > 0.85:
		if T > 600.0 and heat > 2500.0:
			return "roaring"
		if smoke + steam > 0.00025:
			return "steaming" if steam > smoke * 1.5 else "charring"
		if T < 200.0:
			return "smothered"
		return "finishing" if pyro < 0.00012 else "charring"
	if heat < 2500.0 and char_w < heat * 0.6:
		return "catching"
	if char_w > heat * 0.6:
		return "embers"
	return "flaming"


static func describe(d: Dictionary) -> String:
	## What a player can tell by looking at a site (no instruments - just signs).
	var phase := String(d.get("phase", "cold"))
	var covered := shell_coverage(d) > 0.6
	var vents: int = d.get("vents", []).size()
	var lines: PackedStringArray = []
	match phase:
		"catching":
			lines.append("Small flames are catching in the kindling.")
		"flaming":
			lines.append("A crackling fire, throwing out heat." if float(d.get("heat", 0.0)) > 6.0 else "A steady fire.")
		"embers":
			lines.append("Glowing embers - hot, with little flame.")
		"steaming":
			lines.append("Thick white steam: the wood is drying out.")
		"charring":
			if float(d.get("smoke", 0.0)) > 0.15:
				lines.append("Dense, yellow-gray smoke pours out: the wood is charring.")
			else:
				lines.append("Hot inside and charring steadily; thin smoke from the vents.")
		"finishing":
			lines.append("The smoke has thinned and turned blue. The wood is nearly all charcoal.")
		"roaring":
			lines.append("Roaring inside, and glowing at the gaps - too much air is getting in.")
		"smothered":
			lines.append("Barely smoking - the fire inside is starved of air.")
		"cooling":
			lines.append("Still hot. Give it time to cool.")
		"ash":
			lines.append("Cold ashes.")
		_:
			lines.append("A cold fire pit.")
	if covered:
		lines.append("Packed with earth%s." % ((", %d vent%s open" % [vents, "s" if vents != 1 else ""]) if vents > 0 else ", no vents"))
	elif float(d.get("encl", 0.0)) > 0.45:
		lines.append("Sheltered by what's around it.")
	if float(d.get("ash_n", 0.0)) >= 0.02 and float(d.get("ash_c", 0.0)) >= 0.05:
		lines.append("There's ash to scoop up.")
	return "\n".join(lines)


# ---------------------------------------------------------------------------
# Finishing, cooling and loose ends
# ---------------------------------------------------------------------------

static func _finish(e: Dictionary, rt: Dictionary) -> void:
	## The fire is out and cold: charcoal is charcoal, half-burnt wood is
	## charred wood, and untouched fuel is just fuel again.
	var id := int(e["id"])
	var d: Dictionary = e["d"]
	var char_pool := 0.0
	var nu_pool := 0.0
	var atmo_c := 0.0
	for mid in rt["members"]:
		var me := World.get_entity(mid)
		if me.is_empty():
			continue
		var md: Dictionary = me["d"]
		var iid := String(md.get("i", ""))
		var x: Dictionary = md.get("x", {})
		if not x.has("fm"):
			if float(md.get("heat", 15.0)) > 30.0:
				World.update(mid, {"heat": 15, "hot": false})
			continue
		var fm := float(x["fm"])
		var ch := float(x["ch"])
		var nu := float(x["nu"])
		var m0 := float(x.get("m0", fm + ch))
		var n := int(md.get("n", 1))
		if iid == "charred_wood" and not _unsettled(md):
			continue
		if iid == "charcoal" or fm <= 0.1 * m0:
			char_pool += fm + ch
			nu_pool += nu
			World.despawn(mid)
		elif iid != "charred_wood" and iid != "torch" and fm >= 0.97 * m0 and ch <= 0.01 * m0 and nu >= 0.999 * n * ItemDB.nutrients(iid):
			# barely touched: it's plain fuel again (the tiny difference is the air's)
			atmo_c -= n * ItemDB.unit_mass(iid) - fm - ch
			nu_pool += nu - n * ItemDB.nutrients(iid)
			var x2 := {"moist": float(x.get("moist", ItemDB.default_moist(iid)))}
			World.update(mid, {"x": x2, "heat": 15, "hot": false, "char": 0.0})
		else:
			var from := iid if iid != "charred_wood" else String(x.get("from", "firewood"))
			if from == "torch":
				from = "stick"
			World.update(mid, {"i": "charred_wood", "n": 1, "heat": 15, "hot": false, "char": snappedf(ch / maxf(fm + ch, 1e-6), 0.01),
				"x": {"fm": fm, "ch": ch, "nu": nu, "m0": m0, "from": from, "moist": float(x.get("moist", 0.1))}})
	var count := int(floor(char_pool / ItemDB.unit_mass("charcoal") + 1e-6))
	if count > 0:
		var a: Actions = World.actions
		var c: Vector3 = e["xf"].origin
		var left := count
		while left > 0:
			var k := mini(left, 30)
			a.spawn_item("charcoal", k, {}, c + Vector3(randf_range(-0.1, 0.1), 0.3, randf_range(-0.1, 0.1)))
			left -= k
	d["ash_c"] = float(d.get("ash_c", 0.0)) + char_pool - count * ItemDB.unit_mass("charcoal")
	d["ash_n"] = float(d.get("ash_n", 0.0)) + nu_pool
	World.pools["atmo_carbon_kg"] = float(World.pools.get("atmo_carbon_kg", 0.0)) + atmo_c
	rt["cold_s"] = 0.0
	rt["T"] = minf(float(rt["T"]), 40.0)
	World.update(id, {"lit": false, "phase": "ash" if float(d["ash_n"]) > 0.0005 else "cold", "flame": 0.0, "glow": 0.0, "smoke": 0.0,
		"ash_n": d["ash_n"], "ash_c": d["ash_c"]})
	if count > 0 and float(d.get("shell_l", 0.0)) <= 0.0:
		World.discover("first_charcoal", _nearest_player(e["xf"].origin))
	_maybe_remove(e)


static func _maybe_remove(e: Dictionary) -> void:
	var d: Dictionary = e["d"]
	if float(d.get("shell_l", 0.0)) > 0.0 or bool(d.get("lit", false)):
		return
	for o in World.entities_near(e["xf"].origin, 1.2, "item"):
		if int(o["d"].get("site", -1)) == int(e["id"]):
			return
	if float(d.get("ash_n", 0.0)) > 0.0005 or float(d.get("ash_c", 0.0)) > 0.002:
		return
	_dump_ash(e)
	_rt.erase(int(e["id"]))
	World.despawn(int(e["id"]))


static func _dump_ash(e: Dictionary) -> void:
	## Whatever ash is left goes into the soil where the fire was.
	var d: Dictionary = e["d"]
	var c: Vector3 = e["xf"].origin
	var cells := World.terrain.cells_in_radius(Vector2(c.x, c.z), 0.4)
	var an := float(d.get("ash_n", 0.0))
	if cells.size() > 0 and an > 0.0:
		for k in cells:
			World.terrain.nutr[k] += an / cells.size()
	elif an > 0.0:
		World.pools["lost_nutr"] = float(World.pools.get("lost_nutr", 0.0)) + an
	World.pools["soil_mineral_kg"] = float(World.pools.get("soil_mineral_kg", 0.0)) + float(d.get("ash_c", 0.0))
	d["ash_n"] = 0.0
	d["ash_c"] = 0.0


static func _leach(e: Dictionary, dt: float, rain: float) -> void:
	## Rain on an open ash bed washes the minerals into the soil.
	var d: Dictionary = e["d"]
	if rain < 0.15 or bool(d.get("lit", false)) or float(d.get("shell_l", 0.0)) > 0.0:
		return
	var an := float(d.get("ash_n", 0.0))
	var ac := float(d.get("ash_c", 0.0))
	if an + ac <= 0.0:
		_maybe_remove(e)
		return
	var f := clampf(rain * 0.1 * dt / 3600.0, 0.0, 1.0)
	var c: Vector3 = e["xf"].origin
	var cells := World.terrain.cells_in_radius(Vector2(c.x, c.z), 0.4)
	if cells.size() == 0:
		return
	for k in cells:
		World.terrain.nutr[k] += an * f / cells.size()
	World.pools["soil_mineral_kg"] = float(World.pools.get("soil_mineral_kg", 0.0)) + ac * f
	d["ash_n"] = an * (1.0 - f)
	d["ash_c"] = ac * (1.0 - f)
	if an * (1.0 - f) < 0.0005 and ac * (1.0 - f) < 0.002:
		_maybe_remove(e)


static func _sweep_loose(dt: float) -> void:
	## Something burning lying outside any fire starts one; hot things taken
	## out of a fire cool in the air.
	for e in World.entities_of("item"):
		var d: Dictionary = e["d"]
		var site := int(d.get("site", -1))
		if site != -1 and World.has_entity(site):
			continue
		var heat := float(d.get("heat", 15.0))
		if String(d.get("i", "")) == "torch" or (heat > 300.0 and not _fuel_props(String(d.get("i", "")), d.get("x", {})).is_empty()):
			var sid := site_at(e["xf"].origin)
			if sid == -1:
				sid = make_site(e["xf"].origin)
			World.update(int(e["id"]), {"site": sid, "heat": maxf(heat, 600.0)})
			continue
		if heat > 30.0:
			var T_amb := Climate.base_temp()
			var nt := T_amb + (heat - T_amb) * exp(-dt / 900.0)
			if absf(nt - heat) > 20.0 or nt < 40.0:
				World.update(int(e["id"]), {"heat": int(nt), "hot": nt > 70.0, "site": -1})
			else:
				d["heat"] = nt


static func _torches(dt: float) -> void:
	## Burning sticks carried around burn down.
	for pid in World.inventories:
		var inv: Inventory = World.inventories[pid]
		var changed := false
		for i in inv.slots.size():
			var s: Dictionary = inv.slots[i]
			if s.is_empty() or String(s["i"]) != "torch":
				continue
			var x: Dictionary = s["d"]
			var m0 := ItemDB.unit_mass("stick")
			var mass := float(x.get("mass", m0))
			var burn := mass / m0 - dt / (TORCH_HOURS * 3600.0)
			if burn <= 0.0:
				World.pools["atmo_carbon_kg"] = float(World.pools.get("atmo_carbon_kg", 0.0)) + mass
				var p: Vector3 = World.actions.player_pos(pid) if World.actions else Vector3.ZERO
				var cells := World.terrain.cells_in_radius(Vector2(p.x, p.z), 0.5)
				var nu := ItemDB.nutrients("stick")
				if cells.size() > 0:
					for k in cells:
						World.terrain.nutr[k] += nu / cells.size()
				else:
					World.pools["lost_nutr"] = float(World.pools.get("lost_nutr", 0.0)) + nu
				inv.slots[i] = {}
				World.notify(pid, "Your burning stick has burnt out.")
				changed = true
			else:
				var nm := burn * m0
				World.pools["atmo_carbon_kg"] = float(World.pools.get("atmo_carbon_kg", 0.0)) + (mass - nm)
				x["mass"] = nm
				if int(burn * 20.0) != int(mass / m0 * 20.0):
					changed = true
		if changed:
			World.mark_inventory(pid)


# ---------------------------------------------------------------------------
# API for actions and other systems
# ---------------------------------------------------------------------------

static func site_at(pos: Vector3, radius: float = 0.0) -> int:
	var best := -1
	var bd := INF
	for e in World.entities_of("site"):
		var c: Vector3 = e["xf"].origin
		var reach := maxf(0.5, float(e["d"].get("r", 0.25)) + JOIN_MARGIN) + radius
		var hd := Vector2(pos.x - c.x, pos.z - c.z).length()
		if hd <= reach and absf(pos.y - c.y) < 1.2 and hd < bd:
			bd = hd
			best = int(e["id"])
	return best


static func make_site(pos: Vector3) -> int:
	var g := Vector3(pos.x, World.terrain.height(pos.x, pos.z), pos.z)
	if g.y < pos.y - 0.5:
		g = pos  # on a structure or a stone: the fire sits where the fuel is
	var shell := []
	shell.resize(CELLS)
	shell.fill(0.0)
	return World.spawn("site", Transform3D(Basis(), g), {"r": 0.25, "h": 0.1, "T": int(Climate.base_temp()), "lit": false,
		"shell": shell, "vents": [], "shell_l": 0.0, "ash_n": 0.0, "ash_c": 0.0, "phase": "cold", "flame": 0.0, "glow": 0.0,
		"smoke": 0.0, "sc": 0.0, "encl": 0.0, "open": 0.5, "peak": 0})


static func ignite(item_eid: int, temp: float = 560.0) -> bool:
	## Light one item.  Whether the fire takes is up to the physics.
	var e := World.get_entity(item_eid)
	if e.is_empty() or e["t"] != "item":
		return false
	var d: Dictionary = e["d"]
	if _fuel_props(String(d.get("i", "")), d.get("x", {})).is_empty():
		return false
	var sid := int(d.get("site", -1))
	if sid == -1 or not World.has_entity(sid):
		sid = site_at(e["xf"].origin)
	if sid == -1:
		sid = make_site(e["xf"].origin)
	if not d.has("x") or not (d["x"] is Dictionary):
		d["x"] = {}
	_init_fuel(d)
	World.update(item_eid, {"site": sid, "heat": int(maxf(float(d.get("heat", 15.0)), temp)), "hot": true})
	var rt := _runtime(World.get_entity(sid))
	rt["T"] = maxf(float(rt["T"]), 260.0)
	rt["cold_s"] = 0.0
	rt["dirty"] = true
	World.fx("sparks", e["xf"].origin + Vector3(0, 0.05, 0), {"amount": 10})
	return true


static func heat_sources() -> Array:
	var out: Array = []
	for e in World.entities_of("site"):
		var d: Dictionary = e["d"]
		var kw := float(d.get("heat", 0.0))
		if kw <= 0.05 and int(d.get("T", 15)) < 80:
			continue
		var encl := float(d.get("encl", 0.0))
		var radiant := kw * (1.0 - encl * 0.85) * 1.5 + maxf(0.0, float(d.get("T", 15)) - 60.0) * 0.004 * encl
		out.append({"pos": e["xf"].origin + Vector3(0, 0.3, 0), "kw": radiant})
	return out


static func burn_at(pos: Vector3) -> float:
	var worst := 0.0
	for e in World.entities_of("site"):
		var d: Dictionary = e["d"]
		var flame := float(d.get("flame", 0.0))
		if flame < 0.06:
			continue
		var c: Vector3 = e["xf"].origin
		var hd := Vector2(pos.x - c.x, pos.z - c.z).length()
		if hd < float(d.get("r", 0.25)) * 0.9 and pos.y - c.y < 0.7 and pos.y - c.y > -0.5:
			worst = maxf(worst, 0.05 + flame * 0.08)
	return worst


static func douse(site_id: int, litres: float) -> void:
	## Water on a fire: it boils away, taking heat with it and soaking the fuel.
	var e := World.get_entity(site_id)
	if e.is_empty():
		return
	var rt := _runtime(e)
	var J := litres * 2.6e6
	var T := float(rt["T"])
	var used := 0.0
	var take := minf(J, maxf(0.0, T - 20.0) * 800.0)
	rt["T"] = T - take / 800.0
	used += take
	var pieces: Array = []
	for mid in rt["members"]:
		var me := World.get_entity(mid)
		if not me.is_empty() and float(me["d"].get("heat", 15.0)) > 100.0:
			pieces.append(me)
	for me in pieces:
		if used >= J:
			break
		var md: Dictionary = me["d"]
		var x: Dictionary = md.get("x", {})
		var m := float(x.get("fm", ItemDB.unit_mass(String(md.get("i", ""))))) + float(x.get("ch", 0.0))
		var Tp := float(md.get("heat", 15.0))
		var q := minf(J - used, (Tp - 40.0) * m * 1400.0)
		var nt := Tp - q / maxf(1.0, m * 1400.0)
		used += q
		if x.has("fm"):
			x["moist"] = float(x.get("moist", 0.0)) + litres / maxf(1.0, pieces.size()) * 0.3 / maxf(0.05, float(x["fm"]) + 0.05)
		if String(md.get("i", "")) == "pot" and Tp > 250.0 and randf() < 0.5:
			_crack(me, "Cold water on a hot pot - it cracked.")
		World.update(int(me["id"]), {"heat": int(nt), "hot": nt > 70.0})
	# whatever didn't boil soaks into the ground
	var boiled := minf(litres, used / 2.6e6)
	World.pools["atmo_water_l"] = float(World.pools.get("atmo_water_l", 0.0)) + boiled
	if litres - boiled > 0.0:
		WaterActions.soak(e["xf"].origin, litres - boiled, 0.4)
	World.fx("sizzle", e["xf"].origin + Vector3(0, 0.2, 0), {"amount": int(clampf(boiled * 30.0, 4.0, 20.0))})
	rt["vis_t"] = 0.0
