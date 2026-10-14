class_name BlockActs
extends RefCounted
## Host rules for breaking and placing blocks: tools, drops, felling whole
## trees, plants that go with the block they stand on, sand and gravel falling.

const NATURAL := 8          # meta bit: a log that grew (felling takes the whole tree)
const MAX_TREE := 80
const FALL_MS := 1500      # how long a felled tree takes to come down

var a: Actions


func _init(actions: Actions) -> void:
	a = actions


static func break_time(id: int, meta: int, tool_kind: String) -> float:
	## Seconds of holding the button.  -1: can't be broken this way.  (Shared by
	## the client, which times the break, and the host, which checks the tool.)
	var d := Blocks.def(id)
	var hard := float(d.get("hard", 1.0))
	if hard < 0.0:
		return -1.0
	var needs := String(d.get("needs", ""))
	if needs != "" and tool_kind != needs:
		return -1.0
	var t := hard
	var kind := String(d.get("tool", needs))
	if kind != "" and kind == tool_kind:
		t = hard / maxf(0.5, _tool_speed(tool_kind))
	if bool(d.get("tree", false)) and meta & NATURAL:
		t *= 2.4      # a whole tree comes down
	return maxf(0.0, t)


static func _tool_speed(kind: String) -> float:
	for id in ItemDB.items:
		var ti := ItemDB.tool_info(id)
		if String(ti.get("kind", "")) == kind:
			return float(ti.get("speed", 1.0))
	return 1.0


func break_at(pid: int, args: Dictionary) -> void:
	var c: Vector3i = args.get("c", Vector3i(-1, -1, -1))
	var slot := int(args.get("slot", -1))
	if not a.in_reach(pid, c) or not a._rate(pid, "break", 60):
		return
	var be := World.be(c)
	if not be.is_empty():
		_break_be(pid, be)
		return
	var id := World.block(c)
	if id == 0 or Blocks.shape[id] == Blocks.Shape.LIQUID:
		return
	var kind := a.held_kind(pid, slot)
	var m := World.block_meta(c)
	if break_time(id, m, kind) < 0.0:
		var needs := String(Blocks.def(id).get("needs", ""))
		if needs == "pick":
			World.notify(pid, "Granite is too hard to break with what you have.", "warn")
		elif needs != "":
			World.notify(pid, "You need %s for that." % ("an " + needs if needs[0] in "aeiou" else "a " + needs), "warn")
		return
	var d := Blocks.def(id)
	if bool(d.get("tree", false)) and m & NATURAL:
		_fell(pid, c, id, slot)
		return
	var drops := drops_of(id, m, kind)
	remove_block(c)
	var at := Vector3(c) + Vector3(0.5, 0.3, 0.5)
	for s in drops:
		a.drop_item(String(s["i"]), int(s["n"]), {}, at + Vector3(randf_range(-0.2, 0.2), 0, randf_range(-0.2, 0.2)))
	var tool_kind := String(d.get("tool", d.get("needs", "")))
	if kind != "" and kind == tool_kind:
		a.wear_tool(pid, slot)
	World.fx_except(pid, "break", Vector3(c) + Vector3(0.5, 0.5, 0.5), {"b": id})
	if Blocks.name_of(id) == "tallgrass" and kind != "knife":
		World.hint_to(pid, "grass_knife")


static func drops_of(id: int, m: int, kind: String) -> Array:
	var d := Blocks.def(id)
	var out: Array = []
	if d.has("crop"):
		var crop := String(d["crop"])
		if m >= 3:
			if crop == "turnip":
				out.append({"i": "turnip", "n": randi_range(2, 3)})
				out.append({"i": "seeds_turnip", "n": randi_range(1, 2)})
			else:
				out.append({"i": "plant_fiber", "n": randi_range(2, 4)})
				out.append({"i": "seeds_flax", "n": randi_range(1, 2)})
		else:
			out.append({"i": "seeds_" + crop, "n": 1})
		return out
	if Blocks.name_of(id) == "berry_bush":
		out.append({"i": "berry_bush", "n": 1})
		if m == 1:
			out.append({"i": "berries", "n": randi_range(2, 4)})
		return out
	if not d.has("drops"):
		var item := String(d.get("item", ""))
		if item != "":
			out.append({"i": item, "n": 1})
		return out
	for dr in d["drops"]:
		if dr.has("tool") and String(dr["tool"]) != kind:
			continue
		if randf() > float(dr.get("p", 1.0)):
			continue
		var n := randi_range(int(dr["n"][0]), int(dr["n"][1]))
		if n > 0:
			out.append({"i": String(dr["item"]), "n": n})
	return out


