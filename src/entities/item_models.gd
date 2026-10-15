class_name ItemModels
extends RefCounted
## Small solid models of items, built from textured boxes like the rest of the
## world, at their real size (block units, origin at the bottom centre): what
## lies on the ground or in a kiln pit, bobs in a stew pot, roasts on a spit,
## or has been dropped.  Round pottery is made of octagonal rings.  Items with
## no model here (tools, knapped heads...) fall back to the extruded icon.
##
## pile() lays out a stack the way such things lie: sticks and firewood in
## crossing layers, stones and berries in a heap, bowls nested, bricks stacked.

const FIRED := "terracotta"
const RAW := "clay_raw"


static func has(id: String) -> bool:
	return _build(id, {}).size() > 0


static func mesh(id: String, d: Dictionary = {}) -> Mesh:
	var key := "im:%s:%s" % [id, _variant(id, d)]
	return EntityModels.get_or_build(key, func():
		var boxes := _build(id, d)
		if boxes.is_empty():
			return null
		var lin: Array = []
		for b in boxes:
			var tint: Color = b[3] if b.size() > 3 else Color.WHITE
			var l := tint.srgb_to_linear()
			lin.append([b[0], b[1], b[2], Color(l.r, l.g, l.b, 1.0), b[4] if b.size() > 4 else 0.0])
		return EntityView.boxes_mesh(lin))


static func node(id: String, d: Dictionary = {}) -> Node3D:
	## A ready MeshInstance3D: the model if there is one, else the item's icon
	## lying flat at a sensible size.
	var mi := MeshInstance3D.new()
	var m := mesh(id, d)
	if m:
		mi.mesh = m
	else:
		mi.mesh = Icons.mesh(id, d)
		mi.scale = Vector3.ONE * 0.4
		mi.rotation.x = -PI * 0.5
		mi.position.y = 0.012
	var n := Node3D.new()
	n.add_child(mi)
	return n


static func _variant(id: String, d: Dictionary) -> String:
	match id:
		"bowl":
			return String(d.get("c", ""))
		"pot":
			return "w" if int(d.get("w", 0)) > 0 else ("s" if int(d.get("stew", 0)) > 0 else "")
		"jar":
			return "full" if not (d.get("inv", []) as Array).is_empty() else ""
	return ""


# ---------------------------------------------------------------------------
# Shapes
# ---------------------------------------------------------------------------

static func _disk(out: Array, y0: float, y1: float, r: float, tex: String, tint := Color.WHITE) -> void:
	## An octagonal slab (corners at radius r): four bars across it, a
	## quarter-turn apart by eighths, whose union is exactly the octagon.
	var h := r * 0.924
	var a := h * tan(PI / 8.0)
	for k in 4:
		out.append([Vector3(-h, y0, -a), Vector3(h, y1, a), tex, tint, k * PI / 4.0])


static func _ring(out: Array, y0: float, y1: float, r: float, t: float, tex: String, tint := Color.WHITE) -> void:
	## An octagonal wall, outer radius r, thickness t.
	var seg := 2.0 * r * tan(PI / 8.0) + 0.004
	for k in 8:
		var a := k * PI / 4.0
		var c := Vector3(sin(a), 0, cos(a)) * (r - t * 0.5)
		out.append([c + Vector3(-seg * 0.5, y0, -t * 0.5), c + Vector3(seg * 0.5, y1, t * 0.5), tex, tint, a])


static func _box(out: Array, a: Vector3, b: Vector3, tex: String, tint := Color.WHITE, rot := 0.0) -> void:
	out.append([a, b, tex, tint, rot])


