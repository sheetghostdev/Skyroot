class_name WorkLedger
extends RefCounted
## Material held in crafting workpieces (for the ledger).


static func contrib(d: Dictionary) -> Dictionary:
	var out := Ledger.empty()
	match String(d.get("kind", "")):
		"knap":
			out["stone"] = float(d.get("kg", 0.0))
		"clay_prep":
			out["clay"] = float(d.get("vol", 0.0))
			out["water"] = float(d.get("vol", 0.0)) * float(d.get("moist", 0.0))
		"pottery":
			var pot: Dictionary = d.get("pot", {})
			out["clay"] = float(pot.get("vol", 0.0))
			out["water"] = float(pot.get("vol", 0.0)) * float(pot.get("moist", 0.0))
		"cordage":
			out["carbon"] = int(d.get("fibers", 2)) * ItemDB.unit_mass("fiber")
			out["nutr"] = int(d.get("fibers", 2)) * ItemDB.nutrients("fiber")
		"fire_drill":
			out["carbon"] = ItemDB.unit_mass("hearth_board") + ItemDB.unit_mass("stick")
			out["nutr"] = ItemDB.nutrients("hearth_board") + ItemDB.nutrients("stick")
		"haft":
			out["stone"] = float(d.get("head", {}).get("stone_kg", 0.0))
			out["carbon"] = ItemDB.unit_mass("stick") + ItemDB.unit_mass("cordage")
			out["nutr"] = ItemDB.nutrients("stick") + ItemDB.nutrients("cordage")
	return out
