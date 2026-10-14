class_name CraftController
extends Node
## Client: runs the close-up crafting session for a workpiece this player is
## working on.  The camera glides from the player's eyes to a working view;
## Esc steps away (the work stays where it is), Enter finishes.

const SESSIONS := {
	"knap": preload("res://src/crafting/knap_session.gd"),
	"clay_prep": preload("res://src/crafting/clay_session.gd"),
	"pottery": preload("res://src/crafting/pottery_session.gd"),
	"cordage": preload("res://src/crafting/cordage_session.gd"),
	"haft": preload("res://src/crafting/haft_session.gd"),
}

var session: CraftSession = null
var cam: Camera3D
var eid := -1
var overlay: Control
var result_card: PanelContainer
var _tw: Tween
var _result_t := 0.0


func _ready() -> void:
	add_to_group("crafting")
	Events.entity_removed.connect(_on_removed)
	cam = Camera3D.new()
	cam.name = "WorkCamera"
	cam.fov = 48.0
	cam.near = 0.01
	cam.far = 1600.0
	add_child(cam)


func is_open() -> bool:
	return session != null


func open(id: int) -> void:
	if session:
		close(false)
	var e := World.get_entity(id)
	if e.is_empty() or e["t"] != "work":
		return
	var gw = Game.game_world
	var lp: LocalPlayer = gw.local_player() if gw else null
	if lp == null:
		return
	var script: Script = SESSIONS.get(String(e["d"]["kind"]))
	if script == null:
		return
	eid = id
	session = script.new()
	session.name = "Session"
	gw.add_child(session)
	session.setup(self, id)
	lp.set_mode("craft")
	lp.hands.set_hidden(true)
	# glide from the eyes to the bench
	cam.global_transform = lp.active_camera().global_transform
	cam.fov = lp.active_camera().fov
	cam.current = true
	if _tw:
		_tw.kill()
	_tw = create_tween().set_parallel(true).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_tw.tween_property(cam, "global_transform", session.camera_xf(), 0.55)
	_tw.tween_property(cam, "fov", session.camera_fov(), 0.55)
	gw.hud.set_work_hint(session.hint_text())
	Events.craft_started.emit(String(e["d"]["kind"]), id)
	Sfx.ui("ui_open", -14.0)


func close(release: bool = true) -> void:
	if session == null:
		return
	if release and World.has_entity(eid):
		World.request("work_close", {"eid": eid})
	session.end()
	session.queue_free()
	session = null
	eid = -1
	var gw = Game.game_world
	var lp: LocalPlayer = gw.local_player() if gw else null
	if gw:
		gw.hud.set_work_hint("")
	if lp:
		if _tw:
			_tw.kill()
		_tw = create_tween().set_parallel(true).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
		_tw.tween_property(cam, "global_transform", lp.active_camera().global_transform, 0.4)
		_tw.tween_property(cam, "fov", lp.active_camera().fov, 0.4)
		_tw.chain().tween_callback(func():
			lp.active_camera().current = true
			if lp.mode == "craft":
				lp.set_mode("play")
			lp.hands.set_hidden(false))
	Events.craft_ended.emit()


func on_result(id: int, text: String, kind: String) -> void:
	_show_result(text, kind)
	if id == eid and session:
		close(false)


func _show_result(text: String, kind: String) -> void:
	var gw = Game.game_world
	if gw == null:
		return
	if result_card:
		result_card.queue_free()
	result_card = PanelContainer.new()
	result_card.set_anchors_preset(Control.PRESET_CENTER)
	result_card.offset_left = -260
	result_card.offset_right = 260
	result_card.offset_top = -190
	var good := kind == "craft"
	result_card.add_theme_stylebox_override("panel", UITheme.panel(Color(0.1, 0.09, 0.075, 0.92), 12, Color(UITheme.ACCENT if good else UITheme.DANGER, 0.6), 18))
	result_card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var l := UITheme.label(text, 17, UITheme.PAPER)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(480, 0)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	result_card.add_child(l)
	gw.hud.root.add_child(result_card)
	_result_t = 5.5 if good else 7.0
	Sfx.ui("build_complete" if good else "ui_error", -6.0 if good else -10.0)


func _process(delta: float) -> void:
	if result_card:
		_result_t -= delta
		result_card.modulate.a = clampf(_result_t, 0.0, 1.0)
		if _result_t <= 0.0:
			result_card.queue_free()
			result_card = null
	if session and not World.has_entity(eid):
		close(false)


func _on_removed(id: int) -> void:
	if id == eid and session:
		close(false)


func _unhandled_input(event: InputEvent) -> void:
	if session == null:
		return
	if event.is_action_pressed("pause"):
		close(true)
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("confirm"):
		World.request("work_finish", {"eid": eid})
		get_viewport().set_input_as_handled()
		return
	if session.handle_input(event):
		get_viewport().set_input_as_handled()
