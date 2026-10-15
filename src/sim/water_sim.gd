class_name WaterSim
extends RefCounted
## Finite water (host).  A water block holds 1-8 units; its meta is how many it
## is short of full (so a full block is meta 0).  Water drops into open space
## below, trickles over edges, and every connected sheet of it evens out across
## its whole surface (and into open cells around it).  It never makes more of
## itself: dig beside the pond and the whole pond goes down a little; open it to
## the sky under the island and it is gone.  Rain tops up open water and fills
## hollows; thin puddles dry up in the sun.

const STEP := 0.2           # seconds between flow steps
const BUDGET := 600         # cells updated per step at most (the rest wait)
const MAX_BODY := 2048      # cells levelled together at most
const SIDES := [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]

var a: Actions
var water := 0
var _active := {}
var _leveled := {}          # cells already evened out this step
var _acc := 0.0
var _weather_acc := 0.0
var _rng := RandomNumberGenerator.new()


func _init(actions: Actions) -> void:
	a = actions
	water = Blocks.id_of("water")
	Events.block_changed.connect(_on_block_changed)


static func level_of(m: int) -> int:
	return 8 - (m & 7)


func level(c: Vector3i) -> int:
	return level_of(World.block_meta(c)) if World.block(c) == water else 0


func set_level(c: Vector3i, lv: int) -> void:
	if lv <= 0:
		if World.block(c) == water:
			World.set_block(c, 0)
		return
	lv = mini(lv, 8)
	if World.block(c) == water and level(c) == lv:
		return
	World.set_block(c, water, 8 - lv)


func take(c: Vector3i, n: int) -> int:
	## Scoop up to n units out of this cell (a bowl, a pot).  Returns how many.
	var lv := level(c)
	var got := mini(lv, n)
	set_level(c, lv - got)
	return got


func add(c: Vector3i, n: int) -> int:
	## Pour n units in here (or as close above as there is room).  Returns what
	## did not fit.
	var p := c
	for i in 4:
		var id := World.block(p)
		if id == water or _open(p, id):
			var lv := level(p)
			var put := mini(n, 8 - lv)
			if put > 0:
				_clear_plant(p)
				set_level(p, lv + put)
				n -= put
		if n <= 0:
			return 0
		p += Vector3i.UP
	return n


func busy() -> bool:
	return not _active.is_empty()


func _on_block_changed(c: Vector3i, _old_h: int) -> void:
	if not World.is_host():
		return
	if World.block(c) == water:
		_active[c] = true
	for d in [Vector3i.UP, Vector3i.DOWN, Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]:
		var n: Vector3i = c + d
		if World.block(n) == water:
			_active[n] = true


func _open(c: Vector3i, id: int) -> bool:
	## Can water move into this cell?  Air, or a small plant it washes away.
	if not VoxelData.in_bounds(c.x, c.y, c.z) or World.be_at.has(c):
		return false
	if id == 0:
		return true
	return Blocks.is_replaceable(id) and not Blocks.is_solid(id) and Blocks.shape[id] != Blocks.Shape.LIQUID


func _clear_plant(c: Vector3i) -> void:
	var id := World.block(c)
	if id != 0 and id != water:
		a.blocks._pop(c, id)


func step(delta: float) -> void:
	_acc += delta
	_weather_acc += delta
	if _weather_acc >= 1.0:
		_weather_acc = 0.0
		_weather()
	if _acc < STEP:
		return
	_acc = 0.0
	if _active.is_empty():
		return
	var cells: Array = _active.keys()
	_active.clear()
	_leveled.clear()
	# lower cells first, so water settles from the bottom up
	cells.sort_custom(func(p: Vector3i, q: Vector3i) -> bool: return p.y < q.y)
	var n := 0
	for c in cells:
		if n >= BUDGET:
			_active[c] = true
			continue
		n += 1
		_flow(c)


func settle(max_steps := 400) -> int:
	## Run the flow until it rests (tests, world setup).  Returns steps taken.
	var i := 0
	while busy() and i < max_steps:
		_acc = STEP
		step(0.0)
		i += 1
	return i


