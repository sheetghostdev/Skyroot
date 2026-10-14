class_name Survival
extends RefCounted
## Host-side survival model for every player: hunger, thirst, body warmth and
## health.  Food and water fill the bars; cold nights in the open drain warmth,
## a fire or shelter restores it; an empty bar hurts.  Death leaves your things
## in a bag where you fell (gone for good if you fell into the abyss).

const HUNGER_HOURS := 30.0      # full to empty
const THIRST_HOURS := 22.0
const COMFORT_C := 12.0

static var _hinted: Dictionary = {}    # "pid:hint" -> true: each survival tip once per session


static func reset_hints() -> void:
	_hinted.clear()


static func hint_once(pid: int, hint_id: String) -> void:
	var k := "%d:%s" % [pid, hint_id]
	if _hinted.has(k):
		return
	_hinted[k] = true
	World.hint_to(pid, hint_id)


static func eat(pid: int, food: Dictionary, raw: bool) -> void:
	var st: Dictionary = World.stats.get(pid, {})
	if st.is_empty():
		return
	st["hunger"] = clampf(float(st["hunger"]) + float(food.get("hunger", 0.0)), 0.0, 1.0)
	st["thirst"] = clampf(float(st["thirst"]) + float(food.get("thirst", 0.0)), 0.0, 1.0)
	if not raw:
		st["health"] = clampf(float(st["health"]) + 0.03, 0.0, 1.0)
	World.mark_stats(pid)


static func drink(pid: int, amount: float) -> void:
	var st: Dictionary = World.stats.get(pid, {})
	if st.is_empty():
		return
	st["thirst"] = clampf(float(st["thirst"]) + amount, 0.0, 1.0)
	World.mark_stats(pid)


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
	var a: Actions = World.actions
	a.close_inventory(pid)
	var inv: Inventory = World.inventory_of(pid)
	var items := inv.all_stacks()
	inv.clear()
	World.mark_inventory(pid)
	var pos: Vector3 = a.player_pos(pid) if a else Vector3.ZERO
	if cause != "abyss" and not items.is_empty() and a:
		var y := World.vox.rest_height(pos + Vector3(0, 0.6, 0))
		if y == -INF:
			# died over the edge: the bag goes back to where you last stood safely
			pos = World.spawn_point(pid)
			y = pos.y
		World.spawn("satchel", Transform3D(Basis(), Vector3(pos.x, y, pos.z)), {"items": items, "owner": Net.player_name(pid)})
	World.mark_stats(pid)
	World.notify(pid, _death_text(cause), "death")


static func _death_text(cause: String) -> String:
	match cause:
		"abyss": return "You fell into the abyss. Everything you carried is gone."
		"fall": return "You fell badly. Your things are in a bag where you fell."
		"burn": return "The fire was too much. Your things are in a bag where you fell."
		"hunger": return "You starved. Your things are in a bag where you fell."
		"thirst": return "You died of thirst. Your things are in a bag where you fell."
		"cold": return "The cold took you. Your things are in a bag where you fell."
	return "You died. Your things are in a bag where you fell."


static func respawn(pid: int) -> void:
	var st: Dictionary = World.stats.get(pid, {})
	if st.is_empty() or st.get("alive", true):
		return
	st["alive"] = true
	st["health"] = 0.6
	st["warmth"] = maxf(float(st.get("warmth", 0.5)), 0.7)
	st["hunger"] = maxf(float(st["hunger"]), 0.35)
	st["thirst"] = maxf(float(st["thirst"]), 0.35)
	var pos := World.spawn_point(pid)
	var bed: Vector3i = st.get("bed", Vector3i(-1, -1, -1))
	if bed.x >= 0 and Blocks.has_flag(World.block(bed), "bed"):
		pos = Vector3(bed) + Vector3(0.5, 0.5, 0.5)
	World.mark_stats(pid)
	World.teleport(pid, pos, 0.0)


static func tick(pid: int, hours: float, real_dt: float, ctx: Dictionary) -> void:
	var st: Dictionary = World.stats.get(pid, {})
	if st.is_empty() or not st.get("alive", true):
		return
	var sleeping: bool = ctx.get("sleeping", false)
	var temp: float = ctx.get("temp", 15.0)
	var slow := 0.55 if sleeping else 1.0
	st["hunger"] = maxf(0.0, float(st["hunger"]) - hours / HUNGER_HOURS * slow * (1.0 + float(ctx.get("work", 0.0)) * 0.3))
	st["thirst"] = maxf(0.0, float(st["thirst"]) - hours / THIRST_HOURS * slow * (1.0 + maxf(0.0, temp - 24.0) * 0.05))
	# warmth drifts toward what the air allows
	var target := clampf(0.55 + (temp - COMFORT_C) / 14.0, 0.0, 1.0)
	if ctx.get("wet", false):
		target -= 0.15
	var rate := 0.9 if target > float(st["warmth"]) else 0.3
	st["warmth"] = move_toward(float(st["warmth"]), clampf(target, 0.0, 1.0), rate * hours)
	var hp := float(st["health"])
	var cause := ""
	if float(st["hunger"]) <= 0.001:
		hp -= 0.04 * hours
		cause = "hunger"
	if float(st["thirst"]) <= 0.001:
		hp -= 0.07 * hours
		cause = "thirst"
	if float(st["warmth"]) < 0.12:
		hp -= 0.05 * hours
		cause = "cold"
	var burn: float = ctx.get("burn", 0.0)
	if burn > 0.0:
		hp -= burn * real_dt
		cause = "burn"
	if float(st["hunger"]) > 0.3 and float(st["thirst"]) > 0.3 and float(st["warmth"]) > 0.3:
		hp += (0.08 if sleeping else 0.035) * hours
	st["health"] = clampf(hp, 0.0, 1.0)
	st["temp"] = temp
	st["near_fire"] = bool(ctx.get("near_fire", false))
	World.mark_stats(pid)
	if float(st["health"]) <= 0.0:
		die(pid, cause)
		return
	if float(st["hunger"]) < 0.3:
		hint_once(pid, "hungry")
	if float(st["thirst"]) < 0.3:
		hint_once(pid, "thirsty")
	if float(st["warmth"]) < 0.35:
		hint_once(pid, "cold")
	if float(st["health"]) < 0.5:
		hint_once(pid, "hurt")
