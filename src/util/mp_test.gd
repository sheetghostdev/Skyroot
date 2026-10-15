extends Node
## Automated multiplayer check, run as separate game instances on one machine
## (see tools/mp_test.sh, mp_crowd.sh, mp_crash.sh):
##   host:    --autostart=host --world=MPTest --new --name=Host --mptest=host
##   client:  --autostart=join --name=Ana --mptest=client   (then again with --mptest=rejoin)
##   at sea:  --mptest=sea_host (with --kind=sea) and --mptest=sea_client (tools/mp_sea.sh)
## The instances talk through the game's own chat, so everything they check
## travels the same network paths as real play.  Lines start with "MPT".

const TIMEOUT := 150.0

var role := ""
var _t := 0.0
var _msgs: Array = []          # [from, text] received over chat
var passes := 0
var fails := 0


func _ready() -> void:
	role = String(Game.cli.get("mptest", ""))
	Events.chat.connect(func(from, text):
		_msgs.append([String(from), String(text)])
		if OS.has_environment("MPT_TRACE"):
			_log("%.1fs chat <- %s: %s" % [_t, from, text]))
	_run.call_deferred()


func _process(delta: float) -> void:
	_t += delta
	if _t > TIMEOUT:
		_log("FAIL timed out")
		_finish()


func _log(s: String) -> void:
	print("MPT %s: %s" % [role, s])


func check(cond: bool, what: String) -> void:
	if cond:
		passes += 1
		_log("ok   " + what)
	else:
		fails += 1
		_log("FAIL " + what)


func _finish() -> void:
	set_process(false)
	_log("RESULT %d passed, %d failed" % [passes, fails])
	await get_tree().create_timer(0.5).timeout
	Sfx.shutdown()
	Net.close()
	await get_tree().create_timer(0.3).timeout
	get_tree().quit(0 if fails == 0 else 1)


func _frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame


func _wait_msg(prefix: String, secs: float = 40.0) -> String:
	## Wait for a chat line starting with prefix; returns what follows the prefix,
	## "." when nothing does, or "" on timeout.
	var t := 0.0
	while t < secs:
		for m in _msgs:
			if String(m[1]).begins_with(prefix):
				_msgs.erase(m)
				var rest := String(m[1]).substr(prefix.length()).strip_edges()
				return rest if rest != "" else "."
		await get_tree().process_frame
		t += get_process_delta_time()
	return ""


func _wait(cond: Callable, secs: float = 20.0) -> bool:
	var t := 0.0
	while t < secs:
		if cond.call():
			return true
		await get_tree().process_frame
		t += get_process_delta_time()
	return false


func _say(text: String) -> void:
	Net.send_chat(text)


func _lp() -> LocalPlayer:
	return Game.game_world.local_player()


func _go(p: Vector3) -> void:
	## Move this machine's own player (each machine owns its movement).
	var lp := _lp()
	lp.global_position = p
	lp.velocity = Vector3.ZERO


func _run() -> void:
	if role == "fifth":
		await _fifth()
		_finish()
		return
	await _wait(func(): return World.running and Game.game_world != null and Game.game_world.local_player() != null, 30.0)
	await _frames(10)
	match role:
		"host":
			await _host()
		"client":
			await _client()
		"rejoin":
			await _rejoin()
		"crowd_host":
			await _crowd_host()
		"crowd":
			await _crowd()
		"crash_host":
			await _crash_host()
		"crash_a":
			await _crash_a()
		"crash_b":
			await _crash_b()
		"sea_host":
			await _sea_host()
		"sea_client":
			await _sea_client()
	_finish()


static func blocks_hash() -> int:
	return hash(World.vox.ids)


static func flat_spot(x: int, z: int) -> Vector3i:
	for r in range(0, 8):
		for dz in range(-r, r + 1):
			for dx in range(-r, r + 1):
				var y := World.vox.surface_y(x + dx, z + dz)
				if y < 0:
					continue
				var c := Vector3i(x + dx, y, z + dz)
				if Blocks.is_opaque(World.block(c)) and Blocks.is_replaceable(World.block(c + Vector3i.UP)) and World.block(c + Vector3i(0, 2, 0)) == 0 and not World.be_at.has(c + Vector3i.UP):
					return c
	return Vector3i(-1, -1, -1)


# ---------------------------------------------------------------------------
# Host
# ---------------------------------------------------------------------------

func _client_pid(name: String) -> int:
	for pid in Net.players:
		if Net.player_name(pid) == name:
			return pid
	return -1


