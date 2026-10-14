class_name Interactor
extends Node
## Works out what you're looking at (a block, a block entity such as a fire
## pit or a knapping stone - down to the cell of its grid - or a dropped bag),
## outlines it, and turns the mouse buttons into requests: hold left to break
## (with the crack growing), click to chip or shape, right click to use, hold
## right to eat, drink or work a bow drill.

const REACH := 4.6
const BRUSHES := ["1x1", "2x2", "3x3", "copy layer below"]
const KNAP_BRUSHES := ["single chips", "2x2 flakes", "3x3 flakes"]

var player: LocalPlayer
var target: Dictionary = {}
var lmb_rule: Dictionary = {}
var rmb_rule: Dictionary = {}
var brush := 0
var knap_brush := 0

var break_cell := Vector3i(-999, 0, 0)
var break_t := 0.0
var break_need := 0.0
var _swing_t := 0.0
var _hold_t := 0.0
var _hold_need := 0.0
var _hold_rule: Dictionary = {}
var _hold_target: Dictionary = {}
var _repeat_t := 0.0
var _chip_t := 0.0
var _last_sub := -1
var _cooldown := 0.0
var _last_key := ""
var _again := false
var _repeat_ok := false

var _outline: MeshInstance3D
var _outline_mesh: ImmediateMesh
var _crack: MeshInstance3D
var _crack_mat: ShaderMaterial
var _cell_box: MeshInstance3D
var _cell_mesh: ImmediateMesh


func setup(p: LocalPlayer) -> void:
	player = p
	_outline_mesh = ImmediateMesh.new()
	_outline = MeshInstance3D.new()
	_outline.mesh = _outline_mesh
	_outline.top_level = true
	_outline.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var lm := StandardMaterial3D.new()
	lm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	lm.albedo_color = Color(0.05, 0.05, 0.05, 0.75)
	lm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_outline.material_override = lm
	player.add_child(_outline)
	_cell_mesh = ImmediateMesh.new()
	_cell_box = MeshInstance3D.new()
	_cell_box.mesh = _cell_mesh
	_cell_box.top_level = true
	_cell_box.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var cm := StandardMaterial3D.new()
	cm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	cm.albedo_color = Color(1.0, 0.95, 0.6, 0.9)
	cm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	cm.no_depth_test = true
	cm.render_priority = 2
	_cell_box.material_override = cm
	player.add_child(_cell_box)
	_crack = MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3.ONE
	_crack.mesh = bm
	_crack.top_level = true
	_crack.visible = false
	_crack.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_crack_mat = ShaderMaterial.new()
	_crack_mat.shader = load("res://assets/shaders/crack.gdshader")
	_crack_mat.set_shader_parameter("atlas", BlockTex.array())
	_crack.material_override = _crack_mat
	player.add_child(_crack)


func busy() -> bool:
	return _hold_need > 0.0


func cancel() -> void:
	_hold_need = 0.0
	_hold_t = 0.0
	_hold_rule = {}
	break_t = 0.0
	player.play_action("")


func hold_progress() -> float:
	return clampf(_hold_t / _hold_need, 0.0, 1.0) if _hold_need > 0.0 else -1.0


func break_progress() -> float:
	return clampf(break_t / break_need, 0.0, 1.0) if break_need > 0.0 and break_t > 0.0 else -1.0


# ---------------------------------------------------------------------------
# Targeting
# ---------------------------------------------------------------------------

static func be_box(c: Vector3i) -> AABB:
	var be := World.be(c)
	if be.is_empty():
		return AABB()
	var d: Dictionary = be["d"]
	match String(be["t"]):
		"firepit":
			var h := 0.16 + 0.04 * ceili(int(d.get("sticks", 0)) / 2.0) + (0.18 if int(d.get("logs", 0)) > 0 else 0.0)
			return AABB(Vector3(0.08, 0, 0.08), Vector3(0.84, maxf(h, 0.16), 0.84))
		"kiln":
			return AABB(Vector3(0.04, 0, 0.04), Vector3(0.92, 0.5, 0.92))
		"knap":
			return AABB(Vector3(0, 0, 0), Vector3(1, 0.1, 1))
		"clay":
			var layers := 1
			if String(d.get("r", "")) != "" and ItemDB.clayforming.has(String(d["r"])):
				layers = mini(int(d.get("layer", 0)) + 1, (ItemDB.clayforming[String(d["r"])]["layers"] as Array).size())
			return AABB(Vector3(0, 0, 0), Vector3(1, layers / 16.0 + 0.03, 1))
		"ground":
			return AABB(Vector3(0.1, 0, 0.1), Vector3(0.8, 0.32, 0.8))
		"jar":
			return AABB(Vector3(0.2, 0, 0.2), Vector3(0.6, 0.75, 0.6))
	return AABB(Vector3(0.1, 0, 0.1), Vector3(0.8, 0.5, 0.8))


