class_name CraftActs
extends RefCounted
## Things set down on the ground and worked there (host):
##
## * Knapping - a stone or flint laid flat shows a 16x16 grid.  Pick what to make;
##   the outline shows what must stay.  Every left click chips one cell away.
##   Chip into the outline more than twice and the stone splits.
## * Clay forming - a lump of clay on the ground; build the chosen shape one
##   16x16 layer at a time (right click adds, left click removes).  Each lump is
##   worth 32 cells; more lumps are taken from your inventory as you go.
## * Ground storage - sneak-right-click anything else onto the ground to leave
##   it there (up to four stacks).  Raw pottery left there becomes a pit kiln as
##   soon as you cover it with dry grass.
## * Storage jars - placed jars keep eight stacks.

const N := ItemDB.KNAP
const MAX_MISS := 2
const GROUND_SLOTS := 4
const JAR_SLOTS := 8

var a: Actions


func _init(actions: Actions) -> void:
	a = actions


func set_down(pid: int, c: Vector3i, slot: int, s: Dictionary, sneak: bool) -> bool:
	if s.is_empty():
		return false
	var id := String(s["i"])
	var inv := World.inventory_of(pid)
	var d := ItemDB.def(id)
	if id == "jar":
		inv.take_from(slot, 1)
		World.mark_inventory(pid)
		World.spawn_be("jar", c, {"inv": []})
		World.fx("place", Vector3(c) + Vector3(0.5, 0.3, 0.5), {"b": 0})
		return true
	if not sneak:
		return false
	if d.has("knap"):
		inv.take_from(slot, 1)
		World.mark_inventory(pid)
		var cells := ItemDB.stone_mask.duplicate()
		World.spawn_be("knap", c, {"mat": String(d["knap"]), "r": "", "cells": cells, "miss": 0})
		World.fx("place", Vector3(c) + Vector3(0.5, 0.05, 0.5), {"b": Blocks.id_of("loose_stones")})
		World.open_chooser(pid, "knap", c)
		return true
	if id == "clay":
		inv.take_from(slot, 1)
		World.mark_inventory(pid)
		World.spawn_be("clay", c, {"r": "", "vox": PackedByteArray(), "layer": 0, "budget": ItemDB.CLAY_PER_LUMP, "lumps": 1})
		World.fx("clay", Vector3(c) + Vector3(0.5, 0.05, 0.5))
		World.open_chooser(pid, "clay", c)
		return true
	if id == "stick" or ItemDB.fuel(id) == "tinder":
		return a.fire.new_firepit(pid, c, slot, id)
	# anything else: leave it lying here
	var one := inv.take_from(slot, 1)
	World.mark_inventory(pid)
	World.spawn_be("ground", c, {"items": [one]})
	World.fx("place", Vector3(c) + Vector3(0.5, 0.1, 0.5), {"b": 0, "i": id})
	if ItemDB.is_raw_pottery(id):
		World.hint_to(pid, "kiln")
	return true


# ---------------------------------------------------------------------------
# Ground storage
# ---------------------------------------------------------------------------

static func slots_used(items: Array) -> int:
	var n := 0
	for s in items:
		n += int(ItemDB.def(String(s["i"])).get("size", 1)) if ItemDB.is_raw_pottery(String(s["i"])) else (2 if String(s["i"]) == "pot" else 1)
	return n