func _count_everywhere(id: String) -> int:
	var n := 0
	for pid in World.inventories:
		n += World.inventories[pid].count(id)
	for e in World.entities.values():
		if e["t"] == "item" and String(e["d"].get("i", "")) == id:
			n += int(e["d"].get("n", 1))
	for nm in World.player_saves:
		if _client_pid(nm) == -1:
			for s in World.player_saves[nm].get("inv", []):
				if s is Dictionary and String(s.get("i", "")) == id:
					n += int(s["n"])
	return n


func _host() -> void:
	if Game.cli.has("open_later"):
		check(not Net.is_online(), "the island started solo")
		check(Net.open_to_friends(int(Game.cli.get("port", str(Net.DEFAULT_PORT)))) == OK, "and was opened to friends mid-session")
	_log("hosting, waiting for a player")
	var joined := await _wait(func(): return Net.players.size() >= 2, 60.0)
	check(joined, "a second player joined over the network")
	if not joined:
		return
	var cpid := _client_pid("Ana")
	check(cpid != -1, "the player is called Ana")
	var ready := await _wait_msg("READY", 40.0)
	var parts := ready.split(" ")
	check(parts.size() == 2 and int(parts[0]) == World.entities.size(), "Ana sees the same %d things on the island (%s)" % [World.entities.size(), ready])
	check(parts.size() == 2 and int(parts[1]) == blocks_hash(), "and exactly the same blocks")
	# one flint on the ground, two people walking onto it: one of them gets it
	var spot := flat_spot(30, 36)
	var at := Vector3(spot) + Vector3(0.5, 1.2, 0.5)
	World.actions.drop_item("flint", 1, {}, at)
	await _frames(5)
	_say("FLINT %.2f,%.2f,%.2f" % [at.x, at.y, at.z])
	await _wait_msg("ONIT", 30.0)
	_go(at + Vector3(0, -0.2, 0))
	await _frames(40)
	check(_count_everywhere("flint") == 1, "the flint exists exactly once after both stepped on it (%d)" % _count_everywhere("flint"))
	# Ana works: breaks loose stones, places soil, builds and lights a fire, knaps
	World.inventory_of(cpid).add("dirt", 2)
	World.inventory_of(cpid).add("stick", 4)
	World.inventory_of(cpid).add("dry_grass", 2)
	World.inventory_of(cpid).add("firestarter", 1, {"dur": 8})
	World.mark_inventory(cpid)
	_say("WORK")
	var did := await _wait_msg("DID", 60.0)
	var w := did.split(" ")
	check(w.size() >= 3, "Ana reports her work (%s)" % did)
	if w.size() >= 3:
		var placed := _cell(w[0])
		var fire := _cell(w[1])
		var knap := _cell(w[2])
		check(Blocks.name_of(World.block(placed)) == "dirt", "the soil Ana placed is on the host's island")
		var fb := World.be(fire)
		check(not fb.is_empty() and fb["t"] == "firepit" and bool(fb["d"]["lit"]), "her fire pit is burning on the host")
		check(not fb.is_empty() and int(fb["d"]["sticks"]) >= 3, "with the sticks she laid (%d)" % (int(fb["d"]["sticks"]) if not fb.is_empty() else 0))
		check(World.be(knap).is_empty() and World.inventory_of(cpid).count("knife_blade") == 1, "she knapped a knife blade")
		var view = Game.game_world.entities.view(int(fb.get("id", -1)))
		check(view != null, "and the host's world shows the fire")
	check(World.inventory_of(cpid).count("stone") >= 1, "Ana carries the stones she picked up (%d)" % World.inventory_of(cpid).count("stone"))
	_say("FINE")
	var bye := await _wait_msg("BYE", 30.0)
	check(bye != "", "Ana says goodbye")
	var gone := await _wait(func(): return _client_pid("Ana") == -1, 20.0)
	check(gone, "Ana disconnected")
	await _frames(5)
	check(World.player_saves.has("Ana"), "the host kept Ana's belongings while she's away")
	var stones := 0
	var blades := 0
	for s in World.player_saves.get("Ana", {}).get("inv", []):
		if s is Dictionary and String(s.get("i", "")) == "stone":
			stones += int(s["n"])
		if s is Dictionary and String(s.get("i", "")) == "knife_blade":
			blades += 1
	check(stones >= 1 and blades == 1, "including her stones and her blade")
	var back := await _wait(func(): return _client_pid("Ana") != -1, 60.0)
	check(back, "Ana came back")
	var inv_said := await _wait_msg("BACK", 30.0)
	check(inv_said == "stone=%d blade=1" % stones, "she has exactly what she left with (%s)" % inv_said)
	check(_count_everywhere("flint") == 1, "and still exactly one flint on the island")
	check(Game.save() == OK, "the host saves the island")
	_say("DONE")
	await _frames(30)
	World.delete_save(World.world_name)
	await _frames(30)


