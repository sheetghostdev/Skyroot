class_name FarmActs
extends RefCounted
## Using blocks (host): picking berries, tilling with a hoe, sowing, filling
## bowls and pots at the water, beds.  Also the island's slow life: random
## ticks that grow crops, refill berry bushes, raise saplings into trees, let
## grass and mushrooms come back and keep farmland moist near water.

const RANDOM_TICKS := 260
const STAGE_H := 18.0          # in-game hours per crop stage on wet farmland
const BERRY_H := 36.0
const SAPLING_H := 40.0

var a: Actions
var _rng := RandomNumberGenerator.new()


func _init(actions: Actions) -> void:
	a = actions
	_rng.randomize()


func use_block(pid: int, c: Vector3i, target: int, slot: int, s: Dictionary, face: Vector3i, sneak: bool) -> bool:
	var nm := Blocks.name_of(target)
	var id := String(s.get("i", ""))
	var inv := World.inventory_of(pid)
	if nm == "berry_bush" and not sneak:
		if World.block_meta(c) == 1:
			World.set_block_meta(c, 0)
			a.give(pid, "berries", _rng.randi_range(2, 4), {}, Vector3(c) + Vector3(0.5, 0.6, 0.5))
			World.fx("harvest", Vector3(c) + Vector3(0.5, 0.6, 0.5), {"b": target})
			return true
		if id == "":
			World.notify(pid, "No berries yet. They come back in a day or two.")
			return true
	if Blocks.shape[target] == Blocks.Shape.LIQUID:
		if id == "bowl" and String(s["d"].get("c", "")) == "":
			if a.water.take(c, 1) < 1:
				return true
			if int(s["n"]) > 1:
				inv.take_from(slot, 1)
				a.give(pid, "bowl", 1, {"c": "water"})
			else:
				inv.set_data(slot, {"c": "water"})
			World.mark_inventory(pid)
			World.fx("splash", Vector3(c) + Vector3(0.5, 0.85, 0.5))
			return true
		if id == "pot" and int(s["d"].get("w", 0)) < 3:
			var got := a.water.take(c, 3 - int(s["d"].get("w", 0)))
			if got < 1:
				return true
			inv.set_data(slot, {"w": int(s["d"].get("w", 0)) + got})
			World.mark_inventory(pid)
			World.fx("splash", Vector3(c) + Vector3(0.5, 0.85, 0.5))
			return true
		return id == ""
	if ItemDB.tool_kind(id) == "hoe" and face == Vector3i.UP and nm in ["grass", "dirt"]:
		var up := c + Vector3i.UP
		var uid := World.block(up)
		if World.be_at.has(up) or (uid != 0 and not Blocks.is_replaceable(uid)):
			return false
		if uid != 0:
			World.set_block(up, 0)
		World.set_block(c, Blocks.id_of("farmland"), 1 if _near_water(c) else 0)
		a.wear_tool(pid, slot)
		World.fx("till", Vector3(c) + Vector3(0.5, 1.0, 0.5), {"b": target})
		a.flag_player(pid, "tilled")
		return true
	if ItemDB.def(id).has("crop") and nm == "farmland":
		var up2 := c + Vector3i.UP
		if not World.cell_free(up2) or World.block(up2) != 0:
			return true
		inv.take_from(slot, 1)
		World.mark_inventory(pid)
		World.set_block(up2, Blocks.id_of(String(ItemDB.def(id)["crop"])), 0)
		World.fx("place", Vector3(up2) + Vector3(0.5, 0.1, 0.5), {"b": Blocks.id_of("tallgrass")})
		a.flag_player(pid, "sowed")
		return true
	if Blocks.has_flag(target, "bed") and id == "":
		# the client lies down; the host learns where to wake via bed_set
		return true
	return false


