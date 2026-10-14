extends Node
## Headless test suites.  They drive the real game through the same requests
## the client sends, then check the world.
##
##   godot --headless --path . res://tests/test_main.tscn -- --suite=core,blocks,water,craft,fire,kiln,survival,farm,save,longrun
##   (--suite=all runs everything)

const SUITES := ["core", "blocks", "water", "craft", "fire", "kiln", "survival", "farm", "save", "longrun"]

var passes := 0
var fails := 0
var a: Actions
var lp: LocalPlayer
var pid := 1
var _suite := ""


func _ready() -> void:
	var want: Array = []
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--suite="):
			for s in arg.substr(8).split(","):
				want.append(s)
	if want.is_empty() or want.has("all"):
		want = SUITES.duplicate()
	await _start()
	for s in want:
		if not SUITES.has(s):
			print("unknown suite ", s)
			fails += 1
			continue
		_suite = s
		print("== suite ", s)
		await _fresh()
		await call("suite_" + s)
	print("RESULT %d passed, %d failed" % [passes, fails])
	Game._teardown()
	World.delete_save("TestIsland")
	get_tree().quit(0 if fails == 0 else 1)


func _start() -> void:
	await get_tree().process_frame
	DirAccess.make_dir_recursive_absolute(World.SAVE_DIR)
	World.delete_save("TestIsland")
	var err := Game.start_world("solo", "TestIsland", true)
	if err != "":
		print("FAIL could not start: ", err)
		fails += 1
	for i in 5:
		await get_tree().process_frame


func _fresh() -> void:
	## A brand-new island for every suite.
	Game._teardown()
	await get_tree().process_frame
	Game.start_world("solo", "TestIsland", true)
	for i in 3:
		await get_tree().process_frame
	a = World.actions
	a.no_rate = true
	lp = Game.game_world.local_player()
	lp.set_physics_process(false)
	lp.interactor.set_process(false)
	Game.game_world.sim.set_process(false)
	pid = Net.my_id()
	clear_inv()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func check(cond: bool, msg: String) -> bool:
	if OS.has_environment("TEST_VERBOSE"):
		print("   %s %s" % ["ok  " if cond else "FAIL", msg])
	if cond:
		passes += 1
	else:
		fails += 1
		print("FAIL [%s] %s" % [_suite, msg])
	return cond


func inv() -> Inventory:
	return World.inventory_of(pid)


func clear_inv() -> void:
	inv().clear()
	World.mark_inventory(pid)


func give(id: String, n: int = 1, d: Dictionary = {}, slot: int = 0) -> void:
	if not ItemDB.tool_info(id).is_empty() and not d.has("dur"):
		d["dur"] = ItemDB.max_durability(id, d)
	inv().set_slot(slot, Inventory.make(id, n, d))
	World.mark_inventory(pid)


func count(id: String) -> int:
	return inv().count(id)


func place_player(p: Vector3) -> void:
	lp.global_position = p
	Net.poses[pid] = {"p": p, "c": false, "m": "play"}


func req(action: String, args: Dictionary = {}) -> void:
	World.request(action, args)


func top(x: int, z: int) -> Vector3i:
	return Vector3i(x, World.vox.surface_y(x, z), z)


func flat_spot(x: int, z: int) -> Vector3i:
	## A solid block with open air above it, near (x, z): its cell.
	for r in range(0, 8):
		for dz in range(-r, r + 1):
			for dx in range(-r, r + 1):
				var c := top(x + dx, z + dz)
				if c.y < 0:
					continue
				var up := c + Vector3i.UP
				if Blocks.is_solid(World.block(c)) and Blocks.is_opaque(World.block(c)) and World.block(up + Vector3i.UP) == 0 and not World.be_at.has(up):
					if World.block(up) != 0:
						World.set_block(up, 0)
					return c
	return Vector3i(-1, -1, -1)


func stand_near(c: Vector3i) -> void:
	place_player(Vector3(c) + Vector3(1.5, 1.0, 0.5))


func items_near(p: Vector3, r: float, id: String) -> int:
	var n := 0
	for e in World.entities_near(p, r, "item"):
		if String(e["d"]["i"]) == id:
			n += int(e["d"]["n"])
	return n


func pickup_all(p: Vector3) -> void:
	## Walk over everything lying around p.
	for e in World.entities_near(p, 6.0, "item"):
		place_player((e["xf"] as Transform3D).origin)
		a._pickup_t = 0.0
		a._physics_process(0.2)


func use_on(c: Vector3i, slot: int = 0, sneak := false, face := Vector3i.UP) -> void:
	req("use", {"c": c, "face": face, "slot": slot, "sneak": sneak})


func hours(h: float, step: float = 0.25) -> void:
	## Let time pass (the host's systems, without the real-time clock).
	var t := 0.0
	while t < h - 1e-6:
		var dh := minf(step, h - t)
		World.env["t"] = float(World.env["t"]) + dh
		Game.game_world.sim._tick(dh, dh * SimDriver.DAY_SECONDS / 24.0)
		t += dh


func real_seconds(s: float) -> void:
	hours(s * 24.0 / SimDriver.DAY_SECONDS, 0.5 * 24.0 / SimDriver.DAY_SECONDS)


func count_blocks(nm: String) -> int:
	var id := Blocks.id_of(nm)
	return World.vox.ids.count(id)


# ---------------------------------------------------------------------------
# Core: the island, physics, raycasts
# ---------------------------------------------------------------------------

