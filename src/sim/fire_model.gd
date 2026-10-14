class_name FireModel
extends RefCounted
## The physics of a process site, independent of the world.
##
## A fuel bed at temperature T draws air through whatever openings the
## surroundings leave.  Air lets wood burn (heat, CO2, ash).  Heat without
## enough air drives pyrolysis: wood breaks down into charcoal and smoky
## volatiles, which burn too if any air is left.  Charcoal itself burns when
## air reaches it.  Heat is lost with the hot gases leaving, by radiation
## through the openings and by conduction through earth walls.
##
## So the same rules give an open campfire (ash), a covered pit (hot enough
## to fire pottery) and a sealed mound (charcoal) - depending only on how the
## players arranged things.

const AIR_PER_KG_WOOD := 6.0      # kg of air to burn 1 kg of dry wood
const AIR_PER_KG_CHAR := 11.0
const AIR_PER_KG_VOL := 5.0
const HEAT_WOOD := 15.0e6          # J/kg
const HEAT_CHAR := 29.0e6
const HEAT_VOL := 14.0e6
const CHAR_YIELD := 0.32           # kg charcoal per kg wood pyrolysed
const CP_AIR := 1005.0
const SIGMA := 5.67e-8
const BURN_K := 0.00042            # 1/s: fraction of a fuel's mass burnable per second at full heat
const PYRO_K := 0.00034            # 1/s at 500 C
const CHAR_BURN_K := 0.0005


static func step(s: Dictionary, p: Dictionary, dt: float) -> Dictionary:
	## Advance the state `s` by dt game-seconds.
	## s: {T, wood: [[mass_kg, rate, ign_C, moist], ...], char_kg}
	## p: {open_m2, wall_m2, ground_m2, wind, T_amb, insul, extra_mass_kg}
	## Returns per-step totals: burned_wood, pyro_wood, char_made, char_burned, vol_burned, vol_smoke, heat_w
	var T: float = s["T"]
	var T_amb: float = p.get("T_amb", 15.0)
	var dT := maxf(0.0, T - T_amb)
	var open_m2: float = p["open_m2"]
	var wind: float = p.get("wind", 1.0)
	# draft through openings: warm gas rises, wind pushes
	var v := 0.035 + 0.055 * sqrt(dT / 100.0) + 0.03 * wind * p.get("windward", 0.3)
	var air_pot := open_m2 * v * 1.2  # kg/s of air that can get in
	var openness := clampf(open_m2 / maxf(0.05, p.get("bed_m2", 0.3)), 0.0, 1.0)
	var excess := lerpf(1.25, 2.6, openness)
	# what the fuel could do at this temperature
	var burn_max := 0.0
	var pyro_rate := 0.0
	var wood: Array = s["wood"]
	var moist_heat := 0.0
	for w in wood:
		var m: float = w[0]
		if m <= 0.0:
			continue
		var f := clampf((T - float(w[2])) / 250.0, 0.0, 1.0)
		burn_max += m * BURN_K * float(w[1]) * f
		if T > 270.0:
			pyro_rate += m * PYRO_K * clampf((T - 270.0) / 230.0, 0.0, 1.8)
		moist_heat += m * float(w[3])
	var char_kg: float = s.get("char_kg", 0.0)
	var char_max := char_kg * CHAR_BURN_K * clampf((T - 360.0) / 200.0, 0.0, 1.2)
	# air allocation: wood first, then charcoal, then volatiles
	var air_want := burn_max * AIR_PER_KG_WOOD * excess
	var air := minf(air_pot, air_want + char_max * AIR_PER_KG_CHAR * excess + pyro_rate * (1.0 - CHAR_YIELD) * AIR_PER_KG_VOL)
	var air_left := air
	var burn := minf(burn_max, air_left / (AIR_PER_KG_WOOD * excess))
	air_left -= burn * AIR_PER_KG_WOOD * excess
	var char_burn := minf(char_max, maxf(0.0, air_left) / (AIR_PER_KG_CHAR * excess))
	air_left -= char_burn * AIR_PER_KG_CHAR * excess
	var vol := pyro_rate * (1.0 - CHAR_YIELD)
	var vol_burn := minf(vol, maxf(0.0, air_left) / AIR_PER_KG_VOL)
	var vol_smoke := vol - vol_burn
	# wet fuel spends heat boiling off water
	var total_wood := 0.0
	for w in wood:
		total_wood += maxf(0.0, w[0])
	var avg_moist := moist_heat / maxf(total_wood, 0.001)
	var heat := burn * HEAT_WOOD * (1.0 - clampf(avg_moist * 1.6, 0.0, 0.75)) + char_burn * HEAT_CHAR + vol_burn * HEAT_VOL
	# losses
	var flue := air * CP_AIR * dT
	var Tk := T + 273.15
	var Ta := T_amb + 273.15
	var rad := 0.6 * SIGMA * (Tk * Tk * Tk * Tk - Ta * Ta * Ta * Ta) * minf(open_m2, p.get("bed_m2", 0.3)) * 0.8
	var cond := dT * (p.get("wall_m2", 0.0) * lerpf(9.0, 2.2, p.get("insul", 0.5)) + p.get("ground_m2", 0.3) * 4.0)
	var loss := flue + rad + cond
	var mass := total_wood + char_kg + p.get("extra_mass_kg", 0.0)
	var C := 1400.0 * mass + 6000.0
	T = clampf(T + (heat - loss) / C * dt, T_amb, 1350.0)
	# apply mass changes proportionally across fuel pieces
	var out := {"burned_wood": 0.0, "pyro_wood": 0.0, "char_made": 0.0, "char_burned": 0.0,
		"vol_burned": vol_burn * dt, "vol_smoke": vol_smoke * dt, "heat_w": heat, "air": air, "flue_w": flue}
	if burn_max > 0.0 or pyro_rate > 0.0:
		var burn_frac := burn / maxf(burn_max, 1e-12)
		for w in wood:
			var m: float = w[0]
			if m <= 0.0:
				continue
			var f := clampf((T - float(w[2])) / 250.0, 0.0, 1.0)
			var b := minf(m, m * BURN_K * float(w[1]) * f * burn_frac * dt)
			var pr := 0.0
			if T > 270.0:
				pr = minf(m - b, m * PYRO_K * clampf((T - 270.0) / 230.0, 0.0, 1.8) * dt)
			w[0] = m - b - pr
			w[3] = maxf(0.0, float(w[3]) - (b + pr) * 2.0 / maxf(m, 0.001) * float(w[3]))
			out["burned_wood"] += b
			out["pyro_wood"] += pr
	out["char_made"] = out["pyro_wood"] * CHAR_YIELD
	var cb := minf(char_kg + out["char_made"], char_burn * dt)
	out["char_burned"] = cb
	s["char_kg"] = char_kg + out["char_made"] - cb
	s["T"] = T
	return out