func bed_set(pid: int, args: Dictionary) -> void:
	var c: Vector3i = args.get("c", Vector3i(-1, -1, -1))
	if not a.in_reach(pid, c) or not Blocks.has_flag(World.block(c), "bed"):
		return
	var st: Dictionary = World.stats.get(pid, {})
	if st.is_empty():
		return
	st["bed"] = c
	World.mark_stats(pid)
	a.flag_player(pid, "slept")


func _near_water(c: Vector3i) -> bool:
	for dz in range(-4, 5):
		for dx in range(-4, 5):
			for dy in [-1, 0]:
				if Blocks.shape[World.block(c + Vector3i(dx, dy, dz))] == Blocks.Shape.LIQUID:
					return true
	return false


# ---------------------------------------------------------------------------
# Random ticks
# ---------------------------------------------------------------------------

func tick(hours: float) -> void:
	var vd := World.vox
	var rain := float(World.env.get("rain", 0.0)) > 0.3
	# every sampled column stands for (columns / samples) of game time
	var cols := 48 * 48
	var dt_h := hours * float(cols) / RANDOM_TICKS
	for _i in RANDOM_TICKS:
		var x := _rng.randi_range(8, 55)
		var z := _rng.randi_range(4, 59)
		var h := vd.column_height(x, z)
		if h < 0:
			continue
		# look under any canopy for the ground
		var y := h
		var under_leaves := false
		while y > 0 and not Blocks.is_solid(vd.get_id(x, y, z)):
			if Blocks.has_flag(vd.get_id(x, y, z), "leaves"):
				under_leaves = true
			y -= 1
			if h - y > 12:
				break
		var g := Vector3i(x, y, z)
		var up := g + Vector3i.UP
		var gid := vd.get_id(x, y, z)
		var uid := vd.get_id(x, y + 1, z)
		var gname := Blocks.name_of(gid)
		var uname := Blocks.name_of(uid)
		if gname == "farmland":
			var wet := 1 if (_near_water(g) or rain) else 0
			if wet != vd.get_m(x, y, z) and (wet == 1 or not rain):
				World.set_block_meta(g, wet)
		if Blocks.def(uid).has("crop"):
			var stage := vd.get_m(x, y + 1, z)
			if stage < 3:
				var rate := 1.0 if vd.get_m(x, y, z) == 1 else 0.4
				if _rng.randf() < dt_h * rate / STAGE_H:
					World.set_block(up, uid, stage + 1)
		elif uname == "berry_bush":
			if vd.get_m(x, y + 1, z) == 0 and _rng.randf() < dt_h / BERRY_H:
				World.set_block_meta(up, 1)
		elif uname == "sapling_oak" or uname == "sapling_birch":
			if _rng.randf() < dt_h / SAPLING_H:
				_grow_sapling(up, "oak" if uname == "sapling_oak" else "birch")
		elif uid == 0 and not World.be_at.has(up):
			if gname == "grass":
				var p := _rng.randf()
				if under_leaves and p < dt_h * 0.004:
					World.set_block(up, Blocks.id_of("mushroom"))
				elif p < dt_h * 0.01:
					World.set_block(up, Blocks.id_of("tallgrass"))
			elif gname == "dirt" and vd.open_to_sky(up) and _rng.randf() < dt_h * 0.05:
				# grass creeps back over bare soil next to it
				for o in [Vector3i.LEFT, Vector3i.RIGHT, Vector3i.FORWARD, Vector3i.BACK]:
					if Blocks.name_of(World.block(g + o)) == "grass" or Blocks.name_of(World.block(g + o + Vector3i.DOWN)) == "grass":
						World.set_block(g, Blocks.id_of("grass"))
						break


func _grow_sapling(c: Vector3i, kind: String) -> void:
	World.set_block(c, 0)
	var ok := IslandGen.grow_tree(World.vox, c.x, c.y, c.z, kind, _rng.randi(), func(p: Vector3i, id: int, m: int): World.set_block(p, id, m))
	if not ok:
		World.set_block(c, Blocks.id_of("sapling_" + kind))