func _cell(s: String) -> Vector3i:
	var p := s.split(",")
	return Vector3i(int(p[0]), int(p[1]), int(p[2])) if p.size() == 3 else Vector3i(-1, -1, -1)


# ---------------------------------------------------------------------------
# Client
# ---------------------------------------------------------------------------

func _client() -> void:
	_log("joined as %s (peer %d)" % [Settings.player_name, Net.my_id()])
	await _frames(20)
	_say("READY %d %d" % [World.entities.size(), blocks_hash()])
	var f := await _wait_msg("FLINT", 30.0)
	var fp := f.split(",")
	if fp.size() == 3:
		_go(Vector3(float(fp[0]), float(fp[1]) - 0.2, float(fp[2])))
	_say("ONIT")
	await _frames(40)
	_log("I hold %d flint" % World.my_inventory.count("flint"))
	await _wait_msg("WORK", 30.0)
	await _wait(func(): return World.my_inventory.count("firestarter") > 0, 10.0)
	check(World.my_inventory.count("firestarter") == 1, "the host's gifts arrived")
	var lp := _lp()
	# pick up loose stones: break them and walk over what drops
	var got := 0
	for z in range(10, 56):
		for x in range(10, 56):
			if got >= 2:
				break
			var y := World.vox.surface_y(x, z)
			var c := Vector3i(x, y + 1, z)
			if y >= 0 and Blocks.name_of(World.block(c)) == "loose_stones":
				_go(Vector3(c) + Vector3(1.5, 0.0, 0.5))
				await _frames(10)
				World.request("break", {"c": c, "slot": 0})
				await _frames(15)
				_go(Vector3(c) + Vector3(0.5, 0.0, 0.5))
				await _frames(25)
				if World.my_inventory.count("stone") > got:
					got = World.my_inventory.count("stone")
	check(got >= 1, "broke loose stones and picked them up through the host (%d)" % got)
	# place soil
	var spot := flat_spot(24, 32)
	_go(Vector3(spot) + Vector3(-1.5, 1.0, 0.5))
	await _frames(10)
	var placed := spot + Vector3i.UP
	World.request("place", {"c": placed, "slot": World.my_inventory.find("dirt"), "face": Vector3i.UP})
	await _wait(func(): return Blocks.name_of(World.block(placed)) == "dirt", 5.0)
	check(Blocks.name_of(World.block(placed)) == "dirt", "placed soil, and see it placed")
	# a fire pit: a stick on the ground, more sticks, tinder, the bow drill
	var fs := flat_spot(28, 40)
	var up := fs + Vector3i.UP
	_go(Vector3(fs) + Vector3(1.6, 1.0, 0.5))
	await _frames(10)
	var sticks := World.my_inventory.find("stick")
	World.request("use", {"c": fs, "face": Vector3i.UP, "slot": sticks, "sneak": true})
	await _wait(func(): return not World.be(up).is_empty(), 5.0)
	for i in 2:
		await _frames(8)
		World.request("use", {"c": up, "face": Vector3i.UP, "slot": World.my_inventory.find("stick"), "sneak": false})
	await _frames(8)
	World.request("use", {"c": up, "face": Vector3i.UP, "slot": World.my_inventory.find("dry_grass"), "sneak": false})
	await _frames(8)
	World.request("ignite", {"c": up, "slot": World.my_inventory.find("firestarter")})
	await _wait(func(): return not World.be(up).is_empty() and bool(World.be(up)["d"]["lit"]), 5.0)
	check(not World.be(up).is_empty() and bool(World.be(up)["d"]["lit"]), "my fire pit is lit")
	var view = Game.game_world.entities.view(int(World.be(up).get("id", -1)))
	check(view != null, "and I can see it")
	# knap a knife blade from one of the stones
	var ks := flat_spot(34, 34)
	var kc := ks + Vector3i.UP
	_go(Vector3(ks) + Vector3(1.6, 1.0, 0.5))
	await _frames(10)
	World.request("use", {"c": ks, "face": Vector3i.UP, "slot": World.my_inventory.find("stone"), "sneak": true})
	await _wait(func(): return not World.be(kc).is_empty(), 5.0)
	World.request("knap_choose", {"c": kc, "r": "knife_blade"})
	await _wait(func(): return not World.be(kc).is_empty() and String(World.be(kc)["d"]["r"]) == "knife_blade", 5.0)
	var mask: PackedByteArray = ItemDB.knapping["knife_blade"]["mask"]
	for i in 256:
		if ItemDB.stone_mask[i] == 1 and mask[i] == 0:
			World.request("knap", {"c": kc, "i": i})
			await get_tree().create_timer(0.07).timeout
	await _wait(func(): return World.my_inventory.count("knife_blade") == 1, 10.0)
	check(World.my_inventory.count("knife_blade") == 1, "knapped a knife blade")
	_say("DID %d,%d,%d %d,%d,%d %d,%d,%d" % [placed.x, placed.y, placed.z, up.x, up.y, up.z, kc.x, kc.y, kc.z])
	var fine := await _wait_msg("FINE", 30.0)
	check(fine != "", "the host has seen enough")
	_say("BYE")
	await _frames(10)


