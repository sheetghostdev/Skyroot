class_name InteractionRules
extends RefCounted
## What can the player do with what they are holding to what they are looking
## at?  Returns up to three options keyed "interact" (E), "primary" (LMB) and
## "secondary" (RMB).  Each option: {label, action, args, anim, hold, enabled, why}
## or {label, local: Callable}.  The host re-validates every request.

static var _lift_cache: Dictionary = {}


const HEAP_STARTERS := ["leaves", "grass", "food_scraps", "straw"]


static func opt(label: String, action: String, args: Dictionary = {}, anim: String = "", hold: bool = false) -> Dictionary:
	return {"label": label, "action": action, "args": args, "anim": anim, "hold": hold, "enabled": true}


static func fire_verb(held: String) -> String:
	## "Roast" only what cooks; fuel and pots go in; anything else just burns.
	if ItemDB.food(held).has("cooks_to"):
		return "Roast %s at the fire"
	if not ItemDB.fuel(held).is_empty() or held == "pot":
		return "Put %s in the fire"
	return "Put %s in the fire (it will burn)"


static func confirm(label: String, action: String, args: Dictionary = {}, anim: String = "", secs: float = 0.8) -> Dictionary:
	## For something that can't be undone: it happens only after the button is held a moment.
	return {"label": label + " (hold)", "action": action, "args": args, "anim": anim, "hold": false, "confirm_s": secs, "enabled": true}


static func disabled(label: String, why: String) -> Dictionary:
	return {"label": label, "enabled": false, "why": why}


static func options(p: LocalPlayer, t: Dictionary) -> Dictionary:
	var out := {}
	var stack := p.held_stack()
	var held := String(stack.get("i", ""))
	var hd: Dictionary = stack.get("d", {})
	var tool := ItemDB.tool_kind(held)
	# things you can do with the held item regardless of target
	_self_options(out, held, hd, t)
	if t.is_empty():
		return out
	match String(t.get("kind", "")):
		"entity":
			_entity_options(out, p, t, held, hd, tool)
		"ground":
			_ground_options(out, p, t, held, hd, tool)
		"water":
			_water_options(out, p, t, held, hd)
		"cliff":
			if held != "" and ItemDB.exists(held):
				pass
	# generic placement of the held item on any surface pointing up
	if not out.has("secondary") and held != "" and t.has("pos") and t["normal"].y > 0.45 and _placeable(held) and t.get("etype", "") != "compost":
		var xf := place_xf(p, t["pos"], t["normal"], held, hd)
		out["secondary"] = opt("Place %s" % ItemDB.display_name(held, hd), "place", {"xf": xf}, "place")
	return out


static func _placeable(id: String) -> bool:
	return ItemDB.exists(id)


static func place_xf(p: LocalPlayer, pos: Vector3, normal: Vector3, id: String, d: Dictionary) -> Transform3D:
	var yaw := p.yaw + p.interactor.place_yaw
	var b := Basis(Vector3.UP, yaw)
	var key := id + str(hash(d))
	if not _lift_cache.has(key):
		var vis := ItemVisual.single(id, d)
		var lift := 0.0
		if vis:
			lift = -Models.aabb_of(vis).position.y
			vis.free()
		_lift_cache[key] = lift
	return Transform3D(b, pos + Vector3(0, float(_lift_cache[key]) + 0.004, 0))


# ---------------------------------------------------------------------------

static func _self_options(out: Dictionary, held: String, hd: Dictionary, t: Dictionary) -> void:
	var food := ItemDB.food(held)
	if not food.is_empty():
		out["primary"] = opt("Eat %s" % ItemDB.display_name(held, hd), "eat", {}, "eat")
	if held == "pot":
		var water := float(hd.get("water", 0.0))
		var cont: Dictionary = hd.get("contents", {})
		if cont.has("porridge"):
			out["primary"] = opt("Eat porridge", "eat_vessel", {}, "eat")
		elif water > 0.01:
			out["primary"] = opt("Drink (%.2f L)" % water, "drink_vessel", {}, "drink")
	if held == "grain":
		out["primary"] = opt("Thresh grain (seeds + straw)", "process_held", {}, "knead")
	if held == "pot" and String(hd.get("state", "")) == "cracked":
		out["primary"] = opt("Break it into potsherds", "break_pot", {}, "hammer")


