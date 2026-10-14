class_name CraftController
extends Node
## Client: opens close-up crafting sessions for workpieces this player works on.


func _ready() -> void:
	add_to_group("crafting")