# ---------------------------------------------------------------------------
# Calibration bench (used by tests): run a scenario and summarise it
# ---------------------------------------------------------------------------

static func bench(name: String, wood_kg: float, piece_kg: float, rate: float, p: Dictionary, hours: float, ignite_T: float = 450.0,
		open_after_h: float = -1.0, open_m2_after: float = 0.0, seal_after_h: float = -1.0, seal_m2: float = 0.0) -> Dictionary:
	var s := {"T": ignite_T, "wood": [], "char_kg": 0.0}
	var n := int(ceil(wood_kg / piece_kg))
	for i in n:
		s["wood"].append([wood_kg / n, rate, 380.0, 0.15])
	# a little tinder and kindling to get going
	s["wood"].append([0.3, 4.0, 230.0, 0.1])
	s["wood"].append([0.6, 2.4, 300.0, 0.12])
	var dt := 5.0
	var t := 0.0
	var peak := 0.0
	var time_above_600 := 0.0
	var totals := {"burned_wood": 0.0, "pyro_wood": 0.0, "char_made": 0.0, "char_burned": 0.0, "vol_smoke": 0.0}
	var pp := p.duplicate()
	while t < hours * 3600.0:
		if seal_after_h >= 0.0 and t >= seal_after_h * 3600.0:
			pp["open_m2"] = seal_m2
		if open_after_h >= 0.0 and t >= open_after_h * 3600.0:
			pp["open_m2"] = open_m2_after
		var r := step(s, pp, dt)
		for k in totals:
			totals[k] += float(r.get(k, 0.0))
		peak = maxf(peak, float(s["T"]))
		if float(s["T"]) > 600.0:
			time_above_600 += dt
		t += dt
	var left := 0.0
	for w in s["wood"]:
		left += float(w[0])
	return {"name": name, "peak_C": int(peak), "end_C": int(s["T"]), "charcoal_kg": snappedf(float(s["char_kg"]), 0.01),
		"wood_left_kg": snappedf(left, 0.01), "burned_kg": snappedf(totals["burned_wood"], 0.01),
		"pyrolysed_kg": snappedf(totals["pyro_wood"], 0.01), "hours_above_600": snappedf(time_above_600 / 3600.0, 0.01),
		"smoke_kg": snappedf(totals["vol_smoke"], 0.01)}