static func _entity_options(out: Dictionary, p: LocalPlayer, t: Dictionary, held: String, hd: Dictionary, tool: String) -> void:
	var ent: Dictionary = t["ent"]
	var d: Dictionary = ent["d"]
	var eid: int = t["eid"]
	var part: String = t.get("part", "")
	match String(ent["t"]):
		"item":
			var iid := String(d.get("i", ""))
			var nm := ItemDB.display_name(iid, d.get("x", {}))
			var n := int(d.get("n", 1))
			if Inventory.stack_kg(iid, 1, d.get("x", {})) > Actions.LIFT_KG:
				out["interact"] = disabled("%s (too heavy to lift)" % nm, "Split it where it lies with an axe.")
			else:
				var what := ItemDB.a_name(iid, d.get("x", {})) if n == 1 else ItemDB.count_name(iid, n, d.get("x", {}))
				if bool(d.get("hot", false)):
					out["interact"] = opt("Take %s (hot!)" % what, "pickup", {"eid": eid}, "pick")
				else:
					out["interact"] = opt("Pick up %s" % what, "pickup", {"eid": eid}, "pick")
			var proc: Dictionary = ItemDB.def(iid).get("process", {})
			var in_fire: bool = d.get("x", {}).has("fm")
			if in_fire and (not proc.is_empty() or ItemDB.has_tag(iid, "splittable")):
				out["primary"] = disabled("Work the %s" % nm.to_lower(), "Take it out of the fire first.")
			elif not proc.is_empty():
				var need := String(proc.get("tool", ""))
				if need == "hand" or tool == need or (need == "cut" and tool == "chop"):
					var verb := String(proc.get("label", "Cut up %s" % nm.to_lower() if need != "chop" else "Chop up %s" % nm.to_lower()))
					out["primary"] = opt(verb, "process", {"eid": eid}, "cut" if tool == "cut" else "swing", true)
				else:
					out["primary"] = disabled("Process %s" % nm.to_lower(), "You need a %s." % {"cut": "sharp blade", "chop": "stone axe"}.get(need, "tool"))
			if ItemDB.has_tag(iid, "splittable") and not in_fire:
				if tool == "chop":
					out["primary"] = opt("Split %s (aim at the end)" % nm.to_lower(), "split", {"eid": eid, "pos": t["pos"]}, "swing")
				else:
					out["primary"] = disabled("Split %s" % nm.to_lower(), "Splitting wood needs a stone axe.")
			var site := int(d.get("site", -1))
			var site_e := World.get_entity(site) if site >= 0 else {}
			var burning := not site_e.is_empty() and bool(site_e["d"].get("lit", false))
			if held == "torch" and ItemDB.fuel(iid).size() > 0:
				out["primary"] = opt("Light the %s" % nm.to_lower(), "ignite", {"eid": eid}, "place")
			if held == "earth":
				if site >= 0 or ItemDB.fuel(iid).size() > 0:
					out["primary"] = opt("Pack earth over the %s" % ("fire" if burning else "pile"), "fire_cover", {"eid": eid, "pos": t["pos"]}, "pack", true)
			if burning:
				if held == "stick":
					out["secondary"] = opt("Light the stick in the fire", "fire_torch", {"eid": site}, "place")
				elif held != "" and (not ItemDB.fuel(held).is_empty() or not ItemDB.food(held).is_empty() or held == "pot"):
					var verb2 := fire_verb(held)
					out["secondary"] = opt(verb2 % ItemDB.display_name(held, hd).to_lower(), "fire_add", {"eid": site}, "place")
			if iid == "pot" and held == "" and float(d.get("x", {}).get("water", 0.0)) > 0.01:
				out["primary"] = opt("Drink from the %s" % nm.to_lower(), "drink_entity", {"eid": eid}, "drink")
			if iid == "pot" and held == "seed_grain":
				if String(d.get("x", {}).get("state", "")) == "fired":
					out["primary"] = opt("Put grain in the %s" % nm.to_lower(), "pot_add", {"eid": eid}, "place")
				else:
					out["primary"] = disabled("Put grain in the pot", "Only fired pottery holds food and water.")
			if iid == "hearth_board" and held == "stick":
				out["primary"] = opt("Drill for fire", "work_start", {"kind": "fire_drill", "board": eid, "pos": ent["xf"].origin}, "place")
			elif iid == "hearth_board" and held == "":
				out["primary"] = disabled("Drill for fire", "Hold a straight stick to spin in the notch.")
		"tree":
			_tree_options(out, t, d, eid, part, tool)
		"outcrop":
			if part.begins_with("loose:"):
				out["interact"] = opt("Pry loose a stone", "outcrop_take", {"eid": eid, "idx": int(part.get_slice(":", 1))}, "pick")
			else:
				_work_surface(out, p, t, held, hd, eid)
				var loose: Array = d.get("loose", [])
				if held == "stone" or tool == "chop" or tool == "dig":
					if not loose.has(0):
						out["primary"] = disabled("Break a stone loose", "There are loose stones here already.")
					elif float(d.get("rock", 0.0)) < ItemDB.unit_mass("stone"):
						out["primary"] = disabled("Break a stone loose", "The rock is worn down to its core.")
					else:
						out["primary"] = opt("Break a stone loose (%d%%)" % int(float(d.get("pry", 0.0)) * 100.0), "outcrop_break", {"eid": eid}, "swing" if tool != "" else "hammer", true)
		"flat_stone", "boulder":
			_work_surface(out, p, t, held, hd, eid)
		"mushrooms":
			if part.begins_with("cap:"):
				out["interact"] = opt("Pick mushroom", "pick_mushroom", {"eid": eid, "idx": int(part.get_slice(":", 1))}, "pick")
		"bush":
			if float(d.get("berries", 0.0)) >= 0.25:
				out["interact"] = opt("Pick berries", "pick_berries", {"eid": eid}, "pick")
			else:
				out["interact"] = disabled("Berry bush (ripening)", "The berries are not ripe yet. A watered bush fruits faster.")
			_watering(out, held, hd, eid, t)
		"plant":
			_plant_options(out, t, d, eid, held, hd, tool)
		"work":
			_work_options(out, p, t, d, eid, held)
		"site":
			SiteRules.options(out, p, t, d, eid, held, hd, tool)
		"structure":
			BuildRules.options(out, p, t, d, eid, held, hd, tool)
		"compost":
			CompostRules.options(out, p, t, d, eid, held, hd, tool)
		"satchel":
			out["interact"] = opt("Recover belongings (%s)" % String(d.get("owner", "")), "satchel_take", {"eid": eid}, "pick")
		"mossy_log":
			_work_surface(out, p, t, held, hd, eid)


