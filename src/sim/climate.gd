class_name Climate
extends RefCounted
## Air temperature where you stand: time of day, weather, wind exposure,
## shelter and the warmth of nearby fires.


static func base_temp() -> float:
	var h := World.hour_of_day()
	# warmest mid-afternoon, coldest before dawn
	var daily := 13.0 + 8.0 * cos((h - 15.0) / 24.0 * TAU)
	daily -= float(World.env.get("rain", 0.0)) * 4.0
	daily -= float(World.env.get("cloud", 0.0)) * 1.5 * (1.0 if not World.is_night() else -0.6)
	return daily


static func temp_at(world3d: World3D, pos: Vector3, fires: Array = []) -> Dictionary:
	var t := base_temp()
	var wind: Vector2 = World.env.get("wind", Vector2(1, 0.3))
	var roof := Shelter.roof_above(world3d, pos + Vector3(0, 1.4, 0))
	var walls := Shelter.wall_cover(world3d, pos + Vector3(0, 1.0, 0))
	var exposure := clampf(1.0 - walls * 0.8, 0.0, 1.0)
	t -= wind.length() * 0.6 * exposure
	if roof:
		t += 2.5 + walls * 2.5
	var heat := 0.0
	for f in fires:
		var fp: Vector3 = f["pos"]
		var kw: float = f["kw"]
		var d2 := fp.distance_squared_to(pos)
		heat += kw / (d2 + 1.2)
	t += heat * 1.6
	var rain := float(World.env.get("rain", 0.0))
	return {"temp": t, "roof": roof, "walls": walls, "wet": rain > 0.2 and not roof, "fire_heat": heat}