func _ray() -> Array:
	var cam := player.active_camera()
	var dir := -cam.global_transform.basis.z
	var origin := player.eye_position()
	if player.third_person:
		# start where the camera's line of sight passes the head: no reach bonus,
		# and nothing behind you gets in the way
		var co := cam.global_position
		var t := (origin - co).dot(dir)
		origin = co + dir * maxf(t, 0.0)
	return [origin, dir]


func _compute_target() -> Dictionary:
	var r := _ray()
	var origin: Vector3 = r[0]
	var dir: Vector3 = r[1]
	var liquids := player.held_id() in ["", "bowl", "pot"]
	var hit := World.vox.raycast(origin, dir, REACH, be_box, liquids)
	var best := {}
	if not hit.is_empty():
		var c: Vector3i = hit["cell"]
		if bool(hit["be"]):
			best = {"type": "be", "cell": c, "normal": hit["normal"], "point": hit["point"], "dist": hit["dist"], "be": World.be(c)}
		else:
			best = {"type": "block", "cell": c, "normal": hit["normal"], "point": hit["point"], "dist": hit["dist"], "id": hit["id"]}
	# dropped bags
	for e in World.entities_of("satchel"):
		var p: Vector3 = (e["xf"] as Transform3D).origin
		var box := AABB(p - Vector3(0.3, 0, 0.3), Vector3(0.6, 0.5, 0.6))
		var rr := VoxelData._ray_box(origin, dir, box)
		if not rr.is_empty() and float(rr["t"]) < REACH and (best.is_empty() or float(rr["t"]) < float(best["dist"])):
			best = {"type": "satchel", "eid": e["id"], "point": origin + dir * float(rr["t"]), "dist": rr["t"], "cell": VoxelData.cell_of(p), "normal": Vector3i.UP}
	if best.get("type", "") == "be":
		best["sub"] = _sub_cell(best, origin, dir)
	return best


func _sub_cell(t: Dictionary, origin: Vector3, dir: Vector3) -> int:
	## The cell of a knapping stone or a clay layer under the crosshair.
	var be: Dictionary = t["be"]
	var c: Vector3i = t["cell"]
	var y := 0.5 / 16.0
	if be["t"] == "clay":
		y = (int(be["d"].get("layer", 0)) + 0.5) / 16.0
	elif be["t"] != "knap":
		return -1
	var plane_y := c.y + y
	if absf(dir.y) < 1e-4:
		return -1
	var tt := (plane_y - origin.y) / dir.y
	if tt < 0.0:
		return -1
	var p := origin + dir * tt - Vector3(c)
	if p.x < 0.0 or p.z < 0.0 or p.x >= 1.0 or p.z >= 1.0:
		return -1
	return int(p.x * 16.0) + int(p.z * 16.0) * 16


func knap_cells(t: Dictionary) -> PackedInt32Array:
	## The cells a chip or flake would knock off, around the one under the crosshair.
	var out := PackedInt32Array()
	var sub := int(t.get("sub", -1))
	if sub < 0:
		return out
	var n := knap_brush + 1
	var x0 := sub % 16
	var z0 := sub / 16
	for dz in n:
		for dx in n:
			var x := x0 + dx - (n - 1) / 2
			var z := z0 + dz - (n - 1) / 2
			if x >= 0 and z >= 0 and x < 16 and z < 16:
				out.append(x + z * 16)
	return out


