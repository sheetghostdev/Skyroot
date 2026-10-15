extends Node
## Headless test suites.  They drive the real game through the same requests
## the client sends, then check the world.
##
##   godot --headless --path . res://tests/test_main.tscn -- --suite=core,blocks,water,craft,fire,kiln,survival,farm,save,longrun
##   (--suite=all runs everything)

const SUITES := ["core", "blocks", "water", "craft", "fire", "kiln", "survival", "farm", "save", "longrun", "sea", "raft", "animals"]
const SEA_SUITES := ["sea", "raft", "animals"]  # these run on an archipelago

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
		await _fresh("sea" if s in SEA_SUITES else "sky")
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


func _fresh(kind := "sky") -> void:
	## A brand-new island (or archipelago) for every suite.
	Game._teardown()
	await get_tree().process_frame
	Game.start_world("solo", "TestIsland", true, Net.DEFAULT_PORT, kind, 777)
	for i in 3:
		await get_tree().process_frame
	a = World.actions
	a.no_rate = true
	lp = Game.game_world.local_player()
	lp.set_physics_process(false)
	lp.interactor.set_process(false)
	Game.game_world.sim.set_process(false)
	# no surprise showers: it rains in a test only when the test says so
	Game.game_world.sim.weather.showers = false
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
	var gids: Array = Guide.active_goals().map(func(g): return String(g["id"]))
	check(gids.has("tinder") and not gids.has("raft"), "the sky island keeps its own goals")
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
		var r := body.move(SolidFrame.new(World.vox), p, Vector3(0, -0.2, 0), false)
		p = r["pos"]
	check(absf(p.y - sp.y) < 0.05 and body.on_ground, "a falling body lands on the ground (%.2f vs %.2f)" % [p.y, sp.y])
	# a wall stops you
	var c := VoxelData.cell_of(p)
	World.set_block(c + Vector3i(1, 0, 0), Blocks.id_of("dirt"))
	World.set_block(c + Vector3i(1, 1, 0), Blocks.id_of("dirt"))
	var start := Vector3(c.x + 0.5, p.y, c.z + 0.5)
	var q := start
	for i in 20:
		q = body.move(SolidFrame.new(World.vox), q, Vector3(0.1, 0, 0), false)["pos"]
	check(q.x <= c.x + 1.0 - 0.299, "walls stop you (%.3f)" % q.x)
	# a low step (a straw bed) is climbed on its own
	World.set_block(c + Vector3i(1, 0, 0), Blocks.id_of("straw_bed"))
	World.set_block(c + Vector3i(1, 1, 0), 0)
	q = start
	for i in 20:
		var r2 := body.move(SolidFrame.new(World.vox), q, Vector3(0.1, -0.05, 0), false)
		q = r2["pos"]
	check(q.x > c.x + 1.2 and q.y > start.y + 0.25, "steps up onto a low block (%.2f, %.2f)" % [q.x, q.y])
	# farmland (15/16 high) needs a jump
	World.set_block(c + Vector3i(1, 0, 0), Blocks.id_of("farmland"))
	q = start
	for i in 20:
		q = body.move(SolidFrame.new(World.vox), q, Vector3(0.1, -0.05, 0), false)["pos"]
	check(q.x < c.x + 1.0, "a full-height step needs a jump")
	# sneaking at the edge, you don't fall
	var edge := _find_edge()
	if check(edge.x >= 0, "found an edge"):
		var ep := Vector3(edge.x + 0.5, edge.y + 1.0, edge.z + 0.5)
		var dir := _edge_dir(edge)
		var e2 := ep
		for i in 40:
			var r3 := body.move(SolidFrame.new(World.vox), e2, Vector3(dir.x, 0, dir.z) * 0.1 + Vector3(0, -0.05, 0), true)
			e2 = r3["pos"]
		check(e2.y > edge.y + 0.9, "sneaking keeps you on the edge")
		var e3 := ep
		for i in 60:
			var r4 := body.move(SolidFrame.new(World.vox), e3, Vector3(dir.x, 0, dir.z) * 0.1 + Vector3(0, -0.2, 0), false)
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
	# a block broken at the very edge gives its drops to you, not the sky
	# (a lone block stuck out over the abyss, broken from the edge)
	var ed := _find_edge()
	var lone := Vector3i(ed.x + 1, ed.y, ed.z)
	World.set_block(lone, Blocks.id_of("dirt"))
	place_player(Vector3(ed) + Vector3(0.5, 1.0, 0.5))
	clear_inv()
	req("break", {"c": lone, "slot": 0})
	check(World.block(lone) == 0 and count("dirt") == 1, "a block broken over the abyss drops into your hands")
	# a torch against the side of a block hangs on it, and goes when the block does
	var tw := flat_spot(34, 36)
	var wall := tw + Vector3i.UP
	World.set_block(wall, Blocks.id_of("dirt"))
	World.set_block(wall + Vector3i(1, 0, 0), 0)
	place_player(Vector3(wall) + Vector3(2.5, 0.0, 0.5))
	clear_inv()
	give("torch_lit", 2)
	req("place", {"c": wall + Vector3i(1, 0, 0), "slot": 0, "face": Vector3i(1, 0, 0)})
	var tm := World.block_meta(wall + Vector3i(1, 0, 0))
	check(World.block(wall + Vector3i(1, 0, 0)) == Blocks.id_of("torch") and Blocks.on_wall(Blocks.id_of("torch"), tm) and Blocks.wall_dir(tm) == Vector3i(-1, 0, 0), "a torch hangs on the side of a block")
	req("break", {"c": wall, "slot": 0})
	check(World.block(wall + Vector3i(1, 0, 0)) == 0, "and drops when that block is dug out")
	# a bed is two blocks long, its head the way you face; it goes as one
	var bf := flat_spot(27, 31)
	var bc := bf + Vector3i.UP
	for dz in range(-3, 1):
		World.set_block(bc + Vector3i(0, 0, dz), 0)
		World.set_block(bf + Vector3i(0, 0, dz), Blocks.id_of("dirt"))
	place_player(Vector3(bc) + Vector3(0.5, 0.0, 2.5))
	Net.poses[pid]["y"] = 0.0   # looking toward -Z
	clear_inv()
	give("straw_bed", 1)
	req("place", {"c": bc, "slot": 0, "face": Vector3i.UP})
	var bh := bc + Vector3i(0, 0, -1)
	check(World.block(bc) == Blocks.id_of("straw_bed") and World.block(bh) == Blocks.id_of("straw_bed_head") and Blocks.facing_dir(World.block_meta(bc)) == Vector3i(0, 0, -1), "a bed: foot where you put it, head the way you face")
	req("break", {"c": bh, "slot": 0})
	check(World.block(bc) == 0 and World.block(bh) == 0 and items_near(Vector3(bc), 3.0, "straw_bed") == 1, "breaking either end takes the whole bed (one bed back)")
	# a number key over a slot swaps it onto the hotbar
	clear_inv()
	give("stick", 5, {}, 20)
	give("flint", 1, {}, 2)
	req("inv_swap", {"slot": 20, "i": 2})
	check(String(inv().get_slot(2).get("i", "")) == "stick" and String(inv().get_slot(20).get("i", "")) == "flint", "swapping a pack slot with a hotbar slot")
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
			for y in range(maxi(0, ctr.y - r), mini(World.vox.sy, ctr.y + r + 1)):
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
	# scoop a lot from one spot: the whole pond goes down evenly, no hole is left
	for i in 5:
		ws.take(top2, 1)
	ws.settle()
	var lo := 9
	var hi := 0
	for z in range(pond.z - 8, pond.z + 9):
		for x in range(pond.x - 8, pond.x + 9):
			var c := Vector3i(x, pond.y, z)
			if World.block(c) == w and World.block(c + Vector3i.UP) != w:
				lo = mini(lo, ws.level(c))
				hi = maxi(hi, ws.level(c))
	check(hi - lo <= 1 and ws.level(top2) >= hi - 1, "the pond evens out after water is taken from one spot (levels %d-%d)" % [lo, hi])
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


