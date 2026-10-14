extends Node
## QA scratch: scripted host/client instances (pattern copied from src/util/mp_test.gd).
##   host:   --autostart=host --world=QAMP --new --name=Host --port=N --qamp=host
##   client: --autostart=join --ip=127.0.0.1 --port=N --name=Ana --qamp=client

const TIMEOUT := 120.0

var role := ""
var _t := 0.0
var _msgs: Array = []
var passes := 0
var fails := 0


func _ready() -> void:
	role = String(Game.cli.get("qamp", ""))
	if role == "":
		return
	Events.chat.connect(func(from, text): _msgs.append([String(from), String(text)]))
	Events.toast.connect(func(t, k): _log("[toast] " + String(t)))
	_run.call_deferred()


func _process(delta: float) -> void:
	if role == "":
		return
	_t += delta
	if _t > TIMEOUT:
		_log("FAIL timed out")
		_finish()


func _log(s: String) -> void:
	print("QAMP %s: %s" % [role, s])


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
	if Net.is_host() and World.has_method("delete_save"):
		World.delete_save(World.world_name)
	await get_tree().create_timer(0.5).timeout
	Sfx.shutdown()
	Net.close()
	await get_tree().create_timer(0.3).timeout
	get_tree().quit(0 if fails == 0 else 1)


func _frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame


func _wait_msg(prefix: String, secs: float = 40.0) -> String:
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


func _client_pid(name: String) -> int:
	for pid in Net.players:
		if Net.player_name(pid) == name:
			return pid
	return -1


func _run() -> void:
	await _wait(func(): return World.running and Game.game_world != null and Game.game_world.local_player() != null, 30.0)
	await _frames(10)
	match role:
		"host":
			await _host()
		"client":
			await _client()
		"crash_host":
			await _crash_host()
		"crash_a":
			await _crash_a()
		"crash_b":
			await _crash_b()
	_finish()


# ---------------------------------------------------------------------------

func _host() -> void:
	var joined := await _wait(func(): return Net.players.size() >= 2, 60.0)
	check(joined, "a client joined")
	if not joined:
		return
	var cpid := _client_pid("Ana")
	await _wait_msg("READY", 30.0)
	World.inventory_of(cpid).add("stone", 2)
	World.inventory_of(cpid).add("blade", 1, {"seed": 5, "cuts": [], "q": 0.8, "stone_kg": 0.3, "dur": 1.0})
	World.mark_inventory(cpid)
	_say("STONES")
	var done := await _wait_msg("DONE", 60.0)
	check(done != "", "the client finished")
	await _frames(20)


