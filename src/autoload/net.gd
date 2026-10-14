extends Node
## Networking: hosting / joining over ENet (LAN or direct IP), the handshake and
## the player roster.  Single-player runs the exact same code with an offline peer
## where this machine is the host.
##
## Player movement is owned by each player's own machine and relayed through the
## host at ~20 Hz (unreliable).  Everything else - items, terrain, crafting
## workpieces, fires, buildings - is owned by the host (see World).

const PROTOCOL := 3
const MAX_PLAYERS := 4
const DEFAULT_PORT := 7777
const COLORS := [Color("c98d3a"), Color("3f9a94"), Color("b3523c"), Color("7d9a52")]

signal joined_ok
signal join_failed(reason: String)
signal session_ended(reason: String)
signal roster_changed

var players: Dictionary = {}   # peer id -> {"name": String, "color": int}
var _joining := false
var _reject_reason := ""

# latest replicated pose of every player: peer id -> Dictionary
var poses: Dictionary = {}


func _ready() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)


func is_online() -> bool:
	var p := multiplayer.multiplayer_peer
	return p != null and not (p is OfflineMultiplayerPeer) \
		and p.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED


func is_host() -> bool:
	return multiplayer.is_server()


func my_id() -> int:
	return multiplayer.get_unique_id()


func client_count() -> int:
	return maxi(0, players.size() - 1)


func player_name(pid: int) -> String:
	return String(players.get(pid, {}).get("name", "?"))


func player_color(pid: int) -> Color:
	return COLORS[int(players.get(pid, {}).get("color", 0)) % COLORS.size()]


# ---------------------------------------------------------------------------
# Start / stop
# ---------------------------------------------------------------------------

func start_offline() -> void:
	close()
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	players = {1: {"name": Settings.player_name, "color": 0}}
	roster_changed.emit()


func host(port: int = DEFAULT_PORT) -> Error:
	close()
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(port, MAX_PLAYERS - 1)
	if err != OK:
		return err
	multiplayer.multiplayer_peer = peer
	players = {1: {"name": Settings.player_name, "color": 0}}
	roster_changed.emit()
	return OK


func join(ip: String, port: int = DEFAULT_PORT) -> Error:
	close()
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(ip, port)
	if err != OK:
		return err
	multiplayer.multiplayer_peer = peer
	_joining = true
	_reject_reason = ""
	return OK


func close() -> void:
	_joining = false
	if multiplayer.multiplayer_peer and not (multiplayer.multiplayer_peer is OfflineMultiplayerPeer):
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	players.clear()
	poses.clear()


# ---------------------------------------------------------------------------
# Connection events
# ---------------------------------------------------------------------------

func _on_peer_connected(_pid: int) -> void:
	pass  # wait for the client's hello before registering it


func _on_peer_disconnected(pid: int) -> void:
	if not is_host():
		return
	if players.has(pid):
		var pose: Dictionary = poses.get(pid, {})
		World.on_player_left(pid, player_name(pid), pose.get("p", World.spawn_point(pid)), pose.get("y", 0.0))
		var left_name := player_name(pid)
		players.erase(pid)
		poses.erase(pid)
		_rpc_roster.rpc(players)
		roster_changed.emit()
		Events.player_left.emit(pid)
		Events.chat.emit("", "%s left the island." % left_name)
		_rpc_chat.rpc("", "%s left the island." % left_name)


func _on_connected_to_server() -> void:
	_rpc_hello.rpc_id(1, Settings.player_name, PROTOCOL)


func _on_connection_failed() -> void:
	_joining = false
	join_failed.emit("Could not reach the host.")
	close()


func _on_server_disconnected() -> void:
	var reason := _reject_reason if _reject_reason != "" else "The host closed the island."
	_joining = false
	close()
	session_ended.emit(reason)


# ---------------------------------------------------------------------------
# Handshake
# ---------------------------------------------------------------------------

@rpc("any_peer", "call_remote", "reliable")
func _rpc_hello(requested_name: String, protocol: int) -> void:
	if not is_host():
		return
	var pid := multiplayer.get_remote_sender_id()
	if protocol != PROTOCOL:
		_kick(pid, "Version mismatch (host %d, you %d)." % [PROTOCOL, protocol])
		return
	if players.size() >= MAX_PLAYERS:
		_kick(pid, "The island is full (4 players).")
		return
	if not World.running:
		_kick(pid, "The host is not ready yet.")
		return
	var clean := requested_name.strip_edges().left(18)
	if clean == "":
		clean = "Wanderer"
	var final_name := clean
	var n := 2
	while _name_taken(final_name):
		final_name = "%s %d" % [clean, n]
		n += 1
	players[pid] = {"name": final_name, "color": _free_color()}
	var info := World.on_player_joined(pid, final_name)
	World.send_snapshot(pid)
	_rpc_roster.rpc(players)
	_rpc_welcome.rpc_id(pid, info)
	roster_changed.emit()
	Events.player_joined.emit(pid)
	var msg := "%s joined the island." % final_name
	Events.chat.emit("", msg)
	_rpc_chat.rpc("", msg)


func _kick(pid: int, reason: String) -> void:
	_rpc_reject.rpc_id(pid, reason)
	await get_tree().create_timer(0.3).timeout
	if multiplayer.multiplayer_peer is ENetMultiplayerPeer:
		multiplayer.multiplayer_peer.disconnect_peer(pid)


func _name_taken(n: String) -> bool:
	for p in players.values():
		if p["name"] == n:
			return true
	return false


func _free_color() -> int:
	for c in COLORS.size():
		var used := false
		for p in players.values():
			if p["color"] == c:
				used = true
		if not used:
			return c
	return 0


@rpc("authority", "call_remote", "reliable")
func _rpc_reject(reason: String) -> void:
	_reject_reason = reason
	_joining = false
	join_failed.emit(reason)


@rpc("authority", "call_remote", "reliable")
func _rpc_roster(roster: Dictionary) -> void:
	players = roster
	roster_changed.emit()


@rpc("authority", "call_remote", "reliable")
func _rpc_welcome(info: Dictionary) -> void:
	_joining = false
	Game.on_client_welcome(info)


# ---------------------------------------------------------------------------
# Player pose relay
# ---------------------------------------------------------------------------

func send_pose(pose: Dictionary) -> void:
	poses[my_id()] = pose
	if is_online():
		_rpc_pose.rpc(pose)


@rpc("any_peer", "call_remote", "unreliable_ordered")
func _rpc_pose(pose: Dictionary) -> void:
	var pid := multiplayer.get_remote_sender_id()
	if not players.has(pid):
		return
	poses[pid] = pose
	var node := get_tree().get_first_node_in_group("players_root")
	if node:
		node.apply_remote_pose(pid, pose)


# ---------------------------------------------------------------------------
# Chat
# ---------------------------------------------------------------------------

func send_chat(text: String) -> void:
	text = text.strip_edges().left(200)
	if text == "":
		return
	var from := player_name(my_id())
	Events.chat.emit(from, text)
	if is_online():
		_rpc_chat.rpc(from, text)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_chat(from: String, text: String) -> void:
	var pid := multiplayer.get_remote_sender_id()
	if pid != 1 and players.has(pid):
		from = player_name(pid)  # never trust a client's claimed name
	Events.chat.emit(from, text.left(200))