func use_ground(pid: int, be: Dictionary, slot: int, sneak: bool) -> void:
	var d: Dictionary = be["d"]
	var s := a.held(pid, slot)
	if s.is_empty():
		take_ground(pid, be)
		return
	var id := String(s["i"])
	var items: Array = d.get("items", []).duplicate(true)
	# raw pottery covered with dry grass becomes a pit kiln
	if ItemDB.fuel(id) == "tinder" and not items.is_empty() and not bool(d.get("ash", false)):
		var all_raw := true
		for it in items:
			if not ItemDB.is_raw_pottery(String(it["i"])):
				all_raw = false
		if all_raw:
			var c: Vector3i = d["cell"]
			World.inventory_of(pid).take_from(slot, 1)
			World.mark_inventory(pid)
			World.despawn(be["id"])
			World.spawn_be("kiln", c, {"items": items, "grass": 1, "sticks": 0, "lit": false, "t": 0.0, "stage": 0})
			World.fx("place_fuel", Vector3(c) + Vector3(0.5, 0.2, 0.5), {"i": id})
			World.hint_to(pid, "kiln_cover")
			return
	# add one more to what lies here
	var inv := World.inventory_of(pid)
	for it in items:
		if String(it["i"]) == id and ItemDB.can_stack(id, s["d"]) and ItemDB.can_stack(id, it["d"]) and int(it["n"]) < ItemDB.stack_max(id):
			inv.take_from(slot, 1)
			it["n"] = int(it["n"]) + 1
			World.update(be["id"], {"items": items})
			World.mark_inventory(pid)
			World.fx("place", Vector3(d["cell"]) + Vector3(0.5, 0.1, 0.5), {"b": 0, "i": id})
			return
	var one := Inventory.make(id, 1, s["d"].duplicate(true))
	if slots_used(items + [one]) > GROUND_SLOTS:
		World.notify(pid, "There's no room for that here.")
		return
	inv.take_from(slot, 1)
	items.append(one)
	World.update(be["id"], {"items": items})
	World.mark_inventory(pid)
	World.fx("place", Vector3(d["cell"]) + Vector3(0.5, 0.1, 0.5), {"b": 0, "i": id})


func take_ground(pid: int, be: Dictionary) -> void:
	var items: Array = be["d"].get("items", []).duplicate(true)
	if items.is_empty():
		World.despawn(be["id"])
		return
	var s: Dictionary = items.pop_back()
	a.give_stack(pid, s)
	if items.is_empty():
		World.despawn(be["id"])
	else:
		World.update(be["id"], {"items": items})
	if ["bowl", "pot", "jar", "brick"].has(String(s["i"])):
		a.flag_player(pid, "fired_pottery")


# ---------------------------------------------------------------------------
# Knapping
# ---------------------------------------------------------------------------

func use_knap(pid: int, be: Dictionary, slot: int, sneak: bool) -> void:
	var d: Dictionary = be["d"]
	if String(d["r"]) == "":
		World.open_chooser(pid, "knap", d["cell"])
	elif (d["cells"] as PackedByteArray) == ItemDB.stone_mask:
		World.open_chooser(pid, "knap", d["cell"])


func knap_choose(pid: int, args: Dictionary) -> void:
	var c: Vector3i = args.get("c", Vector3i(-1, -1, -1))
	var r := String(args.get("r", ""))
	var be := World.be(c)
	if be.is_empty() or be["t"] != "knap" or not ItemDB.knapping.has(r) or not a.in_reach(pid, c):
		return
	if (be["d"]["cells"] as PackedByteArray) != ItemDB.stone_mask:
		return   # already being worked: the plan can't change
	World.update(be["id"], {"r": r})


func knap(pid: int, args: Dictionary) -> void:
	var c: Vector3i = args.get("c", Vector3i(-1, -1, -1))
	var i := int(args.get("i", -1))
	var be := World.be(c)
	if be.is_empty() or be["t"] != "knap" or i < 0 or i >= N * N or not a.in_reach(pid, c):
		return
	var d: Dictionary = be["d"]
	var r := String(d["r"])
	if r == "":
		World.open_chooser(pid, "knap", c)
		return
	var cells: PackedByteArray = (d["cells"] as PackedByteArray).duplicate()
	if cells[i] == 0:
		return
	if not a._rate(pid, "knap", 40):
		return
	var mask: PackedByteArray = ItemDB.knapping[r]["mask"]
	cells[i] = 0
	var miss := int(d["miss"])
	var at := Vector3(c) + Vector3((i % N + 0.5) / N, 0.08, (i / N + 0.5) / N)
	if mask[i] == 1:
		miss += 1
		if miss > MAX_MISS:
			World.despawn(be["id"])
			World.fx("knap_fail", at, {"mat": d["mat"]})
			World.notify(pid, "Too much chipped off the shape: the stone splits. Chip only the shaded cells.", "warn")
			return
		World.notify(pid, "That cell was part of the %s. (%d more and the stone splits.)" % [String(ItemDB.knapping[r]["label"]).to_lower(), MAX_MISS - miss + 1], "warn")
	World.fx_except(pid, "knap", at, {"mat": d["mat"]})
	# finished when nothing outside the outline is left
	var left := 0
	for k in N * N:
		if cells[k] == 1 and mask[k] == 0:
			left += 1
	if left == 0:
		World.despawn(be["id"])
		var q := 1.0 - 0.15 * miss
		a.give(pid, r, 1, {"mat": String(d["mat"]), "q": q}, Vector3(c) + Vector3(0.5, 0.3, 0.5))
		World.fx("knap_done", Vector3(c) + Vector3(0.5, 0.1, 0.5), {"mat": d["mat"]})
		a.flag_player(pid, "knapped:" + r)
		World.discover("first_knap", pid)
		return
	World.update(be["id"], {"cells": cells, "miss": miss})


