class_name FireModel
extends RefCounted
## The physics of a process site, independent of the world.
##
## Every piece of fuel - and every pot, stone or tuber sitting in the fire -
## has its own temperature.  A hot piece loses its water (steam), then breaks
## down (pyrolysis) into charcoal and combustible gases.  Air arriving through
## the openings burns those gases first - the flames - and whatever air is left
## reaches the glowing charcoal.  Part of a burning piece's heat stays with it;
## the rest feeds the flames, which reach the finest fuel first and engulf more
## of the pile as they grow - so a fire climbs from tinder to kindling to logs,
## and a log alone with an ember goes nowhere.  The bed temperature T is the
## hot gas around the fuel: it loses heat up the flue, by radiation through the
## openings and by conduction into the ground and any earth walls.
##
## One set of rules gives an open campfire (everything burns: ash), a covered
## pit (hot and long: fires pottery) and an earth mound with small vents (air
## only for the gases: the charcoal survives) - depending only on how players
## arranged things.
##
## A fuel piece is an Array:
##   [0] wood kg  [1] burn speed (firewood = 1)  [2] ignition C  [3] water kg per kg wood
##   [4] charcoal kg  [5] temperature C
##   [6] out: charcoal burned  [7] out: gases released  [8] out: water boiled off
## An inert piece (pot, stone, food) is [mass kg, size factor, temperature C, specific heat J/kgK].
## Outputs accumulate across calls; callers reset them.

const AIR_PER_KG_GAS := 4.5        # kg air to burn 1 kg of wood gases
const AIR_PER_KG_CHAR := 11.5
const HEAT_GAS := 11.0e6           # J/kg
const HEAT_CHAR := 29.0e6
const PYRO_HEAT := 0.35e6          # J/kg of wood broken down
const EVAP_HEAT := 2.4e6           # J/kg of water boiled off
const CP_WOOD := 1400.0
const CP_WATER := 4190.0
const CP_AIR := 1005.0
const SIGMA := 5.67e-8
const PYRO_K := 0.000127           # 1/s for firewood at full heat (~2 game hours)
const CHAR_K := 0.0003
const CHAR_T0 := 380.0             # charcoal glows hot above this
const EMBER := 0.06                # ...and smoulders a little below it
const EVAP_K := 0.0016
const HEAT_K := 10.0               # W per kg per K: how fast flames can heat a piece
const COOL_K := 2.5                # W per kg per K: how fast a hot piece cools
const SELF_HEAT := 0.25            # share of a burning piece's heat that stays in it
const FLAME_SHARE := 0.85          # share of the flames' heat that reaches fuel
const FLAME_REACH_W := 2500.0      # watts of flame per kg of fuel engulfed
const PILE_KEEP := 0.75            # a burning pile keeps its pieces hot...
const PILE_KG := 2.5               # ...once this much of it is alight
const IN_FLAME := 0.8
const BED_C := 800.0               # J/K of the bed gas and ground surface
const T_PIECE_MAX := 1050.0

const W_MASS := 0
const W_RATE := 1
const W_IGN := 2
const W_MOIST := 3
const W_CHAR := 4
const W_T := 5
const O_CHAR_BURNED := 6
const O_GAS := 7
const O_STEAM := 8


static func piece(mass: float, rate: float, ign: float, moist: float, char_kg: float = 0.0, temp: float = 15.0) -> Array:
	return [mass, rate, ign, moist, char_kg, temp, 0.0, 0.0, 0.0]


static func char_yield(T: float) -> float:
	## Slow, cool charring keeps more of the carbon.
	return lerpf(0.36, 0.22, clampf((T - 350.0) / 450.0, 0.0, 1.0))


