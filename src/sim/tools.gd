class_name Tools
extends RefCounted
## Tool performance and wear.  A tool's quality comes from how well its head
## was knapped and how well it was hafted.


static func power(stack: Dictionary) -> float:
	var d: Dictionary = stack.get("d", {})
	var q := float(d.get("q", 0.5))
	var dur := float(d.get("dur", 1.0))
	return (0.45 + 0.8 * q) * (0.6 + 0.4 * dur)


static func wear(pid: int, args: Dictionary, amount: float) -> void:
	var inv := World.inventory_of(pid)
	var slot := int(args.get("slot", -1))
	var s := inv.get_slot(slot)
	if s.is_empty() or ItemDB.tool_kind(String(s["i"])) == "":
		return
	var d: Dictionary = s["d"].duplicate(true)
	var q := float(d.get("q", 0.5))
	var bind := float(d.get("bind", 0.7))
	var dur := float(d.get("dur", 1.0)) - amount * (1.6 - q * 0.8) * (1.4 - bind * 0.6)
	if dur <= 0.0:
		_break(pid, slot, s)
		return
	d["dur"] = dur
	inv.set_data(slot, d)
	World.mark_inventory(pid)


static func _break(pid: int, slot: int, s: Dictionary) -> void:
	var inv := World.inventory_of(pid)
	var id := String(s["i"])
	inv.set_slot(slot, {})
	World.mark_inventory(pid)
	var name := ItemDB.display_name(id, s["d"])
	var a: Actions = World.actions
	match id:
		"axe", "digger":
			# the handle survives; the worn head is a dull stone again; the cord frays to fibre
			a.give(pid, "stick", 1)
			var head: Dictionary = s["d"].get("head", {}).duplicate(true)
			head["shape"] = ""
			head["q"] = 0.0
			a.give(pid, "stone_head", 1, head)
			a.give(pid, "fiber", 1)
			World.pools["soil_organic_kg"] = float(World.pools.get("soil_organic_kg", 0.0)) + maxf(0.0, ItemDB.unit_mass("cordage") - ItemDB.unit_mass("fiber"))
			var k := a.cell_index_at(a.player_pos(pid))
			World.terrain.nutr[k] += maxf(0.0, ItemDB.nutrients("cordage") - ItemDB.nutrients("fiber"))
		"blade":
			World.pools["debris_stone_kg"] = float(World.pools.get("debris_stone_kg", 0.0)) + float(s["d"].get("stone_kg", ItemDB.unit_mass("blade")))
	World.notify(pid, "Your %s broke." % name.to_lower(), "warn")
	World.fx("stone_break", a.player_pos(pid) + Vector3(0, 1.2, 0), {"amount": 6})
