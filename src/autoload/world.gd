extends Node
## Authoritative world state and its replication.
##
## The host owns everything here: the blocks (VoxelData), the entities (dropped
## items and block entities such as fire pits, knapping stones, clay work, kilns,
## ground storage) and every player's inventory and stats.  Every mutation goes
## through set_block() / spawn() / update() / set_xf() / despawn(), which apply
## the change locally and queue a replication op.  Ops are flushed to all clients
## once per physics frame as one reliable RPC, so clients see changes in exactly
## the order the host made them.  Clients never change state: they call
## request(action, args) and the host's Actions validate and apply it.

const SAVE_VERSION := 11
const MIN_VERSION := 10            # older saves are from before the block world
const SAVE_DIR := "user://saves"
const START_HOUR := 7.0

var running := false
var world_name := ""
var world_seed := 0
var kind := "sky"                  # "sky": one floating island, "sea": an archipelago
var geo: Dictionary = {}           # facts about the generated world (islands, spawn...), replicated
var vox := IslandGen.new_grid()
var entities: Dictionary = {}      # id -> {"id": int, "t": String, "xf": Transform3D, "d": Dictionary}
var be_at: Dictionary = {}         # Vector3i -> entity id (block entities: one per cell)
var next_id := 1
var env: Dictionary = {}           # replicated environment: time, weather, wind
var discoveries: Dictionary = {}   # discovery id -> player name
var player_saves: Dictionary = {}  # host-only: player name -> persisted record

# host-only runtime state
var inventories: Dictionary = {}   # peer id -> Inventory
var stats: Dictionary = {}         # peer id -> survival stats Dictionary
var guide_states: Dictionary = {}  # peer id -> per-player guide progress
var actions: Node = null           # the game scene's action handler (host)

# client view of the local player's own inventory/stats
var my_inventory := Inventory.new()
var my_stats: Dictionary = {}

var _ops: Array = []
var _inv_dirty: Dictionary = {}
var _stats_dirty: Dictionary = {}
var _env_timer := 0.0


func is_host() -> bool:
	return multiplayer.is_server()


# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

func new_world(name: String, seed_value: int = 0, world_kind: String = "sky") -> void:
	reset()
	world_name = name
	world_seed = seed_value if seed_value != 0 else randi()
	kind = world_kind
	if kind == "sea":
		vox = ArchipelagoGen.new_grid()
		geo = ArchipelagoGen.generate(vox, world_seed)
	else:
		IslandGen.generate(vox)
	env = {
		"t": 24.0 + START_HOUR,   # absolute game hours; day 1 starts at t=24
		"rain": 0.0, "cloud": 0.2, "wind": Vector2(1.2, 0.4), "fog": 0.0, "rain_target": 0.0,
	}
	running = true


func reset() -> void:
	running = false
	kind = "sky"
	geo = {}
	vox = IslandGen.new_grid()
	entities.clear()
	be_at.clear()
	next_id = 1
	env = {}
	discoveries.clear()
	player_saves.clear()
	inventories.clear()
	stats.clear()
	guide_states.clear()
	_ops.clear()
	_inv_dirty.clear()
	_stats_dirty.clear()
	my_inventory = Inventory.new()
	my_stats = {}


func _physics_process(delta: float) -> void:
	if not running:
		return
	if is_host():
		_flush(delta)


func _flush(delta: float) -> void:
	var online := Net.is_online()
	if _ops.size() > 0:
		if online and Net.client_count() > 0:
			_rpc_ops.rpc(_ops)
		_ops = []
	for pid in _inv_dirty.keys():
		if inventories.has(pid):
			var arr: Array = inventories[pid].to_array()
			if pid == multiplayer.get_unique_id():
				_apply_inventory(arr)
			elif online:
				_rpc_inventory.rpc_id(pid, arr)
	_inv_dirty.clear()
	for pid in _stats_dirty.keys():
		if stats.has(pid):
			if pid == multiplayer.get_unique_id():
				_apply_stats(stats[pid])
			elif online:
				_rpc_stats.rpc_id(pid, stats[pid])
	_stats_dirty.clear()
	_env_timer -= delta
	if _env_timer <= 0.0:
		_env_timer = 1.0
		if online and Net.client_count() > 0:
			_rpc_env.rpc(env)


func send_ops_now() -> void:
	if _ops.size() > 0:
		if Net.is_online() and Net.client_count() > 0:
			_rpc_ops.rpc(_ops)
		_ops = []


# ---------------------------------------------------------------------------
# Blocks (host)
# ---------------------------------------------------------------------------