func brush_cells(t: Dictionary, add: bool) -> PackedInt32Array:
	var out := PackedInt32Array()
	var sub := int(t.get("sub", -1))
	var be: Dictionary = t.get("be", {})
	if sub < 0 or be.is_empty():
		return out
	var d: Dictionary = be["d"]
	var layer := int(d.get("layer", 0))
	var vox: PackedByteArray = d.get("vox", PackedByteArray())
	if brush == 3:
		if layer == 0 or not add:
			out.append(sub)
			return out
		for i in 256:
			var below := (layer - 1) * 256 + i
			if below < vox.size() and vox[below] == 1:
				out.append(i)
		return out
	var n := brush + 1
	var x0 := sub % 16
	var z0 := sub / 16
	for dz in n:
		for dx in n:
			var x := x0 + dx - (n - 1) / 2
			var z := z0 + dz - (n - 1) / 2
			if x >= 0 and z >= 0 and x < 16 and z < 16:
				out.append(x + z * 16)
	return out


# ---------------------------------------------------------------------------
# Every frame
# ---------------------------------------------------------------------------

func _process(delta: float) -> void:
	_cooldown = maxf(0.0, _cooldown - delta)
	if player.mode != "play":
		_set_target({})
		cancel()
		_crack.visible = false
		return
	var t := _compute_target()
	_set_target(t)
	var s := player.held_stack()
	lmb_rule = UseRules.lmb(target, s)
	rmb_rule = UseRules.rmb(target, s, Input.is_action_pressed("sneak"))
	var key := "%s|%s|%s" % [JSON.stringify(lmb_rule), JSON.stringify(rmb_rule), str(target.get("cell", ""))]
	if key != _last_key:
		_last_key = key
		Events.target_changed.emit(target)
	_handle_lmb(delta)
	_handle_rmb(delta)
	_draw_cell_hover()


func _unhandled_input(event: InputEvent) -> void:
	if player == null or player.mode != "play":
		return
	if event.is_action_pressed("tool_mode"):
		var be: Dictionary = target.get("be", {})
		if not be.is_empty() and be["t"] == "clay":
			brush = (brush + 1) % BRUSHES.size()
			Events.toast.emit("Clay brush: " + BRUSHES[brush], "info")
			_last_key = ""
		elif not be.is_empty() and be["t"] == "knap":
			knap_brush = (knap_brush + 1) % KNAP_BRUSHES.size()
			Events.toast.emit("Knapping: " + KNAP_BRUSHES[knap_brush], "info")
			_last_key = ""
	elif event.is_action_pressed("pick_block"):
		if target.get("type", "") == "block":
			var item := ItemDB.item_of_block(int(target["id"]))
			if item != "":
				for i in Inventory.HOTBAR:
					if World.my_inventory.item_at(i) == item:
						player.select_hotbar(i)
						break


func _set_target(t: Dictionary) -> void:
	target = t
	_outline_mesh.clear_surfaces()
	if t.is_empty() or t.get("type", "") == "satchel":
		if t.get("type", "") == "satchel":
			var p: Vector3 = World.entity_pos(int(t["eid"]))
			_box_lines(AABB(p - Vector3(0.3, 0, 0.3), Vector3(0.6, 0.5, 0.6)))
		return
	var c: Vector3i = t["cell"]
	var box: AABB
	if t["type"] == "be":
		box = be_box(c)
	else:
		box = Blocks.select.get(int(t["id"]), AABB(Vector3.ZERO, Vector3.ONE))
	_box_lines(AABB(box.position + Vector3(c), box.size).grow(0.004))


func _box_lines(b: AABB) -> void:
	_outline_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	var p := b.position
	var e := b.end
	var corners := [Vector3(p.x, p.y, p.z), Vector3(e.x, p.y, p.z), Vector3(e.x, p.y, e.z), Vector3(p.x, p.y, e.z),
		Vector3(p.x, e.y, p.z), Vector3(e.x, e.y, p.z), Vector3(e.x, e.y, e.z), Vector3(p.x, e.y, e.z)]
	for pair in [[0, 1], [1, 2], [2, 3], [3, 0], [4, 5], [5, 6], [6, 7], [7, 4], [0, 4], [1, 5], [2, 6], [3, 7]]:
		_outline_mesh.surface_add_vertex(corners[pair[0]])
		_outline_mesh.surface_add_vertex(corners[pair[1]])
	_outline_mesh.surface_end()