func _client() -> void:
	_log("joined as %s (peer %d)" % [Net.player_name(Net.my_id()), Net.my_id()])
	await _frames(20)
	_say("READY")
	await _wait_msg("STONES", 30.0)
	await _wait(func(): return World.my_inventory.count("stone") >= 2, 10.0)
	var lp: LocalPlayer = Game.game_world.local_player()
	var cc: CraftController = Game.game_world.crafting
	# --- 1. starting a craft on a client: does the close-up open? ---
	var fs := {}
	for e in World.entities.values():
		if e["t"] == "flat_stone":
			fs = e
	var v: Node = Game.game_world.entities.view(int(fs["id"]))
	var top := Vector3(fs["xf"].origin.x, v.work_top(), fs["xf"].origin.z)
	var stand := top + Vector3(0, 0, 0.8)
	stand.y = World.terrain.height(stand.x, stand.z) + 0.05
	lp.global_position = stand
	lp.velocity = Vector3.ZERO
	await _frames(30)
	var slot := World.my_inventory.find("stone")
	World.request("work_start", {"kind": "knap", "surface": int(fs["id"]), "pos": top + Vector3(-0.1, 0, 0), "slot": slot, "eye": lp.eye_position()})
	var appeared := await _wait(func():
		for e in World.entities.values():
			if e["t"] == "work" and int(e["d"].get("by", 0)) == Net.my_id():
				return true
		return false, 5.0)
	check(appeared, "my knapping workpiece appeared on the anvil")
	await _frames(60)
	check(cc.is_open() and lp.mode == "craft", "the knapping close-up opened after work_start (open=%s, mode=%s)" % [cc.is_open(), lp.mode])
	var wid := -1
	for e in World.entities.values():
		if e["t"] == "work" and int(e["d"].get("by", 0)) == Net.my_id():
			wid = int(e["id"])
	if not cc.is_open() and wid != -1:
		World.request("work_open", {"eid": wid, "eye": lp.eye_position()})
		await _frames(60)
		_log("after pressing E again (work_open): open=%s, mode=%s" % [cc.is_open(), lp.mode])
	if cc.is_open():
		cc.close(true)
		await _frames(30)
	# --- 2. cutting a branch: does the tree shake on this machine too? ---
	var tree := {}
	for e in World.entities.values():
		if e["t"] == "tree":
			tree = e
	var tv: Node = Game.game_world.entities.view(int(tree["id"]))
	var si := -1
	for i in TreeSim.SMALL:
		if float(tree["d"]["sb"][i]) >= 0.98:
			si = i
			break
	if si != -1 and tv:
		var tip: Vector3 = tv.interaction_point("sb:%d" % si)
		var o: Vector3 = tree["xf"].origin
		var foot := Vector3(tip.x, 0, tip.z) + (Vector3(tip.x, 0, tip.z) - Vector3(o.x, 0, o.z)).normalized() * 0.4
		foot.y = World.terrain.height(foot.x, foot.z) + 0.05
		lp.global_position = foot
		lp.velocity = Vector3.ZERO
		await _frames(30)
		var shp0 := float(World.get_entity(int(tree["id"]))["d"]["shp"][si])
		var max_shake := 0.0
		World.request("tree_cut", {"eid": int(tree["id"]), "part": "sb:%d" % si, "slot": World.my_inventory.find("blade"), "eye": lp.eye_position()})
		for f in 30:
			await get_tree().physics_frame
			max_shake = maxf(max_shake, float(tv.get("_shake")))
		var shp1 := float(World.get_entity(int(tree["id"]))["d"]["shp"][si])
		_log("branch toughness %.2f -> %.2f after my cut" % [shp0, shp1])
		check(shp1 < shp0, "my cut reached the host")
		check(max_shake > 0.0, "the tree shook on my screen when I cut it (shake %.2f)" % max_shake)
	_say("DONE")
	await _frames(20)


# ---------------------------------------------------------------------------
# A client crashes and comes straight back under the same name
# ---------------------------------------------------------------------------

func _crash_host() -> void:
	var joined := await _wait(func(): return _client_pid("Ana") != -1, 60.0)
	check(joined, "Ana joined")
	var cpid := _client_pid("Ana")
	await _wait_msg("READY", 30.0)
	World.inventory_of(cpid).add("stone", 3)
	World.inventory_of(cpid).add("cordage", 2)
	World.mark_inventory(cpid)
	_say("GIFT")
	await _wait_msg("GOT", 30.0)
	_log("Ana (peer %d) holds 3 stones; now she crashes and restarts" % cpid)
	var t0 := _t
	await _wait(func(): return Net.players.size() >= 3 or (not Net.players.has(cpid) and Net.players.size() >= 2), 40.0)
	for pid in Net.players:
		_log("on the island: peer %d '%s' carrying %d stones" % [pid, Net.player_name(pid), World.inventory_of(pid).count("stone")])
	var back := await _wait_msg("BACK", 30.0)
	_log("the restarted game says: %s" % back)
	var parts := back.split(" ")
	check(parts.size() >= 2 and parts[0] == "Ana" and parts[parts.size() - 1] == "3", "after a crash, Ana comes back as Ana with her 3 stones (she is '%s')" % back)
	var gone := await _wait(func(): return not Net.players.has(cpid), 60.0)
	_log("the crashed connection timed out after %.1f s (gone %s); away records: %s" % [_t - t0, gone, str(World.player_saves.keys())])
	_say("DONE")
	await _frames(30)


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
	await _wait_msg("DONE", 90.0)
