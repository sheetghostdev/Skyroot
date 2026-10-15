class_name UseRules
extends RefCounted
## What the mouse buttons will do, given what you hold and what you look at.
## The client uses this for the prompts under the crosshair and to decide which
## request to send; the host re-checks everything when the request arrives.

const DRILL_S := 2.6
const EAT_S := 1.1
const DRINK_S := 0.7


static func lmb(t: Dictionary, s: Dictionary) -> Dictionary:
	var kind := String(t.get("type", ""))
	if kind == "":
		return {}
	if kind == "satchel":
		return {}
	var tool_kind := ItemDB.tool_kind(String(s.get("i", "")))
	if kind == "animal":
		return {"text": "Hunt" if tool_kind in ["spear", "knife", "axe"] else "Hit", "kind": "hit"}
	if kind == "raft":
		var rt := BlockActs.break_time(int(t["id"]), int(t["m"]), tool_kind)
		if Blocks.has_flag(int(t["id"]), "raft_only") and rt >= 0.0:
			return {"text": "Take apart" if Blocks.name_of(int(t["id"])) == "raft_floor" else "Take down", "kind": "break", "time": rt}
		return {"text": "Pick up" if rt >= 0.0 else "Too hard to break", "kind": "break" if rt >= 0.0 else "none", "time": rt}
	if kind == "be":
		var be: Dictionary = t["be"]
		match String(be["t"]):
			"knap":
				if String(be["d"]["r"]) == "":
					return {"text": "Pick up the stone", "kind": "break", "time": 0.25}
				return {"text": "Chip", "kind": "chip"}
			"clay":
				if String(be["d"]["r"]) == "":
					return {"text": "Pick up the clay", "kind": "break", "time": 0.25}
				return {"text": "Remove clay", "kind": "clay_remove"}
			"firepit":
				return {"text": "Take the fire pit apart", "kind": "break", "time": 0.6}
			"kiln":
				return {"text": "Take the kiln apart", "kind": "break", "time": 0.8}
			"ground":
				return {"text": "Pick up", "kind": "break", "time": 0.3}
			"jar":
				return {"text": "Pick up the jar", "kind": "break", "time": 0.6}
		return {}
	var id: int = t["id"]
	var bt := BlockActs.break_time(id, World.block_meta(t["cell"]), tool_kind)
	if bt < 0.0:
		var needs := String(Blocks.def(id).get("needs", ""))
		if needs == "pick":
			return {"text": "Too hard to break", "kind": "none"}
		return {"text": "Needs %s" % ("an " + needs if needs != "" and needs[0] in "aeiou" else "a " + needs), "kind": "none"}
	var verb := "Break"
	if Blocks.has_flag(id, "tree") and World.block_meta(t["cell"]) & BlockActs.NATURAL:
		verb = "Fell the tree"
	elif Blocks.shape[id] == Blocks.Shape.CROSS or Blocks.shape[id] == Blocks.Shape.BOXES:
		verb = "Pick up" if Blocks.name_of(id).begins_with("loose") else ("Cut" if tool_kind == "knife" else "Break")
	return {"text": verb, "kind": "break", "time": bt}


