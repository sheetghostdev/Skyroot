class_name GroundView
extends EntityView
## Things left lying on the ground: up to four stacks, one per corner, each a
## little pile of solid models; pots and jars stand in the middle.  After a pit
## kiln, a bed of ash.

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
	## Each stack in its own corner (pots and jars in the middle), as a pile of
	## solid models; things with no model lie flat as their icon.
	var spot := 0
	for s in items:
		var id := String(s["i"])
		var d: Dictionary = s.get("d", {})
		var b := ItemDB.block_of(id)
		var is_block := b >= 0 and Blocks.shape[b] == Blocks.Shape.CUBE
		var big := id in ["pot", "pot_raw", "jar", "jar_raw"]
		var at: Vector2 = Vector2(0.5, 0.5) if big else SPOTS[spot % 4]
		spot += 2 if id in ["pot", "pot_raw"] else (4 if big else 1)
		var n := int(s["n"])
		var spin := float(spot) * 1.3
		var m := ItemModels.mesh(id, d)
		if m:
			var base := Transform3D(Basis(Vector3.UP, spin), Vector3(at.x, 0.0, at.y))
			for xf in ItemModels.pile(id, n, d):
				var mi := MeshInstance3D.new()
				mi.mesh = m
				mi.transform = base * (xf as Transform3D)
				parent.add_child(mi)
			continue
		var shown := 1 if n == 1 else mini(3, 1 + n / 6)
		for k in shown:
			var mi := MeshInstance3D.new()
			mi.mesh = Icons.mesh(id, d)
			if is_block:
				mi.scale = Vector3.ONE * 0.3
				mi.position = Vector3(at.x, 0.15 + k * 0.3, at.y)
			else:
				mi.scale = Vector3.ONE * 0.4
				mi.position = Vector3(at.x, 0.012 + k * 0.03, at.y)
				mi.rotation = Vector3(-PI * 0.5, 0.0, k * 0.7 + spot)
			parent.add_child(mi)