func _draw_cell_hover() -> void:
	_cell_mesh.clear_surfaces()
	var be: Dictionary = target.get("be", {})
	if be.is_empty() or int(target.get("sub", -1)) < 0:
		return
	var c: Vector3i = target["cell"]
	var y := 0.0
	var cells := PackedInt32Array()
	if be["t"] == "knap":
		if String(be["d"]["r"]) == "":
			return
		y = 1.0 / 16.0 + 0.003
		cells = knap_cells(target)
	elif be["t"] == "clay":
		if String(be["d"]["r"]) == "":
			return
		y = (int(be["d"].get("layer", 0)) + 1) / 16.0 + 0.003
		cells = brush_cells(target, true)
		if brush == 3:
			cells = PackedInt32Array([int(target["sub"])])
	else:
		return
	_cell_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	for i in cells:
		var x0 := c.x + (i % 16) / 16.0
		var z0 := c.z + (i / 16) / 16.0
		var x1 := x0 + 1.0 / 16.0
		var z1 := z0 + 1.0 / 16.0
		var yy := c.y + y
		for seg in [[Vector3(x0, yy, z0), Vector3(x1, yy, z0)], [Vector3(x1, yy, z0), Vector3(x1, yy, z1)],
				[Vector3(x1, yy, z1), Vector3(x0, yy, z1)], [Vector3(x0, yy, z1), Vector3(x0, yy, z0)]]:
			_cell_mesh.surface_add_vertex(seg[0])
			_cell_mesh.surface_add_vertex(seg[1])
	_cell_mesh.surface_end()


# ---------------------------------------------------------------------------
# Left button
# ---------------------------------------------------------------------------

func _handle_lmb(delta: float) -> void:
	var held := Input.is_action_pressed("primary")
	var kind := String(lmb_rule.get("kind", ""))
	if not held or _hold_need > 0.0:
		break_t = 0.0
		_crack.visible = false
		_chip_t = 0.0
		_last_sub = -1
		return
	match kind:
		"break":
			var c: Vector3i = target["cell"]
			if c != break_cell:
				break_cell = c
				break_t = 0.0
			break_need = float(lmb_rule.get("time", 1.0))
			if _cooldown > 0.0:
				return
			break_t += delta
			_swing_t -= delta
			if _swing_t <= 0.0:
				_swing_t = 0.26
				player.play_action("swing")
				_hit_sound()
			if break_t >= break_need:
				World.request("break", {"c": c, "slot": player.hotbar})
				if target["type"] == "block":
					var fxn := get_tree().get_first_node_in_group("fx")
					if fxn:
						fxn.play("break", Vector3(c) + Vector3(0.5, 0.5, 0.5), {"b": int(target["id"])})
				break_t = 0.0
				_cooldown = 0.18 if break_need < 0.2 else 0.08
				_crack.visible = false
			else:
				_show_crack(c, break_t / maxf(break_need, 0.001))
		"chip":
			_crack.visible = false
			_chip_t -= delta
			var sub := int(target.get("sub", -1))
			var be: Dictionary = target["be"]
			var cells: PackedByteArray = be["d"].get("cells", PackedByteArray())
			# chip on click, and keep chipping cells you sweep across while held
			if sub >= 0 and sub < cells.size() and _chip_t <= 0.0 and sub != _last_sub:
				var hit := knap_cells(target)
				var any := false
				for i in hit:
					if cells[i] == 1:
						any = true
				if any:
					_chip_t = 0.06 if knap_brush == 0 else 0.16
					_last_sub = sub
					World.request("knap", {"c": target["cell"], "cells": hit})
					player.play_action("swing")
					Sfx.play("knap", target["point"], -4.0)
		"clay_remove":
			_crack.visible = false
			_chip_t -= delta
			if _chip_t <= 0.0:
				var cells2 := brush_cells(target, false)
				if not cells2.is_empty():
					_chip_t = 0.14
					World.request("clay", {"c": target["cell"], "cells": cells2, "add": false})
					player.play_action("swing")
					Sfx.play("clay_squish", target["point"], -6.0)
		_:
			_crack.visible = false
			break_t = 0.0


func _hit_sound() -> void:
	if target.get("type", "") != "block":
		return
	var snd := String(Blocks.def(int(target["id"])).get("sound", "dirt"))
	var p: Vector3 = target["point"]
	match snd:
		"stone": Sfx.play("stone_drop", p, -10.0)
		"wood": Sfx.play("chop", p, -6.0)
		"leaves", "grass": Sfx.play("rustle", p, -10.0)
		"gravel": Sfx.play("dig_soil", p, -8.0, 1.2)
		"clay": Sfx.play("dig_clay", p, -8.0)
		_: Sfx.play("dig_soil", p, -8.0)


