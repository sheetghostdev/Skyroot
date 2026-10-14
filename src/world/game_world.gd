extends Node3D
## The running game: environment, blocks, entities, players, UI and (on the
## host) the authoritative simulation and action handling.

var spawn_info: Dictionary = {}
var sky: SkyEnv
var voxels: VoxelView
var entities: EntityManager
var players: PlayersRoot
var fx: FX
var hud: HUD
var actions: Actions
var sim: SimDriver
var _amb_t := 0.0


func _ready() -> void:
	sky = SkyEnv.new()
	sky.name = "Sky"
	add_child(sky)
	voxels = VoxelView.new()
	voxels.name = "Voxels"
	add_child(voxels)
	voxels.build(World.vox)
	fx = FX.new()
	fx.name = "FX"
	add_child(fx)
	entities = EntityManager.new()
	entities.name = "Entities"
	add_child(entities)
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
	hud = HUD.new()
	hud.name = "HUD"
	add_child(hud)
	Events.block_changed.connect(voxels.block_changed)
	Events.env_changed.connect(_on_env)
	_on_env()
	if bool(spawn_info.get("new", false)):
		Events.hint.emit.call_deferred("welcome")


func local_player() -> LocalPlayer:
	return players.local if players else null


func _on_env() -> void:
	voxels.set_wind(World.env.get("wind", Vector2(1, 0.3)), float(World.env.get("rain", 0.0)))


func _exit_tree() -> void:
	if World.actions == actions:
		World.actions = null


func _process(delta: float) -> void:
	_amb_t -= delta
	if _amb_t > 0.0:
		return
	_amb_t = 0.5
	var lp := local_player()
	if lp == null:
		return
	var p := lp.global_position
	var wind: Vector2 = World.env.get("wind", Vector2(1, 0.3))
	var w := clampf(wind.length() / 6.0, 0.0, 1.0)
	var c := VoxelData.cell_of(p + Vector3(0, 1.0, 0))
	var sheltered := not World.vox.open_to_sky(c)
	var near_edge := World.vox.rest_height(p + Vector3(3, 1, 0)) == -INF or World.vox.rest_height(p + Vector3(-3, 1, 0)) == -INF \
		or World.vox.rest_height(p + Vector3(0, 1, 3)) == -INF or World.vox.rest_height(p + Vector3(0, 1, -3)) == -INF
	var edge := 0.35 if near_edge else 0.0
	var rain := float(World.env.get("rain", 0.0))
	Sfx.set_ambient("wind_soft", clampf(0.35 + edge - w * 0.2, 0.0, 1.0) * (0.5 if sheltered else 1.0))
	Sfx.set_ambient("wind_strong", clampf(w * 0.9 + edge * 0.4 - 0.25, 0.0, 1.0) * (0.45 if sheltered else 1.0))
	Sfx.set_ambient("rain_light", clampf(rain, 0.0, 1.0) * (0.7 if sheltered else 1.0))
	var night := World.is_night()
	Sfx.set_ambient("crickets_night", 0.5 if night and rain < 0.2 else 0.0)
	var water_near := false
	for e in [Vector3(2, 0, 0), Vector3(-2, 0, 0), Vector3(0, 0, 2), Vector3(0, 0, -2), Vector3(4, -1, 0), Vector3(-4, -1, 0), Vector3(0, -1, 4), Vector3(0, -1, -4)]:
		if World.vox.liquid_at(p + e):
			water_near = true
			break
	Sfx.set_ambient("pond_lap", 0.5 if water_near else 0.0)
