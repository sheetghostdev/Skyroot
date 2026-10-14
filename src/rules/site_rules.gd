class_name SiteRules
extends RefCounted
## What you can do to a fire, a pit kiln or a charcoal mound.


static func options(out: Dictionary, p: LocalPlayer, t: Dictionary, d: Dictionary, eid: int, held: String, hd: Dictionary, tool: String) -> void:
	var opt := InteractionRules.opt
	var lit := bool(d.get("lit", false))
	var hot := int(d.get("T", 15)) > 70
	var covered := FireSim.shell_coverage(d) > 0.5
	var shell := float(d.get("shell_l", 0.0))
	var pos: Vector3 = t.get("pos", Vector3.ZERO)
	var title := "Charcoal mound" if covered else ("Fire" if lit else "Fire pit")
	out["info"] = {"title": title, "text": FireSim.describe(d)}
	if held == "earth":
		out["primary"] = opt.call("Pack earth over the %s" % ("fire" if lit else "pit"), "fire_cover", {"eid": eid, "pos": pos}, "pack", true)
	if held == "stick":
		if shell > 0.0 and FireSim.coverage(d, _cell_at(t, d)) > 0.6:
			out["secondary"] = opt.call("Poke a vent here", "fire_vent", {"eid": eid, "pos": pos}, "cut")
		elif lit and not covered:
			out["secondary"] = opt.call("Light the stick in the fire", "fire_torch", {"eid": eid}, "place")
	if shell > 0.0 and (held == "" or tool == "dig"):
		var what := "Dig the mound open" + (" (hot!)" if hot else "")
		out["interact"] = opt.call(what, "fire_uncover", {"eid": eid, "pos": pos}, "dig", true)
	elif held == "" and not lit and not hot and float(d.get("ash_n", 0.0)) >= ItemDB.nutrients("ash") and float(d.get("ash_c", 0.0)) >= ItemDB.unit_mass("ash"):
		out["interact"] = opt.call("Scoop up ash", "fire_ash", {"eid": eid}, "pick")
	if held == "pot" and float(hd.get("water", 0.0)) > 0.01:
		out["primary"] = opt.call("Pour water on the fire" if lit or hot else "Pour water on the ashes", "pour", {"eid": eid, "pos": pos}, "pour")
	if not covered and held != "" and held != "earth" and held != "stick" and not out.has("secondary"):
		if not ItemDB.fuel(held).is_empty() or not ItemDB.food(held).is_empty() or held == "pot":
			var verb := InteractionRules.fire_verb(held).replace("at the fire", "at the fire's edge")
			if not lit:
				verb = "Put %s in the fire pit"
			out["secondary"] = opt.call(verb % ItemDB.display_name(held, hd).to_lower(), "fire_add", {"eid": eid}, "place")
	if held == "torch" and not lit and not covered:
		out["primary"] = InteractionRules.disabled("Light the fire", "Touch the burning stick to the tinder or kindling itself.")


static func _cell_at(t: Dictionary, d: Dictionary) -> int:
	var ent: Dictionary = t.get("ent", {})
	if ent.is_empty():
		return 0
	var c: Vector3 = ent["xf"].origin
	var rr := FireSim.dome_radii(d)
	var rel: Vector3 = t["pos"] - c
	var dir := Vector3(rel.x / rr.x, rel.y / rr.y, rel.z / rr.x)
	return FireSim.cell_of_dir(dir if dir.length() > 0.001 else Vector3.UP)
