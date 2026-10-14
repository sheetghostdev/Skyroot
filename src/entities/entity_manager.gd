class_name EntityManager
extends Node3D
## Keeps one view node per World entity, following World's replication signals.

const VIEWS := {
	"item": preload("res://src/entities/item_view.gd"),
	"tree": preload("res://src/entities/tree_view.gd"),
	"outcrop": preload("res://src/entities/rock_view.gd"),
	"flat_stone": preload("res://src/entities/rock_view.gd"),
	"boulder": preload("res://src/entities/rock_view.gd"),
	"mossy_log": preload("res://src/entities/rock_view.gd"),
	"mushrooms": preload("res://src/entities/mushroom_view.gd"),
	"bush": preload("res://src/entities/bush_view.gd"),
	"plant": preload("res://src/entities/plant_view.gd"),
	"work": preload("res://src/entities/work_view.gd"),
}

var views: Dictionary = {}
var extra_views: Dictionary = {}   # type -> script, registered by other systems


func _ready() -> void:
	add_to_group("entities")
	Events.entity_spawned.connect(_on_spawned)
	Events.entity_changed.connect(_on_changed)
	Events.entity_removed.connect(_on_removed)
	for id in World.entities.keys():
		_on_spawned(id)


func register(t: String, script: Script) -> void:
	extra_views[t] = script


func _on_spawned(id: int) -> void:
	if views.has(id):
		return
	var ent = World.entities.get(id)
	if ent == null:
		return
	var script: Script = VIEWS.get(ent["t"], extra_views.get(ent["t"]))
	if script == null:
		return
	var v: EntityView = script.new()
	v.entity_id = id
	v.name = "%s_%d" % [ent["t"], id]
	add_child(v)
	v.setup(ent)
	views[id] = v


func _on_changed(id: int, keys: Array) -> void:
	var v: EntityView = views.get(id)
	if v and World.entities.has(id):
		v.on_changed(World.entities[id], keys)


func _on_removed(id: int) -> void:
	var v: EntityView = views.get(id)
	if v:
		views.erase(id)
		v.on_removed()


func view(id: int) -> EntityView:
	return views.get(id)
