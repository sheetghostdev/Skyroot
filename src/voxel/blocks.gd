class_name Blocks
extends RefCounted
## The block registry: data/blocks.json flattened into per-id lookup tables so
## the mesher, physics and raycasts (some of which run on worker threads) can read
## them without touching dictionaries.  Loaded once; read-only afterwards.

enum Shape { NONE, CUBE, CROSS, BOXES, BUSH, LIQUID }
enum Face { TOP, BOTTOM, NORTH, SOUTH, EAST, WEST }   # +Y -Y -Z +Z +X -X

const AIR := 0
const MAX := 64

static var loaded := false
static var defs: Dictionary = {}          # name -> def dictionary
static var by_name: Dictionary = {}       # name -> id
static var names: PackedStringArray = []
static var shape: PackedByteArray = []
static var solid: PackedByteArray = []
static var opaque: PackedByteArray = []   # hides neighbour faces, blocks skylight
static var cutout: PackedByteArray = []
static var sky_cost: PackedByteArray = [] # extra skylight attenuation through this block
static var light: PackedByteArray = []
static var axis: PackedByteArray = []
static var jitter: PackedByteArray = []   # cross plants placed a little off-centre
static var hang: PackedByteArray = []     # hangs from the block above
static var replace: PackedByteArray = []
static var fixture: PackedByteArray = []  # drawn by a model of its own (torches), not the chunk mesh
static var wall: PackedByteArray = []     # can hang on the side of a block (meta 1-4: which side)
static var facing: PackedByteArray = []   # boxes turn with meta & 3 (drawn facing -Z)
static var sway: PackedFloat32Array = []
static var tint: PackedFloat32Array = []
static var y_off: PackedFloat32Array = []
static var scale: PackedFloat32Array = []
# texture layers: [id * 6 + face]
static var face_tex: PackedInt32Array = []
# per-meta textures for cross/bush/boxes-top: id -> PackedInt32Array
static var meta_tex: Dictionary = {}
# boxes: id -> Array of {"a": Vector3, "b": Vector3, "tex": int, "top": PackedInt32Array, "rot": float}
static var boxes: Dictionary = {}
# collision boxes in block-local units (0..1): id -> Array[AABB]
static var collide: Dictionary = {}
# selection boxes: id -> AABB
static var select: Dictionary = {}


static func load_all() -> void:
	if loaded:
		return
	BlockTex.load_meta()
	var f := FileAccess.open("res://data/blocks.json", FileAccess.READ)
	var parsed = JSON.parse_string(f.get_as_text()) if f else null
	if not parsed is Dictionary:
		push_error("Blocks: cannot read data/blocks.json")
		return
	# (packed arrays are values: resize each one by name)
	names.resize(MAX)
	shape.resize(MAX)
	solid.resize(MAX)
	opaque.resize(MAX)
	cutout.resize(MAX)
	sky_cost.resize(MAX)
	light.resize(MAX)
	axis.resize(MAX)
	replace.resize(MAX)
	fixture.resize(MAX)
	wall.resize(MAX)
	facing.resize(MAX)
	jitter.resize(MAX)
	hang.resize(MAX)
	sway.resize(MAX)
	tint.resize(MAX)
	y_off.resize(MAX)
	scale.resize(MAX)
	face_tex.resize(MAX * 6)
	for nm in parsed:
		if String(nm).begins_with("_"):
			continue
		var d: Dictionary = parsed[nm]
		var id := int(d["id"])
		d["name"] = nm
		defs[nm] = d
		by_name[nm] = id
		names[id] = nm
		var sh := String(d.get("shape", "cube"))
		shape[id] = {"none": Shape.NONE, "cube": Shape.CUBE, "cross": Shape.CROSS, "boxes": Shape.BOXES,
			"bush": Shape.BUSH, "liquid": Shape.LIQUID}.get(sh, Shape.CUBE)
		solid[id] = 1 if bool(d.get("solid", sh == "cube")) else 0
		opaque[id] = 1 if bool(d.get("opaque", sh == "cube")) else 0
		cutout[id] = 1 if bool(d.get("cutout", false)) else 0
		light[id] = int(d.get("light", 0))
		axis[id] = 1 if bool(d.get("axis", false)) else 0
		fixture[id] = 1 if String(d.get("fixture", "")) != "" else 0
		wall[id] = 1 if bool(d.get("wall", false)) else 0
		facing[id] = 1 if bool(d.get("facing", false)) else 0
		replace[id] = 1 if bool(d.get("replace", false)) or sh == "none" or sh == "liquid" else 0
		jitter[id] = 1 if sh == "cross" and not d.has("crop") else 0
		hang[id] = 1 if String(d.get("attach", "")) == "ceiling" else 0
		sway[id] = float(d.get("sway", 0.0))
		tint[id] = float(d.get("tint", 0.0))
		y_off[id] = float(d.get("y_off", 0.0)) / 16.0
		scale[id] = float(d.get("scale", 1.0))
		if bool(d.get("leaves", false)) or sh == "liquid":
			sky_cost[id] = 2
		elif opaque[id] == 0 and sh == "bush":
			sky_cost[id] = 1
		_textures(id, d)
		_shapes(id, d)
	loaded = true