func suite_core() -> void:
	check(count_blocks("stone") > 4000, "plenty of rock (%d)" % count_blocks("stone"))
	check(count_blocks("water") >= 20, "a pond (%d water)" % count_blocks("water"))
	check(count_blocks("clay") >= 15, "clay in the banks (%d)" % count_blocks("clay"))
	check(count_blocks("log_oak") + count_blocks("log_birch") >= 50, "trees")
	check(count_blocks("loose_stones") >= 24, "loose stones (%d)" % count_blocks("loose_stones"))
	check(count_blocks("loose_flint") >= 4, "flint (%d)" % count_blocks("loose_flint"))
	check(count_blocks("loose_sticks") >= 10, "fallen sticks (%d)" % count_blocks("loose_sticks"))
	check(count_blocks("tallgrass") > 100, "tall grass")
	check(count_blocks("reeds") >= 6, "cattails (%d)" % count_blocks("reeds"))
	check(count_blocks("wild_turnip") >= 3 and count_blocks("wild_flax") >= 3, "wild crops")
	check(count_blocks("berry_bush") >= 4, "berry bushes")
	# the islet across the gap
	check(World.vox.surface_y(53, 13) > 30, "the islet is there")
	check(World.vox.surface_y(47, 19) < 0 or World.vox.surface_y(46, 20) < 0, "a gap between the islands")
	# spawn is on solid ground
	var sp := World.spawn_point(1)
	var below := VoxelData.cell_of(sp - Vector3(0, 0.1, 0))
	check(Blocks.is_solid(World.block(below)), "spawn stands on ground")
	# raycast straight down
	var hit := World.vox.raycast(sp + Vector3(0, 3, 0), Vector3.DOWN, 10.0)
	check(not hit.is_empty() and hit["normal"] == Vector3i.UP, "raycast down hits the ground's top face")
	# physics: drop onto the ground
	var body := VoxelBody.new()
	var p := sp + Vector3(0, 3, 0)
	for i in 120:
		var r := body.move(World.vox, p, Vector3(0, -0.2, 0), false)
		p = r["pos"]
	check(absf(p.y - sp.y) < 0.05 and body.on_ground, "a falling body lands on the ground (%.2f vs %.2f)" % [p.y, sp.y])
	# a wall stops you
	var c := VoxelData.cell_of(p)
	World.set_block(c + Vector3i(1, 0, 0), Blocks.id_of("dirt"))
	World.set_block(c + Vector3i(1, 1, 0), Blocks.id_of("dirt"))
	var start := Vector3(c.x + 0.5, p.y, c.z + 0.5)
	var q := start
	for i in 20:
		q = body.move(World.vox, q, Vector3(0.1, 0, 0), false)["pos"]
	check(q.x <= c.x + 1.0 - 0.299, "walls stop you (%.3f)" % q.x)
	# a low step (a straw bed) is climbed on its own
	World.set_block(c + Vector3i(1, 0, 0), Blocks.id_of("straw_bed"))
	World.set_block(c + Vector3i(1, 1, 0), 0)
	q = start
	for i in 20:
		var r2 := body.move(World.vox, q, Vector3(0.1, -0.05, 0), false)
		q = r2["pos"]
	check(q.x > c.x + 1.2 and q.y > start.y + 0.25, "steps up onto a low block (%.2f, %.2f)" % [q.x, q.y])
	# farmland (15/16 high) needs a jump
	World.set_block(c + Vector3i(1, 0, 0), Blocks.id_of("farmland"))
	q = start
	for i in 20:
		q = body.move(World.vox, q, Vector3(0.1, -0.05, 0), false)["pos"]
	check(q.x < c.x + 1.0, "a full-height step needs a jump")
	# sneaking at the edge, you don't fall
	var edge := _find_edge()
	if check(edge.x >= 0, "found an edge"):
		var ep := Vector3(edge.x + 0.5, edge.y + 1.0, edge.z + 0.5)
		var dir := _edge_dir(edge)
		var e2 := ep
		for i in 40:
			var r3 := body.move(World.vox, e2, Vector3(dir.x, 0, dir.z) * 0.1 + Vector3(0, -0.05, 0), true)
			e2 = r3["pos"]
		check(e2.y > edge.y + 0.9, "sneaking keeps you on the edge")
		var e3 := ep
		for i in 60:
			var r4 := body.move(World.vox, e3, Vector3(dir.x, 0, dir.z) * 0.1 + Vector3(0, -0.2, 0), false)
			e3 = r4["pos"]
		check(e3.y < edge.y, "walking normally, you go over")


func _find_edge() -> Vector3i:
	for x in range(32, 63):
		var z := 32
		if World.vox.surface_y(x, z) >= 0 and World.vox.surface_y(x + 1, z) < 0:
			var c := top(x, z)
			if World.block(c + Vector3i.UP) != 0:
				World.set_block(c + Vector3i.UP, 0)
			return c
	return Vector3i(-1, -1, -1)


func _edge_dir(_c: Vector3i) -> Vector3:
	return Vector3(1, 0, 0)


# ---------------------------------------------------------------------------
# Blocks: breaking, placing, trees, drops
# ---------------------------------------------------------------------------

func suite_blocks() -> void:
	var c := flat_spot(30, 36)
	stand_near(c)
	var id := World.block(c)
	req("break", {"c": c, "slot": 0})
	check(World.block(c) == 0, "soil breaks by hand")
	var dirt_n := items_near(Vector3(c), 2.0, "dirt")
	check(dirt_n == 1, "it drops soil (%d)" % dirt_n)
	pickup_all(Vector3(c))
	check(count("dirt") == 1, "walking over it picks it up")
	stand_near(c)
	req("place", {"c": c, "slot": inv().find("dirt"), "face": Vector3i.UP})
	check(World.block(c) == Blocks.id_of("dirt"), "and it can be put back")
	check(count("dirt") == 0, "using it up")
	# not inside yourself
	give("dirt", 3)
	var me := VoxelData.cell_of(lp.global_position + Vector3(0, 0.5, 0))
	req("place", {"c": me, "slot": 0, "face": Vector3i.UP})
	check(World.block(me) != Blocks.id_of("dirt"), "can't place a block where you stand")
	# trees need an axe, and come down whole
	var tree := _find_tree()
	if check(tree.x >= 0, "found a tree"):
		stand_near(tree)
		clear_inv()
		req("break", {"c": tree, "slot": 0})
		check(Blocks.has_flag(World.block(tree), "tree"), "a trunk won't break by hand")
		var logs := _tree_logs(tree)
		give("axe", 1, {"mat": "flint"})
		var dur0 := int(inv().get_slot(0)["d"]["dur"])
		req("break", {"c": tree, "slot": 0})
		check(World.block(tree) == 0, "the axe fells it")
		var left := 0
		for y in range(tree.y, tree.y + 10):
			if Blocks.has_flag(World.block(Vector3i(tree.x, y, tree.z)), "tree"):
				left += 1
		check(left == 0, "the whole trunk came down (%d left)" % left)
		var dropped := items_near(Vector3(tree), 12.0, "log_oak") + items_near(Vector3(tree), 12.0, "log_birch")
		check(dropped == logs, "every log drops (%d of %d)" % [dropped, logs])
		check(int(inv().get_slot(0).get("d", {}).get("dur", dur0)) < dur0, "the axe wears")
		# it topples: the logs lie out along the fallen trunk, and only turn up
		# once it has come down
		var stump := Vector3(tree) + Vector3(0.5, 0, 0.5)
		var far_log := 0.0
		var a_log := Vector3.ZERO
		for e in World.entities_near(stump, 12.0, "item"):
			if String(e["d"]["i"]).begins_with("log"):
				var off: Vector3 = (e["xf"] as Transform3D).origin - stump
				if Vector2(off.x, off.z).length() > far_log:
					far_log = Vector2(off.x, off.z).length()
					a_log = (e["xf"] as Transform3D).origin
		check(far_log > 2.5, "the logs lie along the fallen trunk (%.1f out)" % far_log)
		place_player(a_log)
		a._pickup_t = 0.0
		a._physics_process(0.2)
		check(count("log_oak") + count("log_birch") == 0, "nothing to pick up while it is still falling")
		await get_tree().create_timer(BlockActs.FALL_MS / 1000.0 + 0.1).timeout
		a._pickup_t = 0.0
		a._physics_process(0.2)
		check(count("log_oak") + count("log_birch") > 0, "then the logs can be picked up")
	# grass: nothing by hand, dry grass with a knife
	var g := _find("tallgrass")
	if check(g.x >= 0, "found tall grass"):
		stand_near(g)
		clear_inv()
		req("break", {"c": g, "slot": 0})
		check(World.block(g) == 0 and items_near(Vector3(g), 1.5, "dry_grass") == 0, "tall grass torn by hand gives nothing")
		var g2 := _find("tallgrass")
		stand_near(g2)
		give("knife", 1, {"mat": "stone"})
		var d0 := int(inv().get_slot(0)["d"]["dur"])
		req("break", {"c": g2, "slot": 0})
		check(items_near(Vector3(g2), 1.5, "dry_grass") == 1, "cut with a knife: dry grass")
		check(int(inv().get_slot(0)["d"]["dur"]) == d0 - 1, "the knife wears a little")
	# loose things
	var ls := _find("loose_stones")
	stand_near(ls)
	clear_inv()
	req("break", {"c": ls, "slot": 0})
	check(items_near(Vector3(ls), 1.5, "stone") >= 1, "loose stones give stones")
	var lf := _find("loose_flint")
	stand_near(lf)
	req("break", {"c": lf, "slot": 0})
	check(items_near(Vector3(lf), 1.5, "flint") == 1, "flint nodules give flint")
	# granite is too hard
	var st := _find("stone")
	stand_near(st)
	req("break", {"c": st, "slot": 0})
	check(World.block(st) == Blocks.id_of("stone"), "granite can't be broken with stone tools")
	# gravel falls
	var f := flat_spot(22, 26)
	World.set_block(f + Vector3i(0, 1, 0), Blocks.id_of("dirt"))
	World.set_block(f + Vector3i(0, 2, 0), Blocks.id_of("gravel"))
	World.set_block(f + Vector3i(0, 3, 0), 0)
	stand_near(f + Vector3i(0, 1, 0))
	clear_inv()
	req("break", {"c": f + Vector3i(0, 1, 0), "slot": 0})
	check(World.block(f + Vector3i(0, 1, 0)) == Blocks.id_of("gravel"), "gravel falls into the gap")
	# plants go with the ground under them
	var pl := _find("flower_red")
	if pl.x >= 0:
		stand_near(pl)
		req("break", {"c": pl + Vector3i.DOWN, "slot": 0})
		check(World.block(pl) == 0, "a flower goes when the soil under it is dug")
	# saplings need soil
	give("sapling_oak", 2)
	var rock := _find_top("stone")
	if rock.x >= 0:
		stand_near(rock)
		req("place", {"c": rock + Vector3i.UP, "slot": 0, "face": Vector3i.UP})
		check(World.block(rock + Vector3i.UP) != Blocks.id_of("sapling_oak"), "a sapling won't grow on rock")
	var soil := flat_spot(26, 33)
	stand_near(soil)
	if Blocks.name_of(World.block(soil)) in ["grass", "dirt"]:
		req("place", {"c": soil + Vector3i.UP, "slot": 0, "face": Vector3i.UP})
		check(World.block(soil + Vector3i.UP) == Blocks.id_of("sapling_oak"), "a sapling planted in soil")
	# logs placed against a wall lie sideways
	give("log_oak", 2)
	var w := flat_spot(34, 40)
	place_player(Vector3(w) + Vector3(-1.5, 1.0, 0.5))
	World.set_block(w + Vector3i(0, 1, 0), Blocks.id_of("dirt"))
	req("place", {"c": w + Vector3i(1, 1, 0), "slot": 0, "face": Vector3i(1, 0, 0)})
	check(World.block(w + Vector3i(1, 1, 0)) == Blocks.id_of("log_oak") and World.block_meta(w + Vector3i(1, 1, 0)) & 3 == 1, "a log placed on a side lies along that axis")
	# out of reach
	var far := flat_spot(20, 22)
	place_player(Vector3(40, 46, 40))
	clear_inv()
	req("break", {"c": far, "slot": 0})
	check(World.block(far) != 0, "can't break things far away")