func block(c: Vector3i) -> int:
	return vox.get_id(c.x, c.y, c.z)


func block_meta(c: Vector3i) -> int:
	return vox.get_m(c.x, c.y, c.z)


func set_block(c: Vector3i, id: int, m: int = 0) -> void:
	if not vox.in_bounds_v(c):
		return
	var old_h := vox.column_height(c.x, c.z)
	vox.set_block(c.x, c.y, c.z, id, m)
	if is_host():
		_ops.append(["b", c, id, m])
	Events.block_changed.emit(c, old_h)


func set_block_meta(c: Vector3i, m: int) -> void:
	set_block(c, block(c), m)


# ---------------------------------------------------------------------------
# Entity API (host)
# ---------------------------------------------------------------------------

func spawn(t: String, xf: Transform3D, d: Dictionary = {}) -> int:
	if not is_host():
		push_error("World.spawn called on client")
		return -1
	var id := next_id
	next_id += 1
	var e := {"id": id, "t": t, "xf": xf, "d": d}
	entities[id] = e
	_index(e)
	_ops.append(["s", {"id": id, "t": t, "xf": xf, "d": d.duplicate(true)}])
	Events.entity_spawned.emit(id)
	return id


func spawn_be(t: String, c: Vector3i, d: Dictionary = {}) -> int:
	## A block entity occupying cell c (a puddle there soaks away).
	d["cell"] = c
	if Blocks.shape[block(c)] == Blocks.Shape.LIQUID:
		set_block(c, 0)
	return spawn(t, Transform3D(Basis(), Vector3(c)), d)


func update(id: int, changes: Dictionary) -> void:
	var e = entities.get(id)
	if e == null:
		return
	for k in changes:
		e["d"][k] = changes[k]
	if is_host():
		_ops.append(["u", id, changes.duplicate(true)])
	Events.entity_changed.emit(id, changes.keys())


func set_xf(id: int, xf: Transform3D) -> void:
	var e = entities.get(id)
	if e == null:
		return
	e["xf"] = xf
	if is_host():
		_ops.append(["x", id, xf])
	Events.entity_changed.emit(id, ["xf"])


func despawn(id: int) -> void:
	if not entities.has(id):
		return
	_unindex(entities[id])
	entities.erase(id)
	if is_host():
		_ops.append(["r", id])
	Events.entity_removed.emit(id)


func _index(e: Dictionary) -> void:
	var d: Dictionary = e["d"]
	if d.has("cell"):
		be_at[d["cell"]] = e["id"]


func _unindex(e: Dictionary) -> void:
	var d: Dictionary = e["d"]
	if d.has("cell") and be_at.get(d["cell"], -1) == e["id"]:
		be_at.erase(d["cell"])


func _reindex() -> void:
	be_at.clear()
	for e in entities.values():
		_index(e)


func be(c: Vector3i) -> Dictionary:
	var id := int(be_at.get(c, -1))
	return entities.get(id, {}) if id >= 0 else {}


func get_entity(id: int) -> Dictionary:
	return entities.get(id, {})


func has_entity(id: int) -> bool:
	return entities.has(id)


func entity_pos(id: int) -> Vector3:
	var e = entities.get(id)
	return e["xf"].origin if e else Vector3.ZERO


func entities_of(t: String) -> Array:
	var out: Array = []
	for e in entities.values():
		if e["t"] == t:
			out.append(e)
	return out


func entities_near(pos: Vector3, radius: float, t: String = "") -> Array:
	var out: Array = []
	var r2 := radius * radius
	for e in entities.values():
		if (t == "" or e["t"] == t) and (e["xf"].origin as Vector3).distance_squared_to(pos) <= r2:
			out.append(e)
	return out


func cell_free(c: Vector3i) -> bool:
	## Nothing in this cell: no block (or only one that can be replaced) and no block entity.
	return Blocks.is_replaceable(block(c)) and not be_at.has(c)


# ---------------------------------------------------------------------------
# Players (host)
# ---------------------------------------------------------------------------

func inventory_of(pid: int) -> Inventory:
	if not inventories.has(pid):
		inventories[pid] = Inventory.new()
	return inventories[pid]


func mark_inventory(pid: int) -> void:
	_inv_dirty[pid] = true


func mark_stats(pid: int) -> void:
	_stats_dirty[pid] = true


