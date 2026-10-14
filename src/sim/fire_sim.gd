class_name FireSim
extends RefCounted
## Combustion, pyrolysis and firing in process sites.


static func tick(_hours: float, _real_dt: float) -> void:
	pass


static func heat_sources() -> Array:
	return []


static func burn_at(_pos: Vector3) -> float:
	return 0.0
