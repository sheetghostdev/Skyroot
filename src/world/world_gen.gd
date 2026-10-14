class_name WorldGen
extends RefCounted
## The hand-authored starting island: everything the players will ever have is
## placed here (plus what the terrain layers hold).  Nothing is ever added from
## outside afterwards.

const LOOSE_STONES := [Vector2(2.2, 2.0), Vector2(3.7, 2.4), Vector2(-1.0, 3.5), Vector2(5.1, -1.7),
	Vector2(-6.1, 0.0), Vector2(0.9, 4.7), Vector2(-3.4, -3.3)]
const TWIGS := [Vector2(0.2, -0.6), Vector2(2.3, -0.9), Vector2(1.9, -2.9), Vector2(-0.3, -2.3), Vector2(0.6, -3.2), Vector2(2.9, -1.6)]
const STICKS := [Vector2(-0.5, -1.0), Vector2(2.6, -0.4)]
const WILD_FIBER := [Vector2(-5.7, 1.7), Vector2(-4.6, 2.4), Vector2(-2.5, -0.7), Vector2(-5.3, -0.7)]
const WILD_TUBER := [Vector2(2.7, -3.0), Vector2(-0.4, -2.8)]
const BOULDERS := [[Vector2(6.5, 3.3), "a", 0.4], [Vector2(-7.0, 3.3), "b", 2.0], [Vector2(3.7, -5.1), "c", 4.1]]


static func ground_xf(t: TerrainData, p: Vector2, yaw: float = 0.0, lift: float = 0.0) -> Transform3D:
	return Transform3D(Basis(Vector3.UP, yaw), Vector3(p.x, t.height(p.x, p.y) + lift, p.y))


static func initial_entities(t: TerrainData) -> Array:
	## Returns entity descriptors [{t, xf, d}] for a brand new island.
	var out: Array = []
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261014
	out.append({"t": "tree", "xf": ground_xf(t, TerrainData.TREE_POS, 0.4, -0.05), "d": TreeSim.new_state()})
	out.append({"t": "outcrop", "xf": ground_xf(t, TerrainData.OUTCROP_POS, 2.6, -0.25), "d": {"loose": [1, 1, 1, 1, 1, 1, 1, 1]}})
	out.append({"t": "flat_stone", "xf": ground_xf(t, TerrainData.FLAT_STONE_POS, 0.3, -0.06), "d": {}})
	for b in BOULDERS:
		out.append({"t": "boulder", "xf": ground_xf(t, b[0], b[2], -0.12), "d": {"model": b[1]}})
	out.append({"t": "mossy_log", "xf": ground_xf(t, Vector2(-0.9, -4.5), 0.35, -0.04), "d": {}})
	out.append({"t": "mushrooms", "xf": ground_xf(t, Vector2(-0.35, -4.15), 0.9, 0.0), "d": {"caps": [1.0, 1.0, 1.0, 0.6], "substrate": 6.0, "nutr": 0.04}})
	out.append({"t": "bush", "xf": ground_xf(t, Vector2(-5.9, -2.7), 1.3, -0.03), "d": {"berries": 1.0, "biomass": 6.0}})
	out.append({"t": "plant", "xf": ground_xf(t, Vector2(5.35, 0.15), 0.0, -0.02),
		"d": {"sp": "grain", "g": 1.0, "wild": true, "perennial": true, "protected": true, "nutr": 0.012, "bio": 1.0}})
	for p in WILD_FIBER:
		out.append({"t": "plant", "xf": ground_xf(t, p, rng.randf() * TAU, -0.02),
			"d": {"sp": "fiber", "g": rng.randf_range(0.82, 1.0), "wild": true, "perennial": true, "nutr": 0.008, "bio": 0.6}})
	for p in WILD_TUBER:
		out.append({"t": "plant", "xf": ground_xf(t, p, rng.randf() * TAU, -0.02),
			"d": {"sp": "tuber", "g": 1.0, "wild": true, "perennial": true, "nutr": 0.016, "bio": 1.6}})
	for p in LOOSE_STONES:
		out.append({"t": "item", "xf": _item_xf(t, p, rng, 0.04), "d": {"i": "stone", "n": 1, "x": {}}})
	for p in TWIGS:
		out.append({"t": "item", "xf": _item_xf(t, p, rng, 0.015), "d": {"i": "twig", "n": 1, "x": {"moist": 0.1}}})
	for p in STICKS:
		out.append({"t": "item", "xf": _item_xf(t, p, rng, 0.02), "d": {"i": "stick", "n": 1, "x": {"moist": 0.15}}})
	return out


static func _item_xf(t: TerrainData, p: Vector2, rng: RandomNumberGenerator, lift: float) -> Transform3D:
	var n := t.normal_at(p.x, p.y)
	var yaw := rng.randf() * TAU
	var b := Basis(Vector3.UP, yaw)
	var tilt := Vector3.UP.cross(n)
	if tilt.length() > 0.001:
		b = Basis(tilt.normalized(), Vector3.UP.angle_to(n)) * b
	return Transform3D(b, Vector3(p.x, t.height(p.x, p.y) + lift, p.y))


static func populate() -> void:
	## Host: spawn the initial island content into the World.
	for e in initial_entities(World.terrain):
		World.spawn(e["t"], e["xf"], e["d"])
