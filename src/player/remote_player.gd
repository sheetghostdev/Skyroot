class_name RemotePlayer
extends Node3D
## Another player, driven by relayed poses (interpolated ~100 ms behind).

var pid := 0
var model: CharacterModel
var nameplate: Label3D
var _buf: Array = []         # [time, pose]
var _last_seq := -1
var _vel := Vector3.ZERO
var _mode := "play"
var _held := ""
var _ride_raft := -1
var _ride_prev := Vector3.ZERO

const DELAY := 0.1


func _ready() -> void:
	model = CharacterModel.new()
	model.carry_light = true
	add_child(model)
	model.build(Net.player_color(pid))
	nameplate = Label3D.new()
	nameplate.text = Net.player_name(pid)
	nameplate.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	nameplate.position.y = 2.05
	nameplate.font_size = 40
	nameplate.pixel_size = 0.0035
	nameplate.outline_size = 10
	nameplate.modulate = Net.player_color(pid).lightened(0.35)
	nameplate.outline_modulate = Color(0, 0, 0, 0.7)
	nameplate.no_depth_test = false
	nameplate.fixed_size = false
	if UITheme.font_bold():
		nameplate.font = UITheme.font_bold()
	add_child(nameplate)


func push_pose(pose: Dictionary) -> void:
	_buf.append([Time.get_ticks_msec() / 1000.0, pose])
	while _buf.size() > 20:
		_buf.pop_front()
	var seq := int(pose.get("s", 0))
	if seq != _last_seq:
		if _last_seq != -1:
			model.swing()
		_last_seq = seq
	var held := String(pose.get("h", ""))
	var hd = pose.get("hd", {})
	model.set_held(held, hd if hd is Dictionary else {})
	_mode = String(pose.get("m", "play"))


func _physics_process(delta: float) -> void:
	if _buf.is_empty():
		return
	var now := Time.get_ticks_msec() / 1000.0 - DELAY
	var a: Array = _buf[0]
	var b: Array = _buf[_buf.size() - 1]
	for i in range(_buf.size() - 1):
		if _buf[i][0] <= now and _buf[i + 1][0] >= now:
			a = _buf[i]
			b = _buf[i + 1]
			break
	var pa: Dictionary = a[1]
	var pb: Dictionary = b[1]
	var t := 0.0
	if b[0] > a[0]:
		t = clampf((now - a[0]) / (b[0] - a[0]), 0.0, 1.2)
	var pos: Vector3 = (pa["p"] as Vector3).lerp(pb["p"], t)
	if now > b[0]:
		pos = (pb["p"] as Vector3) + (pb.get("v", Vector3.ZERO) as Vector3) * clampf(now - b[0], 0.0, 0.25)
	var facing := lerp_angle(float(pa.get("f", 0.0)), float(pb.get("f", 0.0)), t)
	# on a raft: placed on the raft as this machine draws it
	var raft := RaftView.find(int(pb.get("rv", -1)))
	var old := global_position
	if raft != null:
		var rxf := raft.view_xf()
		var rp: Vector3 = pb["rp"]
		var rf := float(pb.get("rf", 0.0))
		if int(pa.get("rv", -1)) == int(pb["rv"]):
			rp = (pa["rp"] as Vector3).lerp(pb["rp"], minf(t, 1.0))
			rf = lerp_angle(float(pa.get("rf", 0.0)), rf, minf(t, 1.0))
		pos = rxf * rp
		facing = rf + rxf.basis.get_euler().y
		old = rxf * (_ride_prev if _ride_raft == raft.entity_id else rp)
		_ride_prev = rp
		_ride_raft = raft.entity_id
	else:
		_ride_raft = -1
	global_position = pos
	_vel = _vel.lerp((pos - old) / maxf(delta, 0.001), 0.25)
	model.rotation.y = lerp_angle(model.rotation.y, facing, 1.0 - exp(-14.0 * delta))
	var hv := Vector2(_vel.x, _vel.z).length()
	model.animate(delta, {"speed": hv, "crouch": bool(pb.get("c", false)), "air": not bool(pb.get("g", true)),
		"pitch": float(pb.get("x", 0.0)), "mode": _mode, "action": String(pb.get("a", "")), "sit": bool(pb.get("st", false))})
	nameplate.visible = _mode != "dead"