static func _tree_options(out: Dictionary, t: Dictionary, d: Dictionary, eid: int, part: String, tool: String) -> void:
	var felled := bool(d.get("felled", false))
	if part.begins_with("sb:"):
		var i := int(part.get_slice(":", 1))
		var g := float(d["sb"][i])
		if g < 0.98:
			out["primary"] = disabled("Young branch (%d%%)" % int(g * 100.0), "This branch is still regrowing. Cutting it now would waste it.")
		elif tool == "cut" or tool == "chop":
			out["primary"] = opt("Cut branch", "tree_cut", {"eid": eid, "part": part}, "cut" if tool == "cut" else "swing", true)
		else:
			out["primary"] = disabled("Cut branch", "Too tough to snap by hand - you need a sharp edge. Knap a stone blade.")
	elif part.begins_with("lb:"):
		var j := int(part.get_slice(":", 1))
		var g2 := float(d["lb"][j])
		if g2 < 0.98:
			out["primary"] = disabled("Regrowing limb (%d%%)" % int(g2 * 100.0), "This limb is still regrowing.")
		elif tool == "chop":
			out["primary"] = opt("Chop limb (%d%%)" % int((1.0 - float(d["lhp"][j])) * 100.0), "tree_chop_limb", {"eid": eid, "part": part}, "swing", true)
		else:
			out["primary"] = disabled("Chop limb", "A limb this thick needs a stone axe.")
	elif part == "trunk" and not felled:
		if tool == "chop":
			out["primary"] = opt("Fell the tree (%d%%)" % int((1.0 - float(d.get("trunk", 1.0))) * 100.0), "tree_fell", {"eid": eid}, "swing", true)
			out["primary"]["warn"] = "felling"
		else:
			out["primary"] = disabled("The great tree", "Its branches regrow if you leave the trunk standing.")
	elif part == "stump" or felled:
		var st := TreeSim.stage(d)
		out["interact"] = disabled("Stump - %s" % ("regrowing from its roots" if st != "dead" else "dead"), "Living roots push up new shoots. Water and nutrients help it regrow.")