func remove_block(c: Vector3i) -> void:
	## Take a block out, and with it what depended on it.
	World.set_block(c, 0)
	# what stood on it
	var up := c + Vector3i.UP
	var uid := World.block(up)
	if uid != 0 and String(Blocks.def(uid).get("attach", "")) in ["ground", "soil", "farmland"] and not Blocks.on_wall(uid, World.block_meta(up)):
		_pop(up, uid)
	# what hung on its sides
	for d in Blocks.WALL_DIRS:
		var n: Vector3i = c - d
		var nid := World.block(n)
		if Blocks.on_wall(nid, World.block_meta(n)) and Blocks.wall_dir(World.block_meta(n)) == d:
			_pop(n, nid)
	var upbe := World.be(up)
	if not upbe.is_empty():
		_break_be(0, upbe, true)
	# what hung from it
	var dn := c + Vector3i.DOWN
	var did := World.block(dn)
	if did != 0 and String(Blocks.def(did).get("attach", "")) == "ceiling":
		_pop(dn, did)
	# loose blocks above fall into the gap
	var col := c + Vector3i.UP
	while Blocks.has_flag(World.block(col), "falls"):
		var fid := World.block(col)
		World.set_block(col, 0)
		var land := col + Vector3i.DOWN
		while land.y > 0 and World.block(land + Vector3i.DOWN) == 0 and not World.be_at.has(land + Vector3i.DOWN):
			land += Vector3i.DOWN
		if land.y <= 1:
			break
		World.set_block(land, fid)
		col += Vector3i.UP
	a.resettle_items(c)


func _pop(c: Vector3i, id: int) -> void:
	## A plant or loose thing loses its footing and drops as items.
	var drops := drops_of(id, World.block_meta(c), "")
	World.set_block(c, 0)
	for s in drops:
		a.drop_item(String(s["i"]), int(s["n"]), {}, Vector3(c) + Vector3(0.5, 0.3, 0.5))
	World.fx("break", Vector3(c) + Vector3(0.5, 0.5, 0.5), {"b": id, "quiet": true})