# ---------------------------------------------------------------------------
# Water: finite, it flows and settles
# ---------------------------------------------------------------------------

func water_units(ctr: Vector3i, r: int) -> int:
	var n := 0
	var w := Blocks.id_of("water")
	for z in range(ctr.z - r, ctr.z + r + 1):
		for x in range(ctr.x - r, ctr.x + r + 1):
			for y in range(maxi(0, ctr.y - r), mini(VoxelData.SY, ctr.y + r + 1)):
				var c := Vector3i(x, y, z)
				if World.block(c) == w:
					n += a.water.level(c)
	return n


func suite_water() -> void:
	var ws := a.water
	var w := Blocks.id_of("water")
	var pond := Vector3i(int(IslandGen.POND.x), IslandGen.TOP - 1, int(IslandGen.POND.y))
	check(World.block(pond) == w, "the pond is where it should be")
	var u0 := water_units(pond, 9)
	# the pond as generated is at rest
	for z in range(pond.z - 8, pond.z + 9):
		for x in range(pond.x - 8, pond.x + 9):
			for y in range(pond.y - 3, pond.y + 2):
				if World.block(Vector3i(x, y, z)) == w:
					ws._active[Vector3i(x, y, z)] = true
	var steps := ws.settle()
	check(water_units(pond, 9) == u0 and steps <= 2, "the pond rests as it is (%d units, %d steps)" % [u0, steps])
	# dig beside it: water runs into the hole, and the pond goes down by as much
	var bank := Vector3i(-1, -1, -1)
	for z in range(pond.z - 8, pond.z + 9):
		for x in range(pond.x - 8, pond.x + 9):
			var c := Vector3i(x, pond.y, z)
			if bank.x < 0 and Blocks.is_solid(World.block(c)) and World.block(c + Vector3i.UP) == 0:
				for d in WaterSim.SIDES:
					if World.block(c + d) == w:
						bank = c
	if check(bank.x >= 0, "found the bank"):
		World.set_block(bank, 0)
		World.set_block(bank + Vector3i.DOWN, 0)
		ws.settle()
		check(World.block(bank + Vector3i.DOWN) == w and ws.level(bank + Vector3i.DOWN) == 8, "water fills the hole dug beside the pond")
		check(water_units(pond, 9) == u0, "and no water is made or lost (%d / %d)" % [water_units(pond, 9), u0])
		check(ws.busy() == false, "then it rests")
	# a block set into water pushes it aside
	var u1 := water_units(pond, 9)
	var top_w := Vector3i(-1, -1, -1)
	for z in range(pond.z - 3, pond.z + 4):
		for x in range(pond.x - 3, pond.x + 4):
			var c := Vector3i(x, pond.y, z)
			if World.block(c) == w and World.block(c + Vector3i.UP) == 0:
				top_w = c
	stand_near(top_w)
	give("dirt", 1)
	req("place", {"c": top_w, "slot": 0, "face": Vector3i.UP})
	ws.settle()
	check(World.block(top_w) == Blocks.id_of("dirt") and water_units(pond, 9) == u1, "a block put into the pond pushes the water aside (%d / %d)" % [water_units(pond, 9), u1])
	# a bowl takes a little
	var top2 := Vector3i(-1, -1, -1)
	for z in range(pond.z - 3, pond.z + 4):
		for x in range(pond.x - 3, pond.x + 4):
			var c := Vector3i(x, pond.y, z)
			if World.block(c) == w and World.block(c + Vector3i.UP) == 0 and ws.level(c) == 8:
				top2 = c
	stand_near(top2)
	clear_inv()
	give("bowl", 1)
	use_on(top2, 0)
	ws.settle()
	check(String(inv().get_slot(0).get("d", {}).get("c", "")) == "water" and water_units(pond, 9) == u1 - 1, "filling a bowl takes one part of eight from the pond")
	# poured on flat ground it spreads out thin, all of it
	var f := flat_spot(36, 28)
	World.set_block(f + Vector3i.UP, w, 0)
	ws.settle()
	var cells := 0
	for z in range(f.z - 4, f.z + 5):
		for x in range(f.x - 4, f.x + 5):
			for y in range(f.y - 2, f.y + 3):
				if World.block(Vector3i(x, y, z)) == w:
					cells += 1
	check(cells >= 3 and water_units(f, 6) == 8, "a block of water on open ground spreads out (%d cells, %d units)" % [cells, water_units(f, 6)])
	# over the edge of the island it is gone
	var edge := Vector3i(2, 50, 2)
	check(World.vox.surface_y(2, 2) < 0, "open sky at the corner of the world")
	World.set_block(edge, w, 0)
	ws.settle()
	check(water_units(edge, 3) == 0 and World.vox.ids.count(w) > 0, "water over the abyss falls away")
	# rain pools in a hollow; a puddle dries in the sun
	var hol := flat_spot(30, 40)
	World.set_block(hol, 0)
	var hc := hol
	var walled := true
	for d in WaterSim.SIDES:
		if not (Blocks.is_solid(World.block(hc + d)) and Blocks.is_opaque(World.block(hc + d))):
			walled = false
	if walled:
		ws.weather_at(hc.x, hc.z, 1.0, false, 0.0)
		check(World.block(hc) == w and ws.level(hc) == 1, "rain collects in a hole")
		ws.weather_at(hc.x, hc.z, 1.0, false, 0.0)
		check(ws.level(hc) == 2, "and keeps filling it")
		ws.set_level(hc, 1)
		ws.weather_at(hc.x, hc.z, 0.0, true, 0.0)
		check(World.block(hc) != w, "a thin puddle dries in the sun")
	# swimming depends on how deep it is
	World.set_block(hc, w, 7)
	check(not World.vox.liquid_at(Vector3(hc) + Vector3(0.5, 0.4, 0.5)) and World.vox.liquid_at(Vector3(hc) + Vector3(0.5, 0.05, 0.5)), "a puddle is only ankle deep")