# ---------------------------------------------------------------------------
# The archipelago
# ---------------------------------------------------------------------------

func _island_of(b: String) -> Dictionary:
	for it in World.geo["islands"]:
		if String(it["b"]) == b:
			return it
	return {}


func _count_near(it: Dictionary, nm: String) -> int:
	var id := Blocks.id_of(nm)
	var c: Vector2 = it["c"]
	var r := int(float(it["r"]) * 1.3) + 2
	var n := 0
	for z in range(int(c.y) - r, int(c.y) + r + 1):
		for x in range(int(c.x) - r, int(c.x) + r + 1):
			for y in range(ArchipelagoGen.SEA - 4, World.vox.sy):
				if World.vox.get_id(x, y, z) == id:
					n += 1
	return n


func suite_sea() -> void:
	var vd := World.vox
	var sea := int(World.geo["sea"])
	check(World.kind == "sea" and vd.sx == ArchipelagoGen.W and vd.sz == ArchipelagoGen.D, "an archipelago world (%dx%dx%d)" % [vd.sx, vd.sy, vd.sz])
	var isl: Array = World.geo["islands"]
	check(isl.size() >= 12, "a dozen or more islands (%d)" % isl.size())
	var kinds := {}
	for it in isl:
		kinds[String(it["b"])] = true
		check(float(it["r"]) <= 22.0, "no island is huge (%s r %.1f)" % [it["b"], it["r"]])
	for b in ["home", "atoll", "grove", "rocky", "marsh", "meadow"]:
		check(kinds.has(b), "there is a %s island" % b)
	var sp := World.spawn_point(pid)
	check(sp.y > sea + 1 and Blocks.is_solid(World.block(VoxelData.cell_of(sp - Vector3(0, 0.1, 0)))), "you wake on dry land (%.1f)" % sp.y)
	# the nearest other island is a short row away
	var home: Dictionary = isl[0]
	var nearest := 9999.0
	for it in isl:
		if it != home:
			nearest = minf(nearest, (it["c"] as Vector2).distance_to(home["c"]) - float(it["r"]) - float(home["r"]))
	check(nearest < 50.0, "another island within reach of a first raft (%.0f m of water)" % nearest)
	# each kind of island has its own things to find
	check(_count_near(_island_of("rocky"), "loose_flint") > 0 and _count_near(_island_of("home"), "loose_flint") == 0, "flint on the rocky isle, none at home")
	check(_count_near(_island_of("grove"), "water") > 0, "a fresh pond on the grove island")
	check(_count_near(_island_of("marsh"), "clay") > 20, "clay in the marsh")
	check(_count_near(_island_of("atoll"), "coconut") > 0 or _count_near(_island_of("home"), "coconut") > 0, "coconuts on the palms")
	check(_count_near(_island_of("home"), "palm_log") > 0, "palms on the home island")
	check(vd.ids.count(Blocks.id_of("seaweed")) > 50, "seaweed in the shallows")
	# the sea reaches past the edge of the world
	check(vd.get_id(-5, sea, 40) == Blocks.sea and vd.get_id(vd.sx + 3, sea, 40) == Blocks.sea, "open sea beyond the edge")
	# the sea is salt
	var shore := _find_shore(home)
	if check(shore.x >= 0, "found the shore of the home island"):
		var wcell := shore + Vector3i(0, 0, 0)
		stand_near(shore + Vector3i.UP)
		var st: Dictionary = World.stats[pid]
		st["thirst"] = 0.5
		req("drink", {"c": wcell})
		check(float(st["thirst"]) < 0.5, "drinking sea water makes you thirstier (%.2f)" % float(st["thirst"]))
		clear_inv()
		give("bowl", 1)
		use_on(wcell, 0)
		check(String(inv().get_slot(0).get("d", {}).get("c", "")) == "sea", "a bowl dipped in the sea holds sea water")
	# the goals and the handbook are the archipelago's own
	var gids: Array = Guide.active_goals().map(func(g): return String(g["id"]))
	check(gids.has("coconut") and gids.has("raft") and gids.has("voyage") and gids.has("boil") and not gids.has("tinder"), "goals for the sea: coconuts, a raft, a voyage, boiling water")
	check(Guide.hint_for("thirsty") == "thirsty_sea" and Guide.hint_for("dusk") == "dusk", "sea wording for the hints that need it")
	check(Guide.for_this_world(Guide.pages["rafts"]) and not Guide.for_this_world(Guide.pages["island"]), "the handbook has the sea pages, not the sky island's")
	clear_inv()
	give("coconut", 1)
	World.stats[pid]["thirst"] = 0.5
	req("eat", {"slot": 0})
	check(float(World.stats[pid]["thirst"]) > 0.6 and Guide.has_flag("ate:coconut"), "a coconut to drink")
	# a coconut pressed into the sand grows a palm
	var sand := _find_beach(home)
	if check(sand.x >= 0 and Blocks.name_of(World.block(sand)) == "sand", "a sandy beach"):
		clear_inv()
		give("coconut", 2)
		stand_near(sand)
		use_on(sand, 0, true)
		check(Blocks.name_of(World.block(sand + Vector3i.UP)) == "sapling_palm" and count("coconut") == 1, "plant a coconut in the sand: a palm sapling")
	# fresh water at sea: boil sea water in a pot over a fire
	var fc := flat_spot(int(home["c"].x) + 2, int(home["c"].y) + 2)
	if shore.x >= 0 and check(fc.x >= 0, "a flat spot for a fire"):
		var fup := fc + Vector3i.UP
		_firepit(fc, 6, 2, 3)
		clear_inv()
		give("pot", 1, {}, 0)
		give("firestarter", 1, {"dur": 8}, 1)
		give("bowl", 1, {}, 2)
		give("waterskin", 1, {}, 3)
		stand_near(shore + Vector3i.UP)
		use_on(shore, 0)
		var pd: Dictionary = inv().get_slot(0)["d"]
		check(int(pd.get("w", 0)) == 3 and bool(pd.get("salt", false)), "a pot dipped in the sea holds sea water")
		use_on(shore, 3)
		check(int(inv().get_slot(3)["d"].get("n", 0)) == 0, "a waterskin won't take sea water")
		stand_near(fc)
		use_on(fup, 0)
		req("ignite", {"c": fup, "slot": 1})
		var fpot: Dictionary = World.be(fup)["d"]["pot"]
		check(bool(World.be(fup)["d"]["lit"]) and bool(fpot.get("salt", false)), "a pot of sea water over a fire")
		use_on(fup, 3)
		check(int(inv().get_slot(3)["d"].get("n", 0)) == 0, "not fit for the waterskin yet")
		real_seconds(FireActs.DESALT_S * 1.4)
		fpot = World.be(fup)["d"]["pot"]
		check(not bool(fpot.get("salt", false)) and int(fpot.get("water", 0)) == 3, "boiled, it's fresh water (%s)" % str(fpot))
		use_on(fup, 2)
		check(String(inv().get_slot(2)["d"].get("c", "")) == "water", "ladle out a bowl of it")
		use_on(fup, 3)
		check(int(inv().get_slot(3)["d"].get("n", 0)) == 2 and int(World.be(fup)["d"]["pot"].get("water", 0)) == 0, "and the rest into the waterskin")
		var stw: Dictionary = World.stats[pid]
		stw["thirst"] = 0.3
		req("eat", {"slot": 3})
		check(float(stw["thirst"]) > 0.6 and int(inv().get_slot(3)["d"].get("n", 0)) == 1, "a long drink from the waterskin")
	# dig out a beach block at sea level beside the water: the sea pours in
	var beach := _find_beach(home)
	if check(beach.x >= 0, "found a beach cell at sea level"):
		World.set_block(beach, 0)
		a.water.settle()
		check(World.block(beach) == Blocks.sea, "the sea pours into a hole dug at the water's edge")
	# things dropped in the sea float
	if shore.x >= 0:
		var eid := a.drop_item("stick", 1, {}, Vector3(shore) + Vector3(0.5, 3.0, 0.5))
		var e: Dictionary = World.entities.get(eid, {})
		check(not e.is_empty() and absf((e["xf"] as Transform3D).origin.y - (sea + 0.8)) < 0.05, "a stick dropped in the sea floats")
	# time passes without trouble across the whole sea
	hours(2.0)
	check(true, "two hours of random ticks over the islands")
	# saved and loaded, it is the same sea
	check(Game.save() == OK, "the archipelago saves")
	var n_isl := isl.size()
	check(World.load_world("TestIsland") == OK and World.kind == "sea" and World.vox.sx == ArchipelagoGen.W and (World.geo["islands"] as Array).size() == n_isl, "and loads again as the same archipelago")
	World.on_player_joined(pid, Settings.player_name)