func _fell(pid: int, c: Vector3i, id: int, slot: int) -> void:
	## The whole tree comes down: every log of it, and the leaves around them.
	var logs: Array[Vector3i] = []
	var seen := {c: true}
	var q: Array[Vector3i] = [c]
	while not q.is_empty() and logs.size() < MAX_TREE:
		var p: Vector3i = q.pop_front()
		logs.append(p)
		for dy in [0, 1]:
			for dz in [-1, 0, 1]:
				for dx in [-1, 0, 1]:
					var n := p + Vector3i(dx, dy, dz)
					if seen.has(n):
						continue
					seen[n] = true
					if World.block(n) == id and World.block_meta(n) & NATURAL and n.y >= c.y:
						q.append(n)
	var leaf_id := Blocks.id_of("leaves_oak" if Blocks.name_of(id) == "log_oak" else "leaves_birch")
	var leaves: Array[Vector3i] = []
	var lseen := {}
	var lq: Array = []
	for p in logs:
		lq.append([p, 0])
	while not lq.is_empty():
		var item: Array = lq.pop_front()
		var p: Vector3i = item[0]
		var depth: int = item[1]
		if depth >= 3:
			continue
		for n in [p + Vector3i.UP, p + Vector3i.DOWN, p + Vector3i.LEFT, p + Vector3i.RIGHT, p + Vector3i.FORWARD, p + Vector3i.BACK]:
			if lseen.has(n):
				continue
			lseen[n] = true
			if World.block(n) == leaf_id and not _other_tree_near(n, seen):
				leaves.append(n)
				lq.append([n, depth + 1])
	var sticks := 0
	var saplings := 0
	for p in leaves:
		World.set_block(p, 0)
		if randf() < 0.22:
			sticks += 1
		if randf() < 0.045:
			saplings += 1
	for p in logs:
		World.set_block(p, 0)
	for p in logs:
		remove_block(p)
	# it topples away from you (onto open ground if it can), and what it was
	# made of lands along where the trunk came down
	var dir := _fall_dir(pid, c, logs)
	var reach := _fall_reach(c, dir)
	var pivot := Vector3(c) + Vector3(0.5, 0.0, 0.5) + Vector3(dir) * 0.5
	var land := func(along: float, side: float) -> Vector3:
		var side_v := Vector3(-dir.z, 0, dir.x)
		var spot := pivot + Vector3(dir) * minf(along, reach) + side_v * side + Vector3(0, 1.2, 0)
		if World.vox.rest_height(spot) == -INF:
			# not over the edge of the island: what would fall off stays by the stump
			spot = Vector3(c) + Vector3(0.5 + randf_range(-0.6, 0.6), 1.2, 0.5 + randf_range(-0.6, 0.6))
		return spot
	var item := ItemDB.item_of_block(id)
	var per := 1 if logs.size() <= 10 else 2
	var top_h := 0
	var k := 0
	for p in logs:
		top_h = maxi(top_h, p.y - c.y)
	while k < logs.size():
		var p: Vector3i = logs[k]
		var off := Vector3(p - c)
		var side := off.x * -dir.z + off.z * dir.x
		var n := mini(per, logs.size() - k)
		a.drop_item(item, n, {}, land.call(float(p.y - c.y) + 0.5, side + randf_range(-0.15, 0.15)), Vector3.ZERO, 0, FALL_MS)
		k += n
	var crown := float(top_h) * 0.85 + 0.5
	if sticks > 0:
		a.drop_item("stick", sticks, {}, land.call(crown + randf_range(-0.8, 0.8), randf_range(-1.2, 1.2)), Vector3.ZERO, 0, FALL_MS)
	if saplings > 0 or randf() < 0.6:
		var sap := "sapling_oak" if leaf_id == Blocks.id_of("leaves_oak") else "sapling_birch"
		a.drop_item(sap, maxi(1, saplings), {}, land.call(crown + randf_range(-0.8, 0.8), randf_range(-1.2, 1.2)), Vector3.ZERO, 0, FALL_MS)
	a.wear_tool(pid, slot, 1 + logs.size() / 3)
	# everyone sees the same tree come down (cells relative to the stump)
	var rl := PackedInt32Array()
	for p in logs:
		rl.append_array([p.x - c.x, p.y - c.y, p.z - c.z])
	var rv := PackedInt32Array()
	for p in leaves:
		rv.append_array([p.x - c.x, p.y - c.y, p.z - c.z])
	World.fx("tree_fall", Vector3(c), {"b": leaf_id, "log": id, "logs": rl, "leaves": rv, "dir": dir, "reach": reach, "ms": FALL_MS})
	a.flag_player(pid, "felled_tree")


func _fall_dir(pid: int, c: Vector3i, logs: Array[Vector3i]) -> Vector3i:
	## Away from whoever felled it, unless that way is the abyss or a wall and
	## another way is clear.
	var away := Vector3(c) + Vector3(0.5, 0, 0.5) - a.player_pos(pid)
	away.y = 0.0
	var first := Vector3i(signi(roundi(away.x)) if absf(away.x) >= absf(away.z) else 0, 0, 0 if absf(away.x) >= absf(away.z) else signi(roundi(away.z)))
	if first == Vector3i.ZERO:
		first = Vector3i(1, 0, 0)
	var h := 1
	for p in logs:
		h = maxi(h, p.y - c.y + 1)
	var best := first
	var best_s := -INF
	for d in [first, Vector3i(-first.z, 0, first.x), Vector3i(first.z, 0, -first.x), -first]:
		var s := 0.0
		for i in range(1, h + 1):
			var q := Vector3(c + d * i) + Vector3(0.5, 1.2, 0.5)
			if World.vox.rest_height(q) == -INF:
				s -= 3.0   # over the edge
			elif i <= _fall_reach(c, d):
				s += 1.0
		if d == first:
			s += 1.5
		if s > best_s:
			best_s = s
			best = d
	return best


func _fall_reach(c: Vector3i, d: Vector3i) -> float:
	## How far along d the trunk can lie before it meets something solid.
	for i in range(1, 16):
		var q := c + d * i
		for b in [World.block(q), World.block(q + Vector3i.UP)]:
			if Blocks.is_solid(b) and not Blocks.has_flag(b, "leaves"):
				return float(i) - 0.5
	return 16.0


func _other_tree_near(p: Vector3i, mine: Dictionary) -> bool:
	for dz in range(-2, 3):
		for dx in range(-2, 3):
			for dy in range(-2, 2):
				var n := p + Vector3i(dx, dy, dz)
				if mine.has(n):
					continue
				var id := World.block(n)
				if Blocks.has_flag(id, "tree") and World.block_meta(n) & NATURAL:
					return true
	return false


