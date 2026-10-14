extends Node
## Automated looks at the game, for development: starts a world (main.gd's
## --autostart), sets up a scene, saves a screenshot and quits.
##
##   --shot=out.png       screenshot path
##   --pos=x,y,z          put the player here       --yaw=deg --pitch=deg
##   --hour=h             time of day               --tp  third person
##   --give=id:n,id:n     items in the hotbar       --slot=n  select hotbar slot
##   --setup=name         a staged scene (firepit, firepit_lit, knap, clay, kiln, kiln_lit, ground, inventory, handbook, chooser, night, rain)
##   --smoke=secs         just run for a while, then quit
##   --perf=secs          print frame time stats

var _t := 0.0
var _phase := 0
var _frames := 0
var _times: Array = []


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func _cli(k: String, def: String = "") -> String:
	return String(Game.cli.get(k, def))


func _vec(s: String) -> Vector3:
	var p := s.split(",")
	return Vector3(float(p[0]), float(p[1]), float(p[2])) if p.size() == 3 else Vector3.ZERO


func _process(delta: float) -> void:
	_t += delta
	if Game.state == "menu" and Game.cli.has("menu"):
		if _t > float(_cli("menu", "6")) and _phase == 0:
			_phase = 2
			_shoot()
		return
	if Game.state != "playing":
		return
	var gw = Game.game_world
	if gw == null:
		return
	var lp: LocalPlayer = gw.local_player()
	if lp == null:
		return
	match _phase:
		0:
			_phase = 1
			_t = 0.0
			if Game.cli.has("hour"):
				World.env["t"] = 24.0 + float(_cli("hour"))
			if _cli("setup") == "rain":
				World.env["rain"] = 1.0
				World.env["rain_target"] = 1.0
				World.env["cloud"] = 1.0
			Events.env_changed.emit()
			if Game.cli.has("give"):
				var inv := World.inventory_of(Net.my_id())
				var slot := 0
				for spec in _cli("give").split(","):
					var kv := spec.split(":")
					var id := kv[0]
					var n := int(kv[1]) if kv.size() > 1 else 1
					var d := {}
					if not ItemDB.tool_info(id).is_empty() or ItemDB.def(id).get("part", false):
						d = {"mat": "flint"}
						if not ItemDB.tool_info(id).is_empty():
							d["dur"] = ItemDB.max_durability(id, d)
					inv.set_slot(slot, Inventory.make(id, n, d))
					slot += 1
				World.mark_inventory(Net.my_id())
			if Game.cli.has("pos"):
				lp.respawn_at(_vec(_cli("pos")), deg_to_rad(float(_cli("yaw", "0"))))
				lp.pitch = deg_to_rad(float(_cli("pitch", "0")))
			if Game.cli.has("tp"):
				lp.set_third_person(true)
			if Game.cli.has("slot"):
				lp.select_hotbar(int(_cli("slot")))
			_setup(_cli("setup"), lp, gw)
		1:
			if Game.cli.has("smoke"):
				if _t > float(_cli("smoke", "10")):
					print("SMOKE_OK")
					get_tree().quit(0)
				return
			if Game.cli.has("perf"):
				_times.append(delta)
				if _t > float(_cli("perf", "10")):
					_times.sort()
					var avg := 0.0
					for x in _times:
						avg += x
					avg /= maxf(1.0, _times.size())
					print("PERF avg %.1f ms  p95 %.1f ms  max %.1f ms  frames %d" % [avg * 1000.0, _times[int(_times.size() * 0.95)] * 1000.0, _times[_times.size() - 1] * 1000.0, _times.size()])
					get_tree().quit(0)
				return
			# wait for the chunks to be meshed, then a few frames for the picture to settle
			if gw.voxels.pending() > 0 and _t < 30.0:
				return
			_frames += 1
			if _frames < int(_cli("frames", "40")):
				return
			_phase = 2
			_shoot()


func _shoot() -> void:
	var path := _cli("shot", "user://shot.png")
	var img := get_viewport().get_texture().get_image()
	img.save_png(path)
	print("SHOT_SAVED ", path)
	get_tree().quit(0)


