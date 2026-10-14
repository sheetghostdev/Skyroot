class_name Survival
extends RefCounted
## Host-side survival model for every player.
##
## Hunger and thirst fall over game time; body water is real water (drunk from
## the pond or a vessel, lost to the air as breath and sweat).  Food carbon is
## respired back into the island's atmosphere and its nutrients come back out
## as food scraps for the compost heap.

const BODY_WATER_L := 2.5      # water reserve represented by a full thirst bar
const HUNGER_HOURS := 34.0
const THIRST_HOURS := 24.0
const SCRAP_NUTR := 0.003


static func eat(pid: int, id: String, food: Dictionary, count: int = 1) -> void:
	var st: Dictionary = World.stats.get(pid, {})
	if st.is_empty():
		return
	st["hunger"] = clampf(float(st["hunger"]) + float(food.get("hunger", 0.0)), 0.0, 1.0)
	var th := float(food.get("thirst", 0.0))
	if th > 0.0:
		# juicy food: its water (drawn from the soil by the plant) joins the body's water
		var w := th * BODY_WATER_L
		var room := (1.0 - float(st["thirst"])) * BODY_WATER_L
		var into_body := minf(w, room)
		st["thirst"] = clampf(float(st["thirst"]) + into_body / BODY_WATER_L, 0.0, 1.0)
		st["body_water_l"] = float(st.get("body_water_l", 0.0)) + into_body
		World.pools["plant_water_l"] = float(World.pools.get("plant_water_l", 0.0)) - w
		World.pools["atmo_water_l"] = float(World.pools.get("atmo_water_l", 0.0)) + (w - into_body)
	var nutr := ItemDB.nutrients(id) * count
	var mass := ItemDB.unit_mass(id) * count
	st["waste_nutr"] = float(st.get("waste_nutr", 0.0)) + nutr
	# carbon: respired to the air, except what leaves later as scraps
	var scrap_mass := nutr / SCRAP_NUTR * ItemDB.unit_mass("food_scraps")
	World.pools["atmo_carbon_kg"] = float(World.pools.get("atmo_carbon_kg", 0.0)) + maxf(0.0, mass - scrap_mass)
	st["scrap_carbon"] = float(st.get("scrap_carbon", 0.0)) + minf(mass, scrap_mass)
	if not food.get("raw", true) or id.ends_with("_roasted"):
		st["health"] = clampf(float(st["health"]) + 0.02, 0.0, 1.0)
	_emit_scraps(pid, st)
	World.mark_stats(pid)


static func _emit_scraps(pid: int, st: Dictionary) -> void:
	while float(st.get("waste_nutr", 0.0)) >= SCRAP_NUTR:
		st["waste_nutr"] = float(st["waste_nutr"]) - SCRAP_NUTR
		var sm := ItemDB.unit_mass("food_scraps")
		st["scrap_carbon"] = maxf(0.0, float(st.get("scrap_carbon", 0.0)) - sm)
		var a: Actions = World.actions
		if a:
			a.give(pid, "food_scraps", 1)


static func drink(pid: int, litres: float) -> float:
	## Returns how much was actually drunk.
	var st: Dictionary = World.stats.get(pid, {})
	if st.is_empty():
		return 0.0
	var room := (1.0 - float(st["thirst"])) * BODY_WATER_L
	var take := clampf(litres, 0.0, room)
	st["thirst"] = clampf(float(st["thirst"]) + take / BODY_WATER_L, 0.0, 1.0)
	st["body_water_l"] = float(st.get("body_water_l", 0.0)) + take
	World.mark_stats(pid)
	return take


static func damage(pid: int, amount: float, cause: String) -> void:
	var st: Dictionary = World.stats.get(pid, {})
	if st.is_empty() or not st.get("alive", true):
		return
	st["health"] = clampf(float(st["health"]) - amount, 0.0, 1.0)
	st["last_hurt"] = cause
	World.mark_stats(pid)
	if float(st["health"]) <= 0.0:
		die(pid, cause)


static func die(pid: int, cause: String) -> void:
	var st: Dictionary = World.stats.get(pid, {})
	if st.is_empty() or not st.get("alive", true):
		return
	st["alive"] = false
	st["health"] = 0.0
	st["death_cause"] = cause
	var inv: Inventory = World.inventory_of(pid)
	var items: Array = []
	for s in inv.slots:
		if not s.is_empty():
			items.append(s.duplicate(true))
	inv.clear()
	World.mark_inventory(pid)
	var a: Actions = World.actions
	var pos: Vector3 = a.player_pos(pid) if a else Vector3.ZERO
	if cause == "abyss":
		for s in items:
			a.lose_to_abyss(String(s["i"]), int(s["n"]), s["d"])
		# the body's water and carbon are gone too
		World.pools["lost_water_l"] = float(World.pools.get("lost_water_l", 0.0)) + float(st.get("body_water_l", 0.0))
		st["body_water_l"] = 0.0
	elif not items.is_empty() and a:
		var rest := a.settle_point(pos + Vector3(0, 0.5, 0))
		if rest == Vector3.INF:
			for s in items:
				a.lose_to_abyss(String(s["i"]), int(s["n"]), s["d"])
		else:
			World.spawn("satchel", Transform3D(Basis(), rest), {"items": items, "owner": Net.player_name(pid)})
	World.mark_stats(pid)
	World.notify(pid, _death_text(cause), "death")