func _open_water(it: Dictionary, from_shore: float) -> Vector3:
	## A point on the sea surface well clear of the island (and of the bottom).
	var c: Vector2 = it["c"]
	var sea := int(World.geo["sea"])
	for k in 32:
		var dir := Vector2.from_angle(k * TAU / 32.0)
		var p := c + dir * (float(it["r"]) + from_shore)
		var ok := true
		for dz in range(-4, 5):
			for dx in range(-4, 5):
				var x := int(p.x) + dx
				var z := int(p.y) + dz
				for y in [sea - 1, sea, sea + 1]:
					if Blocks.is_solid(World.vox.get_id(x, y, z)):
						ok = false
		if ok:
			return Vector3(p.x, sea + 0.875, p.y)
	return Vector3.INF


func _raft_e() -> Dictionary:
	var rs := World.entities_of("raft")
	return rs[0] if rs.size() == 1 else {}


func _raft_cells() -> Dictionary:
	var e := _raft_e()
	return e["d"]["cells"] if not e.is_empty() else {}


func _deck_pos(e: Dictionary, c: Vector3i) -> Vector3:
	## Where someone standing on cell c of the deck has their feet.
	return (e["xf"] as Transform3D) * (Vector3(c) + Vector3(0.5, Raft.DECK, 0.5))