static func step(s: Dictionary, p: Dictionary, dt: float) -> Dictionary:
	## Advance state s = {T, pieces, inert} by dt seconds under conditions p:
	##   open_m2   effective area of the openings
	##   bed_m2    footprint of the fuel bed
	##   wall_m2   area of walls/cover around the fuel; insul 0..1 how well they hold heat
	##   encl      0..1 how enclosed the fuel is (hot walls keep it hot)
	##   wall_mass_kg  earth/stone warmed along with the bed
	##   wind, windward, T_amb, extra_loss_w (rain)
	## Returns this step's rates (kg/s, W) for feedback.
	var T: float = s["T"]
	var T_amb := float(p.get("T_amb", 15.0))
	var dT := maxf(0.0, T - T_amb)
	var open_m2 := float(p.get("open_m2", 0.5))
	var bed_m2 := maxf(0.03, float(p.get("bed_m2", 0.25)))
	var encl := float(p.get("encl", 0.0))
	var v: float = 0.04 + 0.06 * sqrt(dT / 100.0) + 0.03 * float(p.get("wind", 1.0)) * float(p.get("windward", 0.3))
	var air_pot: float = open_m2 * v * 1.2
	var excess := lerpf(1.15, 2.4, clampf(open_m2 / bed_m2, 0.0, 1.0))
	var pieces: Array = s["pieces"]
	var n := pieces.size()
	var pyro := PackedFloat64Array()
	var evap := PackedFloat64Array()
	var cmax := PackedFloat64Array()
	var gas_i := PackedFloat64Array()
	pyro.resize(n)
	evap.resize(n)
	cmax.resize(n)
	gas_i.resize(n)
	var gas := 0.0
	var cmax_sum := 0.0
	var evap_sum := 0.0
	var pyro_sum := 0.0
	var hot_mass := 0.0
	for i in n:
		var w: Array = pieces[i]
		var m: float = w[W_MASS]
		var rate: float = w[W_RATE]
		var moist: float = w[W_MOIST]
		var ch: float = w[W_CHAR]
		var Tp: float = w[W_T]
		if m > 0.0:
			if moist > 0.0 and Tp > 70.0:
				evap[i] = m * moist * EVAP_K * pow(rate, 0.6) * clampf((Tp - 70.0) / 120.0, 0.0, 2.0)
			var g := clampf((Tp - (float(w[W_IGN]) - 100.0)) / 200.0, 0.0, 1.4)
			var dry := clampf(1.25 - moist * 3.0, 0.2, 1.0)
			pyro[i] = m * PYRO_K * rate * g * dry
			gas_i[i] = pyro[i] * (1.0 - char_yield(Tp))
		if ch > 0.0 and Tp > 200.0:
			cmax[i] = ch * CHAR_K * sqrt(rate) * (clampf((Tp - CHAR_T0) / 250.0, 0.0, 1.6) + EMBER)
		if Tp > 250.0:
			hot_mass += m + ch
		gas += gas_i[i]
		cmax_sum += cmax[i]
		evap_sum += evap[i]
		pyro_sum += pyro[i]
	# air: the gases burn first (they meet the incoming air), then the charcoal
	var want := (gas * AIR_PER_KG_GAS + cmax_sum * AIR_PER_KG_CHAR) * excess
	var air := minf(air_pot, want)
	var react := air / excess
	var gas_burn := minf(gas, react / AIR_PER_KG_GAS)
	react = maxf(0.0, react - gas_burn * AIR_PER_KG_GAS)
	var char_burn := minf(cmax_sum, react / AIR_PER_KG_CHAR)
	var gf := gas_burn / gas if gas > 0.0 else 0.0
	var cf := char_burn / cmax_sum if cmax_sum > 0.0 else 0.0
	var heat := gas_burn * HEAT_GAS + char_burn * HEAT_CHAR
	var shared := heat * (1.0 - SELF_HEAT)
	var T_flame := maxf(T, T_amb + 900.0 * clampf(heat / 3000.0, 0.0, 1.0)) if heat > 200.0 else T
	# the flames reach the finest fuel first; a bigger fire engulfs more of the pile
	var reach := maxf(0.3, heat / FLAME_REACH_W)
	var order: Array = range(n)
	order.sort_custom(func(a, b): return float(pieces[a][W_RATE]) > float(pieces[b][W_RATE]))
	var contact := PackedFloat64Array()
	contact.resize(n)
	var acc := 0.0
	for i in order:
		var mm: float = float(pieces[i][W_MASS]) + float(pieces[i][W_CHAR])
		if mm <= 1e-6:
			continue
		contact[i] = clampf((reach - acc) / mm, 0.1, 1.0)
		acc += mm
	var wt := PackedFloat64Array()
	var capw := PackedFloat64Array()
	wt.resize(n)
	capw.resize(n)
	var wsum := 0.0
	for i in n:
		var w: Array = pieces[i]
		var Tp: float = w[W_T]
		if T_flame > Tp:
			var mm: float = float(w[W_MASS]) + float(w[W_CHAR])
			wt[i] = pow(float(w[W_RATE]), 1.5) * mm * (T_flame - Tp) * contact[i]
			capw[i] = HEAT_K * float(w[W_RATE]) * mm * (T_flame - Tp) * contact[i]
			wsum += wt[i]
	var inert: Array = s.get("inert", [])
	var wti := PackedFloat64Array()
	var capi := PackedFloat64Array()
	wti.resize(inert.size())
	capi.resize(inert.size())
	for j in inert.size():
		var it: Array = inert[j]
		var d := maxf(0.0, T_flame - float(it[2]))
		wti[j] = pow(float(it[1]), 1.5) * float(it[0]) * d
		capi[j] = HEAT_K * float(it[1]) * float(it[0]) * d
		wsum += wti[j]
	var pool := FLAME_SHARE * shared
	var given := 0.0
	var dem := PackedFloat64Array()
	dem.resize(n)
	for i in n:
		if wsum > 0.0:
			dem[i] = minf(capw[i], pool * wt[i] / wsum)
			given += dem[i]
	var demi := PackedFloat64Array()
	demi.resize(inert.size())
	for j in inert.size():
		if wsum > 0.0:
			demi[j] = minf(capi[j], pool * wti[j] / wsum)
			given += demi[j]
	# hot pieces cool toward their surroundings: open air - or a hot enclosure,
	# or the other burning pieces around them (one log alone goes out)
	var keep := maxf(encl, PILE_KEEP * clampf(hot_mass / PILE_KG, 0.0, 1.0))
	var cooled := 0.0
	var cool := PackedFloat64Array()
	cool.resize(n)
	for i in n:
		var w: Array = pieces[i]
		var Te := T_amb + (T - T_amb) * maxf(keep, IN_FLAME * contact[i])
		cool[i] = COOL_K * pow(float(w[W_RATE]), 0.6) * (float(w[W_MASS]) + float(w[W_CHAR])) * (float(w[W_T]) - Te)
		cooled += cool[i]
	var T_env := T_amb + (T - T_amb) * keep
	var cooli := PackedFloat64Array()
	cooli.resize(inert.size())
	for j in inert.size():
		var it: Array = inert[j]
		cooli[j] = COOL_K * float(it[1]) * float(it[0]) * (float(it[2]) - T_env)
		cooled += cooli[j]
	# the bed
	var flue := air * CP_AIR * dT * 0.6
	var Tk := T + 273.15
	var Ta := T_amb + 273.15
	var rad := 0.35 * SIGMA * (Tk * Tk * Tk * Tk - Ta * Ta * Ta * Ta) * minf(open_m2, bed_m2)
	var cond: float = dT * (float(p.get("wall_m2", 0.0)) * lerpf(9.0, 1.6, float(p.get("insul", 0.5))) + bed_m2 * 3.0)
	var loss: float = flue + rad + cond + float(p.get("extra_loss_w", 0.0))
	var C: float = BED_C + 900.0 * float(p.get("wall_mass_kg", 0.0))
	s["T"] = clampf(T + (shared - given + cooled - loss) / C * dt, T_amb, 1300.0)
	# the pieces
	for i in n:
		var w: Array = pieces[i]
		var m: float = w[W_MASS]
		var ch: float = w[W_CHAR]
		if m + ch < 1e-5:
			w[W_T] = T_env
			continue
		var Tp: float = w[W_T]
		var moist: float = w[W_MOIST]
		var Y := char_yield(Tp)
		var dp := minf(m, pyro[i] * dt)
		var dw := minf(m * moist, evap[i] * dt)
		var cb := minf(ch + dp * Y, cmax[i] * cf * dt)
		var cap := CP_WOOD * (m + ch) + CP_WATER * m * moist + 30.0
		var own := (gas_i[i] * gf * HEAT_GAS + cmax[i] * cf * HEAT_CHAR) * SELF_HEAT
		var q := dem[i] + own - cool[i] - evap[i] * EVAP_HEAT - pyro[i] * PYRO_HEAT
		w[W_T] = clampf(Tp + q / cap * dt, T_amb, T_PIECE_MAX)
		var m2 := m - dp
		w[W_MOIST] = (m * moist - dw) / m2 if m2 > 1e-6 else 0.0
		w[W_MASS] = m2 if m2 > 1e-6 else 0.0
		w[W_CHAR] = ch + dp * Y - cb
		w[O_CHAR_BURNED] = float(w[O_CHAR_BURNED]) + cb
		w[O_GAS] = float(w[O_GAS]) + dp * (1.0 - Y)
		w[O_STEAM] = float(w[O_STEAM]) + dw
	for j in inert.size():
		var it: Array = inert[j]
		it[2] = float(it[2]) + (demi[j] - cooli[j]) / maxf(1.0, float(it[0]) * float(it[3])) * dt
	return {"heat_w": heat, "gas_burn": gas_burn, "smoke": gas - gas_burn, "steam": evap_sum, "char_burn": char_burn,
		"pyro": pyro_sum, "air": air, "air_need": want, "T_flame": T_flame}