static func rmb(t: Dictionary, s: Dictionary, sneak: bool, ctx: Dictionary = {}) -> Dictionary:
	## ctx: {"raft": the raft you stand on, or -1}
	var id := String(s.get("i", ""))
	var d: Dictionary = s.get("d", {})
	var kind := String(t.get("type", ""))
	var food := ItemDB.food(id)
	var r := {}
	if kind == "satchel":
		return {"text": "Take back your things", "kind": "satchel"}
	if kind == "be":
		r = _be(t["be"], id, d, sneak, s)
		if not r.is_empty():
			return r
	elif kind == "block":
		r = _block(t, id, d, sneak, s)
		if not r.is_empty():
			return r
	elif kind == "raft":
		r = _raft(t, id)
		if not r.is_empty():
			return r
	elif kind == "animal":
		r = _animal(t, id)
		if not r.is_empty():
			return r
	# paddling the raft you stand on (or the one you look at)
	if ItemDB.tool_kind(id) == "paddle":
		var eid := int(ctx.get("raft", -1))
		if eid < 0 and kind == "raft":
			eid = int(t["eid"])
		if eid >= 0:
			return {"text": "Paddle (it goes the way you look)", "kind": "paddle", "eid": eid, "repeat": 0.45}
	# your own hands
	if not food.is_empty():
		return {"text": "Eat", "kind": "eat", "hold": EAT_S}
	if id == "bowl" and String(d.get("c", "")) == "water":
		return {"text": "Drink", "kind": "eat", "hold": DRINK_S}
	if id == "bowl" and String(d.get("c", "")) == "sea":
		return {"text": "Drink the sea water (salty!)", "kind": "eat", "hold": DRINK_S}
	if id == "pot" and int(d.get("w", 0)) > 0:
		return {"text": "Drink the sea water (salty!)" if bool(d.get("salt", false)) else "Drink from the pot", "kind": "eat", "hold": DRINK_S}
	if id == "waterskin" and int(d.get("n", 0)) > 0:
		return {"text": "Drink", "kind": "eat", "hold": DRINK_S}
	if id == "bowl" and String(d.get("c", "")) == "stew":
		return {"text": "Eat the stew", "kind": "eat", "hold": EAT_S}
	return {}


static func _count(n: int, mx: int) -> String:
	return "(%d/%d)" % [n, mx]