# ---------------------------------------------------------------------------
# Clay forming
# ---------------------------------------------------------------------------

func use_clay(pid: int, be: Dictionary, slot: int, sneak: bool) -> void:
	if String(be["d"]["r"]) == "":
		World.open_chooser(pid, "clay", be["d"]["cell"])


func clay_choose(pid: int, args: Dictionary) -> void:
	var c: Vector3i = args.get("c", Vector3i(-1, -1, -1))
	var r := String(args.get("r", ""))
	var be := World.be(c)
	if be.is_empty() or be["t"] != "clay" or not ItemDB.clayforming.has(r) or not a.in_reach(pid, c):
		return
	var d: Dictionary = be["d"]
	if (d["vox"] as PackedByteArray).count(1) > 0 and String(d["r"]) != "":
		return
	var layers: Array = ItemDB.clayforming[r]["layers"]
	var vox := PackedByteArray()
	vox.resize(N * N * layers.size())
	World.update(be["id"], {"r": r, "vox": vox, "layer": 0})


static func clay_target(r: String, layer: int) -> PackedByteArray:
	var layers: Array = ItemDB.clayforming[r]["layers"]
	return layers[clampi(layer, 0, layers.size() - 1)]


func clay(pid: int, args: Dictionary) -> void:
	var c: Vector3i = args.get("c", Vector3i(-1, -1, -1))
	var cells: PackedInt32Array = args.get("cells", PackedInt32Array())
	var add := bool(args.get("add", true))
	var be := World.be(c)
	if be.is_empty() or be["t"] != "clay" or not a.in_reach(pid, c) or cells.size() > N * N:
		return
	var d: Dictionary = be["d"]
	var r := String(d["r"])
	if r == "":
		World.open_chooser(pid, "clay", c)
		return
	if not a._rate(pid, "clay", 40):
		return
	var vox: PackedByteArray = (d["vox"] as PackedByteArray).duplicate()
	var layer := int(d["layer"])
	var budget := int(d["budget"])
	var lumps := int(d["lumps"])
	var inv := World.inventory_of(pid)
	var changed := 0
	for i in cells:
		if i < 0 or i >= N * N:
			continue
		var k := layer * N * N + i
		if add:
			if vox[k] == 1:
				continue
			if budget <= 0:
				if not inv.remove("clay", 1):
					World.notify(pid, "You need more clay.", "warn")
					break
				budget += ItemDB.CLAY_PER_LUMP
				lumps += 1
				World.mark_inventory(pid)
			vox[k] = 1
			budget -= 1
			changed += 1
		else:
			if vox[k] == 0:
				continue
			vox[k] = 0
			budget += 1
			changed += 1
	if changed == 0:
		return
	World.fx_except(pid, "clay", Vector3(c) + Vector3(0.5, 0.06 + layer / 16.0, 0.5))
	# the layer is done when it matches the plan exactly
	var target := clay_target(r, layer)
	var done := true
	for i in N * N:
		if vox[layer * N * N + i] != target[i]:
			done = false
			break
	var layers: Array = ItemDB.clayforming[r]["layers"]
	if done:
		layer += 1
		if layer >= layers.size():
			World.despawn(be["id"])
			var out := String(ItemDB.clayforming[r]["out"])
			a.give(pid, out, int(ItemDB.clayforming[r]["n"]), {}, Vector3(c) + Vector3(0.5, 0.3, 0.5))
			var refund := budget / ItemDB.CLAY_PER_LUMP
			if refund > 0:
				a.give(pid, "clay", refund)
			World.fx("clay_done", Vector3(c) + Vector3(0.5, 0.2, 0.5))
			a.flag_player(pid, "shaped:" + r)
			World.hint_to(pid, "raw_pottery")
			return
	World.update(be["id"], {"vox": vox, "layer": layer, "budget": budget, "lumps": lumps})


