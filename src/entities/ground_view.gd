class_name GroundView
extends EntityView
## Things left lying on the ground: up to four stacks, one per corner, laid
## flat; pots and jars stand up in the middle.  After a pit kiln, a bed of ash.

const SPOTS := [Vector2(0.28, 0.28), Vector2(0.72, 0.3), Vector2(0.3, 0.72), Vector2(0.72, 0.72)]

var root: Node3D
var ash: MeshInstance3D


func _build() -> void:
	root = Node3D.new()
	add_child(root)
	ash = add_mesh(boxes_mesh([[Vector3(0.1, 0.0, 0.1), Vector3(0.9, 0.025, 0.9), "ash"]]))


func _refresh(_keys: Array) -> void:
	for ch in root.get_children():
		ch.queue_free()
	place_items(root, data().get("items", []))
	ash.visible = bool(data().get("ash", false))


static func place_items(parent: Node3D, items: Array) -> void:
	var spot := 0
	for s in items:
		var id := String(s["i"])
		var upright := id in ["pot", "pot_raw", "jar", "jar_raw", "bowl", "bowl_raw"]
		var b := ItemDB.block_of(id)
		var is_block := b >= 0 and Blocks.shape[b] == Blocks.Shape.CUBE
		var big := id in ["pot", "pot_raw", "jar", "jar_raw"]
		var at: Vector2 = Vector2(0.5, 0.5) if big else SPOTS[spot % 4]
		spot += 2 if id in ["pot", "pot_raw"] else (4 if big else 1)
		var n := 1 if int(s["n"]) == 1 else mini(3, 1 + int(s["n"]) / 6)
		for k in n:
			var mi := MeshInstance3D.new()
			mi.mesh = Icons.mesh(id, s.get("d", {}))
			if is_block:
				mi.scale = Vector3.ONE * 0.3
				mi.position = Vector3(at.x, 0.15 + k * 0.3, at.y)
			elif upright:
				var sc := 0.62 if big else 0.42
				mi.scale = Vector3.ONE * sc
				mi.position = Vector3(at.x, sc * 0.5 - 0.02, at.y)
				mi.rotation.y = 0.4
				# a crossed copy, so it looks round
				var mi2 := MeshInstance3D.new()
				mi2.mesh = mi.mesh
				mi2.scale = mi.scale
				mi2.position = mi.position
				mi2.rotation.y = 0.4 + PI * 0.5
				parent.add_child(mi2)
			else:
				mi.scale = Vector3.ONE * 0.4
				mi.position = Vector3(at.x, 0.012 + k * 0.03, at.y)
				mi.rotation = Vector3(-PI * 0.5, 0.0, k * 0.7 + spot)
			parent.add_child(mi)