func _find(nm: String) -> Vector3i:
	var id := Blocks.id_of(nm)
	for z in range(10, 54):
		for x in range(10, 54):
			var h := World.vox.column_height(x, z)
			for y in range(maxi(h - 12, 0), mini(h + 3, VoxelData.SY)):
				if World.vox.get_id(x, y, z) == id:
					return Vector3i(x, y, z)
	return Vector3i(-1, -1, -1)


func _find_top(nm: String) -> Vector3i:
	var id := Blocks.id_of(nm)
	for z in range(10, 54):
		for x in range(10, 54):
			var y := World.vox.surface_y(x, z)
			if y >= 0 and World.vox.get_id(x, y, z) == id and World.block(Vector3i(x, y + 1, z)) == 0:
				return Vector3i(x, y, z)
	return Vector3i(-1, -1, -1)


func _find_tree() -> Vector3i:
	for p in IslandGen.OAKS:
		for y in range(30, 60):
			var c := Vector3i(p.x, y, p.y)
			if Blocks.has_flag(World.block(c), "tree") and not Blocks.has_flag(World.block(c + Vector3i.DOWN), "tree"):
				return c
	return Vector3i(-1, -1, -1)


func _tree_logs(base: Vector3i) -> int:
	var n := 0
	var y := base.y
	while Blocks.has_flag(World.block(Vector3i(base.x, y, base.z)), "tree"):
		n += 1
		y += 1
	return n


# ---------------------------------------------------------------------------
# Crafting: knapping, the grid, the inventory screen, clay
# ---------------------------------------------------------------------------