func _break_be(pid: int, be: Dictionary, quiet := false) -> void:
	var d: Dictionary = be["d"]
	var c: Vector3i = d["cell"]
	var at := Vector3(c) + Vector3(0.5, 0.25, 0.5)
	var stacks: Array = []
	match String(be["t"]):
		"firepit":
			stacks = a.fire.firepit_contents(be)
		"kiln":
			stacks = a.fire.kiln_contents(be)
		"ground":
			stacks = d.get("items", []).duplicate(true)
		"knap":
			if (d.get("cells", PackedByteArray()) as PackedByteArray) == ItemDB.stone_mask:
				stacks = [Inventory.make(String(d.get("mat", "stone")), 1)]
			elif pid > 0:
				World.notify(pid, "The half-knapped stone crumbles.", "warn")
		"clay":
			var lumps := a.craft.clay_refund(be)
			if lumps > 0:
				stacks = [Inventory.make("clay", lumps)]
		"jar":
			stacks = d.get("inv", []).duplicate(true)
			stacks.append(Inventory.make("jar", 1))
	World.despawn(be["id"])
	if pid > 0:
		for s in stacks:
			if s is Dictionary and not s.is_empty():
				a.give_stack(pid, s, at)
	else:
		a.drop_stacks(stacks, at)
	if not quiet:
		World.fx("break_be", at, {"t": be["t"]})


func place(pid: int, args: Dictionary) -> void:
	var c: Vector3i = args.get("c", Vector3i(-1, -1, -1))
	var slot := int(args.get("slot", -1))
	var face: Vector3i = args.get("face", Vector3i.UP)
	if not VoxelData.in_bounds(c.x, c.y, c.z) or not a.in_reach(pid, c):
		return
	if not a._rate(pid, "place", 120):
		return
	var s := a.held(pid, slot)
	if s.is_empty():
		return
	var id := ItemDB.block_of(String(s["i"]))
	if id < 0 or not World.cell_free(c):
		return
	# a torch put against the side of a block hangs on it
	var on_wall := Blocks.wall[id] == 1 and face.y == 0 and face != Vector3i.ZERO and Blocks.is_solid(World.block(c - face)) and Blocks.is_opaque(World.block(c - face))
	if not on_wall and not can_stand(id, c):
		var at := String(Blocks.def(id).get("attach", ""))
		if at == "soil":
			World.notify(pid, "That needs soil to grow in.", "warn")
		elif at == "farmland":
			World.notify(pid, "Sow seeds on tilled farmland.", "warn")
		return
	if Blocks.is_solid(id) and _hits_player(c):
		return
	var m := 0
	if Blocks.axis[id] == 1:
		m = 1 if face.x != 0 else (2 if face.z != 0 else 0)
	if on_wall:
		m = Blocks.wall_meta(-face)
	World.inventory_of(pid).take_from(slot, 1)
	World.mark_inventory(pid)
	var displaced := a.water.level(c)
	World.set_block(c, id, m)
	if displaced > 0:
		_displace(c, displaced)
	World.fx_except(pid, "place", Vector3(c) + Vector3(0.5, 0.5, 0.5), {"b": id})
	if Blocks.has_flag(id, "bed"):
		a.flag_player(pid, "placed_bed")


func _displace(c: Vector3i, n: int) -> void:
	## A block set into water pushes that water out: up, else to the sides.
	n = a.water.add(c + Vector3i.UP, n)
	for d in WaterSim.SIDES:
		if n <= 0:
			return
		n = a.water.add(c + d, n)


static func can_stand(id: int, c: Vector3i) -> bool:
	var at := String(Blocks.def(id).get("attach", ""))
	var below := World.block(c + Vector3i.DOWN)
	match at:
		"ground":
			return Blocks.is_solid(below)
		"soil":
			return Blocks.name_of(below) in ["grass", "dirt", "farmland"]
		"farmland":
			return Blocks.name_of(below) == "farmland"
		"ceiling":
			return Blocks.is_solid(World.block(c + Vector3i.UP))
	return true


func _hits_player(c: Vector3i) -> bool:
	var box := AABB(Vector3(c), Vector3.ONE).grow(-0.02)
	for pid in Net.players:
		var p := a.player_pos(pid)
		var pb := AABB(p - Vector3(0.3, 0.0, 0.3), Vector3(0.6, 1.8, 0.6))
		if pb.intersects(box):
			return true
	return false