static func _work_surface(out: Dictionary, p: LocalPlayer, t: Dictionary, held: String, hd: Dictionary, surface_eid: int) -> void:
	var n: Vector3 = t["normal"]
	if n.y < 0.6:
		return
	var inv := World.my_inventory
	var args := {"surface": surface_eid, "pos": t["pos"]}
	var hard := String(t.get("etype", "")) in ["flat_stone", "boulder", "outcrop"]
	match held:
		"stone":
			if not hard:
				out["interact"] = disabled("Shape stone", "Knapping needs a hard anvil - use the flat stone or a boulder.")
			elif inv.count("stone") >= 2:
				out["interact"] = opt("Knap: shape this stone with another", "work_start", args.merged({"kind": "knap"}), "place")
			else:
				out["interact"] = disabled("Shape stone", "You need a second stone to strike with.")
		"clay":
			out["interact"] = opt("Prepare clay (add water, knead)", "work_start", args.merged({"kind": "clay_prep"}), "place")
		"clay_prepared":
			out["interact"] = opt("Shape a vessel", "work_start", args.merged({"kind": "pottery"}), "place")
		"fiber":
			if inv.count("fiber") >= 2:
				out["interact"] = opt("Twist fibers into cordage", "work_start", args.merged({"kind": "cordage"}), "place")
			else:
				out["interact"] = disabled("Twist cordage", "You need at least two bundles of fiber.")
		"stone_head", "blade":
			# a shaped stone can always go back on the anvil to be worked further
			var rework := "Keep knapping this stone"
			if held == "blade":
				rework = "Rework the blade"
			elif String(hd.get("shape", "")) != "":
				rework = "Rework the %s head" % String(hd["shape"])
			var knap_opt: Dictionary
			if not hard:
				knap_opt = disabled(rework, "Knapping needs a hard anvil - use the flat stone or a boulder.")
			elif inv.count("stone") < 1:
				knap_opt = disabled(rework, "You need a stone to strike with.")
			else:
				knap_opt = opt(rework, "work_start", args.merged({"kind": "knap"}), "place")
			if held == "stone_head" and String(hd.get("shape", "")) != "":
				if inv.count("stick") >= 1 and inv.count("cordage") >= 1:
					out["interact"] = opt("Haft the head onto a handle", "work_start", args.merged({"kind": "haft"}), "place")
				else:
					out["interact"] = disabled("Haft the head", "Hafting needs a stick (handle) and cordage.")
				out["primary"] = knap_opt
			else:
				out["interact"] = knap_opt