static func _textures(id: int, d: Dictionary) -> void:
	var tx = d.get("tex", "")
	var faces := [0, 0, 0, 0, 0, 0]
	if tx is String:
		var l := BlockTex.layer(tx) if tx != "" else 0
		faces = [l, l, l, l, l, l]
	elif tx is Dictionary:
		var side := BlockTex.layer(String(tx.get("side", tx.get("all", ""))))
		faces = [BlockTex.layer(String(tx.get("top", tx.get("side", "")))),
			BlockTex.layer(String(tx.get("bottom", tx.get("side", "")))), side, side, side, side]
	elif tx is Array:
		var arr := PackedInt32Array()
		for t in tx:
			arr.append(BlockTex.layer(String(t)))
		meta_tex[id] = arr
		faces = [arr[0], arr[0], arr[0], arr[0], arr[0], arr[0]]
	for i in 6:
		face_tex[id * 6 + i] = faces[i]


static func _shapes(id: int, d: Dictionary) -> void:
	var sh := shape[id]
	var cols: Array = []
	if sh == Shape.BOXES:
		var list: Array = []
		var lo := Vector3(1, 1, 1)
		var hi := Vector3.ZERO
		for b in d.get("boxes", []):
			var a := Vector3(b["from"][0], b["from"][1], b["from"][2]) / 16.0
			var c := Vector3(b["to"][0], b["to"][1], b["to"][2]) / 16.0
			var top := PackedInt32Array()
			for t in b.get("top", []):
				top.append(BlockTex.layer(String(t)))
			list.append({"a": a, "b": c, "tex": BlockTex.layer(String(b.get("tex", ""))), "top": top,
				"rot": deg_to_rad(float(b.get("rot", 0.0)))})
			lo = lo.min(a)
			hi = hi.max(c)
			if solid[id] and not d.has("collide"):
				cols.append(AABB(a, c - a))
		for cb in d.get("collide", []):
			cols.append(AABB(Vector3(cb[0], cb[1], cb[2]) / 16.0, Vector3(cb[3] - cb[0], cb[4] - cb[1], cb[5] - cb[2]) / 16.0))
		boxes[id] = list
		var pad := Vector3(0.04, 0.02, 0.04)
		select[id] = AABB((lo - pad).max(Vector3.ZERO), (hi - lo + pad * 2.0).min(Vector3.ONE))
	elif sh == Shape.CUBE:
		cols.append(AABB(Vector3.ZERO, Vector3.ONE))
		select[id] = AABB(Vector3.ZERO, Vector3.ONE)
	elif sh == Shape.CROSS:
		var s := scale[id]
		select[id] = AABB(Vector3(0.5 - 0.35 * s, y_off[id], 0.5 - 0.35 * s), Vector3(0.7 * s, 0.8 * s, 0.7 * s))
	elif sh == Shape.BUSH:
		select[id] = AABB(Vector3(0.06, 0.0, 0.06), Vector3(0.88, 0.9, 0.88))
	elif sh == Shape.LIQUID:
		select[id] = AABB(Vector3.ZERO, Vector3(1, 0.875, 1))
	collide[id] = cols


const WALL_DIRS := [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]


static func on_wall(id: int, m: int) -> bool:
	return id >= 0 and wall[id] == 1 and (m & 7) >= 1 and (m & 7) <= 4


static func wall_dir(m: int) -> Vector3i:
	## From a wall-hung block toward the block it hangs on.
	return WALL_DIRS[clampi((m & 7) - 1, 0, 3)]


static func wall_meta(to_wall: Vector3i) -> int:
	return WALL_DIRS.find(to_wall) + 1


static func select_box(id: int, m: int) -> AABB:
	if on_wall(id, m):
		var ctr := Vector3(0.5, 0.52, 0.5) + Vector3(wall_dir(m)) * 0.3
		return AABB(ctr - Vector3(0.17, 0.4, 0.17), Vector3(0.34, 0.8, 0.34))
	return select.get(id, AABB())


const FACE_DIRS := [Vector3i(0, 0, -1), Vector3i(1, 0, 0), Vector3i(0, 0, 1), Vector3i(-1, 0, 0)]


static func facing_dir(m: int) -> Vector3i:
	## Which way a turned block (a bed: from its foot to its head) points.
	return FACE_DIRS[m & 3]


static func facing_meta(yaw: float) -> int:
	## The turn that points the way someone at this yaw is looking.
	var f := Vector3(-sin(yaw), 0.0, -cos(yaw))
	var best := 0
	for i in 4:
		if Vector3(FACE_DIRS[i]).dot(f) > Vector3(FACE_DIRS[best]).dot(f):
			best = i
	return best


static func turn_box(a: Vector3, b: Vector3, m: int) -> AABB:
	## A block-local box (drawn facing -Z) turned to face facing_dir(m).
	var p := a
	var q := b
	for i in (m & 3):
		# a quarter turn: -Z becomes +X
		var p2 := Vector3(1.0 - p.z, p.y, p.x)
		var q2 := Vector3(1.0 - q.z, q.y, q.x)
		p = p2.min(q2)
		q = p2.max(q2)
	return AABB(p, q - p)


static func id_of(nm: String) -> int:
	return int(by_name.get(nm, -1))


static func name_of(id: int) -> String:
	return names[id] if id >= 0 and id < names.size() else ""


static func def(id: int) -> Dictionary:
	return defs.get(name_of(id), {})


static func label(id: int) -> String:
	var d := def(id)
	return String(d.get("label", String(d.get("name", "?")).capitalize()))


static func is_solid(id: int) -> bool:
	return solid[id] == 1


static func is_opaque(id: int) -> bool:
	return opaque[id] == 1


static func is_replaceable(id: int) -> bool:
	return replace[id] == 1


static func has_flag(id: int, key: String) -> bool:
	return bool(def(id).get(key, false))