static func _be(be: Dictionary, id: String, d: Dictionary, sneak: bool, s: Dictionary) -> Dictionary:
	var bd: Dictionary = be["d"]
	match String(be["t"]):
		"firepit":
			var lit := bool(bd["lit"])
			var pot: Dictionary = bd.get("pot", {})
			if id == "":
				var food: Array = bd.get("food", [])
				if not food.is_empty():
					var pick: Dictionary = food[0]
					for f in food:
						if bool(f.get("done", false)):
							pick = f
							break
					return {"text": "Take %s" % ItemDB.label(String(pick["i"])).to_lower(), "kind": "use"}
				if not pot.is_empty():
					return {"text": "Take the pot", "kind": "use"} if int(pot.get("stew", 0)) == 0 else {"text": "Stew is ready: ladle it with a bowl", "kind": "none"}
				return {}
			if id == "stick" and int(bd["sticks"]) >= FireActs.STICK_MAX:
				return {"text": "No room for more sticks", "kind": "none"}
			if ItemDB.fuel(id) == "tinder" and int(bd["tinder"]) >= FireActs.TINDER_MAX:
				return {"text": "That's plenty of tinder", "kind": "none"}
			if id == "firewood" and int(bd["logs"]) >= FireActs.LOG_MAX:
				return {"text": "No room for more firewood", "kind": "none"}
			if id == "stick":
				return {"text": "Add a stick " + _count(int(bd["sticks"]), FireActs.STICK_MAX), "kind": "use", "repeat": 0.3}
			if ItemDB.fuel(id) == "tinder":
				return {"text": "Tuck in tinder " + _count(int(bd["tinder"]), FireActs.TINDER_MAX), "kind": "use", "repeat": 0.3}
			if id == "firewood":
				return {"text": "Add firewood " + _count(int(bd["logs"]), FireActs.LOG_MAX), "kind": "use", "repeat": 0.3}
			if id == "firestarter" and not lit:
				if int(bd["tinder"]) <= 0:
					return {"text": "Needs tinder (dry grass) first", "kind": "none"}
				if int(bd["sticks"]) <= 0:
					return {"text": "Needs sticks first", "kind": "none"}
				return {"text": "Light the fire", "kind": "ignite", "hold": DRILL_S}
			if id == "torch_lit" and not lit:
				return {"text": "Light the fire", "kind": "ignite", "hold": 0.3}
			if id == "torch" and lit:
				return {"text": "Light the torch", "kind": "use"}
			if id == "pot" and pot.is_empty():
				return {"text": "Set the pot on the fire", "kind": "use"}
			if id == "bowl" and not pot.is_empty():
				if String(d.get("c", "")) == "" and int(pot.get("stew", 0)) > 0:
					return {"text": "Ladle out stew", "kind": "use"}
				if String(d.get("c", "")) in ["water", "sea"] and int(pot.get("stew", 0)) == 0 and int(pot.get("water", 0)) < 3:
					return {"text": "Pour it into the pot " + _count(int(pot.get("water", 0)), 3), "kind": "use"}
				if String(d.get("c", "")) == "" and int(pot.get("water", 0)) > 0 and (pot.get("items", []) as Array).is_empty():
					return {"text": "Ladle out sea water (let it boil!)" if bool(pot.get("salt", false)) else "Ladle out fresh water", "kind": "use"}
			if id == "waterskin" and not pot.is_empty() and int(pot.get("water", 0)) > 0 and int(pot.get("stew", 0)) == 0 and (pot.get("items", []) as Array).is_empty():
				if bool(pot.get("salt", false)):
					return {"text": "Still sea water: let it boil", "kind": "none"}
				return {"text": "Fill the waterskin from the pot", "kind": "use"}
			if String(ItemDB.food(id).get("cook", "")) != "":
				if not pot.is_empty() and int(pot.get("water", 0)) > 0:
					return {"text": "Put it in the pot", "kind": "use"}
				if pot.is_empty():
					return {"text": "Roast it on the fire", "kind": "use"}
			return {}
		"kiln":
			if bool(bd.get("lit", false)):
				return {}
			if ItemDB.fuel(id) == "tinder" and int(bd["grass"]) < FireActs.KILN_GRASS:
				return {"text": "Cover with dry grass " + _count(int(bd["grass"]), FireActs.KILN_GRASS), "kind": "use", "repeat": 0.3}
			if (id == "stick" or id == "firewood") and int(bd["sticks"]) < FireActs.KILN_STICKS:
				if int(bd["grass"]) < FireActs.KILN_GRASS:
					return {"text": "Cover it with dry grass first", "kind": "none"}
				return {"text": "Lay sticks over it " + _count(int(bd["sticks"]), FireActs.KILN_STICKS), "kind": "use", "repeat": 0.3}
			if id == "firestarter":
				if int(bd["grass"]) < FireActs.KILN_GRASS or int(bd["sticks"]) < FireActs.KILN_STICKS:
					return {"text": "Needs %d dry grass and %d sticks" % [FireActs.KILN_GRASS, FireActs.KILN_STICKS], "kind": "none"}
				return {"text": "Light the kiln", "kind": "ignite", "hold": DRILL_S}
			if id == "torch_lit":
				return {"text": "Light the kiln", "kind": "ignite", "hold": 0.3}
			return {}
		"knap":
			if String(bd["r"]) == "":
				return {"text": "Choose what to knap", "kind": "use"}
			return {}
		"clay":
			if String(bd["r"]) == "":
				return {"text": "Choose what to shape", "kind": "use"}
			return {"text": "Add clay", "kind": "clay_add"}
		"ground":
			var items: Array = bd.get("items", [])
			if id == "":
				if items.is_empty():
					return {}
				var top: Dictionary = items[items.size() - 1]
				return {"text": "Take %s" % ItemDB.label(String(top["i"]), top.get("d", {})).to_lower(), "kind": "use"}
			if ItemDB.fuel(id) == "tinder" and not bd.get("ash", false):
				var all_raw := not items.is_empty()
				for it in items:
					if not ItemDB.is_raw_pottery(String(it["i"])):
						all_raw = false
				if all_raw:
					return {"text": "Cover with dry grass: start a pit kiln", "kind": "use"}
			if sneak:
				return {"text": "Put it down here too", "kind": "use", "repeat": 0.3}
			return {}
		"jar":
			return {"text": "Open the jar", "kind": "use"}
	return {}