func _flow(c: Vector3i) -> void:
	if World.block(c) != water or _leveled.has(c):
		return
	var lv := level(c)
	var below := c + Vector3i.DOWN
	if below.y < 0:
		set_level(c, 0)
		return
	var bid := World.block(below)
	if _open(below, bid):
		# it drops: straight down to whatever it lands on
		var land := below
		while land.y > 0 and _open(land + Vector3i.DOWN, World.block(land + Vector3i.DOWN)):
			land += Vector3i.DOWN
		set_level(c, 0)
		if land.y <= 0:
			if c.y > 2:
				World.fx("spill", Vector3(c) + Vector3(0.5, 0.0, 0.5), {})
			return   # off the island: lost to the sky
		var under := land + Vector3i.DOWN
		if World.block(under) == water and level(under) < 8:
			var room := 8 - level(under)
			var mv := mini(room, lv)
			set_level(under, level(under) + mv)
			lv -= mv
		if lv > 0:
			_clear_plant(land)
			set_level(land, lv)
		return
	if bid == water:
		var bl := level(below)
		if bl < 8:
			var mv := mini(lv, 8 - bl)
			set_level(below, bl + mv)
			lv -= mv
			set_level(c, lv)
			if lv <= 0:
				return
	# over an edge: a unit at a time trickles into open space with a drop below
	for d in SIDES:
		if lv <= 0:
			return
		var nb: Vector3i = c + d
		var nid := World.block(nb)
		if nid != water and _open(nb, nid) and _sinks(nb):
			_clear_plant(nb)
			set_level(nb, 1)
			lv -= 1
			set_level(c, lv)
	# then everything connected at this height evens out
	_level_body(c)


func _sinks(p: Vector3i) -> bool:
	## Water put here would go on down: open space or unfilled water below.
	var b := p + Vector3i.DOWN
	var id := World.block(b)
	if id == water:
		return level(b) < 8
	return _open(b, id)


func _supported(p: Vector3i) -> bool:
	## Resting on something: a block, or water that is already full.
	var b := p + Vector3i.DOWN
	var id := World.block(b)
	if id == water:
		return level(b) >= 8
	return not _open(b, id)


func _level_body(c: Vector3i) -> void:
	## Share the water of one connected sheet (all at this height, resting on
	## something) evenly over it and the open cells around its edge.  Whoever
	## holds more keeps the odd units, so a level body stays exactly as it is.
	var cells: Array[Vector3i] = []
	var opens: Array[Vector3i] = []
	var seen := {c: true}
	var total := 0
	var head := 0
	cells.append(c)
	while head < cells.size() and cells.size() < MAX_BODY:
		var p: Vector3i = cells[head]
		head += 1
		total += level(p)
		_leveled[p] = true
		for d in SIDES:
			var n: Vector3i = p + d
			if seen.has(n):
				continue
			seen[n] = true
			var nid := World.block(n)
			if nid == water:
				if _supported(n):
					cells.append(n)
			elif _open(n, nid) and _supported(n):
				opens.append(n)
	if head < cells.size():
		# too big to do at once: the rest is done from its own cells later
		for i in range(head, cells.size()):
			_active[cells[i]] = true
		cells.resize(head)
	var all: Array[Vector3i] = []
	all.append_array(cells)
	all.append_array(opens)
	var n_all := all.size()
	var base := total / n_all
	var extra := total % n_all
	# highest first (ties: nearest first), so the odd units stay where they are
	var keys: Array = []
	for i in n_all:
		keys.append([level(all[i]), -i, i])
	keys.sort_custom(func(x: Array, y: Array) -> bool: return x[0] > y[0] or (x[0] == y[0] and x[1] > y[1]))
	for k in n_all:
		var i: int = keys[k][2]
		var want := base + (1 if k < extra else 0)
		var p: Vector3i = all[i]
		if want == level(p):
			continue
		if want > 0 and World.block(p) != water:
			_clear_plant(p)
		set_level(p, want)


func _weather() -> void:
	## Rain tops up open water and pools in hollows; puddles dry in the sun.
	var rain := float(World.env.get("rain", 0.0))
	var sunny := rain < 0.05 and not World.is_night()
	if rain < 0.3 and not sunny:
		return
	for i in 48:
		weather_at(_rng.randi_range(0, VoxelData.SX - 1), _rng.randi_range(0, VoxelData.SZ - 1), rain, sunny, _rng.randf())


func weather_at(x: int, z: int, rain: float, sunny: bool, roll: float) -> void:
	var h := World.vox.column_height(x, z)
	if h < 0:
		return
	var top := Vector3i(x, h, z)
	var id := World.block(top)
	if rain >= 0.3:
		if id == water:
			if level(top) < 8 and roll < rain:
				set_level(top, level(top) + 1)
		elif Blocks.is_solid(id) and Blocks.is_opaque(id) and _hollow(top + Vector3i.UP) and roll < rain * 0.5:
			set_level(top + Vector3i.UP, 1)
	elif sunny and id == water and level(top) == 1 and roll < 0.5:
		for d in SIDES:
			if World.block(top + d) == water and level(top + d) > 1:
				return
		set_level(top, 0)


func _hollow(c: Vector3i) -> bool:
	## An empty cell walled in on all four sides: rain collects here.
	if World.block(c) != 0 or World.be_at.has(c):
		return false
	for d in SIDES:
		var id := World.block(c + d)
		if id != water and not (Blocks.is_solid(id) and Blocks.is_opaque(id)):
			return false
	return true
