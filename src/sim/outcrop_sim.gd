class_name OutcropSim
extends RefCounted
## The rock outcrop slowly sheds stones: heat and cold crack a cobble loose
## into an empty hollow every day and a half or so, and a determined islander
## can break one free sooner with a hammerstone or a tool.  The stones come out
## of the outcrop's own rock (counted in the ledger), so the island never runs
## completely out of something to knap - but it is never free either.

const WEATHER_H := 36.0      # hours for frost and sun to crack a stone loose
const PRY_STONE := 0.18      # progress per blow with a hammerstone
const PRY_TOOL := 0.3        # ... with an axe or digging tool


static func tick(hours: float) -> void:
	if not World.is_host():
		return
	for e in World.entities_of("outcrop"):
		var d: Dictionary = e["d"]
		var loose: Array = d.get("loose", [])
		if float(d.get("rock", 0.0)) < ItemDB.unit_mass("stone") or not loose.has(0):
			continue
		var wt := float(d.get("wt", 0.0)) + hours
		if wt >= WEATHER_H:
			shed(e)
			wt = 0.0
		d["wt"] = wt   # bookkeeping only; replicated with the next visible change


static func shed(e: Dictionary) -> bool:
	## One stone comes free into the first empty hollow.
	var d: Dictionary = e["d"]
	var loose: Array = d.get("loose", []).duplicate()
	var i := loose.find(0)
	var rock := float(d.get("rock", 0.0))
	if i == -1 or rock < ItemDB.unit_mass("stone"):
		return false
	loose[i] = 1
	World.update(int(e["id"]), {"loose": loose, "rock": rock - ItemDB.unit_mass("stone"), "pry": 0.0})
	return true
