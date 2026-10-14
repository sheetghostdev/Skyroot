extends Node
## Automated multiplayer check, run as separate game instances on one machine
## (see tools/mp_test.sh):
##   host:    --autostart=host --world=MPTest --new --name=Host --mptest=host
##   client:  --autostart=join --name=Ana --mptest=client   (then again with --mptest=rejoin)
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
	_finish()


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
		# started alone: open the running island to friends, as the pause menu does
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
	check(ready != "", "Ana's world loaded")
	check(ready == str(World.entities.size()), "Ana sees the same %d things on the island as the host (%s)" % [World.entities.size(), ready])
	# one charcoal piece, three hands: whoever's request arrives first gets it; nobody gets a copy
	var lp: LocalPlayer = Game.game_world.local_player()
	var spot := lp.global_position + Vector3(0.6, 0, 0.6)
	var piece: int = World.actions.spawn_item("charcoal", 1, {}, spot + Vector3(0, 0.3, 0))
	var L0 := Ledger.compute()
	_say("ITEM %d" % piece)
	var picked := await _wait_msg("PICKED", 30.0)
	World.request("pickup", {"eid": piece, "eye": lp.eye_position()})
	await _frames(10)
	check(_count_everywhere("charcoal") == 1, "the charcoal piece exists exactly once after both grabbed it (%d)" % _count_everywhere("charcoal"))
	check(not World.has_entity(piece), "and it is no longer on the ground")
	# Ana walks to the outcrop and takes a stone
	var stone_said := await _wait_msg("STONE", 40.0)
	await _frames(10)
	check(World.inventory_of(cpid).count("stone") >= 1, "the host gave Ana the stone she asked for (%s)" % stone_said)
	var pose: Dictionary = Net.poses.get(cpid, {})
	var at := String(stone_said).split(",")
	if at.size() == 3 and pose.has("p"):
		var claimed := Vector3(float(at[0]), float(at[1]), float(at[2]))
		check((pose["p"] as Vector3).distance_to(claimed) < 1.0, "Ana's movement reached the host (%.2f m off)" % (pose["p"] as Vector3).distance_to(claimed))
	# Ana shapes a pot; the host watches it take shape
	World.inventory_of(cpid).add("clay_prepared", 1)
	World.mark_inventory(cpid)
	_say("CLAY")
	var shaped := await _wait_msg("SHAPED", 40.0)
	var work := {}
	for e in World.entities.values():
		if e["t"] == "work" and int(e["d"].get("by", -1)) == cpid:
			work = e
	check(not work.is_empty(), "Ana's pottery workpiece exists on the host")
	if not work.is_empty():
		var st := Pottery.stats(work["d"]["pot"])
		check(bool(st["hollow"]), "the host sees her lump become a hollow vessel (capacity %.2f L, Ana says %s)" % [float(st["capacity_l"]), shaped])
		var view: Node = Game.game_world.entities.view(int(work["id"]))
		check(view != null, "and the host's world shows it")
	_say("FINE")
	var bye := await _wait_msg("BYE", 30.0)
	check(bye != "", "Ana says goodbye")
	var gone := await _wait(func(): return _client_pid("Ana") == -1, 20.0)
	check(gone, "Ana disconnected")
	await _frames(5)
	check(World.player_saves.has("Ana"), "the host kept Ana's belongings while she's away")
	var rec_inv: Array = World.player_saves.get("Ana", {}).get("inv", [])
	var stones := 0
	for s in rec_inv:
		if s is Dictionary and String(s.get("i", "")) == "stone":
			stones += int(s["n"])
	check(stones >= 1, "including her stone")
	var back := await _wait(func(): return _client_pid("Ana") != -1, 60.0)
	check(back, "Ana came back")
	var inv_said := await _wait_msg("BACK", 30.0)
	check(inv_said != "", "Ana reports her things: %s" % inv_said)
	await _frames(10)
	var cpid2 := _client_pid("Ana")
	check(World.inventory_of(cpid2).count("stone") == stones, "she has exactly the stones she left with")
	check(_count_everywhere("charcoal") == 1, "and still exactly one charcoal piece on the island")
	# nothing was created or destroyed by all that coming and going (the host's clay gift aside)
	var L1 := Ledger.compute()
	var clay_gift := Ledger.item_contrib("clay_prepared", 1, {})
	for k in Ledger.KEYS:
		var diff := float(L1[k]) - float(clay_gift[k]) - float(L0[k])
		check(absf(diff) < (0.01 if k == "water" else 0.0005), "the island's %s balances (%+.5f)" % [k, diff])
	check(Game.save() == OK, "the host saves the island")
	_say("DONE")
	await _frames(30)
	World.delete_save(World.world_name)   # a test island shouldn't linger in the list
	await _frames(30)


