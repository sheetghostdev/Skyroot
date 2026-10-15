extends Node
## Loads every script under res://src and res://tests so parse errors show up,
## including scripts that are only loaded by path (the import pass skips those).
##   godot --headless --path . res://tools/check_scripts.tscn

func _ready() -> void:
	var bad := 0
	for dir in ["res://src", "res://tests"]:
		bad += _walk(dir)
	print("CHECK %s" % ("ok" if bad == 0 else "%d script(s) failed" % bad))
	get_tree().quit(0 if bad == 0 else 1)


func _walk(dir: String) -> int:
	var bad := 0
	var d := DirAccess.open(dir)
	if d == null:
		return 0
	for sub in d.get_directories():
		bad += _walk(dir.path_join(sub))
	for f in d.get_files():
		if f.ends_with(".gd"):
			var s := ResourceLoader.load(dir.path_join(f), "", ResourceLoader.CACHE_MODE_IGNORE) as GDScript
			if s == null or not s.can_instantiate():
				print("FAILED ", dir.path_join(f))
				bad += 1
	return bad
