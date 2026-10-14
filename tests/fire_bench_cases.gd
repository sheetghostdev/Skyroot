class_name FireBench
extends RefCounted
## Reference fire arrangements and the outcomes the physics must produce.


static func camp() -> Dictionary:
	return {"open_m2": 0.6, "wall_m2": 0.0, "bed_m2": 0.25, "insul": 0.0, "encl": 0.0}


static func mound_open() -> Dictionary:
	return {"open_m2": 0.45, "wall_m2": 0.3, "bed_m2": 0.45, "insul": 0.5, "encl": 0.2}


static func vent(a: float) -> Dictionary:
	return {"open_m2": a, "wall_m2": 1.3, "insul": 0.85, "wall_mass_kg": 15.0, "encl": 0.95}


static func cases() -> Array:
	## [name, lay, conditions, hours, schedule, pots, expectation (Callable on result)]
	var T := FireModel.LAY_TINDER
	var TW := FireModel.LAY_TWIGS
	var TW2 := [2, 0.48, 10.0, 290.0, 0.12]
	var ST := FireModel.LAY_STICKS
	var ST6 := [6, 0.35, 4.0, 330.0, 0.2]
	var FW := FireModel.lay_firewood(3)
	var MOUND := [T, TW2, ST6, FireModel.lay_firewood(9, 0.2)]
	return [
		["tinder alone flares and dies", [T], camp(), 1.0, [], 0, func(r): return r["wood_left"] < 0.01 and r["end"] < 200.0],
		["an ember can't light firewood", [[1, 0.07, 30.0, 230.0, 0.08], FW], camp(), 2.0, [], 0, func(r): return r["wood_frac"] > 0.9],
		["tinder can't light firewood", [T, FW], camp(), 2.0, [], 0, func(r): return r["wood_frac"] > 0.85],
		["tinder, kindling, sticks, firewood: a campfire", [T, TW, ST, FW], camp(), 4.0, [], 0,
			func(r): return r["peak"] > 650.0 and r["h600"] > 0.8 and r["wood_frac"] < 0.15 and r["char_frac"] < 0.05],
		["green firewood still catches from a good start", [T, TW, ST, FireModel.lay_firewood(3, 0.38)], camp(), 4.0, [], 0,
			func(r): return r["peak"] > 600.0 and r["wood_frac"] < 0.2],
		["covered pit fires pottery", [T, TW, ST, FireModel.lay_firewood(6)],
			{"open_m2": 0.2, "wall_m2": 0.6, "bed_m2": 0.3, "insul": 0.6, "wall_mass_kg": 2.5, "encl": 0.7}, 5.0, [], 3,
			func(r): return r["pot_peak"] > 700.0 and r["pot_h600"] > 0.5],
		["vented mound, sealed when done: charcoal", MOUND, mound_open(), 10.0, [[0.5, vent(0.008)], [5.5, vent(0.0005)]], 0,
			func(r): return r["char_frac"] > 0.15],
		["fully sealed too early: smothered", MOUND, mound_open(), 10.0, [[0.5, vent(0.0005)]], 0,
			func(r): return r["wood_frac"] > 0.4 and r["char_frac"] < 0.12],
		["mound with gaping holes: ash", MOUND, mound_open(), 10.0, [[0.5, vent(0.05)]], 0,
			func(r): return r["char_frac"] < 0.03],
		["mound opened while hot: the charcoal burns", MOUND, mound_open(), 10.0, [[0.5, vent(0.008)], [3.0, mound_open()]], 0,
			func(r): return r["char_frac"] < 0.05],
		["open heap: ash", MOUND, {"open_m2": 0.9, "wall_m2": 0.0, "bed_m2": 0.45, "insul": 0.0}, 12.0, [], 0,
			func(r): return r["char_frac"] < 0.03],
		["covered at once: never gets going", MOUND, vent(0.0005), 6.0, [], 0, func(r): return r["wood_frac"] > 0.9],
	]


static func run_all() -> Array:
	var out := []
	for c in cases():
		var r := FireModel.bench(c[1], c[2], c[3], c[4], c[5])
		var ok: bool = (c[6] as Callable).call(r)
		out.append("%s %s  peak %d  end %d  char %.0f%%  wood left %.0f%%  >600C %.1fh%s" % ["ok  " if ok else "FAIL", c[0],
			int(r["peak"]), int(r["end"]), float(r["char_frac"]) * 100.0, float(r["wood_frac"]) * 100.0, float(r["h600"]),
			("  pot %dC %.1fh" % [int(r["pot_peak"]), float(r["pot_h600"])]) if c[5] > 0 else ""])
	return out