func _setup(nm: String, lp: LocalPlayer, gw) -> void:
	var a: Actions = World.actions
	var pid := Net.my_id()
	var front := lp.global_position + Vector3(-sin(lp.yaw), 0, -cos(lp.yaw)) * 1.6
	var c := VoxelData.cell_of(front + Vector3(0, 0.2, 0))
	# find the ground there
	var y := World.vox.surface_y(c.x, c.z)
	c.y = y + 1
	if World.block(c) != 0:
		World.set_block(c, 0)
	match nm:
		"firepit", "firepit_lit", "firepit_cook":
			var lit := nm != "firepit"
			World.spawn_be("firepit", c, {"tinder": 2, "sticks": 6, "logs": 2 if lit else 0, "tf": 0.24, "sf": 6 * FireActs.STICK_H, "lf": 2 * FireActs.LOG_H,
				"lit": lit, "ash": false, "food": [{"i": "mushroom", "t": 0.0, "cs": 22.0, "done": false}, {"i": "turnip_roasted", "t": 0.0, "cs": 30.0, "done": true}] if nm == "firepit_cook" else [],
				"pot": {}, "heat": 1.0 if lit else 0.0, "phase": "logs" if lit else "", "caught": true})
		"firepit_x":
			for n in [1, 2, 4, 8]:
				var cc := c + Vector3i((n - 4) / 2 * 2, 0, 0)
				cc.y = World.vox.surface_y(cc.x, cc.z) + 1
				World.spawn_be("firepit", cc, {"tinder": 1 if n > 2 else 0, "sticks": n, "logs": 0, "tf": 0.12, "sf": n * FireActs.STICK_H, "lf": 0.0,
					"lit": false, "ash": false, "food": [], "pot": {}, "heat": 0.0, "phase": ""})
		"knap":
			var cells := ItemDB.stone_mask.duplicate()
			var mask: PackedByteArray = ItemDB.knapping["axe_head"]["mask"]
			for i in 256:
				if cells[i] == 1 and mask[i] == 0 and i % 16 < 6:
					cells[i] = 0
			World.spawn_be("knap", c, {"mat": "flint", "r": "axe_head", "cells": cells, "miss": 0})
		"clay":
			var r := "pot"
			var layers: Array = ItemDB.clayforming[r]["layers"]
			var vox := PackedByteArray()
			vox.resize(256 * layers.size())
			for l in 2:
				for i in 256:
					vox[l * 256 + i] = layers[l][i]
			for i in 256:
				if layers[2][i] == 1 and i % 16 < 9:
					vox[2 * 256 + i] = 1
			World.spawn_be("clay", c, {"r": r, "vox": vox, "layer": 2, "budget": 20, "lumps": 8})
		"kiln", "kiln_lit":
			World.set_block(c + Vector3i.DOWN, 0)
			World.spawn_be("kiln", c + Vector3i.DOWN, {"items": [Inventory.make("bowl_raw", 2), Inventory.make("pot_raw", 1)], "grass": 4 if nm == "kiln_lit" else 2,
				"sticks": 6 if nm == "kiln_lit" else 0, "lit": nm == "kiln_lit", "t": 0.5, "stage": 1 if nm == "kiln_lit" else 0, "enc": 4})
		"ground":
			World.spawn_be("ground", c, {"items": [Inventory.make("bowl", 1), Inventory.make("stick", 5), Inventory.make("berries", 3)]})
		"items":
			for i in 6:
				a.drop_item(["stone", "stick", "flint", "berries", "log_oak", "knife"][i], 1 + i, {"mat": "flint"} if i == 5 else {}, front + Vector3(i * 0.4 - 1.0, 0.5, 0))
		"inventory":
			gw.hud.open_panel("inventory")
		"handbook":
			gw.hud.open_panel("handbook")
		"chooser":
			World.spawn_be("knap", c, {"mat": "stone", "r": "", "cells": ItemDB.stone_mask.duplicate(), "miss": 0})
			gw.hud.open_panel("chooser", ["knap", c])
		"clay_chooser":
			gw.hud.open_panel("chooser", ["clay", c])