func _rejoin() -> void:
	_log("back as %s" % Settings.player_name)
	await _frames(30)
	var inv := World.my_inventory
	check(inv.count("stone") >= 1, "my stones were waiting for me")
	_say("BACK stone=%d blade=%d" % [inv.count("stone"), inv.count("knife_blade")])
	var done := await _wait_msg("DONE", 60.0)
	check(done != "", "the host finished")


# ---------------------------------------------------------------------------
# Four on one island (tools/mp_crowd.sh)
# ---------------------------------------------------------------------------

func _crowd_host() -> void:
	var full := await _wait(func(): return Net.players.size() >= 4, 90.0)
	check(full, "four players on the island (%d)" % Net.players.size())
	var spot := flat_spot(38, 41)
	# the host stands well away from the pile (so only the visitors can grab it)
	var away := flat_spot(20, 26)
	_go(Vector3(away) + Vector3(0.5, 1.05, 0.5))
	await _frames(10)
	var at := Vector3(spot) + Vector3(0.5, 1.2, 0.5)
	for i in 3:
		World.actions.drop_item("flint", 1, {}, at)
	var loose := flat_spot(34, 30) + Vector3i.UP
	World.set_block(loose, Blocks.id_of("loose_flint"))
	await _frames(20)
	_say("GRAB %.2f,%.2f,%.2f %d,%d,%d" % [at.x, at.y, at.z, loose.x, loose.y, loose.z])
	var counts: Dictionary = {}
	var t := 0.0
	while counts.size() < 3 and t < 40.0:
		for m in _msgs.duplicate():
			if String(m[1]).begins_with("HAVE "):
				counts[String(m[0])] = int(String(m[1]).substr(5))
				_msgs.erase(m)
		await get_tree().process_frame
		t += get_process_delta_time()
	check(counts.size() == 3, "all three visitors reported back (%s)" % str(counts))
	await _frames(10)
	var held := 0
	for pid in World.inventories:
		held += World.inventories[pid].count("flint")
	var said := 0
	for k in counts:
		said += int(counts[k])
	check(held == 4 and _count_everywhere("flint") == 4, "three flints on the ground and one nodule broken by three people at once make exactly four flints (%d carried)" % held)
	check(said == held, "and each visitor's own view agrees with the host (%d)" % said)
	await get_tree().create_timer(22.0).timeout
	check(Net.players.size() == 4, "a fifth player was turned away; still four here")
	_say("DONE")
	await _frames(30)
	World.delete_save(World.world_name)
	await _frames(30)


func _crowd() -> void:
	var g := await _wait_msg("GRAB", 60.0)
	var parts := g.split(" ")
	if parts.size() == 2:
		var p := parts[0].split(",")
		var at := Vector3(float(p[0]), float(p[1]) - 0.2, float(p[2]))
		var lc := _cell(parts[1])
		# everybody breaks the same nodule at the same moment, then runs for the pile
		_go(Vector3(lc) + Vector3(1.5, 0.0, 0.5))
		await _frames(6)
		World.request("break", {"c": lc, "slot": 0})
		await _frames(10)
		_go(Vector3(lc) + Vector3(0.5, 0.0, 0.5))
		await _frames(20)
		_go(at)
	await _frames(60)
	var n := World.my_inventory.count("flint")
	_log("I got %d flint" % n)
	_say("HAVE %d" % n)
	var done := await _wait_msg("DONE", 90.0)
	check(done != "", "the host wrapped up")