static func _block(t: Dictionary, id: String, d: Dictionary, sneak: bool, s: Dictionary) -> Dictionary:
	var b: int = t["id"]
	var nm := Blocks.name_of(b)
	var c: Vector3i = t["cell"]
	var face: Vector3i = t["normal"]
	if nm == "berry_bush" and not sneak:
		if World.block_meta(c) == 1:
			return {"text": "Pick berries", "kind": "use"}
	if (b == Blocks.sea or (Blocks.waterlog[b] == 1 and World.kind == "sea")) and id == "raft_floor" and World.block(c + Vector3i.UP) == 0:
		# the top of the sea (from a swimmer's eye level, its side will do)
		var ext := _raft_beside(t["point"])
		if not ext.is_empty():
			return {"text": "Lash it to the raft", "kind": "raft_place", "eid": ext["eid"], "cell": ext["cell"], "repeat": 0.3}
		return {"text": "Float a raft section on the sea", "kind": "raft_new"}
	if Blocks.is_water(b):
		var salt := b != Blocks.id_of("water")
		if id == "":
			return {"text": "Drink (it's salt water!)" if salt else "Drink", "kind": "drink", "hold": DRINK_S}
		if id == "bowl" and String(d.get("c", "")) == "":
			return {"text": "Fill the bowl with sea water" if salt else "Fill the bowl", "kind": "use"}
		if id == "pot" and int(d.get("w", 0)) < 3:
			return {"text": "Fill the pot with sea water" if salt else "Fill the pot", "kind": "use"}
		if id == "waterskin":
			if salt:
				return {"text": "Not with sea water: boil it in a pot first", "kind": "none"}
			if int(d.get("n", 0)) < FireActs.WATERSKIN_MAX:
				return {"text": "Fill the waterskin", "kind": "use"}
	if Blocks.has_flag(b, "bed") and id == "":
		return {"text": "Sleep", "kind": "sleep"}
	if ItemDB.tool_kind(id) == "hoe" and face == Vector3i.UP and nm in ["grass", "dirt"]:
		return {"text": "Till the soil", "kind": "use"}
	if ItemDB.def(id).has("crop") and nm == "farmland":
		return {"text": "Sow", "kind": "use"}
	if id == "coconut" and sneak and face == Vector3i.UP and nm in ["sand", "grass", "dirt"] and World.block(c + Vector3i.UP) == 0 and World.cell_free(c + Vector3i.UP):
		return {"text": "Plant the coconut", "kind": "use"}
	if face == Vector3i.UP and Blocks.is_solid(b) and World.cell_free(c + Vector3i.UP):
		if id == "jar":
			return {"text": "Set the jar down", "kind": "use"}
		if sneak and id != "" and ItemDB.block_of(id) < 0:
			if ItemDB.def(id).has("knap"):
				return {"text": "Lay it down to knap", "kind": "use"}
			if id == "clay":
				return {"text": "Lay it down to shape", "kind": "use"}
			if id == "stick":
				return {"text": "Start a fire pit", "kind": "use"}
			if ItemDB.fuel(id) == "tinder":
				return {"text": "Start a fire pit with tinder", "kind": "use"}
			return {"text": "Put it down here", "kind": "use"}
	var place := ItemDB.block_of(id)
	if place >= 0:
		return {"text": "Place %s" % Blocks.label(place).to_lower(), "kind": "use", "repeat": 0.22}
	return {}