func _show_crack(c: Vector3i, f: float) -> void:
	var box: AABB = Blocks.select.get(World.block(c), AABB(Vector3.ZERO, Vector3.ONE))
	if target.get("type", "") == "be":
		box = be_box(c)
	_crack.visible = true
	_crack.global_transform = Transform3D(Basis().scaled(box.size + Vector3.ONE * 0.006), Vector3(c) + box.get_center())
	_crack_mat.set_shader_parameter("layer", float(BlockTex.layer("crack_%d" % clampi(int(f * 8.0), 0, 7))))


# ---------------------------------------------------------------------------
# Right button
# ---------------------------------------------------------------------------

func _handle_rmb(delta: float) -> void:
	var pressed := Input.is_action_just_pressed("secondary")
	var held := Input.is_action_pressed("secondary")
	if _hold_need > 0.0:
		if not held or not _same_target(_hold_target):
			cancel()
			return
		_hold_t += delta
		var kind := String(_hold_rule.get("kind", ""))
		if kind == "ignite" and float(_hold_rule.get("hold", 0.0)) > 1.0:
			# one soft rub per stroke of the bow
			_repeat_t -= delta
			if _repeat_t <= 0.0:
				_repeat_t = 0.35
				Sfx.play("bow_drill", target.get("point", player.global_position), -12.0, 1.0, 0.1)
		if _hold_t >= _hold_need:
			_finish_hold()
		return
	var kind2 := String(rmb_rule.get("kind", ""))
	if _again:
		_again = false
		if held and (kind2 == "eat" or kind2 == "drink"):
			_start(rmb_rule)
			return
	if pressed:
		_repeat_t = float(rmb_rule.get("repeat", 0.0))
		# holding repeats only what you pressed for: starting a fire pit doesn't
		# run straight on into adding sticks to it
		_repeat_ok = rmb_rule.has("repeat")
		_start(rmb_rule)
	elif held:
		if kind2 == "use" and rmb_rule.has("repeat") and _repeat_ok:
			_repeat_t -= delta
			if _repeat_t <= 0.0:
				_repeat_t = float(rmb_rule["repeat"])
				_start(rmb_rule)
		elif kind2 == "clay_add":
			_repeat_t -= delta
			if _repeat_t <= 0.0:
				_start(rmb_rule)


func _same_target(t: Dictionary) -> bool:
	if String(t.get("type", "")) != String(target.get("type", "")):
		return String(_hold_rule.get("kind", "")) == "eat"
	return t.get("cell", null) == target.get("cell", null) or String(_hold_rule.get("kind", "")) == "eat"


func _start(r: Dictionary) -> void:
	var kind := String(r.get("kind", ""))
	match kind:
		"use":
			World.request("use", {"c": target["cell"], "face": target["normal"], "slot": player.hotbar, "sneak": Input.is_action_pressed("sneak")})
			player.play_action("swing")
		"clay_add":
			var cells := brush_cells(target, true)
			if not cells.is_empty():
				World.request("clay", {"c": target["cell"], "cells": cells, "add": true})
				player.play_action("swing")
				Sfx.play("clay_slap", target["point"], -6.0)
			_repeat_t = 0.16
		"eat", "drink", "ignite":
			_hold_rule = r
			_hold_target = target.duplicate()
			_hold_need = float(r.get("hold", 1.0))
			_hold_t = 0.0
			_repeat_t = 0.0
			player.play_action("drill" if kind == "ignite" else "eat")
		"sleep":
			player.lie_down(target["cell"])
		"satchel":
			World.request("satchel", {"eid": int(target["eid"])})


func _finish_hold() -> void:
	var kind := String(_hold_rule.get("kind", ""))
	var t := _hold_target
	match kind:
		"eat":
			World.request("eat", {"slot": player.hotbar})
			Sfx.play("eat", player.global_position + Vector3(0, 1.5, 0), -4.0)
		"drink":
			World.request("drink", {"c": t["cell"]})
			Sfx.play("drink", player.global_position + Vector3(0, 1.5, 0), -4.0)
		"ignite":
			World.request("ignite", {"c": t["cell"], "slot": player.hotbar})
	# keep the button held and you keep eating / drinking, one after another
	_again = (kind == "drink" or kind == "eat") and Input.is_action_pressed("secondary")
	cancel()
