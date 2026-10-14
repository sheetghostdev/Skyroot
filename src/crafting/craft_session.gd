class_name CraftSession
extends Node3D
## Base for a close-up crafting activity.  Lives at the workpiece's transform;
## converts mouse input into small operations sent to the host.

var ctrl: CraftController
var eid := -1
var overlay: Control


func setup(c: CraftController, id: int) -> void:
	ctrl = c
	eid = id
	global_transform = World.get_entity(id)["xf"]
	overlay = Control.new()
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.draw.connect(_draw_overlay)
	Game.game_world.hud.root.add_child(overlay)
	Events.entity_changed.connect(_on_entity_changed)
	_start()


func end() -> void:
	if overlay:
		overlay.queue_free()
	if Events.entity_changed.is_connected(_on_entity_changed):
		Events.entity_changed.disconnect(_on_entity_changed)
	_end()


func data() -> Dictionary:
	return World.get_entity(eid).get("d", {})


func view() -> Node:
	var gw = Game.game_world
	return gw.entities.view(eid) if gw else null


func send(op: Array, immediate: bool = false) -> void:
	World.request("work_op", {"eid": eid, "op": op})


func _on_entity_changed(id: int, keys: Array) -> void:
	if id == eid:
		_changed(keys)
		overlay.queue_redraw()


# --- helpers ---------------------------------------------------------------

func mouse_ray() -> Array:
	var vp := get_viewport()
	var mp := vp.get_mouse_position()
	var cam := ctrl.cam
	return [cam.project_ray_origin(mp), cam.project_ray_normal(mp)]


func ray_plane_local(y_local: float) -> Variant:
	## Intersect the mouse ray with a horizontal plane in workpiece space.
	var r := mouse_ray()
	var inv := global_transform.affine_inverse()
	var o: Vector3 = inv * (r[0] as Vector3)
	var d: Vector3 = inv.basis * (r[1] as Vector3)
	if absf(d.y) < 1e-5:
		return null
	var t := (y_local - o.y) / d.y
	if t < 0.0:
		return null
	return o + d * t


func to_screen(local: Vector3) -> Vector2:
	return ctrl.cam.unproject_position(global_transform * local)


func xf_from(local_eye: Vector3, local_target: Vector3) -> Transform3D:
	var eye := global_transform * local_eye
	var tgt := global_transform * local_target
	return Transform3D(Basis.looking_at(tgt - eye, Vector3.UP), eye)


func draw_meter(at: Vector2, label: String, value: float, good_lo: float = -1.0, good_hi: float = -1.0, width: float = 180.0) -> void:
	var f := UITheme.font_bold()
	overlay.draw_string_outline(f, at + Vector2(0, -6), label, HORIZONTAL_ALIGNMENT_LEFT, width, 13, 4, Color(0, 0, 0, 0.6))
	overlay.draw_string(f, at + Vector2(0, -6), label, HORIZONTAL_ALIGNMENT_LEFT, width, 13, UITheme.PAPER)
	var r := Rect2(at, Vector2(width, 7))
	overlay.draw_rect(r, Color(0, 0, 0, 0.45))
	if good_lo >= 0.0:
		overlay.draw_rect(Rect2(at + Vector2(width * good_lo, 0), Vector2(width * (good_hi - good_lo), 7)), Color(0.45, 0.75, 0.4, 0.45))
	overlay.draw_rect(Rect2(at, Vector2(width * clampf(value, 0.0, 1.0), 7)), Color(UITheme.PAPER, 0.85) if good_lo >= 0.0 else Color(UITheme.ACCENT, 0.9))
	if good_lo >= 0.0:
		var x := at.x + width * clampf(value, 0.0, 1.0)
		overlay.draw_rect(Rect2(Vector2(x - 1.5, at.y - 3), Vector2(3, 13)), UITheme.PAPER)


func draw_text(at: Vector2, text: String, size: int = 15, color: Color = UITheme.PAPER, width: float = 420.0) -> void:
	var f := UITheme.font()
	overlay.draw_multiline_string_outline(f, at, text, HORIZONTAL_ALIGNMENT_LEFT, width, size, -1, 4, Color(0, 0, 0, 0.55))
	overlay.draw_multiline_string(f, at, text, HORIZONTAL_ALIGNMENT_LEFT, width, size, -1, color)


# --- overridable -------------------------------------------------------------

func _start() -> void:
	pass


func _end() -> void:
	pass


func _changed(_keys: Array) -> void:
	pass


func camera_xf() -> Transform3D:
	return xf_from(Vector3(0, 0.4, 0.3), Vector3.ZERO)


func camera_fov() -> float:
	return 46.0


func hint_text() -> String:
	return ""


func handle_input(_event: InputEvent) -> bool:
	return false


func _draw_overlay() -> void:
	pass


func _process(delta: float) -> void:
	_tick(delta)
	overlay.queue_redraw()


func _tick(_delta: float) -> void:
	pass