func suite_craft() -> void:
	var c := flat_spot(30, 36)
	stand_near(c)
	var up := c + Vector3i.UP
	give("flint", 2)
	use_on(c, 0, true)
	var be := World.be(up)
	check(not be.is_empty() and be["t"] == "knap", "sneak-right-click a flint onto the ground: a knapping stone")
	check(count("flint") == 1, "the flint left the hand")
	req("knap_choose", {"c": up, "r": "knife_blade"})
	be = World.be(up)
	check(String(be["d"]["r"]) == "knife_blade", "chose the knife blade")
	var mask: PackedByteArray = ItemDB.knapping["knife_blade"]["mask"]
	var chips := 0
	for i in 256:
		if ItemDB.stone_mask[i] == 1 and mask[i] == 0:
			req("knap", {"c": up, "i": i})
			chips += 1
	check(World.be(up).is_empty(), "after %d chips the blade is done" % chips)
	var bi := inv().find("knife_blade")
	check(bi >= 0 and String(inv().get_slot(bi)["d"].get("mat", "")) == "flint", "a flint knife blade")
	# flakes: 3x3 at a time far from the shape, then a flake into the shape counts each cell
	give("stone", 1, {}, 5)
	use_on(c, 5, true)
	req("knap_choose", {"c": up, "r": "shovel_head"})
	var smask: PackedByteArray = ItemDB.knapping["shovel_head"]["mask"]
	var corner := PackedInt32Array()
	for z in range(6, 9):
		for x in range(0, 3):
			corner.append(x + z * 16)
	var clean := true
	for i in corner:
		if smask[i] == 1:
			clean = false
	req("knap", {"c": up, "cells": corner})
	var cells_after: PackedByteArray = World.be(up)["d"]["cells"]
	var gone := 0
	for i in corner:
		if ItemDB.stone_mask[i] == 1 and cells_after[i] == 0:
			gone += 1
	check(clean and gone == 9 and int(World.be(up)["d"]["miss"]) == 0, "a flake knocks off several cells at once (%d)" % gone)
	var into := PackedInt32Array()
	for i in 256:
		if smask[i] == 1 and into.size() < 3:
			into.append(i)
	req("knap", {"c": up, "cells": into})
	check(World.be(up).is_empty(), "a flake that takes three cells of the shape splits the stone")
	# chipping into the shape: warned twice, then the stone splits
	use_on(c, 0, true)
	req("knap_choose", {"c": up, "r": "axe_head"})
	var amask: PackedByteArray = ItemDB.knapping["axe_head"]["mask"]
	var inside: Array = []
	for i in 256:
		if amask[i] == 1:
			inside.append(i)
	req("knap", {"c": up, "i": inside[0]})
	req("knap", {"c": up, "i": inside[1]})
	check(not World.be(up).is_empty() and int(World.be(up)["d"]["miss"]) == 2, "two slips are survivable")
	req("knap", {"c": up, "i": inside[2]})
	check(World.be(up).is_empty() and count("flint") == 0, "the third splits the stone")
	# sneaking with a block in hand still places it
	clear_inv()
	give("dirt", 2)
	use_on(c, 0, true)
	check(World.block(up) == Blocks.id_of("dirt") and World.be(up).is_empty(), "sneak-right-click with soil places the block, it isn't set down as an item")
	World.set_block(up, 0)
	# the crafting grid
	clear_inv()
	inv().set_slot(Inventory.GRID + 1, Inventory.make("knife_blade", 1, {"mat": "stone", "q": 1.0}))
	inv().set_slot(Inventory.GRID + 4, Inventory.make("stick", 1))
	req("inv_click", {"slot": Actions.OUTPUT, "button": 0, "shift": false})
	var cur := inv().get_slot(Inventory.CURSOR)
	check(String(cur.get("i", "")) == "knife" and String(cur["d"].get("mat", "")) == "stone" and int(cur["d"].get("dur", 0)) == ItemDB.max_durability("knife", {"mat": "stone"}), "blade over stick makes a stone knife")
	check(inv().is_empty_slot(Inventory.GRID + 1) and inv().is_empty_slot(Inventory.GRID + 4), "the ingredients are used")
	req("inv_click", {"slot": 3, "button": 0})
	check(inv().item_at(3) == "knife" and inv().is_empty_slot(Inventory.CURSOR), "put the knife down in a slot")
	# anywhere in the grid
	inv().set_slot(Inventory.GRID + 5, Inventory.make("axe_head", 1, {"mat": "flint"}))
	inv().set_slot(Inventory.GRID + 8, Inventory.make("stick", 1))
	check(String(a.craft_preview(inv()).get("i", "")) == "axe", "the pattern can sit anywhere in the grid")
	req("inv_click", {"slot": Actions.OUTPUT, "button": 0, "shift": true})
	check(count("axe") == 1, "shift-click crafts straight into the inventory")
	# shapeless
	clear_inv()
	inv().set_slot(Inventory.GRID + 0, Inventory.make("plant_fiber", 1))
	inv().set_slot(Inventory.GRID + 4, Inventory.make("plant_fiber", 1))
	inv().set_slot(Inventory.GRID + 8, Inventory.make("plant_fiber", 1))
	req("inv_click", {"slot": Actions.OUTPUT, "button": 0, "shift": true})
	check(count("twine") == 1, "three fibers anywhere make twine")
	inv().set_slot(Inventory.GRID + 2, Inventory.make("stick", 2))
	inv().set_slot(Inventory.GRID + 3, Inventory.make("twine", 1))
	inv().set_slot(Inventory.GRID + 6, Inventory.make("stick", 1))
	inv().set_slot(Inventory.GRID + 7, Inventory.make("dirt", 1))
	check(a.craft_preview(inv()).is_empty(), "not a bow drill with a stray extra stack")
	inv().set_slot(Inventory.GRID + 7, {})
	req("inv_click", {"slot": Actions.OUTPUT, "button": 0, "shift": true})
	check(count("firestarter") == 1, "two sticks and twine make a bow drill")
	# firewood with an axe: the axe stays and wears
	clear_inv()
	inv().set_slot(Inventory.GRID + 0, Inventory.make("log_oak", 3))
	inv().set_slot(Inventory.GRID + 1, Inventory.make("axe", 1, {"mat": "flint", "dur": 10}))
	req("inv_click", {"slot": Actions.OUTPUT, "button": 0, "shift": true})
	check(count("firewood") == 12, "three logs split into twelve firewood (%d)" % count("firewood"))
	check(int(inv().get_slot(Inventory.GRID + 1).get("d", {}).get("dur", 0)) == 7, "the axe lost three uses")
	check(inv().is_empty_slot(Inventory.GRID + 0), "the logs are used")
	# the inventory screen: pick up, split, shift, close
	clear_inv()
	give("stick", 10, {}, 0)
	req("inv_click", {"slot": 0, "button": 1})
	check(int(inv().get_slot(Inventory.CURSOR).get("n", 0)) == 5 and int(inv().get_slot(0)["n"]) == 5, "right click takes half")
	req("inv_click", {"slot": 1, "button": 1})
	check(int(inv().get_slot(1).get("n", 0)) == 1 and int(inv().get_slot(Inventory.CURSOR)["n"]) == 4, "right click puts one down")
	req("inv_click", {"slot": Inventory.GRID + 4, "button": 0})
	check(int(inv().get_slot(Inventory.GRID + 4).get("n", 0)) == 4, "the rest into the grid")
	req("inv_click", {"slot": 0, "button": 0, "shift": true})
	check(inv().is_empty_slot(0) and count("stick") == 6, "shift-click moves a stack from the hotbar into the backpack")
	req("inv_close")
	check(count("stick") == 10 and inv().is_empty_slot(Inventory.GRID + 4), "closing the screen puts the grid back in your inventory")
	# a storage jar keeps things
	clear_inv()
	give("jar", 1, {}, 0)
	give("berries", 20, {}, 1)
	use_on(c, 0)
	var jar := World.be(up)
	check(not jar.is_empty() and jar["t"] == "jar", "a storage jar set down")
	req("container_click", {"c": up, "slot": 101, "button": 0, "shift": true})
	check(count("berries") == 0 and int((World.be(up)["d"]["inv"] as Array)[0].get("n", 0)) == 20, "shift-click puts the berries in the jar")
	req("container_click", {"c": up, "slot": 0, "button": 1, "shift": false})
	check(int(inv().get_slot(Inventory.CURSOR).get("n", 0)) == 10, "right click takes half back out")
	req("inv_close")
	check(count("berries") == 10, "and closing puts them in your pack")
	req("break", {"c": up, "slot": 0})
	check(World.be(up).is_empty() and count("jar") == 1 and count("berries") == 20, "picking the jar up gives back the jar and what was in it")
	# clay forming: a bowl
	clear_inv()
	give("clay", 6)
	stand_near(c)
	use_on(c, 0, true)
	be = World.be(up)
	check(not be.is_empty() and be["t"] == "clay", "clay set down to shape")
	req("clay_choose", {"c": up, "r": "bowl"})
	var layers: Array = ItemDB.clayforming["bowl"]["layers"]
	var total := 0
	for l in layers.size():
		var cells := PackedInt32Array()
		for i in 256:
			if (layers[l] as PackedByteArray)[i] == 1:
				cells.append(i)
		total += cells.size()
		# one wrong cell, then take it away again
		if l == 0:
			req("clay", {"c": up, "cells": PackedInt32Array([0]), "add": true})
			req("clay", {"c": up, "cells": PackedInt32Array([0]), "add": false})
		req("clay", {"c": up, "cells": cells, "add": true})
		if l < layers.size() - 1:
			check(int(World.be(up)["d"]["layer"]) == l + 1, "layer %d done, on to the next" % (l + 1))
	check(World.be(up).is_empty() and count("bowl_raw") == 1, "the bowl is shaped (%d cells)" % total)
	var used := 6 - count("clay")
	check(used == int(ceil(total / 32.0)), "it used %d lumps of clay (%d cells)" % [used, total])
	# not enough clay: it stops and says so
	clear_inv()
	give("clay", 1)
	use_on(c, 0, true)
	req("clay_choose", {"c": up, "r": "jar"})
	var jl: PackedByteArray = ItemDB.clayforming["jar"]["layers"][0]
	var all := PackedInt32Array()
	for i in 256:
		if jl[i] == 1:
			all.append(i)
	req("clay", {"c": up, "cells": all, "add": true})
	var placed := (World.be(up)["d"]["vox"] as PackedByteArray).count(1)
	check(placed == 32, "one lump goes 32 cells far (%d)" % placed)
	req("break", {"c": up, "slot": 0})
	check(count("clay") == 1 and World.be(up).is_empty(), "picking it up gives the clay back")


# ---------------------------------------------------------------------------
# Fire
# ---------------------------------------------------------------------------

func _firepit(c: Vector3i, sticks: int, tinder: int, logs: int = 0) -> Dictionary:
	stand_near(c)
	clear_inv()
	give("stick", sticks + 1, {}, 0)
	give("dry_grass", tinder + 1, {}, 1)
	give("firewood", logs + 1, {}, 2)
	use_on(c, 0, true)
	var up := c + Vector3i.UP
	for i in sticks - 1:
		use_on(up, 0)
	for i in tinder:
		use_on(up, 1)
	for i in logs:
		use_on(up, 2)
	return World.be(up)