func on_player_joined(pid: int, player_name: String) -> Dictionary:
	## Host: restore or create this player's record.  Returns spawn info.
	var inv := Inventory.new()
	var st := default_stats()
	var info := {"pos": spawn_point(pid), "yaw": 0.0, "new": true}
	if player_saves.has(player_name):
		var rec: Dictionary = player_saves[player_name]
		inv.from_array(rec.get("inv", []))
		for k in rec.get("stats", {}):
			st[k] = rec["stats"][k]
		info["pos"] = rec.get("pos", info["pos"])
		info["yaw"] = rec.get("yaw", 0.0)
		info["new"] = false
		guide_states[pid] = rec.get("guide", {})
		info["guide"] = guide_states[pid]
	inventories[pid] = inv
	stats[pid] = st
	mark_inventory(pid)
	mark_stats(pid)
	return info


func on_player_left(pid: int, player_name: String, pos: Vector3, yaw: float) -> void:
	if actions:
		actions.close_inventory(pid)
	store_player_record(pid, player_name, pos, yaw)
	inventories.erase(pid)
	stats.erase(pid)
	guide_states.erase(pid)


func store_player_record(pid: int, player_name: String, pos: Vector3, yaw: float) -> void:
	if player_name == "" or not inventories.has(pid):
		return
	player_saves[player_name] = {
		"inv": inventories[pid].to_array(),
		"stats": stats.get(pid, default_stats()).duplicate(true),
		"pos": pos, "yaw": yaw,
		"guide": guide_states.get(pid, {}),
	}


func default_stats() -> Dictionary:
	return {"health": 1.0, "hunger": 0.8, "thirst": 0.8, "warmth": 0.85, "bed": Vector3i(-1, -1, -1), "alive": true}


func spawn_point(pid: int) -> Vector3:
	var base: Vector3 = geo.get("spawn", IslandGen.SPAWN) if kind == "sea" else IslandGen.SPAWN
	var p := base + Vector3(cos(pid * 1.7), 0.0, sin(pid * 1.7)) * 1.2 * float(pid % 4)
	var y := vox.rest_height(Vector3(p.x, p.y + 6.0, p.z))
	if y == -INF:
		return base
	return Vector3(p.x, y + 0.02, p.z)


# ---------------------------------------------------------------------------
# Client-side application of replicated state
# ---------------------------------------------------------------------------

@rpc("authority", "call_remote", "reliable")
func _rpc_ops(ops: Array) -> void:
	for op in ops:
		match op[0]:
			"b":
				var c: Vector3i = op[1]
				var old_h := vox.column_height(c.x, c.z)
				vox.set_block(c.x, c.y, c.z, int(op[2]), int(op[3]))
				Events.block_changed.emit(c, old_h)
			"s":
				var e: Dictionary = op[1]
				entities[e["id"]] = e
				_index(e)
				Events.entity_spawned.emit(e["id"])
			"u":
				var id: int = op[1]
				if entities.has(id):
					var d: Dictionary = entities[id]["d"]
					for k in op[2]:
						d[k] = op[2][k]
					Events.entity_changed.emit(id, op[2].keys())
			"x":
				if entities.has(op[1]):
					entities[op[1]]["xf"] = op[2]
					Events.entity_changed.emit(op[1], ["xf"])
			"r":
				if entities.has(op[1]):
					_unindex(entities[op[1]])
					entities.erase(op[1])
					Events.entity_removed.emit(op[1])


@rpc("authority", "call_remote", "unreliable_ordered")
func _rpc_env(e: Dictionary) -> void:
	env = e
	Events.env_changed.emit()


@rpc("authority", "call_remote", "reliable")
func _rpc_inventory(arr: Array) -> void:
	_apply_inventory(arr)


func _apply_inventory(arr: Array) -> void:
	my_inventory.from_array(arr)
	Events.inventory_changed.emit()


@rpc("authority", "call_remote", "reliable")
func _rpc_stats(st: Dictionary) -> void:
	_apply_stats(st)


func _apply_stats(st: Dictionary) -> void:
	my_stats = st.duplicate()
	Events.stats_changed.emit()


# ---------------------------------------------------------------------------
# Snapshot (late join)
# ---------------------------------------------------------------------------

func build_snapshot() -> Dictionary:
	return {
		"name": world_name, "seed": world_seed, "entities": entities, "next_id": next_id,
		"vox": vox.to_dict(), "env": env, "discoveries": discoveries, "kind": kind, "geo": geo,
	}


func send_snapshot(pid: int) -> void:
	send_ops_now()
	_rpc_snapshot.rpc_id(pid, build_snapshot())