func _fifth() -> void:
	## A fifth player knocks: the island is full.
	var reason: Array = []
	Net.join_failed.connect(func(r): reason.append(r))
	await _wait(func(): return not reason.is_empty(), 30.0)
	check(not reason.is_empty() and String(reason[0]).contains("full"), "the fifth player is told the island is full (%s)" % (reason[0] if not reason.is_empty() else "no answer"))


# ---------------------------------------------------------------------------
# A client's game crashes and they come straight back (tools/mp_crash.sh)
# ---------------------------------------------------------------------------

func _crash_host() -> void:
	var joined := await _wait(func(): return _client_pid("Ana") != -1, 60.0)
	check(joined, "Ana joined")
	var cpid := _client_pid("Ana")
	await _wait_msg("READY", 30.0)
	World.inventory_of(cpid).add("stone", 3)
	World.mark_inventory(cpid)
	_say("GIFT")
	await _wait_msg("GOT", 30.0)
	var back := await _wait_msg("BACK", 60.0)
	var parts := back.split(" ")
	check(parts.size() >= 2 and parts[0] == "Ana" and parts[parts.size() - 1] == "3", "after a crash Ana comes back as Ana with her 3 stones (%s)" % back)
	check(not Net.players.has(cpid), "her crashed connection was let go at once")
	var anas := 0
	for pid in Net.players:
		if Net.player_name(pid).begins_with("Ana"):
			anas += 1
	check(anas == 1, "and there is only one of her on the island")
	_say("DONE")
	await _frames(30)
	World.delete_save(World.world_name)


func _crash_a() -> void:
	await _frames(20)
	_say("READY")
	await _wait_msg("GIFT", 30.0)
	await _wait(func(): return World.my_inventory.count("stone") >= 3, 10.0)
	_say("GOT")
	_log("holding %d stones, waiting to be killed" % World.my_inventory.count("stone"))
	await get_tree().create_timer(300.0).timeout


func _crash_b() -> void:
	await _frames(30)
	_say("BACK %s %d" % [Net.player_name(Net.my_id()), World.my_inventory.count("stone")])
	var done := await _wait_msg("DONE", 90.0)
	check(done != "", "the host is satisfied")


# ---------------------------------------------------------------------------
# At sea: a raft carries a friend, a paddle stroke moves it, an animal on a lead
# ---------------------------------------------------------------------------

func _sea_host() -> void:
	_log("hosting an archipelago")
	var joined := await _wait(func(): return Net.players.size() >= 2, 60.0)
	check(joined, "a second player joined the archipelago")
	if not joined:
		return
	var cpid := _client_pid("Ana")
	var ready := await _wait_msg("READY", 60.0)
	var parts := ready.split(" ")
	check(parts.size() == 3 and int(parts[1]) == blocks_hash(), "Ana has the same 512 x 512 sea of blocks")
	check(parts.size() == 3 and int(parts[2]) == World.entities_of("animal").size(), "and the same %d animals" % World.entities_of("animal").size())
	# a raft off the shore, with a sail
	var lp := _lp()
	var w := DebugShot.sea_spot(lp.global_position, 4.0)
	var sea := int(World.geo["sea"])
	var cells := {}
	for z in 3:
		for x in 3:
			cells[Vector3i(x, 0, z)] = Vector2i(Blocks.id_of("raft_floor"), 0)
	cells[Vector3i(1, 1, 0)] = Vector2i(Blocks.id_of("raft_sail"), 0)
	var rxf := Transform3D(Basis(), Vector3(w.x - 1.5, Raft.origin_y(sea), w.z - 1.5))
	var rid := World.spawn("raft", rxf, {"cells": cells, "v": Vector3.ZERO, "w": 0.0, "anchor": false})
	World.inventory_of(cpid).add("paddle", 1, {"dur": 400})
	World.inventory_of(cpid).add("twine", 1)
	World.mark_inventory(cpid)
	_say("RAFT %d" % rid)
	await _wait_msg("ABOARD", 30.0)
	await _frames(20)
	var pose: Dictionary = Net.poses.get(cpid, {})
	check(int(pose.get("rv", -1)) == rid, "Ana stands on the raft (her pose says so)")
	# under way: the raft carries her
	World.get_entity(rid)["d"]["v"] = Vector3(1.5, 0, 0.5)
	_say("SAILING")
	await _wait_msg("CARRIED", 40.0)
	var moved := (World.get_entity(rid)["xf"] as Transform3D).origin.distance_to(rxf.origin)
	check(moved > 2.0, "the raft moved %.1f m with her on it" % moved)
	World.get_entity(rid)["d"]["v"] = Vector3.ZERO
	World.get_entity(rid)["d"]["w"] = 0.0
	_say("STILL")
	await _wait_msg("PADDLED", 30.0)
	var v: Vector3 = World.get_entity(rid)["d"].get("v", Vector3.ZERO)
	check(v.length() > 0.05, "her paddle stroke moved the raft (%.2f m/s)" % v.length())
	World.get_entity(rid)["d"]["v"] = Vector3.ZERO
	# a goat brought to her
	var goats := World.entities_of("animal").filter(func(e): return String(e["d"]["s"]) == "goat")
	check(not goats.is_empty(), "there are goats")
	if goats.is_empty():
		return
	var goat: Dictionary = goats[0]
	var land := DebugShot.land_near(lp.global_position)
	World.move_entity(goat["id"], Transform3D(Basis(), land), true)
	World.update(goat["id"], {"home": land})
	_say("GOAT %d %.2f,%.2f,%.2f" % [goat["id"], land.x, land.y, land.z])
	await _wait_msg("LEADING", 30.0)
	await _frames(10)
	check(int(goat["d"].get("lead", -1)) == cpid, "Ana has the goat on a lead (host)")
	_say("DONE")
	await _wait_msg("BYE", 30.0)
	World.delete_save(World.world_name)