static func _raft(t: Dictionary, id: String) -> Dictionary:
	## Right-click on a raft: build on it, raise a sail, drop the anchor, steer.
	var b: int = t["id"]
	var c: Vector3i = t["cell"]
	var face: Vector3i = t["normal"]
	var eid := int(t["eid"])
	var e := World.get_entity(eid)
	if e.is_empty():
		return {}
	var cells: Dictionary = e["d"].get("cells", {})
	if id == "raft_floor":
		var nc := c + face
		if face.y == 0 and Raft.floor_ok(cells, nc):
			return {"text": "Lash it to the raft", "kind": "raft_place", "eid": eid, "cell": nc, "repeat": 0.3}
		return {"text": "New sections go beside the raft, on the water", "kind": "none"}
	if Blocks.has_flag(b, "sail") and id == "":
		var up := (int(t["m"]) & 4) != 0
		return {"text": "Furl the sail" if up else "Raise the sail", "kind": "raft_use"}
	if Blocks.has_flag(b, "anchor") and id == "":
		return {"text": "Weigh anchor" if bool(e["d"].get("anchor", false)) else "Drop the anchor", "kind": "raft_use"}
	if Blocks.has_flag(b, "helm") and id == "":
		return {"text": "Take the helm", "kind": "helm"}
	var place := ItemDB.block_of(id)
	if place >= 0:
		var at := c + face
		if at.y < 1 or cells.has(at) or not Raft.supported(cells, at):
			return {}
		if Blocks.has_flag(place, "raft_only") and at.y != 1:
			return {"text": "That goes on the deck", "kind": "none"}
		return {"text": "Place %s" % Blocks.label(place).to_lower(), "kind": "raft_place", "eid": eid, "cell": at, "face": face, "repeat": 0.22}
	return {}


static func _animal(t: Dictionary, id: String) -> Dictionary:
	## Right-click on an animal: lead it on twine, let it go, feed it.
	var e := World.get_entity(int(t["eid"]))
	if e.is_empty():
		return {}
	var d: Dictionary = e["d"]
	var sp: Dictionary = ItemDB.animals.get(String(d.get("s", "")), {})
	var nm := String(sp.get("label", "animal")).to_lower()
	var lead := int(d.get("lead", -1))
	if id in (sp.get("eats", []) as Array):
		return {"text": "Feed the %s" % nm, "kind": "animal"}
	if lead >= 0 and lead == Net.my_id():
		return {"text": "Let the %s go" % nm, "kind": "animal"}
	if lead >= 0:
		return {"text": "Led by %s" % Net.player_name(lead), "kind": "none"}
	if bool(sp.get("lead", false)) and id == "twine":
		return {"text": "Tie a lead on the %s" % nm, "kind": "animal"}
	return {}


static func _raft_beside(p: Vector3) -> Dictionary:
	## The raft (and its new floor cell) that a section laid on the sea at p
	## would join: {"eid", "cell"} or {}.
	for v in RaftView.all():
		var rv := v as RaftView
		var lp := rv.view_xf().affine_inverse() * p
		var c := Vector3i(floori(lp.x), 0, floori(lp.z))
		if Raft.floor_ok(rv.cells(), c):
			return {"eid": rv.entity_id, "cell": c}
	return {}


static func sneak_hint(t: Dictionary, s: Dictionary) -> String:
	## A reminder of what sneak-right-click would do, when you hold something
	## that is set down that way.
	var id := String(s.get("i", ""))
	if id == "" or String(t.get("type", "")) != "block" or ItemDB.block_of(id) >= 0:
		return ""
	var b: int = t["id"]
	if t["normal"] != Vector3i.UP or not Blocks.is_solid(b) or not World.cell_free((t["cell"] as Vector3i) + Vector3i.UP):
		return ""
	if ItemDB.def(id).has("knap"):
		return "Sneak + right-click: lay it down to knap"
	if id == "clay":
		return "Sneak + right-click: lay it down to shape"
	if id == "stick" or ItemDB.fuel(id) == "tinder":
		return "Sneak + right-click: start a fire pit"
	if ItemDB.is_raw_pottery(id):
		return "Sneak + right-click: set it down (for a pit kiln)"
	if id == "coconut" and Blocks.name_of(b) in ["sand", "grass", "dirt"]:
		return "Sneak + right-click: plant it (a palm grows)"
	return ""