func _sail(seconds: float) -> void:
	for i in int(seconds * 60.0):
		a.rafts.step(1.0 / 60.0)


func suite_raft() -> void:
	var sea := int(World.geo["sea"])
	var home: Dictionary = World.geo["islands"][0]
	# the pieces are made in the crafting grid
	clear_inv()
	inv().set_slot(Inventory.GRID + 0, Inventory.make("palm_log", 1))
	inv().set_slot(Inventory.GRID + 1, Inventory.make("palm_log", 1))
	inv().set_slot(Inventory.GRID + 4, Inventory.make("twine", 1))
	check(String(a.craft_preview(inv()).get("i", "")) == "raft_floor", "two logs and twine lash a raft section")
	clear_inv()
	inv().set_slot(Inventory.GRID + 1, Inventory.make("firewood", 1))
	inv().set_slot(Inventory.GRID + 4, Inventory.make("stick", 1))
	check(String(a.craft_preview(inv()).get("i", "")) == "paddle", "firewood on a stick makes a paddle")
	clear_inv()
	var water := _open_water(home, 10.0)
	if not check(water != Vector3.INF, "found open water off the home island"):
		return
	# a section floats on the sea, not on land
	var beach := _find_beach(home)
	give("raft_floor", 8)
	stand_near(beach)
	req("raft_new", {"point": Vector3(beach) + Vector3(0.5, 1.0, 0.5), "yaw": 0.0, "slot": 0})
	check(World.entities_of("raft").is_empty() and count("raft_floor") == 8, "a raft section won't lie on the beach")
	place_player(water + Vector3(2.0, 0.2, 0.0))
	req("raft_new", {"point": water, "yaw": 0.0, "slot": 0})
	var e := _raft_e()
	if not check(not e.is_empty() and count("raft_floor") == 7, "a raft section floats on open water"):
		return
	var eid: int = e["id"]
	var xf: Transform3D = e["xf"]
	check(absf(_deck_pos(e, Vector3i.ZERO).y - (sea + 0.875 + Raft.FREEBOARD)) < 0.01, "its deck rides a hand above the water")
	# build it out: beside the floor only
	place_player(_deck_pos(e, Vector3i.ZERO))
	for c in [Vector3i(1, 0, 0), Vector3i(0, 0, 1), Vector3i(1, 0, 1), Vector3i(2, 0, 0)]:
		req("raft_place", {"eid": eid, "cell": c, "slot": 0})
	check(Raft.floor_count(_raft_cells()) == 5 and count("raft_floor") == 3, "four more sections lashed on (%d)" % Raft.floor_count(_raft_cells()))
	req("raft_place", {"eid": eid, "cell": Vector3i(4, 0, 0), "slot": 0})
	check(Raft.floor_count(_raft_cells()) == 5, "not one that floats loose")
	# a sail, an anchor and a steering oar on the deck
	clear_inv()
	give("sail", 2, {}, 0)
	give("anchor", 1, {}, 1)
	give("steering_oar", 1, {}, 2)
	give("dirt", 1, {}, 3)
	req("raft_place", {"eid": eid, "cell": Vector3i(1, 1, 0), "slot": 0})
	req("raft_place", {"eid": eid, "cell": Vector3i(1, 1, 1), "slot": 1})
	req("raft_place", {"eid": eid, "cell": Vector3i(0, 1, 1), "slot": 2})
	req("raft_place", {"eid": eid, "cell": Vector3i(1, 2, 0), "slot": 0})
	var cells := _raft_cells()
	check(cells.has(Vector3i(1, 1, 0)) and cells.has(Vector3i(1, 1, 1)) and cells.has(Vector3i(0, 1, 1)), "sail, anchor and steering oar stand on the deck")
	check(not cells.has(Vector3i(1, 2, 0)), "a sail goes on the deck, not on top of another")
	req("raft_place", {"eid": eid, "cell": Vector3i(2, 1, 0), "slot": 3})
	check(_raft_cells().has(Vector3i(2, 1, 0)), "ordinary blocks can be built on a raft too")
	req("raft_place", {"eid": eid, "cell": Vector3i(0, 1, 0), "slot": 3})
	var c_flat := flat_spot(int(home["c"].x), int(home["c"].y))
	place_player(Vector3(c_flat) + Vector3(2.5, 1.0, 0.5))
	req("place", {"c": c_flat + Vector3i.UP, "face": Vector3i.UP, "slot": 0})
	check(World.block(c_flat + Vector3i.UP) != Blocks.id_of("raft_sail") and count("sail") == 1, "a sail can't be put up on dry land")
	# the wind fills the raised sail
	place_player(_deck_pos(e, Vector3i.ZERO))
	req("raft_use", {"eid": eid, "cell": Vector3i(1, 1, 0)})
	check((int((_raft_cells()[Vector3i(1, 1, 0)] as Vector2i).y) & 4) != 0, "the sail goes up")
	World.env["wind"] = Vector2(3.0, 0.0)
	var start := (_raft_e()["xf"] as Transform3D).origin
	_sail(10.0)
	var moved := (_raft_e()["xf"] as Transform3D).origin - start
	check(moved.x > 4.0 and absf(moved.z) < moved.x * 0.3, "it runs before the wind (%.1f m, %.1f across)" % [moved.x, moved.z])
	check(absf((_raft_e()["xf"] as Transform3D).origin.y - Raft.origin_y(sea)) < 0.001, "and stays afloat at the same height")
	# the anchor holds it
	place_player(_deck_pos(_raft_e(), Vector3i.ZERO))
	req("raft_use", {"eid": eid, "cell": Vector3i(1, 1, 1)})
	check(bool(_raft_e()["d"].get("anchor", false)), "the anchor drops")
	_sail(4.0)
	var spd := (_raft_e()["d"].get("v", Vector3.ZERO) as Vector3).length()
	check(spd < 0.6, "and holds it against the wind (%.2f m/s)" % spd)
	req("raft_use", {"eid": eid, "cell": Vector3i(1, 1, 1)})
	req("raft_use", {"eid": eid, "cell": Vector3i(1, 1, 0)})
	check(not bool(_raft_e()["d"].get("anchor", false)) and (int((_raft_cells()[Vector3i(1, 1, 0)] as Vector2i).y) & 4) == 0, "anchor up, sail furled")
	_raft_e()["d"]["v"] = Vector3.ZERO
	_raft_e()["d"]["w"] = 0.0
	# paddling: the way you look, and off-centre strokes turn it
	clear_inv()
	give("paddle", 1)
	var dur0 := int(inv().get_slot(0)["d"]["dur"])
	e = _raft_e()
	place_player(_deck_pos(e, Vector3i(1, 0, 0)))
	req("paddle", {"eid": eid, "slot": 0, "dir": Vector3(0, -0.3, -1)})
	var v: Vector3 = _raft_e()["d"]["v"]
	check(v.z < -0.1 and absf(v.y) < 1e-6, "a paddle stroke pushes the raft the way you look (%.2f)" % v.z)
	check(int(inv().get_slot(0)["d"]["dur"]) < dur0, "and wears the paddle")
	place_player(_deck_pos(e, Vector3i(2, 0, 0)))
	_raft_e()["d"]["w"] = 0.0
	req("paddle", {"eid": eid, "slot": 0, "dir": Vector3(0, 0, -1)})
	check(absf(float(_raft_e()["d"]["w"])) > 0.01, "a stroke off to one side turns it")
	# the helm: steer with the oar
	_raft_e()["d"]["v"] = Vector3.ZERO
	_raft_e()["d"]["w"] = 0.0
	var yaw0 := (_raft_e()["xf"] as Transform3D).basis.get_euler().y
	req("raft_use", {"eid": eid, "cell": Vector3i(0, 1, 1)})
	for i in 20:
		req("helm", {"eid": eid, "amount": 1.0})
		_sail(0.1)
	var turned := (_raft_e()["xf"] as Transform3D).basis.get_euler().y - yaw0
	check(turned > 0.2, "the steering oar turns the raft (%.2f rad)" % turned)
	# it runs aground rather than sailing up the beach
	e = _raft_e()
	var to_home := Vector3(home["c"].x, 0, home["c"].y) - (e["xf"] as Transform3D).origin
	to_home.y = 0.0
	e["d"]["v"] = to_home.normalized() * 3.0
	e["d"]["w"] = 0.0
	_helm_clear()
	for i in 40 * 60:
		e = _raft_e()
		if (e["d"]["v"] as Vector3).dot(to_home) <= 0.0:
			break
		e["d"]["v"] = to_home.normalized() * 3.0
		a.rafts.step(1.0 / 60.0)
	e = _raft_e()
	var dist := Vector2((e["xf"] as Transform3D).origin.x - home["c"].x, (e["xf"] as Transform3D).origin.z - home["c"].y).length()
	check(not a.rafts._hits_land(e["xf"], e["d"]["cells"]) and dist < float(home["r"]) + 12.0, "it comes to the shore and grounds there, not on it (%.0f m out)" % (dist - float(home["r"])))
	# standing on it: the deck holds you up and carries you
	e = _raft_e()
	var rafts := [{"eid": eid, "xf": e["xf"], "cells": e["d"]["cells"]}]
	var col := SolidFrame.new(World.vox, rafts, -1)
	var body := VoxelBody.new()
	var feet := _deck_pos(e, Vector3i(1, 0, 0)) + Vector3(0, 0.6, 0)
	var res := body.move(col, feet, Vector3(0, -1.5, 0), false)
	check(body.on_ground and absf((res["pos"] as Vector3).y - _deck_pos(e, Vector3i(1, 0, 0)).y) < 0.01, "you can stand on the deck (from the world)")
	check(col.raft_under(res["pos"], body.half) == eid, "and know it's this raft under you")
	var colr := SolidFrame.new(World.vox, rafts, eid)
	var lpos := colr.to_local(feet)
	res = body.move(colr, lpos, Vector3(0, -1.5, 0), false)
	check(body.on_ground and absf((res["pos"] as Vector3).y - Raft.DECK) < 0.01, "and in the raft's own frame")
	res = body.move(colr, Vector3(0.5, Raft.DECK, 0.5), Vector3(0, 0, 0.9), false)
	check((res["pos"] as Vector3).z < 1.1, "the steering oar's post is in your way on deck (%.2f)" % (res["pos"] as Vector3).z)
	lp.riding = eid
	lp._ride_xf = e["xf"]
	lp.global_position = _deck_pos(e, Vector3i(1, 0, 0))
	var before := lp.global_position
	var oxf: Transform3D = e["xf"]
	var nxf := Transform3D(Basis(Vector3.UP, 0.3) * oxf.basis, oxf.origin + Vector3(2, 0, 1))
	World.move_entity(eid, nxf, true)
	lp._carry(lp._raft_list())
	var want := nxf * (oxf.affine_inverse() * before)
	check(lp.global_position.distance_to(want) < 0.01, "the raft carries you as it moves and turns")
	lp.riding = -1
	# taking it apart: never so it splits, and what stands on a section first
	e = _raft_e()
	place_player(_deck_pos(e, Vector3i(1, 0, 0)))
	clear_inv()
	req("raft_break", {"eid": eid, "cell": Vector3i(1, 0, 0)})
	check(_raft_cells().has(Vector3i(1, 0, 0)), "not the section under the sail")
	req("raft_break", {"eid": eid, "cell": Vector3i(1, 1, 0)})
	check(not _raft_cells().has(Vector3i(1, 1, 0)) and count("sail") == 1, "the sail comes down and back to you")
	req("raft_break", {"eid": eid, "cell": Vector3i(2, 1, 0)})
	req("raft_break", {"eid": eid, "cell": Vector3i(1, 0, 0)})
	check(_raft_cells().has(Vector3i(1, 0, 0)), "not a section that would set another adrift")
	# saved and loaded, the raft is where it was
	var xf_saved: Transform3D = _raft_e()["xf"]
	var n_cells := _raft_cells().size()
	check(Game.save() == OK and World.load_world("TestIsland") == OK, "saves and loads with a raft")
	World.on_player_joined(pid, Settings.player_name)
	e = _raft_e()
	check(not e.is_empty() and _raft_cells().size() == n_cells and (e["xf"] as Transform3D).origin.distance_to(xf_saved.origin) < 0.001, "the raft is still there, as built")
	a = World.actions
	a.no_rate = true
	# take it all apart: the last section and the raft is gone
	if not e.is_empty():
		eid = e["id"]
		place_player(_deck_pos(e, Vector3i.ZERO))
		clear_inv()
		for k in 3:
			for c in (_raft_cells() as Dictionary).keys():
				if (c as Vector3i).y > 0:
					req("raft_break", {"eid": eid, "cell": c})
			for c in [Vector3i(2, 0, 0), Vector3i(1, 0, 1), Vector3i(1, 0, 0), Vector3i(0, 0, 1), Vector3i.ZERO]:
				if World.entities.has(eid):
					req("raft_break", {"eid": eid, "cell": c})
		check(World.entities_of("raft").is_empty() and count("raft_floor") == 5, "taken apart, the sections come back (%d, %d left)" % [count("raft_floor"), _raft_cells().size()])