@rpc("authority", "call_remote", "reliable")
func _rpc_snapshot(snap: Dictionary) -> void:
	reset()
	world_name = snap["name"]
	world_seed = snap["seed"]
	kind = String(snap.get("kind", "sky"))
	geo = snap.get("geo", {})
	entities = snap["entities"]
	_reindex()
	next_id = snap["next_id"]
	var v := VoxelData.from_saved(snap["vox"])
	if v:
		vox = v
	env = snap["env"]
	discoveries = snap["discoveries"]
	running = true
	Game.on_client_snapshot()


# ---------------------------------------------------------------------------
# Requests (client -> host) and feedback (host -> client)
# ---------------------------------------------------------------------------

func request(action: String, args: Dictionary = {}) -> void:
	if not running:
		return
	if is_host():
		_handle(multiplayer.get_unique_id(), action, args)
	else:
		_rpc_request.rpc_id(1, action, args)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_request(action: String, args: Dictionary) -> void:
	if not is_host() or not running:
		return
	var pid := multiplayer.get_remote_sender_id()
	if not Net.players.has(pid):
		return
	_handle(pid, action, args)


func _handle(pid: int, action: String, args: Dictionary) -> void:
	if actions == null:
		return
	actions.handle(pid, action, args)


func notify(pid: int, text: String, kind: String = "info") -> void:
	if pid == multiplayer.get_unique_id():
		Events.toast.emit(text, kind)
	elif Net.is_online():
		_rpc_notify.rpc_id(pid, text, kind)


@rpc("authority", "call_remote", "reliable")
func _rpc_notify(text: String, kind: String) -> void:
	Events.toast.emit(text, kind)


func notify_all(text: String, kind: String = "info") -> void:
	Events.toast.emit(text, kind)
	if is_host() and Net.is_online() and Net.client_count() > 0:
		_rpc_notify.rpc(text, kind)


func teleport(pid: int, pos: Vector3, yaw: float) -> void:
	## Host: move a player (respawn).  Players own their movement, so ask their machine.
	if pid == multiplayer.get_unique_id():
		_apply_teleport(pos, yaw)
	elif Net.is_online():
		_rpc_teleport.rpc_id(pid, pos, yaw)


@rpc("authority", "call_remote", "reliable")
func _rpc_teleport(pos: Vector3, yaw: float) -> void:
	_apply_teleport(pos, yaw)


func _apply_teleport(pos: Vector3, yaw: float) -> void:
	var lp := get_tree().get_first_node_in_group("local_player")
	if lp:
		lp.respawn_at(pos, yaw)


func hint_to(pid: int, hint_id: String) -> void:
	if pid == multiplayer.get_unique_id():
		Events.hint.emit(hint_id)
	elif Net.is_online():
		_rpc_hint.rpc_id(pid, hint_id)


@rpc("authority", "call_remote", "reliable")
func _rpc_hint(hint_id: String) -> void:
	Events.hint.emit(hint_id)


func open_chooser(pid: int, kind: String, c: Vector3i) -> void:
	## Host: ask a player to pick what to make from the work they just set down.
	if pid == multiplayer.get_unique_id():
		Events.open_chooser.emit(kind, c)
	elif Net.is_online():
		send_ops_now()
		_rpc_chooser.rpc_id(pid, kind, c)


@rpc("authority", "call_remote", "reliable")
func _rpc_chooser(kind: String, c: Vector3i) -> void:
	Events.open_chooser.emit(kind, c)


func fx(kind: String, pos: Vector3, params: Dictionary = {}) -> void:
	## Host: play a one-shot effect (sound/particles) for everyone.
	_play_fx(kind, pos, params)
	if is_host() and Net.is_online() and Net.client_count() > 0:
		_rpc_fx.rpc(kind, pos, params)


func fx_except(pid: int, kind: String, pos: Vector3, params: Dictionary = {}) -> void:
	## Host: an effect the acting player already played locally.
	if pid != multiplayer.get_unique_id():
		_play_fx(kind, pos, params)
	if is_host() and Net.is_online():
		for p in Net.players:
			if p != pid and p != multiplayer.get_unique_id():
				_rpc_fx.rpc_id(p, kind, pos, params)


@rpc("authority", "call_remote", "reliable")
func rpc_flag(f: String) -> void:
	## Host -> a player: you did something your goals track.
	Guide.flag(f)


@rpc("authority", "call_remote", "unreliable")
func _rpc_fx(kind: String, pos: Vector3, params: Dictionary) -> void:
	_play_fx(kind, pos, params)


