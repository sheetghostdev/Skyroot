class_name Climate
extends RefCounted
## Air temperature where you stand: time of day, weather, wind, shelter and the
## warmth of nearby fires.  Shelter is read from the blocks: a roof overhead
## and walls around keep the wind and the night sky off you.


static func base_temp() -> float:
	var h := World.hour_of_day()
	# warmest mid-afternoon (about 21 C), coldest before dawn (about 3 C)
	var daily := 12.0 + 9.0 * cos((h - 15.0) / 24.0 * TAU)
	daily -= float(World.env.get("rain", 0.0)) * 4.0
	daily -= float(World.env.get("cloud", 0.0)) * 1.5 * (1.0 if not World.is_night() else -0.6)
	return daily


static func roof_over(p: Vector3) -> bool:
	return not World.vox.open_to_sky(VoxelData.cell_of(p + Vector3(0, 1.0, 0)))


static func wall_cover(p: Vector3) -> float:
	## 0..1: how walled in this spot is (solid blocks within 4 in eight directions).
	var c := VoxelData.cell_of(p + Vector3(0, 0.8, 0))
	var hits := 0
	for dir in [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1),
			Vector3i(1, 0, 1), Vector3i(-1, 0, 1), Vector3i(1, 0, -1), Vector3i(-1, 0, -1)]:
		for i in range(1, 5):
			if Blocks.is_opaque(World.block(c + dir * i)):
				hits += 1
				break
	return hits / 8.0


static func temp_at(pos: Vector3, fires: Array = []) -> Dictionary:
	var t := base_temp()
	var wind: Vector2 = World.env.get("wind", Vector2(1, 0.3))
	var roof := roof_over(pos)
	var walls := wall_cover(pos)
	t -= wind.length() * 0.7 * (1.0 - walls * 0.85)
	if roof:
		t += 2.0 + walls * 4.0
	# a log fire warms you by ~12 C a step or two away, ~5 C at three blocks
	var heat := 0.0
	for f in fires:
		var fp: Vector3 = f["pos"]
		var d2 := fp.distance_squared_to(pos + Vector3(0, 0.6, 0))
		heat += float(f["kw"]) * 22.0 / (1.0 + d2 * 0.35)
	heat = minf(heat, 25.0)
	t += heat
	var rain := float(World.env.get("rain", 0.0))
	return {"temp": t, "roof": roof, "walls": walls, "wet": rain > 0.25 and not roof, "fire_heat": heat}
