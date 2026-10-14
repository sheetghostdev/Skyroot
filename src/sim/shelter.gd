class_name Shelter
extends RefCounted
## Cheap physical shelter tests: is there a roof overhead, how enclosed is it.


static func roof_above(world3d: World3D, pos: Vector3, height: float = 5.0) -> bool:
	if world3d == null:
		return false
	var space := world3d.direct_space_state
	var q := PhysicsRayQueryParameters3D.create(pos, pos + Vector3(0, height, 0), EntityView.LAYER_STRUCT)
	var hit := space.intersect_ray(q)
	return not hit.is_empty()


static func wall_cover(world3d: World3D, pos: Vector3, dist: float = 3.0) -> float:
	## Fraction of 8 horizontal directions blocked by walls/terrain within `dist`.
	if world3d == null:
		return 0.0
	var space := world3d.direct_space_state
	var blocked := 0
	for i in 8:
		var a := i * TAU / 8.0
		var q := PhysicsRayQueryParameters3D.create(pos, pos + Vector3(cos(a), 0, sin(a)) * dist, EntityView.LAYER_STRUCT | EntityView.LAYER_TERRAIN)
		if not space.intersect_ray(q).is_empty():
			blocked += 1
	return blocked / 8.0