func suite_fire() -> void:
	var c := flat_spot(30, 36)
	var up := c + Vector3i.UP
	var be := _firepit(c, 1, 0)
	check(not be.is_empty() and be["t"] == "firepit" and int(be["d"]["sticks"]) == 1, "a stick on the ground starts a fire pit")
	clear_inv()
	give("stick", 12, {}, 0)
	for i in 10:
		use_on(up, 0)
	be = World.be(up)
	check(int(be["d"]["sticks"]) == 8 and count("stick") == 5, "up to eight sticks (%d, %d left)" % [int(be["d"]["sticks"]), count("stick")])
	give("firestarter", 1, {}, 3)
	req("ignite", {"c": up, "slot": 3})
	check(not bool(World.be(up)["d"]["lit"]), "no tinder: it won't light")
	give("dry_grass", 4, {}, 1)
	for i in 4:
		use_on(up, 1)
	check(int(World.be(up)["d"]["tinder"]) == 3, "three handfuls of tinder at most")
	var dur0 := int(inv().get_slot(3)["d"]["dur"])
	req("ignite", {"c": up, "slot": 3})
	be = World.be(up)
	check(bool(be["d"]["lit"]), "the bow drill lights it")
	check(int(inv().get_slot(3)["d"]["dur"]) == dur0 - 1, "the bow drill wears")
	check(a.fire.heat_sources().size() == 1, "it gives off heat")
	# warmth (once the sticks have caught)
	hours(0.3)
	var near := Climate.temp_at(Vector3(up) + Vector3(1.2, 0, 0.5), a.fire.heat_sources())
	var far := Climate.temp_at(Vector3(up) + Vector3(9, 0, 0), a.fire.heat_sources())
	check(float(near["temp"]) > float(far["temp"]) + 6.0, "warm next to it (%.1f vs %.1f)" % [float(near["temp"]), float(far["temp"])])
	# it burns: tinder, then sticks, then out
	check(String(World.be(up)["d"]["phase"]) == "sticks", "the sticks catch")
	hours(FireActs.STICK_H * 8.0 + 0.3)
	be = World.be(up)
	check(not bool(be["d"]["lit"]) and bool(be["d"]["ash"]) and int(be["d"]["sticks"]) == 0, "eight sticks burn down to ash")
	# relight with logs on top: they last
	be = _firepit(c, 0, 0)
	clear_inv()
	give("stick", 4, {}, 0)
	give("dry_grass", 1, {}, 1)
	give("firewood", 2, {}, 2)
	give("firestarter", 1, {}, 3)
	for i in 3:
		use_on(up, 0)
	use_on(up, 1)
	use_on(up, 2)
	use_on(up, 2)
	req("ignite", {"c": up, "slot": 3})
	check(bool(World.be(up)["d"]["lit"]), "lit again on its ashes")
	hours(FireActs.STICK_H * 3.0 + 0.4)
	var fd: Dictionary = World.be(up)["d"]
	check(bool(fd["lit"]) and String(fd["phase"]) == "logs", "the firewood has caught (lit %s, %s, sticks %.2f h, logs %.2f h)" % [fd["lit"], fd["phase"], float(fd["sf"]), float(fd["lf"])])
	hours(FireActs.LOG_H * 2.0 + 0.3)
	check(not bool(World.be(up)["d"]["lit"]), "and burned down after ~%.1f hours" % (FireActs.LOG_H * 2.0))
	# logs on tinder alone won't catch
	var c2 := flat_spot(24, 30)
	var up2 := c2 + Vector3i.UP
	stand_near(c2)
	clear_inv()
	give("dry_grass", 2, {}, 0)
	give("firewood", 2, {}, 1)
	give("firestarter", 1, {}, 2)
	use_on(c2, 0, true)
	use_on(up2, 1)
	req("ignite", {"c": up2, "slot": 2})
	check(not bool(World.be(up2)["d"]["lit"]), "tinder and firewood without sticks won't light")
	# rain drowns an open fire, not a sheltered one
	World.env["rain"] = 1.0
	World.env["rain_target"] = 1.0
	clear_inv()
	give("stick", 3, {}, 0)
	give("firestarter", 1, {}, 2)
	use_on(up2, 0)
	use_on(up2, 0)
	req("ignite", {"c": up2, "slot": 2})
	check(not bool(World.be(up2)["d"]["lit"]), "can't light an open fire in the rain")
	World.env["rain"] = 0.0
	req("ignite", {"c": up2, "slot": 2})
	check(bool(World.be(up2)["d"]["lit"]), "lit while it's dry")
	World.env["rain"] = 1.0
	real_seconds(FireActs.RAIN_OUT_S + 2.0)
	check(not bool(World.be(up2)["d"]["lit"]), "then the rain puts it out")
	# under a roof
	var c3 := flat_spot(36, 34)
	var up3 := c3 + Vector3i.UP
	World.set_block(up3 + Vector3i(0, 3, 0), Blocks.id_of("dirt"))
	World.env["rain"] = 0.0
	_firepit(c3, 3, 1)
	give("firestarter", 1, {}, 3)
	req("ignite", {"c": up3, "slot": 3})
	World.env["rain"] = 1.0
	real_seconds(FireActs.RAIN_OUT_S + 2.0)
	check(bool(World.be(up3)["d"]["lit"]), "a fire under cover keeps burning in the rain")
	World.env["rain"] = 0.0
	World.env["rain_target"] = 0.0
	# cooking
	clear_inv()
	give("mushroom", 2, {}, 0)
	give("stick", 6, {}, 1)
	for i in 5:
		use_on(up3, 1)
	use_on(up3, 0)
	check((World.be(up3)["d"]["food"] as Array).size() == 1, "a mushroom on the fire")
	real_seconds(23.0)
	var food: Array = World.be(up3)["d"]["food"]
	check(food.size() == 1 and String(food[0]["i"]) == "mushroom_roasted", "it roasts")
	use_on(up3, 5)
	check(count("mushroom_roasted") == 1, "taken off with an empty hand")
	use_on(up3, 0)
	real_seconds(22.0 * 2.8)
	food = World.be(up3)["d"]["food"]
	check(food.size() == 1 and String(food[0]["i"]) == "charred_food", "left too long, it chars")
	use_on(up3, 5)
	# torches
	clear_inv()
	give("torch", 3, {}, 0)
	use_on(up3, 0)
	check(inv().item_at(0) == "torch_lit" and count("torch_lit") == 3, "torches lit at the fire")
	var c4 := flat_spot(28, 28)
	var up4 := c4 + Vector3i.UP
	stand_near(c4)
	give("stick", 2, {}, 1)
	give("dry_grass", 1, {}, 2)
	use_on(c4, 1, true)
	use_on(up4, 1)
	use_on(up4, 2)
	use_on(up4, 0)
	check(bool(World.be(up4)["d"]["lit"]), "a burning torch lights a fire pit at once")
	# stew
	stand_near(c3)
	clear_inv()
	give("pot", 1, {"w": 3}, 0)
	give("turnip", 2, {}, 1)
	give("bowl", 2, {}, 2)
	var sticks := Inventory.make("stick", 8)
	inv().set_slot(3, sticks)
	for i in 4:
		use_on(up3, 3)
	use_on(up3, 0)
	check(not (World.be(up3)["d"]["pot"] as Dictionary).is_empty(), "a pot of water on the fire")
	use_on(up3, 1)
	use_on(up3, 1)
	real_seconds(FireActs.STEW_S + 2.0)
	var pot: Dictionary = World.be(up3)["d"]["pot"]
	check(int(pot.get("stew", 0)) >= 2, "stew (%d portions)" % int(pot.get("stew", 0)))
	use_on(up3, 2)
	var bowl_slot := -1
	for i in Inventory.MAIN:
		var bs := inv().get_slot(i)
		if not bs.is_empty() and String(bs["i"]) == "bowl" and String(bs["d"].get("c", "")) == "stew":
			bowl_slot = i
	check(bowl_slot >= 0, "ladled into a bowl")
	World.stats[pid]["hunger"] = 0.2
	if bowl_slot >= 0:
		var tmp := inv().get_slot(bowl_slot)
		inv().set_slot(bowl_slot, inv().get_slot(4))
		inv().set_slot(4, tmp)
		req("eat", {"slot": 4})
		check(float(World.stats[pid]["hunger"]) > 0.45, "a bowl of stew is a meal")
	# standing in a fire hurts
	check(a.fire.burning_at(Vector3(up3) + Vector3(0.5, 0.05, 0.5)) > 0.0, "standing in the fire burns")
	# taking a cold pit apart gives the fuel back
	var c5 := flat_spot(20, 34)
	_firepit(c5, 4, 2)
	clear_inv()
	req("break", {"c": c5 + Vector3i.UP, "slot": 0})
	check(count("stick") == 4 and count("dry_grass") == 2, "a cold fire pit comes apart into its sticks and tinder")