func _play_fx(kind: String, pos: Vector3, params: Dictionary) -> void:
	var fxn := get_tree().get_first_node_in_group("fx")
	if fxn:
		fxn.play(kind, pos, params)


func discover(discovery_id: String, by_pid: int) -> void:
	## Host: first time the group achieves something notable.
	if discoveries.has(discovery_id):
		return
	var who: String = Net.players.get(by_pid, {}).get("name", "Someone")
	discoveries[discovery_id] = who
	if Net.is_online() and Net.client_count() > 0:
		_rpc_discovery.rpc(discovery_id, who)
	Events.discovery.emit(discovery_id, who)


@rpc("authority", "call_remote", "reliable")
func _rpc_discovery(discovery_id: String, who: String) -> void:
	discoveries[discovery_id] = who
	Events.discovery.emit(discovery_id, who)


# ---------------------------------------------------------------------------
# Time helpers (all peers)
# ---------------------------------------------------------------------------

func hours() -> float:
	return float(env.get("t", 24.0 + START_HOUR))


func day() -> int:
	return int(floor(hours() / 24.0))


func hour_of_day() -> float:
	return fmod(hours(), 24.0)


func is_night() -> bool:
	var h := hour_of_day()
	return h < 5.5 or h > 20.5


# ---------------------------------------------------------------------------
# Persistence (host)
# ---------------------------------------------------------------------------

static func save_path(name: String) -> String:
	return "%s/%s.skyroot" % [SAVE_DIR, name.validate_filename()]


func save_world(players_live: Dictionary = {}) -> Error:
	if not is_host() or not running:
		return ERR_UNAVAILABLE
	DirAccess.make_dir_recursive_absolute(SAVE_DIR)
	for pid in players_live:
		var p: Dictionary = players_live[pid]
		store_player_record(pid, p["name"], p["pos"], p["yaw"])
	var data := {
		"version": SAVE_VERSION, "kind": kind, "geo": geo,
		"name": world_name, "seed": world_seed, "next_id": next_id,
		"entities": entities, "vox": vox.to_dict(), "env": env,
		"discoveries": discoveries, "players": player_saves,
		"saved_at": Time.get_datetime_string_from_system(),
	}
	var path := save_path(world_name)
	var tmp := path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_var(data)
	f.close()
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	DirAccess.rename_absolute(tmp, path)
	var meta := FileAccess.open(path + ".meta", FileAccess.WRITE)
	if meta:
		meta.store_string(JSON.stringify({"name": world_name, "day": day(), "saved_at": data["saved_at"], "version": SAVE_VERSION, "kind": kind}))
	return OK


func load_world(name: String) -> Error:
	var path := save_path(name)
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ERR_FILE_NOT_FOUND
	var data = f.get_var()
	if not data is Dictionary or not data.has("version"):
		return ERR_FILE_CORRUPT
	if int(data["version"]) < MIN_VERSION:
		return ERR_FILE_UNRECOGNIZED   # an island from before the block world
	reset()
	world_name = data["name"]
	world_seed = data["seed"]
	kind = String(data.get("kind", "sky"))
	geo = data.get("geo", {})
	next_id = data["next_id"]
	entities = data["entities"]
	for k in entities:
		var e: Dictionary = entities[k]
		if String(e["t"]) == "item":
			# dropped in an earlier run: settled, and free to pick up at once
			var d: Dictionary = e["d"]
			d.erase("from")
			d.erase("w")
			d["t"] = -100000
	_reindex()
	var v := VoxelData.from_saved(data["vox"])
	if v == null:
		reset()
		return ERR_FILE_CORRUPT
	vox = v
	env = data["env"]
	discoveries = data["discoveries"]
	player_saves = data["players"]
	running = true
	return OK


static func delete_save(name: String) -> void:
	var path := save_path(name)
	for f in [path, path + ".meta", path + ".tmp"]:
		if FileAccess.file_exists(f):
			DirAccess.remove_absolute(f)


static func list_saves() -> Array:
	var out: Array = []
	var dir := DirAccess.open(SAVE_DIR)
	if dir == null:
		return out
	for fn in dir.get_files():
		if fn.ends_with(".skyroot.meta"):
			var f := FileAccess.open(SAVE_DIR + "/" + fn, FileAccess.READ)
			if f:
				var meta = JSON.parse_string(f.get_as_text())
				if meta is Dictionary:
					meta["old"] = int(meta.get("version", 0)) < MIN_VERSION
					out.append(meta)
	out.sort_custom(func(a, b): return String(a.get("saved_at", "")) > String(b.get("saved_at", "")))
	return out