func _animals_of(sp: String) -> Array:
	var out: Array = []
	for e in World.entities_of("animal"):
		if String(e["d"]["s"]) == sp:
			out.append(e)
	return out


func _apos(e: Dictionary) -> Vector3:
	return (e["xf"] as Transform3D).origin


func _run_animals(secs: float) -> void:
	for i in int(secs / AnimalSim.TICK):
		a.animals.step(AnimalSim.TICK)


func suite_animals() -> void:
	var sea := int(World.geo["sea"])
	var all := World.entities_of("animal")
	check(all.size() >= 15, "the islands have animals (%d)" % all.size())
	var crabs := _animals_of("crab")
	var fowl := _animals_of("fowl")
	var goats := _animals_of("goat")
	check(crabs.size() >= 4 and fowl.size() >= 3 and goats.size() >= 2, "crabs, junglefowl and goats (%d, %d, %d)" % [crabs.size(), fowl.size(), goats.size()])
	var on_sand := 0
	for c in crabs:
		var under := World.block(VoxelData.cell_of(_apos(c) - Vector3(0, 0.3, 0)))
		if Blocks.name_of(under) == "sand":
			on_sand += 1
	check(on_sand == crabs.size(), "crabs on the beaches (%d of %d)" % [on_sand, crabs.size()])
	var right_isles := true
	for g in goats:
		var b := String(World.geo["islands"][int(g["d"]["isl"])]["b"])
		if not b in ["rocky", "meadow"]:
			right_isles = false
	check(right_isles, "goats live on the rocky and meadow isles")
	# far from everyone they rest; near, they wander about home
	var goat: Dictionary = goats[0]
	var gp := _apos(goat)
	place_player(gp + Vector3(80, 0, 0))
	_run_animals(5.0)
	check(_apos(goat).distance_to(gp) < 0.01, "an animal nobody is near stands still")
	place_player(gp + Vector3(20, 0, 0))
	var moved := 0.0
	var far := 0.0
	for i in 30:
		_run_animals(1.0)
		moved = maxf(moved, _apos(goat).distance_to(gp))
		far = maxf(far, Vector2(_apos(goat).x, _apos(goat).z).distance_to(Vector2(goat["d"]["home"].x, goat["d"]["home"].z)))
	check(moved > 0.5, "with someone about, it wanders (%.1f m)" % moved)
	check(far < AnimalSim.WANDER + 4.5, "but stays near home (%.1f m)" % far)
	var gy := _apos(goat).y
	check(absf(gy - World.vox.rest_height(_apos(goat) + Vector3(0, 0.5, 0))) < 0.05, "on the ground, not in it or above it")
	# come too close and it runs
	gp = _apos(goat)
	place_player(gp + Vector3(2.0, 0, 0))
	_run_animals(1.5)
	check(_apos(goat).distance_to(gp + Vector3(2.0, 0, 0)) > 2.6, "come close and it runs off (%.1f m)" % _apos(goat).distance_to(gp + Vector3(2.0, 0, 0)))
	# hunting: a crab to one spear thrust, a goat to a few knife cuts
	var crab: Dictionary = crabs[0]
	var cp := _apos(crab)
	place_player(cp + Vector3(1.0, 0, 0))
	clear_inv()
	give("spear", 1, {"mat": "flint"})
	req("hit", {"eid": crab["id"], "slot": 0})
	check(not World.entities.has(crab["id"]), "one spear thrust takes a crab")
	check(items_near(cp, 3.0, "crab_raw") == 1, "and leaves a crab to roast")
	check(int(inv().get_slot(0)["d"]["dur"]) < ItemDB.max_durability("spear", {"mat": "flint"}), "the spear wears")
	goat = goats[1] if goats.size() > 1 else goats[0]
	gp = _apos(goat)
	clear_inv()
	give("knife", 1, {"mat": "stone"})
	place_player(gp + Vector3(1.2, 0, 0))
	req("hit", {"eid": goat["id"], "slot": 0})
	check(World.entities.has(goat["id"]) and float(goat["d"]["hp"]) < 1.0, "a knife cut hurts a goat (%.2f)" % float(goat["d"]["hp"]))
	check(String(a.animals.mind(goat["id"])["st"]) == "flee", "and it bolts")
	for k in 5:
		if World.entities.has(goat["id"]):
			place_player(_apos(goat) + Vector3(1.2, 0, 0))
			req("hit", {"eid": goat["id"], "slot": 0})
	check(not World.entities.has(goat["id"]), "a few more and it's down")
	var meat := 0
	var hides := 0
	for e in World.entities_near(_apos(goat) if World.entities.has(goat["id"]) else gp, 12.0, "item"):
		if String(e["d"]["i"]) == "meat_raw":
			meat += int(e["d"]["n"])
		elif String(e["d"]["i"]) == "hide":
			hides += int(e["d"]["n"])
	check(meat >= 2 and hides == 1, "meat and a hide (%d, %d)" % [meat, hides])
	# a lead of twine
	var bird: Dictionary = fowl[0]
	var bp := _apos(bird)
	clear_inv()
	give("twine", 2)
	place_player(bp + Vector3(1.0, 0, 0))
	req("animal_use", {"eid": bird["id"], "slot": 0})
	check(int(bird["d"]["lead"]) == pid and count("twine") == 1, "tie a lead of twine on a junglefowl")
	var dest := bp + Vector3(5.0, 0, 0)
	dest.y = World.vox.rest_height(dest + Vector3(0, 3, 0))
	place_player(dest)
	_run_animals(6.0)
	var gap := Vector2(_apos(bird).x - dest.x, _apos(bird).z - dest.z).length()
	check(gap < 3.0, "it follows on the lead (%.1f m behind)" % gap)
	# take it across the sea on a raft
	var water := _open_water(World.geo["islands"][int(bird["d"]["isl"])], 6.0)
	if check(water != Vector3.INF, "open water off its island"):
		var cells := {}
		for z in 2:
			for x in 2:
				cells[Vector3i(x, 0, z)] = Vector2i(Blocks.id_of("raft_floor"), 0)
		var rxf := Transform3D(Basis(), Vector3(water.x - 1.0, Raft.origin_y(sea), water.z - 1.0))
		var rid := World.spawn("raft", rxf, {"cells": cells, "v": Vector3.ZERO, "w": 0.0, "anchor": false})
		# you stand on the raft; the bird swims up beside it and hops aboard
		var deck := rxf * Vector3(0.5, Raft.DECK, 0.5)
		place_player(deck)
		Net.poses[pid]["rv"] = rid
		World.move_entity(bird["id"], Transform3D(Basis(), rxf * Vector3(2.8, 0.5, 1.0)), true)
		_run_animals(0.5)
		check(int(bird["d"]["raft"]) == rid, "a led animal hops aboard your raft")
		# the raft sails away; the bird goes with it
		var far_isl := -1
		for i in (World.geo["islands"] as Array).size():
			if i != int(bird["d"]["isl"]) and String(World.geo["islands"][i]["b"]) != "home":
				far_isl = i
				break
		var beach := _find_beach(World.geo["islands"][far_isl])
		if check(beach.x >= 0, "a beach on another island"):
			var land := Vector3(beach) + Vector3(0.5, 1.0, 0.5)
			var seaward := Vector3.ZERO
			for dv in [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]:
				if World.block(beach + dv) == Blocks.sea:
					seaward = Vector3(dv)
			var rp: Vector3 = bird["d"]["rp"]
			var at := land + seaward * 1.6
			var nxf := Transform3D(Basis(), Vector3(at.x - rp.x, Raft.origin_y(sea), at.z - rp.z))
			World.move_entity(rid, nxf, true)
			place_player(nxf * Vector3(0.5, Raft.DECK, 0.5))
			Net.poses[pid]["rv"] = rid
			_run_animals(0.2)
			check(_apos(bird).distance_to(nxf * rp) < 0.3, "it rides the raft across the sea")
			# you step ashore: it jumps down after you
			place_player(land + Vector3(-seaward.x, 0, -seaward.z) * 1.0)
			Net.poses[pid]["rv"] = -1
			_run_animals(0.5)
			check(int(bird["d"]["raft"]) == -1 and not World.vox.liquid_at(_apos(bird) + Vector3(0, 0.2, 0)) and _apos(bird).y > sea + 0.5, "and jumps ashore after you")
			req("animal_use", {"eid": bird["id"], "slot": 1})
			check(int(bird["d"]["lead"]) == -1 and count("twine") == 2, "let go, you get your twine back")
			check(int(bird["d"]["isl"]) == far_isl, "and this island is its home now")
		# take the raft apart under it: it swims for home
		World.move_entity(rid, rxf, true)
		World.update(bird["id"], {"raft": rid, "rp": Vector3(0.5, Raft.DECK, 0.5), "ry": 0.0})
		World.move_entity(bird["id"], Transform3D(Basis(), rxf * Vector3(0.5, Raft.DECK, 0.5)), true)
		place_player(_apos(bird) + Vector3(0, 0, 20))
		World.despawn(rid)
		_run_animals(0.3)
		var home_v: Vector3 = bird["d"]["home"]
		var d0 := Vector2(_apos(bird).x, _apos(bird).z).distance_to(Vector2(home_v.x, home_v.z))
		check(int(bird["d"]["raft"]) == -1 and World.vox.liquid_at(_apos(bird) + Vector3(0, 0.15, 0)), "with the raft gone from under it, it's in the water")
		_run_animals(4.0)
		var d1 := Vector2(_apos(bird).x, _apos(bird).z).distance_to(Vector2(home_v.x, home_v.z))
		check(d1 < d0 - 1.0, "and swims for home (%.1f -> %.1f m)" % [d0, d1])
	# the lead slips if you go too far
	var bird2: Dictionary = fowl[1] if fowl.size() > 1 else fowl[0]
	place_player(_apos(bird2) + Vector3(1.0, 0, 0))
	clear_inv()
	give("twine", 1)
	req("animal_use", {"eid": bird2["id"], "slot": 0})
	place_player(_apos(bird2) + Vector3(30.0, 0, 0))
	_run_animals(0.3)
	check(int(bird2["d"]["lead"]) == -1, "go too far and the lead slips")
	# fed by hand two at a time, they have young
	var pair: Array = []
	for f in _animals_of("fowl"):
		if AnimalSim.grown(f["d"]) >= 1.0 and a.animals.on_raft(f) < 0:
			pair.append(f)
		if pair.size() == 2:
			break
	if check(pair.size() == 2, "two grown junglefowl"):
		var p0 := _apos(pair[0])
		World.move_entity(pair[1]["id"], Transform3D(Basis(), p0 + Vector3(1.0, 0, 0)), true)
		var n0 := _animals_of("fowl").size()
		clear_inv()
		give("berries", 4)
		place_player(p0 + Vector3(0, 0, 1.5))
		req("animal_use", {"eid": pair[0]["id"], "slot": 0})
		check(_animals_of("fowl").size() == n0 and count("berries") == 3, "it eats from your hand")
		req("animal_use", {"eid": pair[1]["id"], "slot": 0})
		var after := _animals_of("fowl")
		check(after.size() == n0 + 1, "feed a second one beside it: a chick (%d -> %d)" % [n0, after.size()])
		var chick: Dictionary = {}
		for f in after:
			if AnimalSim.grown(f["d"]) < 1.0:
				chick = f
		check(not chick.is_empty() and AnimalSim.grown(chick["d"]) < 0.1, "a young one, that grows up")
		req("animal_use", {"eid": pair[0]["id"], "slot": 0})
		req("animal_use", {"eid": pair[1]["id"], "slot": 0})
		check(_animals_of("fowl").size() == n0 + 1, "but not again straight away")
	# junglefowl lay eggs
	var eggs_before := 0
	for e in World.entities_of("item"):
		if String(e["d"]["i"]) == "egg":
			eggs_before += 1
	a.animals.tick(20.0)
	var eggs := 0
	for e in World.entities_of("item"):
		if String(e["d"]["i"]) == "egg":
			eggs += 1
	check(eggs > eggs_before, "junglefowl lay eggs (%d)" % (eggs - eggs_before))
	# a hunted-out beach fills again, while nobody is there
	var home_i := 0
	for e in _animals_of("crab"):
		if int(e["d"]["isl"]) == home_i:
			World.despawn(e["id"])
	place_player(Vector3(5, 40, 5))
	for k in 30:
		a.animals.tick(4.0)
	var back := 0
	for e in _animals_of("crab"):
		if int(e["d"]["isl"]) == home_i:
			back += 1
	check(back >= 3, "crabs come back to a hunted-out beach (%d)" % back)
	# saved and loaded: the same animals, and no second lot
	var n_animals := World.entities_of("animal").size()
	check(Game.save() == OK and World.load_world("TestIsland") == OK, "saves and loads with animals")
	World.on_player_joined(pid, Settings.player_name)
	check(World.entities_of("animal").size() == n_animals and bool(World.geo.get("fauna", false)), "the same animals (%d)" % World.entities_of("animal").size())
	a.animals.populate()
	check(World.entities_of("animal").size() == n_animals, "the islands aren't stocked twice")


