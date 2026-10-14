extends Node
## Sound playback: pooled one-shots (2D and positional), numbered-variant
## selection ("knap" picks knap_1..knap_5 at random), looping streams for
## ambience and fires, and the audio bus layout.

const SFX_DIR := "res://assets/audio/sfx"
const AMB_DIR := "res://assets/audio/amb"
const POOL_3D := 40
const POOL_2D := 10

var _streams: Dictionary = {}     # base name -> Array[AudioStream]
var _pool3d: Array[AudioStreamPlayer3D] = []
var _pool2d: Array[AudioStreamPlayer] = []
var _i3 := 0
var _i2 := 0
var _amb: Dictionary = {}         # name -> AudioStreamPlayer
var _last_play: Dictionary = {}   # name -> msec, to avoid machine-gun repeats


func _ready() -> void:
	_setup_buses()
	_scan(SFX_DIR)
	_scan(AMB_DIR)
	for i in POOL_3D:
		var p := AudioStreamPlayer3D.new()
		p.bus = "SFX"
		p.unit_size = 4.0
		p.max_distance = 40.0
		p.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
		p.attenuation_filter_cutoff_hz = 9000.0
		p.attenuation_filter_db = -12.0
		add_child(p)
		_pool3d.append(p)
	for i in POOL_2D:
		var p := AudioStreamPlayer.new()
		p.bus = "UI"
		add_child(p)
		_pool2d.append(p)
	Events.env_changed.connect(_apply_volumes)
	_apply_volumes()


func _setup_buses() -> void:
	for bus_name in ["SFX", "Ambience", "UI"]:
		if AudioServer.get_bus_index(bus_name) == -1:
			AudioServer.add_bus()
			var idx := AudioServer.bus_count - 1
			AudioServer.set_bus_name(idx, bus_name)
			AudioServer.set_bus_send(idx, "Master")
	var amb := AudioServer.get_bus_index("Ambience")
	if AudioServer.get_bus_effect_count(amb) == 0:
		var lp := AudioEffectLowPassFilter.new()
		lp.cutoff_hz = 20000.0
		AudioServer.add_bus_effect(amb, lp)


func _apply_volumes() -> void:
	AudioServer.set_bus_volume_db(AudioServer.get_bus_index("SFX"), linear_to_db(maxf(Settings.sfx_volume, 0.0001)))
	AudioServer.set_bus_volume_db(AudioServer.get_bus_index("UI"), linear_to_db(maxf(Settings.sfx_volume * 0.8, 0.0001)))
	AudioServer.set_bus_volume_db(AudioServer.get_bus_index("Ambience"), linear_to_db(maxf(Settings.ambience_volume, 0.0001)))


func _scan(dir: String) -> void:
	var files: PackedStringArray
	if ResourceLoader.has_method("list_directory"):
		files = ResourceLoader.list_directory(dir)
	else:
		var d := DirAccess.open(dir)
		if d == null:
			return
		files = d.get_files()
	for f in files:
		f = f.trim_suffix(".import").trim_suffix(".remap")
		if not (f.ends_with(".ogg") or f.ends_with(".wav") or f.ends_with(".mp3")):
			continue
		var base := f.get_basename()
		var key := base
		var us := base.rfind("_")
		if us > 0 and base.substr(us + 1).is_valid_int():
			key = base.substr(0, us)
		var path := dir + "/" + f
		if not _streams.has(key):
			_streams[key] = []
		if not _streams.has(base):
			_streams[base] = []
		var st = load(path)
		if st is AudioStream:
			_streams[key].append(st)
			if base != key:
				_streams[base].append(st)


func has(sound: String) -> bool:
	return _streams.has(sound) and _streams[sound].size() > 0


func get_stream(sound: String, loop: bool = false) -> AudioStream:
	if not has(sound):
		return null
	var arr: Array = _streams[sound]
	var st: AudioStream = arr[randi() % arr.size()]
	if loop:
		if st is AudioStreamWAV:
			st = st.duplicate()
			st.loop_mode = AudioStreamWAV.LOOP_FORWARD
			st.loop_begin = 0
			st.loop_end = int(st.get_length() * st.mix_rate)
		elif st is AudioStreamOggVorbis:
			st = st.duplicate()
			st.loop = true
	return st


