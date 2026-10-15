class_name Weather
extends RefCounted
## Showers come and go; wind wanders; calm mornings bring mist.  Rain puts out
## open fires and pit kilns, soaks you, and waters crops.

var showers := true      # false: it only rains when something sets the rain (tests)


func light_factor() -> float:
	var h := World.hour_of_day()
	var dt := (h - 6.0) / 14.0
	if dt <= 0.0 or dt >= 1.0:
		return 0.0
	var el := sin(dt * PI)
	var oc := clampf(float(World.env.get("cloud", 0.2)) * 1.1 - 0.3, 0.0, 1.0)
	return clampf(el * 1.25, 0.0, 1.0) * (1.0 - 0.55 * oc) * (1.0 - 0.3 * float(World.env.get("rain", 0.0)))


func tick(hours: float) -> void:
	var env := World.env
	var rain := float(env.get("rain", 0.0))
	var target := float(env.get("rain_target", 0.0))
	# the first day stays dry: there is enough to learn without rain
	var first_day := World.hours() < 24.0 + 20.0
	if target <= 0.0:
		if showers and not first_day and randf() < hours * 0.045:
			target = randf_range(0.35, 0.9)
	elif randf() < hours * 0.3:
		target = 0.0
	env["rain_target"] = target
	env["rain"] = move_toward(rain, target, hours * 0.8)
	var cloud_target := clampf(0.25 + sin(World.hours() * 0.37) * 0.2 + sin(World.hours() * 0.11) * 0.15, 0.05, 0.8)
	if target > 0.0:
		cloud_target = 0.95
	env["cloud"] = move_toward(float(env.get("cloud", 0.2)), cloud_target, hours * 0.25)
	var wind: Vector2 = env.get("wind", Vector2(1.2, 0.4))
	wind += Vector2(randf_range(-1, 1), randf_range(-1, 1)) * hours * 1.4
	var want_len := 1.4 + float(env["rain"]) * 2.4 + maxf(0.0, sin(World.hours() * 0.21)) * 1.2
	wind = wind.normalized() * move_toward(wind.length(), want_len, hours * 1.5)
	env["wind"] = wind
	var h := World.hour_of_day()
	var mist := 0.0
	if h > 4.0 and h < 9.0 and wind.length() < 2.2:
		mist = 0.35 * (1.0 - absf(h - 6.5) / 2.5)
	env["fog"] = move_toward(float(env.get("fog", 0.0)), mist, hours * 0.5)