func _helm_clear() -> void:
	a.rafts._helm.clear()


func _find_shore(it: Dictionary) -> Vector3i:
	## A sea-water cell at the surface right next to the island's beach.
	var c: Vector2 = it["c"]
	var sea := int(World.geo["sea"])
	for k in 64:
		var dir := Vector2.from_angle(k * TAU / 64.0)
		for s in range(int(it["r"] * 0.5), int(it["r"] * 2.0)):
			var p := Vector2i(c + dir * s)
			if World.vox.get_id(p.x, sea, p.y) == Blocks.sea:
				return Vector3i(p.x, sea, p.y)
	return Vector3i(-1, -1, -1)


func _find_beach(it: Dictionary) -> Vector3i:
	## A dry beach block at sea level with the sea beside it.
	var c: Vector2 = it["c"]
	var sea := int(World.geo["sea"])
	var r := int(float(it["r"]) * 1.3)
	for z in range(int(c.y) - r, int(c.y) + r + 1):
		for x in range(int(c.x) - r, int(c.x) + r + 1):
			var p := Vector3i(x, sea, z)
			if Blocks.is_solid(World.block(p)) and World.block(p + Vector3i.UP) == 0:
				for d in [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]:
					if World.block(p + d) == Blocks.sea:
						return p
	return Vector3i(-1, -1, -1)