func play(sound: String, pos: Variant = null, vol_db: float = 0.0, pitch: float = 1.0, pitch_jitter: float = 0.06) -> void:
	if not has(sound):
		return
	var now := Time.get_ticks_msec()
	if now - int(_last_play.get(sound, -1000)) < 35:
		return
	_last_play[sound] = now
	var st := get_stream(sound)
	var pj := pitch * (1.0 + randf_range(-pitch_jitter, pitch_jitter))
	if pos is Vector3:
		var p: AudioStreamPlayer3D = _pool3d[_i3]
		_i3 = (_i3 + 1) % _pool3d.size()
		p.stop()
		p.stream = st
		p.volume_db = vol_db
		p.pitch_scale = pj
		p.global_position = pos
		p.play()
	else:
		var p2: AudioStreamPlayer = _pool2d[_i2]
		_i2 = (_i2 + 1) % _pool2d.size()
		p2.stop()
		p2.stream = st
		p2.volume_db = vol_db
		p2.pitch_scale = pj
		p2.play()


func ui(sound: String, vol_db: float = -4.0) -> void:
	play(sound, null, vol_db, 1.0, 0.03)


func set_ambient(sound: String, volume: float, fade: float = 2.0) -> void:
	## Crossfading 2D ambience loop. volume 0..1 (0 stops it).
	if not has(sound):
		return
	var p: AudioStreamPlayer = _amb.get(sound)
	if p == null:
		if volume <= 0.001:
			return
		p = AudioStreamPlayer.new()
		p.bus = "Ambience"
		p.stream = get_stream(sound, true)
		p.volume_db = -60.0
		add_child(p)
		_amb[sound] = p
	if volume > 0.001 and not p.playing:
		p.play()
	var target := linear_to_db(maxf(volume, 0.0001))
	p.set_meta("target", target)
	p.set_meta("fade", maxf(fade, 0.05))


func shutdown() -> void:
	## Silence everything so no playback is left mid-mix when the engine stops.
	for n in get_tree().root.find_children("*", "AudioStreamPlayer3D", true, false):
		n.stop()
	for n2 in get_tree().root.find_children("*", "AudioStreamPlayer", true, false):
		n2.stop()


func _exit_tree() -> void:
	# let go of every stream and playback so nothing outlives the engine
	for p in _pool3d:
		p.stop()
		p.stream = null
	for p2 in _pool2d:
		p2.stop()
		p2.stream = null
	for a in _amb.values():
		a.stop()
		a.stream = null
	_amb.clear()
	_streams.clear()


func stop_all_ambient() -> void:
	for p in _amb.values():
		p.stop()
		p.stream = null
		p.queue_free()
	_amb.clear()


func _process(delta: float) -> void:
	for key in _amb.keys():
		var p: AudioStreamPlayer = _amb[key]
		var target: float = p.get_meta("target", -60.0)
		var rate := 40.0 / float(p.get_meta("fade", 2.0))
		p.volume_db = move_toward(p.volume_db, target, rate * delta)
		if target <= -59.0 and p.volume_db <= -59.0 and p.playing:
			# silent: pause the loop but keep the player for when it's needed again
			p.stream_paused = true
		elif target > -59.0 and p.stream_paused:
			p.stream_paused = false


func make_loop_player(sound: String, parent: Node3D, vol_db: float = 0.0, max_dist: float = 25.0) -> AudioStreamPlayer3D:
	## A positional looping player (fires, mounds, drill...) owned by `parent`.
	var p := AudioStreamPlayer3D.new()
	p.bus = "SFX"
	p.stream = get_stream(sound, true)
	p.volume_db = vol_db
	p.max_distance = max_dist
	p.unit_size = 3.0
	p.tree_exiting.connect(func():
		p.stop()
		p.stream = null)
	parent.add_child(p)
	return p