static func _build(id: String, d: Dictionary) -> Array:
	var o: Array = []
	match id:
		"bowl", "bowl_raw":
			var tex := FIRED if id == "bowl" else RAW
			_disk(o, 0.0, 0.03, 0.11, tex)
			_ring(o, 0.02, 0.08, 0.15, 0.035, tex)
			_ring(o, 0.08, 0.13, 0.175, 0.03, tex)
			match String(d.get("c", "")):
				"water":
					_disk(o, 0.03, 0.08, 0.12, "water")
					_disk(o, 0.08, 0.105, 0.155, "water")
				"stew":
					_disk(o, 0.03, 0.08, 0.12, "dirt", Color(1.15, 0.85, 0.55))
					_disk(o, 0.08, 0.11, 0.155, "dirt", Color(1.15, 0.85, 0.55))
		"pot", "pot_raw":
			var tex := FIRED if id == "pot" else RAW
			_disk(o, 0.0, 0.04, 0.17, tex)
			_ring(o, 0.03, 0.1, 0.2, 0.045, tex)
			_ring(o, 0.1, 0.3, 0.225, 0.045, tex)
			_ring(o, 0.3, 0.36, 0.205, 0.04, tex)
			_ring(o, 0.36, 0.4, 0.225, 0.035, tex, Color(0.92, 0.9, 0.88))
			if int(d.get("w", 0)) > 0:
				_disk(o, 0.26, 0.32, 0.175, "water")
			elif int(d.get("stew", 0)) > 0:
				_disk(o, 0.26, 0.33, 0.175, "dirt", Color(1.15, 0.85, 0.55))
		"jar", "jar_raw":
			var tex := FIRED if id == "jar" else RAW
			_disk(o, 0.0, 0.04, 0.15, tex)
			_ring(o, 0.03, 0.12, 0.18, 0.04, tex)
			_ring(o, 0.12, 0.38, 0.205, 0.04, tex)
			_ring(o, 0.38, 0.46, 0.17, 0.04, tex)
			_disk(o, 0.42, 0.46, 0.15, tex)
			_ring(o, 0.46, 0.53, 0.11, 0.035, tex)
			_ring(o, 0.53, 0.56, 0.13, 0.03, tex, Color(0.92, 0.9, 0.88))
			if not (d.get("inv", []) as Array).is_empty():
				# something in it: a wooden lid on top
				_disk(o, 0.53, 0.57, 0.12, "planks")
				_box(o, Vector3(-0.025, 0.57, -0.025), Vector3(0.025, 0.6, 0.025), "planks")
		"brick", "brick_raw":
			_box(o, Vector3(-0.13, 0, -0.065), Vector3(0.13, 0.085, 0.065), FIRED if id == "brick" else RAW)
		"potsherd":
			_box(o, Vector3(-0.09, 0, -0.05), Vector3(0.05, 0.025, 0.05), FIRED, Color.WHITE, 0.4)
			_box(o, Vector3(0.0, 0, -0.03), Vector3(0.1, 0.02, 0.07), FIRED, Color(0.9, 0.88, 0.85), -0.7)
		"stone":
			_box(o, Vector3(-0.08, 0, -0.065), Vector3(0.08, 0.085, 0.07), "stone")
			_box(o, Vector3(-0.05, 0.05, -0.05), Vector3(0.06, 0.11, 0.04), "stone", Color(1.05, 1.05, 1.05), 0.5)
		"flint":
			_box(o, Vector3(-0.075, 0, -0.05), Vector3(0.07, 0.07, 0.06), "flint")
			_box(o, Vector3(-0.04, 0.04, -0.04), Vector3(0.04, 0.095, 0.035), "flint", Color(1.1, 1.1, 1.15), 0.6)
		"clay":
			_box(o, Vector3(-0.075, 0, -0.065), Vector3(0.075, 0.08, 0.065), "clay")
			_box(o, Vector3(-0.05, 0.05, -0.045), Vector3(0.045, 0.11, 0.05), "clay", Color(1.04, 1.04, 1.04), 0.45)
		"stick":
			_box(o, Vector3(-0.31, 0, -0.022), Vector3(0.31, 0.044, 0.022), "stick")
			_box(o, Vector3(0.06, 0.005, 0.0), Vector3(0.2, 0.03, 0.02), "stick", Color(0.95, 0.95, 0.95), -0.5)
		"firewood":
			_box(o, Vector3(-0.25, 0, -0.065), Vector3(0.25, 0.12, 0.065), "firewood")
		"dry_grass", "plant_fiber":
			var tint := Color.WHITE if id == "dry_grass" else Color(0.7, 0.95, 0.55)
			_box(o, Vector3(-0.2, 0, -0.045), Vector3(0.2, 0.04, 0.045), "dry_grass", tint, 0.08)
			_box(o, Vector3(-0.19, 0.03, -0.035), Vector3(0.21, 0.065, 0.035), "dry_grass", tint * 1.05, -0.12)
			_box(o, Vector3(-0.025, -0.002, -0.05), Vector3(0.025, 0.07, 0.05), "dry_grass", Color(0.65, 0.5, 0.35))
		"twine":
			_ring(o, 0.0, 0.025, 0.085, 0.025, "dry_grass", Color(0.85, 0.7, 0.5))
			_ring(o, 0.022, 0.045, 0.075, 0.022, "dry_grass", Color(0.8, 0.65, 0.45))
		"berries":
			for p in [Vector3(0, 0, 0), Vector3(0.05, 0, 0.02), Vector3(0.02, 0, -0.045), Vector3(0.025, 0.035, -0.005)]:
				_box(o, p + Vector3(-0.022, 0, -0.022), p + Vector3(0.022, 0.044, 0.022), "cloth", Color(0.3, 0.36, 0.78))
		"mushroom", "mushroom_roasted":
			var roast := id == "mushroom_roasted"
			_box(o, Vector3(-0.022, 0, -0.022), Vector3(0.022, 0.07, 0.022), "cloth", Color(0.75, 0.6, 0.45) if roast else Color(0.95, 0.92, 0.85))
			_box(o, Vector3(-0.065, 0.055, -0.065), Vector3(0.065, 0.1, 0.065), "cloth", Color(0.5, 0.33, 0.2) if roast else Color(0.78, 0.6, 0.45))
		"turnip":
			_box(o, Vector3(-0.015, 0, -0.015), Vector3(0.015, 0.02, 0.015), "cloth", Color(0.9, 0.88, 0.82))
			_box(o, Vector3(-0.055, 0.015, -0.055), Vector3(0.055, 0.07, 0.055), "cloth", Color(0.95, 0.93, 0.88))
			_box(o, Vector3(-0.06, 0.065, -0.06), Vector3(0.06, 0.11, 0.06), "cloth", Color(0.62, 0.32, 0.62))
			_box(o, Vector3(-0.012, 0.1, -0.05), Vector3(0.012, 0.2, 0.0), "grass_top", Color(0.85, 1.0, 0.8), 0.3)
			_box(o, Vector3(-0.012, 0.1, 0.0), Vector3(0.012, 0.18, 0.05), "grass_top", Color(0.85, 1.0, 0.8), -0.4)
		"turnip_roasted":
			_box(o, Vector3(-0.055, 0, -0.055), Vector3(0.055, 0.06, 0.055), "cloth", Color(0.95, 0.72, 0.42))
			_box(o, Vector3(-0.058, 0.055, -0.058), Vector3(0.058, 0.1, 0.058), "cloth", Color(0.78, 0.48, 0.3))
		"cattail_root", "cattail_roasted":
			var tint := Color(0.85, 0.74, 0.55) if id == "cattail_root" else Color(0.68, 0.48, 0.3)
			_box(o, Vector3(-0.15, 0, -0.025), Vector3(0.15, 0.05, 0.025), "cloth", tint)
			_box(o, Vector3(-0.05, 0.0, 0.02), Vector3(0.0, 0.015, 0.07), "cloth", tint * 0.9, 0.3)
		"charred_food":
			_box(o, Vector3(-0.06, 0, -0.05), Vector3(0.06, 0.07, 0.05), "charred")
		"seeds_turnip", "seeds_flax":
			var tint := Color(0.45, 0.32, 0.25) if id == "seeds_turnip" else Color(0.75, 0.62, 0.38)
			for p in [Vector3(0, 0, 0), Vector3(0.025, 0, 0.012), Vector3(-0.02, 0, 0.02), Vector3(0.008, 0.012, -0.02), Vector3(-0.012, 0, -0.018)]:
				_box(o, p + Vector3(-0.009, 0, -0.007), p + Vector3(0.009, 0.012, 0.007), "cloth", tint, p.x * 20.0)
		"torch", "torch_lit":
			_box(o, Vector3(-0.2, 0, -0.025), Vector3(0.18, 0.05, 0.025), "stick")
			_box(o, Vector3(0.16, 0, -0.04), Vector3(0.28, 0.08, 0.04), "torch_head" if id == "torch_lit" else "dry_grass")
	return o


