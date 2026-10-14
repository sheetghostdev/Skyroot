class_name CompostSim
extends RefCounted
## Compost heaps (host).  Organic matter rots at a rate set by the mix of
## greens and browns, moisture, air and the heat the heap makes for itself.
## About half of what rots leaves as carbon dioxide and vapour into the
## island's air (where plants and the tree take it back up); the rest becomes
## finished compost.  Every nutrient stays in the heap.
##
## Heap data: g/b = green/brown material still rotting (kg), gw/bw = the part
## of that which is the material's own moisture, hu = finished compost (kg),
## nu = nutrients, w = free water (L), air 0..1, T = heap temperature (C),
## act = how hard it is working (0..1, for display).

const STEP_H := 0.2               # simulate in steps of this many game hours
const K_GREEN := 0.06             # fraction of greens that rots per hour at best
const K_BROWN := 0.04
const HUMUS_YIELD := 0.45         # of the mass that rots, what stays as compost
const SPACING := 1.5
const GREEN_MOIST := 0.7          # default moisture of greens / browns without their own value
const BROWN_MOIST := 0.12
const TURN_AIR_HANDS := 0.2
const TURN_AIR_TOOL := 0.34
const WATER_MAX_L := 6.0

static var _acc := 0.0


static func reset() -> void:
	_acc = 0.0


# ---------------------------------------------------------------------------
# What goes in
# ---------------------------------------------------------------------------

static func kind_of(id: String) -> String:
	## "green", "brown" or "" (not compostable).
	if not ItemDB.exists(id):
		return ""
	var compostable := ItemDB.has_tag(id, "compostable") or (ItemDB.is_organic(id) and (ItemDB.has_tag(id, "green") or ItemDB.has_tag(id, "brown")))
	if not compostable:
		return ""
	if ItemDB.has_tag(id, "brown"):
		return "brown"
	if ItemDB.has_tag(id, "green"):
		return "green"
	return "green" if ItemDB.default_moist(id) > 0.4 else "brown"


static func is_compostable(id: String) -> bool:
	return kind_of(id) != ""


static func unit_nutr() -> float:
	return ItemDB.nutrients("compost")


static func unit_kg() -> float:
	return ItemDB.unit_mass("compost")


# ---------------------------------------------------------------------------
# Readings
# ---------------------------------------------------------------------------

static func raw(d: Dictionary) -> float:
	return float(d.get("g", 0.0)) + float(d.get("b", 0.0))


static func mass(d: Dictionary) -> float:
	return raw(d) + float(d.get("hu", 0.0))


static func wetness(d: Dictionary) -> float:
	## Fraction of the heap's wet weight that is water (a wrung-out sponge is ~0.5).
	var w := float(d.get("w", 0.0))
	var inner := float(d.get("gw", 0.0)) + float(d.get("bw", 0.0)) + float(d.get("hu", 0.0)) * 0.25
	return (w + inner) / maxf(0.05, w + mass(d))


static func browns(d: Dictionary) -> float:
	## Share of browns in the material that is still rotting (0..1).
	var r := raw(d)
	return float(d.get("b", 0.0)) / r if r > 0.001 else 0.5


static func radius(d: Dictionary) -> float:
	return clampf(0.28 + 0.16 * sqrt(mass(d) + float(d.get("w", 0.0)) * 0.3), 0.3, 0.95)


static func ready_count(d: Dictionary) -> int:
	var by_mass := int(floor(float(d.get("hu", 0.0)) / unit_kg() + 1e-6))
	var by_nutr := int(floor(float(d.get("nu", 0.0)) / maxf(unit_nutr(), 1e-9) + 1e-6))
	return maxi(0, mini(by_mass, by_nutr))


static func factors(d: Dictionary) -> Dictionary:
	var W := wetness(d)
	var fm := 1.0
	if W < 0.12:
		fm = 0.05
	elif W < 0.4:
		fm = lerpf(0.05, 1.0, (W - 0.12) / 0.28)
	elif W > 0.85:
		fm = 0.35
	elif W > 0.65:
		fm = lerpf(1.0, 0.35, (W - 0.65) / 0.2)
	var air := float(d.get("air", 1.0))
	var fa := 0.25 + 0.75 * smoothstep(0.05, 0.5, air)
	var B := browns(d)
	var fb := 1.0
	if B < 0.35:
		fb = lerpf(0.55, 1.0, B / 0.35)
	elif B > 0.7:
		fb = lerpf(1.0, 0.2, (B - 0.7) / 0.3)
	return {"wet": W, "fm": fm, "fa": fa, "fb": fb, "browns": B, "air": air, "act": fm * fa * fb}


# ---------------------------------------------------------------------------
# Simulation
# ---------------------------------------------------------------------------

static func tick(hours: float) -> void:
	if not World.is_host():
		return
	_acc += hours
	if _acc < STEP_H:
		return
	var dt := _acc
	_acc = 0.0
	var ambient := Climate.base_temp()
	var sun := 0.0 if World.is_night() else 1.0 - float(World.env.get("cloud", 0.0)) * 0.6
	for e in World.entities_of("compost"):
		_step(e, dt, ambient, sun)