static func _work_options(out: Dictionary, p: LocalPlayer, t: Dictionary, d: Dictionary, eid: int, held: String) -> void:
	var kind := String(d.get("kind", ""))
	var by := int(d.get("by", 0))
	var label: String = {"knap": "Continue knapping", "clay_prep": "Continue working the clay", "pottery": "Continue shaping",
		"cordage": "Continue twisting", "haft": "Continue hafting", "fire_drill": "Use the fire drill"}.get(kind, "Work")
	if kind == "pottery" and bool(d.get("done", false)):
		out["interact"] = opt("Pick up the %s" % Pottery.display_name(d.get("pot", {})).to_lower(), "work_take", {"eid": eid}, "pick")
		return
	if by != 0 and by != p.pid and Net.players.has(by):
		out["interact"] = disabled("%s is working here" % Net.player_name(by), "Watch, or bring them materials.")
		return
	out["interact"] = opt(label, "work_open", {"eid": eid}, "")
	out["primary"] = opt("Gather up the work", "work_cancel", {"eid": eid}, "pick")


static func _plant_options(out: Dictionary, t: Dictionary, d: Dictionary, eid: int, held: String, hd: Dictionary, tool: String) -> void:
	var sp := String(d.get("sp", ""))
	var info := ItemDB.plant(sp)
	var g := float(d.get("g", 0.0))
	var nm := String(info.get("name", sp))
	if g >= 1.0:
		var need := String(info.get("tool", ""))
		# (a plant that wants a blade is slow to pull by hand, whatever else you're holding)
		if need == "" or tool == need or (need == "cut" and tool == "chop"):
			out["interact"] = opt("Harvest %s" % nm.to_lower(), "harvest", {"eid": eid}, "pick" if tool == "" else "cut")
		else:
			var slow := opt("Harvest %s (slow by hand)" % nm.to_lower(), "harvest", {"eid": eid}, "pick")
			slow["speed"] = 0.5
			out["interact"] = slow
	else:
		var notes: PackedStringArray = []
		if float(d.get("thirst", 0.0)) > 0.35:
			notes.append("thirsty")
		if float(d.get("hunger", 0.0)) > 0.35:
			notes.append("soil spent")
		var status := "growing %d%%" % int(g * 100.0)
		if notes.size() > 0:
			status += " - " + ", ".join(notes)
		out["interact"] = disabled("%s (%s)" % [nm, status], "Plants need moist soil, nutrients and daylight.")
	_watering(out, held, hd, eid, t)


static func _watering(out: Dictionary, held: String, hd: Dictionary, eid: int, t: Dictionary) -> void:
	if held == "pot" and float(hd.get("water", 0.0)) > 0.01:
		out["primary"] = opt("Water (%.2f L left)" % float(hd["water"]), "pour", {"pos": t["pos"], "eid": eid}, "pour")