# ---------------------------------------------------------------------------
# Client
# ---------------------------------------------------------------------------

func _client() -> void:
	_log("joined as %s (peer %d)" % [Settings.player_name, Net.my_id()])
	await _frames(20)
	_say("READY %d" % World.entities.size())
	var lp: LocalPlayer = Game.game_world.local_player()
	var item := await _wait_msg("ITEM", 30.0)
	check(item != "", "the host told us about a charcoal piece")
	var eid := int(item)
	await _wait(func(): return World.has_entity(eid), 10.0)
	check(World.has_entity(eid), "the charcoal piece the host dropped appeared here too")
	if World.has_entity(eid):
		var p: Vector3 = World.get_entity(eid)["xf"].origin
		lp.global_position = p + Vector3(0.0, 0.1, 0.9)
		lp.velocity = Vector3.ZERO
		await _frames(20)
		for i in 3:
			World.request("pickup", {"eid": eid, "eye": lp.eye_position()})
	_say("PICKED")
	await _frames(30)
	var mine := World.my_inventory.count("charcoal")
	_log("I hold %d charcoal" % mine)
	# walk to the outcrop and take a loose stone
	var outcrop := {}
	for e in World.entities.values():
		if e["t"] == "outcrop":
			outcrop = e
	var got := false
	if not outcrop.is_empty():
		var loose: Array = outcrop["d"].get("loose", [])
		var idx := -1
		for i in loose.size():
			if int(loose[i]) > 0:
				idx = i
				break
		var v: Node = Game.game_world.entities.view(int(outcrop["id"]))
		if idx >= 0 and v:
			var at: Vector3 = v.interaction_point("loose:%d" % idx)
			var away := Vector3(at.x - outcrop["xf"].origin.x, 0, at.z - outcrop["xf"].origin.z).normalized()
			var stand := at + away * 1.0
			stand.y = World.terrain.height(stand.x, stand.z) + 0.05
			lp.global_position = stand
			lp.velocity = Vector3.ZERO
			await _frames(30)
			for i in 4:
				World.request("outcrop_take", {"eid": int(outcrop["id"]), "idx": idx, "eye": lp.eye_position()})
				await _frames(15)
				if World.my_inventory.count("stone") > 0:
					got = true
					break
	check(got, "took a stone from the outcrop through the host")
	var p2 := lp.global_position
	_say("STONE %.2f,%.2f,%.2f" % [p2.x, p2.y, p2.z])
	# shape a pot on the ground; the host should see it
	var clay := await _wait_msg("CLAY", 30.0)
	await _wait(func(): return World.my_inventory.count("clay_prepared") > 0, 10.0)
	check(World.my_inventory.count("clay_prepared") > 0, "the host's gift of clay arrived")
	var spot := lp.global_position + Vector3(0.6, 0, -0.6)
	spot.y = World.terrain.height(spot.x, spot.z)
	World.request("work_start", {"kind": "pottery", "surface": -1, "pos": spot, "slot": World.my_inventory.find("clay_prepared"), "eye": lp.eye_position()})
	var found: Array = []   # (a lambda can't reassign an outer variable, but it can fill an array)
	await _wait(func():
		for e in World.entities.values():
			if e["t"] == "work" and int(e["d"].get("by", -1)) == Net.my_id():
				found.append(e)
				return true
		return false, 10.0)
	var work: Dictionary = found[0] if not found.is_empty() else {}
	check(not work.is_empty(), "my pottery workpiece appeared")
	if not work.is_empty():
		var wid := int(work["id"])
		for i in 8:
			World.request("work_op", {"eid": wid, "op": ["hollow", 0.1 * (i + 1), 0.25 + 0.06 * i, 0.0], "eye": lp.eye_position()})
		await _frames(20)
		var st := Pottery.stats(World.get_entity(wid)["d"]["pot"])
		_say("SHAPED %.2f" % float(st["capacity_l"]))
	var fine := await _wait_msg("FINE", 30.0)
	check(fine != "", "the host has seen enough")
	_say("BYE")
	await _frames(10)


