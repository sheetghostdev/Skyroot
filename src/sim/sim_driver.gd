class_name SimDriver
extends Node
## Host-only heartbeat: advances game time and runs every simulation system.
## One in-game day lasts 20 real minutes.

const DAY_SECONDS := 1200.0
const HOURS_PER_SECOND := 24.0 / DAY_SECONDS
const TICK := 0.5

var weather := Weather.new()
var time_scale := 1.0
var _acc := 0.0
var _hours := 0.0
var ctx: Dictionary = {}
var _was_night := false
var _was_rain := false


func _process(delta: float) -> void:
	if not World.running or World.env.is_empty():
		return
	time_scale = 14.0 if _everyone_sleeping() else 1.0
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
	return true


func _tick(hours: float, real_dt: float) -> void:
	weather.tick(hours)
	var light := weather.light_factor()
	ctx = {
		"light": light, "sun": light, "temp": Climate.base_temp(),
		"wind": (World.env.get("wind", Vector2.ONE) as Vector2).length(),
		"rain_catch": func(mm: float) -> float: return DryingSim.rain_catch(mm) + CompostSim.rain_catch(mm),
	}
	WaterSim.tick(hours, ctx)
	PlantSim.tick(hours, ctx)
	DryingSim.tick(hours, ctx)
	FireSim.tick(hours, real_dt)
	StructureSim.tick(real_dt)
	CompostSim.tick(hours)
	OutcropSim.tick(hours)
	_survival(hours, real_dt)
	_weather_hints()
	Events.env_changed.emit()


func _weather_hints() -> void:
	var h := World.hour_of_day()
	var night := h > 19.5 or h < 5.0
	var rain := float(World.env.get("rain", 0.0)) > 0.25
	for pid in Net.players:
		if night and not _was_night:
			Survival.hint_once(pid, "night")
		if rain and not _was_rain:
			Survival.hint_once(pid, "rain")
	_was_night = night
	_was_rain = rain


func _survival(hours: float, real_dt: float) -> void:
	var gw = Game.game_world
	if gw == null:
		return
	var fires := FireSim.heat_sources()
	for pid in Net.players:
		var pose: Dictionary = Net.poses.get(pid, {})
		var pos: Vector3 = pose.get("p", World.spawn_point(pid))
		var c := Climate.temp_at(gw.get_world_3d(), pos, fires)
		var mode := String(pose.get("m", "play"))
		var burn := FireSim.burn_at(pos)
		Survival.tick(pid, hours, real_dt, {
			"temp": float(c["temp"]), "wet": bool(c["wet"]) or bool(pose.get("w", false)),
			"sleeping": mode == "sleep", "sprint": bool(pose.get("sp", false)),
			"work": 1.0 if String(pose.get("a", "")) != "" else 0.0, "burn": burn,
		})
