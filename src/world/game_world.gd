extends Node3D
## The running game: environment, island, entities, players, UI and (on the
## host) the authoritative simulation and action handling.

var spawn_info: Dictionary = {}
var sky: SkyEnv
var island: IslandView
var entities: EntityManager
var players: PlayersRoot
var fx: FX
var hud: CanvasLayer
var actions: Node
var sim: Node
var crafting: Node
var _amb_t := 0.0


func _ready() -> void:
	sky = SkyEnv.new()
	sky.name = "Sky"
	add_child(sky)
	island = IslandView.new()
	island.name = "Island"
	add_child(island)
	island.build(World.terrain)
	entities = EntityManager.new()
	entities.name = "Entities"
	add_child(entities)
	Registry.register_views(entities)
	fx = FX.new()
	fx.name = "FX"
	add_child(fx)
	if Net.is_host():
		actions = Actions.new()
		actions.name = "Actions"
		add_child(actions)
		World.actions = actions
		sim = SimDriver.new()
		sim.name = "Sim"
		add_child(sim)
	players = PlayersRoot.new()
	players.name = "Players"
	add_child(players)
	players.spawn_local(spawn_info)
	crafting = CraftController.new()
	crafting.name = "Crafting"
	add_child(crafting)
	hud = HUD.new()
	hud.name = "HUD"
	add_child(hud)
	Events.terrain_changed.connect(island.on_terrain_changed)
	Events.soil_changed.connect(island.on_soil_changed)
	Events.env_changed.connect(_on_env)
	_on_env()
	if bool(spawn_info.get("new", false)):
		Events.hint.emit.call_deferred("welcome")


func local_player() -> LocalPlayer:
	return players.local if players else null


func _on_env() -> void:
	island.set_pond_volume(float(World.env.get("pond_l", 0.0)))
	island.set_weather_visuals(float(World.env.get("rain", 0.0)), World.env.get("wind", Vector2(1, 0.3)))


func _process(delta: float) -> void:
	_amb_t -= delta
	if _amb_t > 0.0:
		return
	_amb_t = 0.5
	Models.sweep_held()
	var lp := local_player()
	if lp == null:
		return
	var p := lp.global_position
	var wind: Vector2 = World.env.get("wind", Vector2(1, 0.3))
	var w := clampf(wind.length() / 6.0, 0.0, 1.0)
	var edge := clampf(World.terrain.edge_factor(Vector2(p.x, p.z)) - 0.5, 0.0, 0.6) / 0.6
	var rain := float(World.env.get("rain", 0.0))
	var sheltered := Shelter.roof_above(get_world_3d(), lp.eye_position())
	Sfx.set_ambient("wind_soft", clampf(0.35 + edge * 0.35 - w * 0.2, 0.0, 1.0) * (0.55 if sheltered else 1.0))
	Sfx.set_ambient("wind_strong", clampf(w * 0.9 + edge * 0.2 - 0.25, 0.0, 1.0) * (0.5 if sheltered else 1.0))
	Sfx.set_ambient("rain_light", clampf(rain, 0.0, 1.0) * (0.7 if sheltered else 1.0))
	var night := World.is_night()
	Sfx.set_ambient("crickets_night", 0.5 if night and rain < 0.2 else 0.0)
	var pd := Vector2(p.x, p.z).distance_to(TerrainData.POND_CENTER)
	Sfx.set_ambient("pond_lap", clampf(1.0 - (pd - 1.5) / 5.0, 0.0, 0.7))
	if not night and rain < 0.3 and randf() < 0.035:
		Sfx.play("bird", p + Vector3(randf_range(-8, 8), randf_range(2, 6), randf_range(-8, 8)), -16.0)
