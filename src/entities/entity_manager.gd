class_name EntityManager
extends Node3D
## Keeps one view node per World entity, following World's replication signals.

const VIEWS := {
	"item": preload("res://src/entities/item_view.gd"),
	"satchel": preload("res://src/entities/satchel_view.gd"),
	"firepit": preload("res://src/entities/firepit_view.gd"),
	"kiln": preload("res://src/entities/kiln_view.gd"),
	"knap": preload("res://src/entities/knap_view.gd"),
	"clay": preload("res://src/entities/clay_view.gd"),
	"ground": preload("res://src/entities/ground_view.gd"),
	"jar": preload("res://src/entities/jar_view.gd"),
	"raft": preload("res://src/entities/raft_view.gd"),
	"animal": preload("res://src/entities/animal_view.gd"),
}

var views: Dictionary = {}


func _ready() -> void:
	add_to_group("entities")
	Events.entity_spawned.connect(_on_spawned)
	Events.entity_changed.connect(_on_changed)
	Events.entity_removed.connect(_on_removed)
	for id in World.entities.keys():
		_on_spawned(id)


func _on_spawned(id: int) -> void:
	if views.has(id):
		return
	var ent = World.entities.get(id)
	if ent == null:
		return
	var script: Script = VIEWS.get(ent["t"])
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
