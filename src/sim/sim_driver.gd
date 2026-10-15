class_name SimDriver
extends Node
## Host-only heartbeat: advances game time and runs every simulation system.
## One in-game day lasts 20 real minutes; when everyone is asleep, the night
## passes quickly.

const DAY_SECONDS := 1200.0
const HOURS_PER_SECOND := 24.0 / DAY_SECONDS
const TICK := 0.5

var weather := Weather.new()
var time_scale := 1.0
var _acc := 0.0
var _hours := 0.0
var _was_night := false
var _was_rain := false


func _process(delta: float) -> void:
	if not World.running or World.env.is_empty():
		return
	time_scale = 30.0 if _everyone_sleeping() else 1.0
	var dh := delta * HOURS_PER_SECOND * time_scale
	World.env["t"] = float(World.env["t"]) + dh
	_acc += delta
	_hours += dh
	if _acc >= TICK:
		_tick(_hours, _acc)
		_acc = 0.0
		_hours = 0.0


func _everyone_sleeping() -> bool:
	if Net.players.is_empty():
		return false
	for pid in Net.players:
		var pose: Dictionary = Net.poses.get(pid, {})
		if String(pose.get("m", "")) != "sleep":
			return false
	return World.is_night() or World.hour_of_day() < 6.5


func _tick(hours: float, real_dt: float) -> void:
	weather.tick(hours)
	var a: Actions = World.actions
	if a == null:
		return
	a.fire.tick(hours, real_dt)
	a.farm.tick(hours)
	a.animals.tick(hours)
	var fires: Array = a.fire.heat_sources()
	for pid in Net.players:
		var pose: Dictionary = Net.poses.get(pid, {})
		var pos: Vector3 = pose.get("p", World.spawn_point(pid))
		var c := Climate.temp_at(pos, fires)
		var mode := String(pose.get("m", "play"))
		Survival.tick(pid, hours, real_dt, {
			"temp": float(c["temp"]), "wet": bool(c["wet"]) or bool(pose.get("w", false)),
			"sleeping": mode == "sleep", "work": 1.0 if bool(pose.get("sp", false)) else 0.0,
			"burn": a.fire.burning_at(pos), "near_fire": float(c["fire_heat"]) > 3.0,
		})
	_weather_hints()
	Events.env_changed.emit()


func _weather_hints() -> void:
	var h := World.hour_of_day()
	var dusk := h > 18.5 and h < 21.0
	var rain := float(World.env.get("rain", 0.0)) > 0.25
	for pid in Net.players:
		if dusk and not _was_night:
			Survival.hint_once(pid, "dusk")
		if rain and not _was_rain:
			Survival.hint_once(pid, "rain")
	_was_night = dusk
	_was_rain = rain