# ---------------------------------------------------------------------------
# Piles
# ---------------------------------------------------------------------------

const LONG := ["stick", "firewood", "dry_grass", "plant_fiber", "cattail_root", "cattail_roasted", "torch", "torch_lit"]
const NEST := ["bowl", "bowl_raw"]
const STACK := ["brick", "brick_raw"]


static func pile(id: String, n: int, d: Dictionary = {}) -> Array:
	## Transforms for a stack of n of this item lying on the ground (origin at
	## the centre of its spot): [Transform3D, ...].
	var out: Array = []
	var m := mesh(id, d)
	var size := m.get_aabb().size if m else Vector3(0.2, 0.03, 0.2)
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(id)
	if id in LONG:
		# crossing layers, two to a layer, like a little woodpile
		var show := mini(n, 8 if id == "stick" else 6)
		for i in show:
			var layer := i / 2
			var ang := (0.0 if layer % 2 == 0 else PI * 0.5) + rng.randf_range(-0.14, 0.14)
			var off := (float(i % 2) - 0.5) * size.z * 1.6 if show > 1 else 0.0
			var b := Basis(Vector3.UP, ang)
			out.append(Transform3D(b, b * Vector3(0, 0, off) + Vector3(0, layer * size.y * 0.92, 0)))
	elif id in NEST:
		for i in mini(n, 6):
			out.append(Transform3D(Basis(Vector3.UP, i * 0.4), Vector3(0, i * 0.035, 0)))
	elif id in STACK:
		for i in mini(n, 8):
			var layer := i / 2
			var ang := 0.0 if layer % 2 == 0 else PI * 0.5
			var b := Basis(Vector3.UP, ang)
			out.append(Transform3D(b, b * Vector3(0, 0, (float(i % 2) - 0.5) * size.z * 1.05) + Vector3(0, layer * size.y, 0)))
	else:
		# a heap: a ring on the ground, the rest on top
		var show := mini(n, 7)
		var r := maxf(size.x, size.z) * 0.62
		for i in show:
			if i == 0 and show == 1:
				out.append(Transform3D(Basis(Vector3.UP, rng.randf() * TAU), Vector3.ZERO))
				continue
			var on_top := i >= 5
			var a := i * TAU / 5.0 + rng.randf_range(-0.3, 0.3)
			var p := Vector3(sin(a), 0, cos(a)) * (r * (0.3 if on_top else 1.0))
			p.y = size.y * 0.85 if on_top else 0.0
			out.append(Transform3D(Basis(Vector3.UP, rng.randf() * TAU), p))
	return out
