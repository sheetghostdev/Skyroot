extends Node
## Starts the test runner.  If its script doesn't compile, say so and quit with
## an error instead of sitting there forever.


func _ready() -> void:
	var script := load("res://tests/test_runner.gd") as GDScript
	if script == null or not script.can_instantiate():
		print("TESTS DID NOT START: res://tests/test_runner.gd failed to compile (see the error above)")
		get_tree().quit(3)
		return
	var runner: Node = script.new()
	runner.name = "Runner"
	add_child(runner)
