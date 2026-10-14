class_name ActionsFire
extends RefCounted
## Host handlers for fires and process sites.


static func register(a: Actions) -> void:
	pass


static func on_item_placed(_eid: int) -> void:
	pass


static func on_item_removed(_eid: int) -> void:
	pass


static func on_terrain_dug(_pos: Vector3) -> void:
	pass


static func douse(_eid: int, _litres: float) -> void:
	pass