func _find(nm: String) -> Vector3i:
	var id := Blocks.id_of(nm)
	for z in range(10, 54):
		for x in range(10, 54):
			var h := World.vox.column_height(x, z)
			for y in range(maxi(h - 12, 0), mini(h + 3, World.vox.sy)):
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
	# only the stone touching the outline needs chipping; the rest falls away
	var chips := 0
	var waste := 0
	var ring: Array[int] = []
	for i in 256:
		if ItemDB.stone_mask[i] == 1 and mask[i] == 0:
			waste += 1
			for o in [1, -1, 16, -16]:
				var j: int = i + o
				if j >= 0 and j < 256 and absi(j % 16 - i % 16) <= 1 and mask[j] == 1:
					ring.append(i)
					break
	check(CraftActs.edge_cells(ItemDB.stone_mask, mask) == ring.size(), "the cells to chip are the ones touching the shape (%d)" % ring.size())
	for i in ring:
		if World.be(up).is_empty():
			break
		req("knap", {"c": up, "i": i})
		chips += 1
	check(World.be(up).is_empty() and chips < waste, "after %d chips (of %d waste cells) the blade is done" % [chips, waste])
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
	var js := inv().get_slot(inv().find("jar"))
	check(World.be(up).is_empty() and count("jar") == 1 and count("berries") == 10 and int((js.get("d", {}).get("inv", [{}]) as Array)[0].get("n", 0)) == 10, "a jar picked up keeps what is in it")
	use_on(c, inv().find("jar"))
	check(not World.be(up).is_empty() and int((World.be(up)["d"]["inv"] as Array)[0].get("n", 0)) == 10, "and still has it when set down again")
	req("break", {"c": up, "slot": 0})
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
	# over the edge: the bag is left where you last stood on firm ground
	var edge := _find_edge()
	place_player(Vector3(edge) + Vector3(0.5, 1.0, 0.5))
	Net.poses[pid]["g"] = true
	a._pickup_t = 0.0
	a._physics_process(0.2)
	give("flint", 3, {}, 2)
	place_player(Vector3(edge) + Vector3(4.5, -30.0, 0.5))
	Survival.die(pid, "abyss")
	var ab := World.entities_of("satchel")
	check(ab.size() == 1 and (ab[0]["xf"] as Transform3D).origin.distance_to(Vector3(edge) + Vector3(0.5, 1.0, 0.5)) < 1.5, "falling into the abyss leaves your bag at the edge")
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