# ---------------------------------------------------------------------------
# Pit kiln
# ---------------------------------------------------------------------------

func _kiln(c: Vector3i, item: String, n: int) -> Vector3i:
	## Set n raw pieces down in cell c (whose floor is c + DOWN) and build a kiln over them.
	stand_near(c)
	clear_inv()
	give(item, n, {}, 0)
	give("dry_grass", 5, {}, 1)
	give("stick", 7, {}, 2)
	give("firestarter", 1, {}, 3)
	use_on(c + Vector3i.DOWN, 0, true)
	for i in n - 1:
		use_on(c, 0, true)
	return c


func suite_kiln() -> void:
	# a pit: dig a hole one deep
	var g := flat_spot(30, 36)
	World.set_block(g, 0)
	var c := g
	_kiln(c, "bowl_raw", 4)
	var be := World.be(c)
	check(not be.is_empty() and be["t"] == "ground" and int(be["d"]["items"][0]["n"]) == 4, "four raw bowls set down in the pit")
	use_on(c, 1)
	be = World.be(c)
	check(be["t"] == "kiln" and int(be["d"]["grass"]) == 1, "dry grass over them: a pit kiln")
	use_on(c, 2)
	check(int(World.be(c)["d"]["sticks"]) == 0, "sticks only after the grass")
	for i in 4:
		use_on(c, 1)
	check(int(World.be(c)["d"]["grass"]) == 4, "four grass at most")
	for i in 7:
		use_on(c, 2)
	check(int(World.be(c)["d"]["sticks"]) == 6, "six sticks")
	req("ignite", {"c": c, "slot": 3})
	be = World.be(c)
	check(bool(be["d"]["lit"]) and int(be["d"]["enc"]) == 4, "lit, walled in on all four sides")
	hours(FireActs.KILN_H + 0.3)
	be = World.be(c)
	check(not be.is_empty() and be["t"] == "ground", "burned down")
	var bowls := 0
	var shards := 0
	for s in be["d"].get("items", []):
		if String(s["i"]) == "bowl":
			bowls += int(s["n"])
		if String(s["i"]) == "potsherd":
			shards += int(s["n"])
	check(bowls == 4 and shards == 0, "in a pit, all four fire without a crack (%d, %d)" % [bowls, shards])
	clear_inv()
	use_on(c, 0)
	check(count("bowl") == 4, "take the bowls out")
	check(World.be(c).is_empty(), "and the ash with them")
	# on open ground some crack
	var o := flat_spot(24, 28) + Vector3i.UP
	_kiln(o, "brick_raw", 16)
	use_on(o, 1)
	for i in 3:
		use_on(o, 1)
	for i in 6:
		use_on(o, 2)
	req("ignite", {"c": o, "slot": 3})
	check(int(World.be(o)["d"]["enc"]) <= 1, "this one stands in the open")
	hours(FireActs.KILN_H + 0.3)
	var cracked := 0
	var bricks := 0
	for s in World.be(o)["d"].get("items", []):
		if String(s["i"]) == "potsherd":
			cracked += int(s["n"])
		if String(s["i"]) == "brick":
			bricks += int(s["n"])
	check(cracked > 0 and bricks > 0 and cracked + bricks == 16, "in the open some crack (%d of 16)" % cracked)
	# rain on an open kiln
	var r := flat_spot(36, 40) + Vector3i.UP
	_kiln(r, "bowl_raw", 1)
	use_on(r, 1)
	for i in 3:
		use_on(r, 1)
	for i in 6:
		use_on(r, 2)
	req("ignite", {"c": r, "slot": 3})
	World.env["rain"] = 1.0
	real_seconds(FireActs.RAIN_OUT_S * 1.5 + 2.0)
	be = World.be(r)
	check(be["t"] == "kiln" and not bool(be["d"]["lit"]) and int(be["d"]["grass"]) == 0, "rain puts out an open kiln")
	World.env["rain"] = 0.0


# ---------------------------------------------------------------------------
# Survival
# ---------------------------------------------------------------------------

func suite_survival() -> void:
	var st: Dictionary = World.stats[pid]
	place_player(World.spawn_point(pid))
	World.env["t"] = 24.0 + 12.0
	var h0 := float(st["hunger"])
	var t0 := float(st["thirst"])
	hours(6.0)
	check(float(st["hunger"]) < h0 - 0.1 and float(st["thirst"]) < t0 - 0.15, "hungry and thirsty after six hours")
	give("berries", 5)
	var h1 := float(st["hunger"])
	req("eat", {"slot": 0})
	check(float(st["hunger"]) > h1 and count("berries") == 4, "eating berries")
	# drink at the pond
	var w := _find("water")
	place_player(Vector3(w) + Vector3(1.5, 1.5, 0.5))
	var t1 := float(st["thirst"])
	clear_inv()
	req("drink", {"c": w})
	check(float(st["thirst"]) > t1, "drinking from the pond")
	# a cold night in the open
	place_player(World.spawn_point(pid))
	World.env["t"] = 24.0 * 2 + 1.0
	st["warmth"] = 0.8
	var tmp := Climate.temp_at(World.spawn_point(pid))
	check(float(tmp["temp"]) < 9.0, "it's cold at night (%.1f C)" % float(tmp["temp"]))
	hours(3.0)
	check(float(st["warmth"]) < 0.55, "warmth drains away in the open (%.2f)" % float(st["warmth"]))
	# by a fire it comes back
	var c := flat_spot(30, 36)
	_firepit(c, 6, 2, 2)
	give("firestarter", 1, {}, 3)
	req("ignite", {"c": c + Vector3i.UP, "slot": 3})
	place_player(Vector3(c) + Vector3(1.7, 1.0, 0.5))
	var w0 := float(st["warmth"])
	hours(1.0)
	check(float(st["warmth"]) > w0 + 0.2, "warming up by the fire (%.2f -> %.2f)" % [w0, float(st["warmth"])])
	# death leaves a bag; respawn; take it back
	clear_inv()
	give("knife", 1, {"mat": "flint"}, 0)
	give("stick", 7, {}, 1)
	place_player(World.spawn_point(pid) + Vector3(2, 0, 0))
	Survival.damage(pid, 2.0, "fall")
	check(not bool(st["alive"]), "dead")
	var bags := World.entities_of("satchel")
	check(bags.size() == 1 and (bags[0]["d"]["items"] as Array).size() == 2, "a bag with your things where you fell")
	check(inv().all_stacks().is_empty(), "nothing left on you")
	req("break", {"c": Vector3i(30, 44, 30), "slot": 0})
	req("respawn")
	check(bool(st["alive"]) and float(st["health"]) > 0.5, "you wake up")
	if not bags.is_empty():
		var bp: Vector3 = (bags[0]["xf"] as Transform3D).origin
		place_player(bp + Vector3(1, 0, 0))
		req("satchel", {"eid": int(bags[0]["id"])})
		check(count("stick") == 7 and count("knife") == 1 and World.entities_of("satchel").is_empty(), "everything back from the bag")
	# the abyss keeps what it takes
	give("flint", 3, {}, 2)
	Survival.die(pid, "abyss")
	check(World.entities_of("satchel").is_empty(), "no bag after falling into the abyss")
	req("respawn")