# ---------------------------------------------------------------------------
# Calibration bench (tests): run an arrangement and summarise it
# ---------------------------------------------------------------------------

const LAY_TINDER := [1, 0.21, 30.0, 230.0, 0.08]
const LAY_TWIGS := [1, 0.48, 10.0, 290.0, 0.12]
const LAY_STICKS := [3, 0.35, 4.0, 330.0, 0.2]


static func lay_firewood(n: int, moist: float = 0.15) -> Array:
	return [n, 1.3, 1.0, 380.0, moist]


static func bench(lay: Array, p: Dictionary, hours: float, schedule: Array = [], pots: int = 0) -> Dictionary:
	## lay: [[count, kg, rate, ign, moist], ...] - the first piece is lit.
	## schedule: [[hour, {param overrides}], ...] applied in order.
	var s := {"T": 15.0, "pieces": [], "inert": []}
	var wood0 := 0.0
	for e in lay:
		for i in int(e[0]):
			s["pieces"].append(piece(float(e[1]), float(e[2]), float(e[3]), float(e[4])))
			wood0 += float(e[1])
	s["pieces"][0][W_T] = 600.0
	for i in pots:
		s["inert"].append([0.5, 1.2, 15.0, 900.0])
	var dt := 5.0
	var t := 0.0
	var peak := 0.0
	var above := 0.0
	var pot_above := 0.0
	var pot_peak := 0.0
	var char_max := 0.0
	var pp := p.duplicate()
	var si := 0
	while t < hours * 3600.0:
		while si < schedule.size() and t >= float(schedule[si][0]) * 3600.0:
			for k in schedule[si][1]:
				pp[k] = schedule[si][1][k]
			si += 1
		step(s, pp, dt)
		peak = maxf(peak, float(s["T"]))
		if float(s["T"]) > 600.0:
			above += dt
		if pots > 0:
			var pt := float(s["inert"][0][2])
			pot_peak = maxf(pot_peak, pt)
			if pt > 600.0:
				pot_above += dt
		t += dt
	var left := 0.0
	var char_kg := 0.0
	for w in s["pieces"]:
		left += float(w[W_MASS])
		char_kg += float(w[W_CHAR])
	return {"peak": peak, "end": float(s["T"]), "char": char_kg, "char_frac": char_kg / wood0, "wood_left": left,
		"wood_frac": left / wood0, "h600": above / 3600.0, "pot_peak": pot_peak, "pot_h600": pot_above / 3600.0}