static func _ground_options(out: Dictionary, p: LocalPlayer, t: Dictionary, held: String, hd: Dictionary, tool: String) -> void:
	var pos: Vector3 = t["pos"]
	var layer := World.terrain.layer_at(pos.x, pos.z)
	var k := TerrainData.cell_at(Vector2(pos.x, pos.z))
	var ki := TerrainData.cell_index(k.x, k.y)
	var grass := World.terrain.grass[ki]
	var tilled := World.terrain.tilled[ki] == 1
	var steep: bool = t["normal"].y < 0.5
	if layer == "rock":
		if tool == "dig" or held == "":
			out["primary"] = disabled("Bedrock", "Solid rock. Nothing to dig here.")
	elif layer == "water":
		pass
	elif not steep:
		var what := "clay" if layer == "clay" else "earth"
		if tool == "dig":
			out["primary"] = opt("Dig %s" % what, "dig", {"pos": pos}, "dig", true)
			if layer == "soil" and not tilled:
				out["secondary"] = opt("Till soil for planting", "till", {"pos": pos}, "till", true)
		elif held == "":
			if grass > 0.35 and layer == "soil":
				out["primary"] = opt("Pull grass", "cut_grass", {"pos": pos}, "pick", true)
			else:
				out["primary"] = opt("Dig %s with your hands" % what, "dig", {"pos": pos, "hands": true}, "dig", true)
		if tool == "cut" and grass > 0.3:
			out["primary"] = opt("Cut grass", "cut_grass", {"pos": pos}, "cut", true)
		if held == "earth":
			out["primary"] = opt("Fill / pack earth here", "fill", {"pos": pos}, "pack")
		if (held == "compost" or held == "ash") and layer == "soil":
			out["secondary"] = opt("Work %s into the soil" % ItemDB.display_name(held).to_lower(), "fertilize", {"pos": pos}, "dig")
		var plant_sp := String(ItemDB.def(held).get("plant", ""))
		if plant_sp != "" and plant_sp != "tree":
			if tilled:
				out["secondary"] = opt("Plant %s" % ItemDB.display_name(held).to_lower(), "plant", {"pos": pos}, "place")
			else:
				out["secondary"] = disabled("Plant %s" % ItemDB.display_name(held).to_lower(), "Till the soil first (digging tool, right mouse).")
		elif plant_sp == "tree" and layer == "soil":
			out["secondary"] = opt("Plant the tree seed", "plant", {"pos": pos}, "place")
		if held == "pot" and float(hd.get("water", 0.0)) > 0.01:
			out["primary"] = opt("Water the soil (%.2f L)" % float(hd["water"]), "pour", {"pos": pos}, "pour")
		if held == "torch":
			out["primary"] = disabled("Burning stick", "Touch it to dry fuel - straw, twigs or a fire lay - to light it.")
		if held == "hearth_board":
			if World.my_inventory.count("stick") >= 1:
				out["interact"] = opt("Set up a fire drill here", "work_start", {"kind": "fire_drill", "pos": pos}, "place")
			else:
				out["interact"] = disabled("Fire drill", "You also need a straight stick to spin.")
		if layer == "clay" and held == "pot" and float(hd.get("water", 0.0)) <= 0.0:
			pass
		if held in ["clay", "clay_prepared", "fiber", "stone_head", "stone"] and not out.has("interact"):
			_work_surface(out, p, t, held, hd, -1)
		# (a heap is started with what heaps are made of, not with food or cord you happen to hold)
		if held in HEAP_STARTERS and not out.has("interact") and layer in ["soil", "clay"] and not hd.has("fm"):
			out["interact"] = opt("Start a compost heap here", "compost_start", {"pos": pos}, "place")


static func _water_options(out: Dictionary, p: LocalPlayer, t: Dictionary, held: String, hd: Dictionary) -> void:
	if not WaterActions.near_pond(p.global_position):
		# (the same reach the island checks: aiming at the water from up the bank isn't enough)
		out["interact"] = disabled("Too far to reach the water", "Step down to the water's edge.")
		return
	if held == "pot":
		var st := String(hd.get("state", ""))
		var cap := Pottery.capacity(hd)
		if st == "fired" and cap > 0.0:
			if float(hd.get("water", 0.0)) < cap - 0.005:
				out["interact"] = opt("Fill the %s" % Pottery.display_name(hd).to_lower(), "fill_vessel", {}, "pick")
			else:
				out["interact"] = disabled("Already full", "The vessel is full.")
		elif st != "fired":
			out["interact"] = disabled("Fill vessel", "Unfired clay would turn back into mud. Fire it first.")
		else:
			out["interact"] = disabled("Fill vessel", "It is cracked and won't hold water.")
	else:
		out["interact"] = opt("Drink with cupped hands", "drink_pond", {}, "drink")