# ---------------------------------------------------------------------------
# Farming and the island's slow life
# ---------------------------------------------------------------------------

func suite_farm() -> void:
	var c := flat_spot(26, 36)
	if Blocks.name_of(World.block(c)) != "grass":
		World.set_block(c, Blocks.id_of("grass"))
	stand_near(c)
	give("hoe", 1, {"mat": "stone"}, 0)
	give("seeds_turnip", 3, {}, 1)
	use_on(c, 0)
	check(Blocks.name_of(World.block(c)) == "farmland", "a hoe tills grass into farmland")
	use_on(c, 1)
	var crop := c + Vector3i.UP
	check(Blocks.name_of(World.block(crop)) == "crop_turnip" and World.block_meta(crop) == 0, "turnips sown")
	for i in 300:
		a.farm.tick(2.0)
		if World.block_meta(crop) >= 3:
			break
	check(World.block_meta(crop) == 3, "they grow to ripeness")
	clear_inv()
	req("break", {"c": crop, "slot": 0})
	pickup_all(Vector3(crop))
	check(count("turnip") >= 2 and count("seeds_turnip") >= 1, "harvest: turnips and seed (%d, %d)" % [count("turnip"), count("seeds_turnip")])
	# berries come back
	var b := _find("berry_bush")
	stand_near(b)
	clear_inv()
	World.set_block_meta(b, 1)
	use_on(b, 0, false, Vector3i(1, 0, 0))
	check(count("berries") >= 2 and World.block_meta(b) == 0, "berries picked")
	for i in 300:
		a.farm.tick(2.0)
		if World.block_meta(b) == 1:
			break
	check(World.block_meta(b) == 1, "the bush fruits again")
	# a sapling grows into a tree
	var s := flat_spot(22, 36)
	World.set_block(s, Blocks.id_of("grass"))
	for o in [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]:
		for y in range(1, 9):
			if World.block(s + o + Vector3i(0, y, 0)) != 0 and not Blocks.has_flag(World.block(s + o + Vector3i(0, y, 0)), "leaves"):
				World.set_block(s + o + Vector3i(0, y, 0), 0)
	World.set_block(s + Vector3i.UP, Blocks.id_of("sapling_oak"))
	for i in 600:
		a.farm.tick(2.0)
		if Blocks.has_flag(World.block(s + Vector3i.UP), "tree"):
			break
	check(Blocks.has_flag(World.block(s + Vector3i.UP), "tree") and World.block_meta(s + Vector3i.UP) & BlockActs.NATURAL, "the sapling became a tree")
	# filling a bowl
	var w := _find("water")
	place_player(Vector3(w) + Vector3(1.5, 1.5, 0.5))
	clear_inv()
	give("bowl", 1, {}, 0)
	use_on(w, 0)
	check(String(inv().get_slot(0)["d"].get("c", "")) == "water", "a bowl filled at the pond")
	var st: Dictionary = World.stats[pid]
	st["thirst"] = 0.3
	req("eat", {"slot": 0})
	check(float(st["thirst"]) > 0.55 and String(inv().get_slot(0)["d"].get("c", "")) == "", "drinking from the bowl")
	# a bed
	var bc := flat_spot(32, 40)
	stand_near(bc)
	give("straw_bed", 1, {}, 1)
	req("place", {"c": bc + Vector3i.UP, "slot": 1, "face": Vector3i.UP})
	check(Blocks.name_of(World.block(bc + Vector3i.UP)) == "straw_bed", "a straw bed placed")
	req("bed_set", {"c": bc + Vector3i.UP})
	check(World.stats[pid]["bed"] == bc + Vector3i.UP, "it's where you'll wake")


# ---------------------------------------------------------------------------
# Saving and loading
# ---------------------------------------------------------------------------

func suite_save() -> void:
	var c := flat_spot(30, 36)
	_firepit(c, 4, 1)
	var g := flat_spot(26, 30) + Vector3i.UP
	stand_near(g + Vector3i.DOWN)
	give("bowl", 2, {}, 0)
	use_on(g + Vector3i.DOWN, 0, true)
	World.set_block(Vector3i(30, 50, 30), Blocks.id_of("brick_block"))
	clear_inv()
	give("knife", 1, {"mat": "flint", "dur": 33}, 4)
	give("berries", 9, {}, 5)
	var t := World.hours()
	var n_ent := World.entities.size()
	check(Game.save() == OK, "saved")
	var data := World.build_snapshot()
	check(World.load_world("TestIsland") == OK, "loaded")
	World.on_player_joined(pid, Settings.player_name)
	check(World.block(Vector3i(30, 50, 30)) == Blocks.id_of("brick_block"), "a placed block is still there")
	check(not World.be(c + Vector3i.UP).is_empty() and int(World.be(c + Vector3i.UP)["d"]["sticks"]) == 4, "the fire pit is still there")
	check(not World.be(g).is_empty() and World.be(g)["t"] == "ground", "the bowl left on the ground too")
	check(World.entities.size() == n_ent, "the same things in the world (%d / %d)" % [World.entities.size(), n_ent])
	check(absf(World.hours() - t) < 0.01, "the same time of day")
	var kn := inv().get_slot(4)
	check(String(kn.get("i", "")) == "knife" and int(kn["d"]["dur"]) == 33 and count("berries") == 9, "your inventory came back")
	# an island from before the block world can't be opened
	var old := FileAccess.open(World.save_path("OldIsland"), FileAccess.WRITE)
	old.store_var({"version": 3, "name": "OldIsland"})
	old.close()
	check(World.load_world("OldIsland") == ERR_FILE_UNRECOGNIZED, "an old island is recognised and refused")
	World.delete_save("OldIsland")
	World.load_world("TestIsland")
	World.on_player_joined(pid, Settings.player_name)


# ---------------------------------------------------------------------------
# Ten days on the island
# ---------------------------------------------------------------------------

func suite_longrun() -> void:
	var st: Dictionary = World.stats[pid]
	var c := flat_spot(30, 36)
	place_player(Vector3(c) + Vector3(1.7, 1.0, 0.5))
	var t0 := Time.get_ticks_msec()
	var ticks := 0
	var max_tick := 0
	for day in 10:
		for step in 48:
			# a sensible islander: eats and drinks when low, keeps warm by a fire at night
			if float(st["hunger"]) < 0.4:
				Survival.eat(pid, {"hunger": 0.3}, false)
			if float(st["thirst"]) < 0.4:
				Survival.drink(pid, 0.5)
			if World.is_night() and World.be(c + Vector3i.UP).is_empty():
				_firepit(c, 6, 2, 4)
				give("firestarter", 1, {}, 3)
				req("ignite", {"c": c + Vector3i.UP, "slot": 3})
				place_player(Vector3(c) + Vector3(1.7, 1.0, 0.5))
			elif not World.is_night() and not World.be(c + Vector3i.UP).is_empty() and not bool(World.be(c + Vector3i.UP)["d"]["lit"]):
				req("break", {"c": c + Vector3i.UP, "slot": 0})
			var tt := Time.get_ticks_msec()
			hours(0.5, 0.5)
			max_tick = maxi(max_tick, Time.get_ticks_msec() - tt)
			ticks += 1
	check(bool(st["alive"]), "alive after ten days (health %.2f)" % float(st["health"]))
	check(World.day() >= 11, "it's day %d" % World.day())
	check(max_tick < 50, "one simulation step takes at most %d ms" % max_tick)
	print("   10 days: %d steps in %d ms" % [ticks, Time.get_ticks_msec() - t0])
