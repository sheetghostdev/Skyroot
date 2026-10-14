class_name PlayersRoot
extends Node3D
## Spawns the local player and one RemotePlayer per other connected peer.

var local: LocalPlayer
var remotes: Dictionary = {}


func _ready() -> void:
	add_to_group("players_root")
	Net.roster_changed.connect(_sync_roster)


func spawn_local(info: Dictionary) -> void:
	local = LocalPlayer.new()
	local.name = "Player_%d" % Net.my_id()
	local.pid = Net.my_id()
	add_child(local)
	local.global_position = info.get("pos", World.spawn_point(local.pid))
	local.yaw = float(info.get("yaw", 0.0))
	local.facing_yaw = local.yaw
	_sync_roster()


func _sync_roster() -> void:
	for pid in Net.players:
		if pid == Net.my_id() or remotes.has(pid):
			continue
		var r := RemotePlayer.new()
		r.pid = pid
		r.name = "Remote_%d" % pid
		add_child(r)
		remotes[pid] = r
		if Net.poses.has(pid):
			r.push_pose(Net.poses[pid])
			r.global_position = Net.poses[pid].get("p", Vector3.ZERO)
	for pid in remotes.keys():
		if not Net.players.has(pid):
			remotes[pid].queue_free()
			remotes.erase(pid)


func apply_remote_pose(pid: int, pose: Dictionary) -> void:
	if pid == Net.my_id():
		return
	if not remotes.has(pid):
		_sync_roster()
	var r: RemotePlayer = remotes.get(pid)
	if r:
		r.push_pose(pose)


func player_node(pid: int) -> Node3D:
	if local and pid == local.pid:
		return local
	return remotes.get(pid)


func player_pos(pid: int) -> Vector3:
	var n := player_node(pid)
	if n:
		return n.global_position
	return Net.poses.get(pid, {}).get("p", Vector3.ZERO)