static func _death_text(cause: String) -> String:
	match cause:
		"abyss": return "You fell into the abyss. Everything you carried is gone."
		"fall": return "You fell badly."
		"burn": return "The fire was too much."
		"hunger": return "You starved."
		"thirst": return "You died of thirst."
		"cold": return "The cold took you."
	return "You died."


static func respawn(pid: int) -> void:
	var st: Dictionary = World.stats.get(pid, {})
	if st.is_empty() or st.get("alive", true):
		return
	st["alive"] = true
	st["health"] = 0.6
	st["stamina"] = 1.0
	st["warmth"] = maxf(float(st.get("warmth", 0.5)), 0.6)
	# you wake beside the pond having drunk a little; food comes from body reserves
	var need := maxf(0.0, 0.4 - float(st["thirst"])) * BODY_WATER_L
	var pond := float(World.env.get("pond_l", 0.0))
	var w := minf(need, pond)
	World.env["pond_l"] = pond - w
	st["thirst"] = float(st["thirst"]) + w / BODY_WATER_L
	st["body_water_l"] = float(st.get("body_water_l", 0.0)) + w
	if float(st["hunger"]) < 0.3:
		var add := 0.3 - float(st["hunger"])
		st["hunger"] = 0.3
		World.pools["atmo_carbon_kg"] = float(World.pools.get("atmo_carbon_kg", 0.0)) - add * 0.8
	var pos := World.spawn_point(pid)
	var bed := int(st.get("bed", -1))
	if bed >= 0 and World.has_entity(bed):
		pos = World.entity_pos(bed) + Vector3(0, 0.3, 0)
	World.mark_stats(pid)
	World.teleport(pid, pos, 0.0)


static func tick(pid: int, hours: float, real_dt: float, ctx: Dictionary) -> void:
	var st: Dictionary = World.stats.get(pid, {})
	if st.is_empty() or not st.get("alive", true):
		return
	var sleeping: bool = ctx.get("sleeping", false)
	var work: float = ctx.get("work", 0.0)
	var hunger_rate := 1.0 / HUNGER_HOURS * (0.6 if sleeping else 1.0) * (1.0 + work * 0.6)
	var thirst_rate := 1.0 / THIRST_HOURS * (0.6 if sleeping else 1.0) * (1.0 + work * 0.8 + maxf(0.0, ctx.get("temp", 18.0) - 24.0) * 0.05)
	var dh := minf(float(st["hunger"]), hunger_rate * hours)
	st["hunger"] = float(st["hunger"]) - dh
	var dt_th := minf(float(st["thirst"]), thirst_rate * hours)
	st["thirst"] = float(st["thirst"]) - dt_th
	# water leaves the body as vapour
	var lost := minf(float(st.get("body_water_l", 0.0)), dt_th * BODY_WATER_L)
	st["body_water_l"] = float(st.get("body_water_l", 0.0)) - lost
	World.pools["atmo_water_l"] = float(World.pools.get("atmo_water_l", 0.0)) + lost
	# warmth
	var temp: float = ctx.get("temp", 18.0)
	var target := clampf(0.5 + (temp - 14.0) / 16.0, 0.0, 1.0)
	var rate := 0.6 if target > float(st["warmth"]) else 0.35
	if ctx.get("wet", false):
		target -= 0.15
	st["warmth"] = move_toward(float(st["warmth"]), clampf(target, 0.0, 1.0), rate * hours)
	# stamina (real time)
	var sprint: bool = ctx.get("sprint", false)
	var regen := 0.11 * (0.4 if float(st["hunger"]) < 0.1 else 1.0) * (0.5 if float(st["thirst"]) < 0.1 else 1.0) * (0.55 if float(st["warmth"]) < 0.3 else 1.0)
	if sleeping:
		regen *= 2.0
	if sprint:
		st["stamina"] = maxf(0.0, float(st["stamina"]) - 0.085 * real_dt)
	else:
		st["stamina"] = minf(1.0, float(st["stamina"]) + regen * real_dt)
	# health
	var hp := float(st["health"])
	if float(st["hunger"]) <= 0.001:
		hp -= 0.03 * hours
		st["last_hurt"] = "hunger"
	if float(st["thirst"]) <= 0.001:
		hp -= 0.06 * hours
		st["last_hurt"] = "thirst"
	if float(st["warmth"]) < 0.08:
		hp -= 0.04 * hours
		st["last_hurt"] = "cold"
	var burn: float = ctx.get("burn", 0.0)
	if burn > 0.0:
		hp -= burn * real_dt
		st["last_hurt"] = "burn"
	if float(st["hunger"]) > 0.35 and float(st["thirst"]) > 0.35 and float(st["warmth"]) > 0.3:
		hp += (0.05 if sleeping else 0.025) * hours
	st["health"] = clampf(hp, 0.0, 1.0)
	st["temp"] = temp
	World.mark_stats(pid)
	if float(st["health"]) <= 0.0:
		die(pid, String(st.get("last_hurt", "")))
