class_name EntityView
extends Node3D
## Base class for the visual/physical representation of a World entity.
## Views never change world state; they render it and expose colliders that the
## interaction raycast resolves back to (entity id, part).

const LAYER_TERRAIN := 1
const LAYER_STRUCT := 2
const LAYER_ITEMS := 4
const LAYER_PLAYERS := 8
const LAYER_INTERACT := 16
const LAYER_WATER := 32

var entity_id := -1
var e: Dictionary = {}


func setup(ent: Dictionary) -> void:
	e = ent
	transform = ent["xf"]
	_build()
	_refresh(ent["d"].keys())


func on_changed(ent: Dictionary, keys: Array) -> void:
	e = ent
	if keys.has("xf"):
		transform = ent["xf"]
	_refresh(keys)


func on_removed() -> void:
	queue_free()


func data() -> Dictionary:
	return e.get("d", {})


func _build() -> void:
	pass


func _refresh(_keys: Array) -> void:
	pass


func make_body(shape: Shape3D, layer: int, part: String = "", xf: Transform3D = Transform3D.IDENTITY, solid: bool = false) -> CollisionObject3D:
	## A collider that resolves to this entity.  `solid` bodies also block players.
	var body: CollisionObject3D
	if solid or layer == LAYER_STRUCT or layer == LAYER_ITEMS:
		body = StaticBody3D.new()
	else:
		var a := Area3D.new()
		a.monitoring = false
		a.monitorable = false
		body = a
	body.collision_layer = layer
	body.collision_mask = 0
	body.set_meta("eid", entity_id)
	body.set_meta("part", part)
	var cs := CollisionShape3D.new()
	cs.shape = shape
	cs.transform = xf
	body.add_child(cs)
	add_child(body)
	return body


func interaction_point(_part: String) -> Vector3:
	return global_position


func game_world() -> Node:
	return Game.game_world