static func _step(e: Dictionary, dt: float, ambient: float, sun: float) -> void:
	var d: Dictionary = e["d"]
	var f := factors(d)
	var act: float = f["act"]
	var m := mass(d)
	var size := smoothstep(0.8, 3.0, m)
	var T := float(d.get("T", ambient))
	# a working heap heats itself; a small one can't hold the heat
	var target := ambient + 48.0 * act * size
	T += (target - T) * (1.0 - exp(-dt / 2.5))
	var fT := clampf(0.45 + 0.55 * (T - 5.0) / 45.0, 0.3, 1.0)
	if T > 62.0:
		fT *= 0.8
	var g := float(d.get("g", 0.0))
	var b := float(d.get("b", 0.0))
	var dg := g * (1.0 - exp(-K_GREEN * act * fT * dt))
	var db := b * (1.0 - exp(-K_BROWN * act * fT * dt))
	var out := {}
	if dg + db > 0.0:
		if g > 0.0:
			out["gw"] = float(d.get("gw", 0.0)) * (1.0 - dg / g)
		if b > 0.0:
			out["bw"] = float(d.get("bw", 0.0)) * (1.0 - db / b)
		out["g"] = g - dg
		out["b"] = b - db
		out["hu"] = float(d.get("hu", 0.0)) + (dg + db) * HUMUS_YIELD
		World.pools["atmo_carbon_kg"] = float(World.pools.get("atmo_carbon_kg", 0.0)) + (dg + db) * (1.0 - HUMUS_YIELD)
	# the microbes use the air up - faster in a soggy, all-green heap; small heaps breathe
	var W: float = f["wet"]
	var use := 0.05 * act * fT + 0.12 * maxf(0.0, W - 0.65) + 0.06 * maxf(0.0, 0.35 - float(f["browns"]))
	var air := float(d.get("air", 1.0))
	air -= use * dt
	air += (1.0 - air) * 0.03 * (1.0 - size) * dt
	out["air"] = clampf(air, 0.0, 1.0)
	# warm heaps steam their water away
	var w := float(d.get("w", 0.0))
	if w > 0.0:
		var r := radius(d)
		var area := PI * r * r
		var evap := minf(w, (0.002 + 0.006 * maxf(0.0, T - ambient) / 30.0 + 0.002 * sun) * area * dt)
		out["w"] = w - evap
		World.pools["atmo_water_l"] = float(World.pools.get("atmo_water_l", 0.0)) + evap
	out["T"] = snappedf(T, 0.01)
	out["act"] = snappedf(act * fT, 0.001)
	var id := int(e["id"])
	var before := ready_count(d)
	World.update(id, out)
	if ready_count(World.get_entity(id)["d"]) > before and before == 0:
		_notify_ready(e["xf"].origin)


static func _notify_ready(pos: Vector3) -> void:
	for pid in Net.players:
		var pp: Vector3 = Net.poses.get(pid, {}).get("p", Vector3.INF)
		if pp.distance_to(pos) < 12.0:
			World.hint_to(pid, "compost_ready")


static func rain_catch(depth_mm: float) -> float:
	## Uncovered heaps soak up their share of the rain.  Returns litres caught.
	var caught := 0.0
	for e in World.entities_of("compost"):
		var d: Dictionary = e["d"]
		if DryingSim._sheltered(e["xf"].origin):
			continue
		var r := radius(d)
		var c := clampf(PI * r * r * depth_mm, 0.0, maxf(0.0, WATER_MAX_L - float(d.get("w", 0.0))))
		if c > 0.0:
			d["w"] = float(d.get("w", 0.0)) + c   # bookkeeping in place; replicated on the next step
			caught += c
	return caught


# ---------------------------------------------------------------------------
# Words for what the heap is doing
# ---------------------------------------------------------------------------

static func describe(d: Dictionary) -> String:
	var f := factors(d)
	var lines: PackedStringArray = []
	var T := float(d.get("T", 15.0))
	var m := mass(d)
	var temp_word := "cold"
	if T > 50.0:
		temp_word = "hot and steaming"
	elif T > 35.0:
		temp_word = "warm"
	elif T > 22.0:
		temp_word = "barely warm"
	lines.append("%.1f kg, %s (%d °C)." % [m, temp_word, int(round(T))])
	var B: float = f["browns"]
	var W: float = f["wet"]
	var air: float = f["air"]
	var mix := "a good mix of greens and browns"
	if raw(d) < 0.01:
		mix = "nothing left to rot"
	elif B < 0.35:
		mix = "mostly greens"
	elif B > 0.7:
		mix = "mostly browns"
	var wet := "damp"
	if W < 0.25:
		wet = "dry"
	elif W > 0.75:
		wet = "soggy"
	elif W > 0.65:
		wet = "wet"
	var air_word := "fresh"
	if air < 0.15:
		air_word = "sour and airless"
	elif air < 0.4:
		air_word = "stale"
	lines.append("Mix: %s. Moisture: %s. Air: %s." % [mix, wet, air_word])
	var n := ready_count(d)
	if n > 0:
		lines.append("Finished compost ready: %d." % n)
	elif float(d.get("hu", 0.0)) > 0.05:
		lines.append("Some compost has formed (%d%% of a basket)." % int(clampf(float(d.get("hu", 0.0)) / unit_kg(), 0.0, 0.99) * 100.0))
	var advice := advise(d, f)
	if advice != "":
		lines.append(advice)
	return "\n".join(lines)


static func advise(d: Dictionary, f: Dictionary) -> String:
	if raw(d) < 0.01:
		return "Add more greens and browns to keep it going, or spread what's left."
	if float(f["air"]) < 0.25:
		return "It needs air: turn it."
	if float(f["wet"]) < 0.25:
		return "Too dry to rot: water it, or add greens."
	if float(f["wet"]) > 0.75:
		return "Too wet: add browns (straw, fiber) and turn it."
	if float(f["browns"]) < 0.3:
		return "Too many greens: add browns (straw, fiber)."
	if float(f["browns"]) > 0.75:
		return "Too many browns: add greens (fresh grass, leaves, scraps)."
	if mass(d) < 2.0:
		return "A bigger heap holds its heat and works faster."
	return ""
