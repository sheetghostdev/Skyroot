class_name EntityModels
extends RefCounted
## Shared meshes and materials for block-entity views (built once, reused).

static var _cache: Dictionary = {}


static func get_or_build(key: String, builder: Callable) -> Variant:
	if not _cache.has(key):
		_cache[key] = builder.call()
	return _cache[key]


static func clear() -> void:
	_cache.clear()