func _sea_client() -> void:
	_log("joined the archipelago as %s" % Settings.player_name)
	await _frames(30)
	check(World.kind == "sea" and World.vox.sx == ArchipelagoGen.W, "the archipelago came over the network")
	_say("READY %d %d %d" % [World.entities.size(), blocks_hash(), World.entities_of("animal").size()])
	check(AnimalView.all().size() == World.entities_of("animal").size(), "every animal is drawn (%d)" % AnimalView.all().size())
	var r := await _wait_msg("RAFT", 30.0)
	var rid := int(r)
	await _wait(func(): return RaftView.find(rid) != null, 10.0)
	var rv := RaftView.find(rid)
	check(rv != null and rv.cells().size() == 10, "I see the raft, sail and all")
	if rv == null:
		return
	var lp := _lp()
	_go(rv.view_xf() * Vector3(1.5, Raft.DECK + 0.3, 1.5))
	await _wait(func(): return lp.riding == rid, 10.0)
	check(lp.riding == rid, "standing on its deck, I ride it")
	_say("ABOARD")
	await _wait_msg("SAILING", 30.0)
	var local0 := rv.view_xf().affine_inverse() * lp.global_position
	var start := rv.view_xf().origin
	await _wait(func(): return rv.view_xf().origin.distance_to(start) > 3.0, 20.0)
	await _frames(10)
	var local1 := rv.view_xf().affine_inverse() * lp.global_position
	check(rv.view_xf().origin.distance_to(start) > 3.0, "the raft sails on my screen")
	check(lp.riding == rid and local0.distance_to(local1) < 0.3, "and carries me (moved %.2f m on its deck)" % local0.distance_to(local1))
	_say("CARRIED")
	await _wait_msg("STILL", 30.0)
	await _frames(10)
	World.request("paddle", {"eid": rid, "slot": World.my_inventory.find("paddle"), "dir": Vector3(0, 0, -1)})
	await _frames(10)
	_say("PADDLED")
	var g := await _wait_msg("GOAT", 30.0)
	var gparts := g.split(" ")
	var gid := int(gparts[0])
	var gpos := gparts[1].split(",")
	var gat := Vector3(float(gpos[0]), float(gpos[1]), float(gpos[2]))
	_go(gat + Vector3(1.2, 0.2, 0))
	await _frames(30)
	World.request("animal_use", {"eid": gid, "slot": World.my_inventory.find("twine")})
	var tied := await _wait(func(): return int(World.get_entity(gid).get("d", {}).get("lead", -1)) == Net.my_id(), 10.0)
	check(tied, "I tied a lead on the goat")
	var av := AnimalView.find(gid)
	check(av != null, "and see it")
	_say("LEADING")
	await _wait_msg("DONE", 30.0)
	_say("BYE")
	await _frames(10)