func clay_refund(be: Dictionary) -> int:
	var d: Dictionary = be["d"]
	var total := int(d.get("budget", 0)) + (d.get("vox", PackedByteArray()) as PackedByteArray).count(1)
	return total / ItemDB.CLAY_PER_LUMP


# ---------------------------------------------------------------------------
# Storage jar
# ---------------------------------------------------------------------------

func use_jar(pid: int, be: Dictionary, slot: int, sneak: bool) -> void:
	open_container(pid, be["d"]["cell"])


func open_container(pid: int, c: Vector3i) -> void:
	if pid == a.multiplayer.get_unique_id():
		Events.open_chooser.emit("jar", c)
	else:
		World.open_chooser(pid, "jar", c)


func container_click(pid: int, args: Dictionary) -> void:
	## Clicks on a jar's slots (0-7), with the same rules as the inventory screen.
	var c: Vector3i = args.get("c", Vector3i(-1, -1, -1))
	var slot := int(args.get("slot", -1))
	var button := int(args.get("button", 0))
	var shift := bool(args.get("shift", false))
	var be := World.be(c)
	if be.is_empty() or be["t"] != "jar" or not a.in_reach(pid, c):
		return
	var jar: Array = (be["d"].get("inv", []) as Array).duplicate(true)
	while jar.size() < JAR_SLOTS:
		jar.append({})
	var inv := World.inventory_of(pid)
	if slot >= 100:
		# shift-click from the player's own slots into the jar
		var ps := slot - 100
		if ps < 0 or ps >= Inventory.MAIN or inv.is_empty_slot(ps):
			return
		var moving := inv.get_slot(ps).duplicate(true)
		inv.set_slot(ps, {})
		var left := _merge_list(jar, moving)
		if left > 0:
			moving["n"] = left
			inv.set_slot(ps, moving)
	elif slot >= 0 and slot < JAR_SLOTS:
		var s: Dictionary = jar[slot]
		var cur := inv.get_slot(Inventory.CURSOR)
		if shift:
			if s.is_empty():
				return
			var left2 := inv.add(String(s["i"]), int(s["n"]), s["d"])
			if left2 > 0:
				s["n"] = left2
			else:
				jar[slot] = {}
		elif button == 0:
			if cur.is_empty():
				inv.set_slot(Inventory.CURSOR, s)
				jar[slot] = {}
			elif s.is_empty():
				jar[slot] = cur
				inv.set_slot(Inventory.CURSOR, {})
			elif a._same(cur, s):
				var mx := ItemDB.stack_max(String(s["i"]))
				var take := mini(int(cur["n"]), mx - int(s["n"]))
				s["n"] = int(s["n"]) + take
				cur["n"] = int(cur["n"]) - take
				if int(cur["n"]) <= 0:
					inv.set_slot(Inventory.CURSOR, {})
			else:
				jar[slot] = cur
				inv.set_slot(Inventory.CURSOR, s)
		else:
			if cur.is_empty() and not s.is_empty():
				var half := int(ceil(int(s["n"]) / 2.0))
				inv.set_slot(Inventory.CURSOR, Inventory.make(String(s["i"]), half, s["d"].duplicate(true)))
				s["n"] = int(s["n"]) - half
				if int(s["n"]) <= 0:
					jar[slot] = {}
			elif not cur.is_empty() and s.is_empty():
				jar[slot] = inv.take_from(Inventory.CURSOR, 1)
			elif not cur.is_empty() and a._same(cur, s) and int(s["n"]) < ItemDB.stack_max(String(s["i"])):
				s["n"] = int(s["n"]) + 1
				inv.take_from(Inventory.CURSOR, 1)
	else:
		return
	World.update(be["id"], {"inv": jar})
	World.mark_inventory(pid)


func _merge_list(arr: Array, s: Dictionary) -> int:
	var n := int(s["n"])
	var id := String(s["i"])
	var mx := ItemDB.stack_max(id)
	if ItemDB.can_stack(id, s["d"]):
		for t in arr:
			if not t.is_empty() and a._same(t, s) and int(t["n"]) < mx:
				var take := mini(n, mx - int(t["n"]))
				t["n"] = int(t["n"]) + take
				n -= take
				if n <= 0:
					return 0
	for i in arr.size():
		if (arr[i] as Dictionary).is_empty():
			var take := mini(n, mx)
			arr[i] = Inventory.make(id, take, s["d"].duplicate(true))
			n -= take
			if n <= 0:
				return 0
	return n
