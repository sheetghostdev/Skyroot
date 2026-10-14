class_name CompostRules
extends RefCounted
## What you can do at a compost heap: add greens and browns, water it, turn it,
## take finished compost, or spread the whole heap into the soil.


static func options(out: Dictionary, _p: LocalPlayer, t: Dictionary, d: Dictionary, eid: int, held: String, hd: Dictionary, tool: String) -> void:
	var opt := InteractionRules.opt
	out["info"] = {"title": "Compost heap", "text": CompostSim.describe(d)}
	var n := CompostSim.ready_count(d)
	if held == "":
		if n > 0:
			out["interact"] = opt.call("Take compost (%d ready)" % n, "compost_take", {"eid": eid}, "dig")
		else:
			out["interact"] = InteractionRules.disabled("No finished compost yet", "Compost forms as the heap rots. Keep it damp, mixed and turned.")
		out["secondary"] = InteractionRules.confirm("Spread the heap into the soil", "compost_spread", {"eid": eid}, "dig")
	if held == "" or held == "stick" or tool == "dig":
		out["primary"] = opt.call("Turn the heap", "compost_turn", {"eid": eid}, "dig", true)
	elif CompostSim.is_compostable(held):
		if hd.has("fm"):
			out["primary"] = InteractionRules.disabled("Add to the heap", "That's been in a fire - it won't rot.")
		else:
			var kind := CompostSim.kind_of(held)
			out["primary"] = opt.call("Add %s to the heap (%s)" % [ItemDB.display_name(held).to_lower(), kind], "compost_add", {"eid": eid}, "place", true)
	elif held == "pot" and float(hd.get("water", 0.0)) > 0.01:
		out["primary"] = opt.call("Water the heap (%.2f L)" % float(hd["water"]), "pour", {"pos": t.get("pos", Vector3.ZERO), "eid": eid}, "pour")
	elif held != "" and ItemDB.is_organic(held) and ItemDB.material(held) == "wood":
		out["primary"] = InteractionRules.disabled("Wood won't compost", "Wood takes years to rot. Burn it or build with it.")
