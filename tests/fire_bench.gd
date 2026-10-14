extends SceneTree
## Calibration bench for FireModel: runs the reference arrangements and prints
## what the physics produces.  (The same scenarios are asserted in the test
## suite: tests/test_runner.gd suite_fire.)
##   godot --headless --path . --script res://tests/fire_bench.gd


func _init() -> void:
	for r in FireBench.run_all():
		print(r)
	quit()