func _rejoin() -> void:
	_log("back as %s" % Settings.player_name)
	await _frames(30)
	var inv := World.my_inventory
	check(inv.count("stone") >= 1, "my stone was waiting for me")
	_say("BACK stone=%d charcoal=%d" % [inv.count("stone"), inv.count("charcoal")])
	var done := await _wait_msg("DONE", 60.0)
	check(done != "", "the host finished")


# ---------------------------------------------------------------------------
# Four on one island (tools/mp_crowd.sh)
# ---------------------------------------------------------------------------

func _crowd_host() -> void:
	var full := await _wait(func(): return Net.players.size() >= 4, 90.0)
	check(full, "four players on the island (%d)" % Net.players.size())
	var outcrop := {}
	for e in World.entities.values():
		if e["t"] == "outcrop":
			outcrop = e
	var loose0 := 0
	for v in outcrop["d"].get("loose", []):
		loose0 += int(v)
	await _frames(20)
	_say("GRAB")
	# everyone grabs at once; then count
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
	var loose1 := 0
	for v in World.get_entity(int(outcrop["id"]))["d"].get("loose", []):
		loose1 += int(v)
	var held := 0
	for pid in World.inventories:
		held += World.inventories[pid].count("stone")
	var said := 0
	for k in counts:
		said += int(counts[k])
	check(loose0 - loose1 == held, "every stone that left the outcrop is in exactly one pack (%d taken, %d carried)" % [loose0 - loose1, held])
	check(said == held, "and each visitor's own view agrees with the host (%d)" % said)
	# meanwhile a fifth player knocks (tools/mp_crowd.sh); give them time to be turned away
	await get_tree().create_timer(22.0).timeout
	check(Net.players.size() == 4, "a fifth player was turned away; still four here")
	_say("DONE")
	await _frames(30)
	World.delete_save(World.world_name)
	await _frames(30)


func _crowd() -> void:
	await _wait_msg("GRAB", 60.0)
	var lp: LocalPlayer = Game.game_world.local_player()
	var outcrop := {}
	for e in World.entities.values():
		if e["t"] == "outcrop":
			outcrop = e
	var v: Node = Game.game_world.entities.view(int(outcrop["id"]))
	var loose: Array = outcrop["d"].get("loose", [])
	# everybody goes for the same first stones at the same moment
	for idx in mini(3, loose.size()):
		var at: Vector3 = v.interaction_point("loose:%d" % idx)
		var away := Vector3(at.x - outcrop["xf"].origin.x, 0, at.z - outcrop["xf"].origin.z).normalized()
		var stand := at + away * 1.0
		stand.y = World.terrain.height(stand.x, stand.z) + 0.05
		lp.global_position = stand
		lp.velocity = Vector3.ZERO
		await _frames(3)
		World.request("outcrop_take", {"eid": int(outcrop["id"]), "idx": idx, "eye": lp.eye_position()})
	await _frames(60)
	var n := World.my_inventory.count("stone")
	_log("I got %d stones" % n)
	_say("HAVE %d" % n)
	var done := await _wait_msg("DONE", 90.0)
	check(done != "", "the host wrapped up")


func _fifth() -> void:
	## A fifth player knocks: the island is full.
	var reason: Array = []
	Net.join_failed.connect(func(r): reason.append(r))
	await _wait(func(): return not reason.is_empty(), 30.0)
	check(not reason.is_empty() and String(reason[0]).contains("full"), "the fifth player is told the island is full (%s)" % (reason[0] if not reason.is_empty() else "no answer"))
