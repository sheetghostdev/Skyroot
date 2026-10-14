class_name Icons
extends RefCounted
## Item icons from the atlas made by tools/art/gen_items.py, and the 3D item
## models made from them: every opaque pixel becomes a little block, so what you
## hold and what lies on the ground look exactly like the icon.  Block items show
## a small cube with the block's own textures instead.

const META := "res://assets/textures/items.json"
const ATLAS := "res://assets/textures/items.png"

static var _index: Dictionary = {}
static var _tile := 32
static var _cols := 16
static var _atlas_tex: Texture2D = null
static var _atlas_img: Image = null
static var _tex_cache: Dictionary = {}
static var _mesh_cache: Dictionary = {}
static var _mat: StandardMaterial3D = null


static func _load() -> void:
	if not _index.is_empty():
		return
	var f := FileAccess.open(META, FileAccess.READ)
	var m = JSON.parse_string(f.get_as_text()) if f else null
	if not m is Dictionary:
		push_error("Icons: missing " + META)
		return
	_tile = int(m.get("tile", 32))
	_cols = int(m.get("cols", 16))
	var i := 0
	for n in m["names"]:
		_index[String(n)] = i
		i += 1


static func has(key: String) -> bool:
	_load()
	return _index.has(key)


static func _atlas() -> Texture2D:
	if _atlas_tex == null:
		_atlas_tex = load(ATLAS)
	return _atlas_tex


static func _image() -> Image:
	if _atlas_img == null:
		var t := _atlas()
		if t:
			_atlas_img = t.get_image()
			if _atlas_img.is_compressed():
				_atlas_img.decompress()
			_atlas_img.convert(Image.FORMAT_RGBA8)
	return _atlas_img


static func _rect(key: String) -> Rect2i:
	var i := int(_index.get(key, -1))
	if i < 0:
		return Rect2i()
	return Rect2i((i % _cols) * _tile, (i / _cols) * _tile, _tile, _tile)


static func key_for(id: String, d: Dictionary = {}) -> String:
	_load()
	var k := ItemDB.icon_key(id, d)
	if _index.has(k):
		return k
	# tools and heads always have a material variant
	if _index.has(id + "@stone"):
		return id + "@stone"
	return k


static func texture(id: String, d: Dictionary = {}) -> Texture2D:
	var key := key_for(id, d)
	if _tex_cache.has(key):
		return _tex_cache[key]
	if not _index.has(key):
		return null
	var at := AtlasTexture.new()
	at.atlas = _atlas()
	at.region = Rect2(_rect(key))
	at.filter_clip = true
	_tex_cache[key] = at
	return at


static func material() -> StandardMaterial3D:
	if _mat == null:
		_mat = StandardMaterial3D.new()
		_mat.vertex_color_use_as_albedo = true
		_mat.roughness = 0.85
		_mat.vertex_color_is_srgb = true
	return _mat


static func mesh(id: String, d: Dictionary = {}) -> Mesh:
	## The item as a 3D object, about 0.5 m across (callers scale it).  Block items
	## are a 1 m cube with the block's textures.
	var key := key_for(id, d)
	var b := ItemDB.block_of(id)
	if b >= 0 and Blocks.shape[b] == Blocks.Shape.CUBE:
		key = "#block:%d" % b
	if _mesh_cache.has(key):
		return _mesh_cache[key]
	var m: Mesh = null
	if key.begins_with("#block:"):
		m = _block_mesh(b)
	else:
		m = _extrude(key)
	_mesh_cache[key] = m
	return m


static func _extrude(key: String) -> Mesh:
	_load()
	var img := _image()
	if img == null or not _index.has(key):
		var bm := BoxMesh.new()
		bm.size = Vector3(0.3, 0.3, 0.3)
		return bm
	var r := _rect(key)
	var px := 1.0 / _tile
	var depth := px * 1.6
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var opaque := func(x: int, y: int) -> bool:
		if x < 0 or y < 0 or x >= _tile or y >= _tile:
			return false
		return img.get_pixel(r.position.x + x, r.position.y + y).a > 0.5
	for y in _tile:
		for x in _tile:
			if not opaque.call(x, y):
				continue
			var c := img.get_pixel(r.position.x + x, r.position.y + y)
			var x0 := (x - _tile * 0.5) * px
			var x1 := x0 + px
			var y1 := (_tile * 0.5 - y) * px
			var y0 := y1 - px
			var z0 := -depth * 0.5
			var z1 := depth * 0.5
			# front and back
			_q(st, Vector3(x0, y0, z1), Vector3(x1, y0, z1), Vector3(x1, y1, z1), Vector3(x0, y1, z1), Vector3(0, 0, 1), c)
			_q(st, Vector3(x1, y0, z0), Vector3(x0, y0, z0), Vector3(x0, y1, z0), Vector3(x1, y1, z0), Vector3(0, 0, -1), c * Color(0.8, 0.8, 0.8, 1))
			var cs := c * Color(0.72, 0.72, 0.72, 1)
			if not opaque.call(x, y - 1):
				_q(st, Vector3(x0, y1, z1), Vector3(x1, y1, z1), Vector3(x1, y1, z0), Vector3(x0, y1, z0), Vector3(0, 1, 0), cs)
			if not opaque.call(x, y + 1):
				_q(st, Vector3(x0, y0, z0), Vector3(x1, y0, z0), Vector3(x1, y0, z1), Vector3(x0, y0, z1), Vector3(0, -1, 0), cs)
			if not opaque.call(x - 1, y):
				_q(st, Vector3(x0, y0, z0), Vector3(x0, y0, z1), Vector3(x0, y1, z1), Vector3(x0, y1, z0), Vector3(-1, 0, 0), cs)
			if not opaque.call(x + 1, y):
				_q(st, Vector3(x1, y0, z1), Vector3(x1, y0, z0), Vector3(x1, y1, z0), Vector3(x1, y1, z1), Vector3(1, 0, 0), cs)
	var m := st.commit()
	if m.get_surface_count() > 0:
		m.surface_set_material(0, material())
	return m


static func _q(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, n: Vector3, col: Color) -> void:
	## Quad a-b-c-d counter-clockwise seen from the front (normal n).
	for v in [a, c, b, a, d, c]:
		st.set_normal(n)
		st.set_color(col)
		st.add_vertex(v)


static func _block_mesh(b: int) -> Mesh:
	var surf := ChunkMesher.Surf.new()
	ChunkMesher.box_faces(surf, Vector3(-0.5, -0.5, -0.5), Vector3(0.5, 0.5, 0.5), 0.0, Vector3.ZERO,
		Blocks.face_tex[b * 6 + 2], Blocks.face_tex[b * 6], Color.WHITE)
	# box_faces samples a tile region by position: shift UVs back into 0..1
	for i in surf.uv.size():
		surf.uv[i] = Vector2(fposmod(surf.uv[i].x, 1.0), fposmod(surf.uv[i].y, 1.0))
	# the bottom face shows the block's bottom texture
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, surf.arrays())
	var mat := ShaderMaterial.new()
	mat.shader = load("res://assets/shaders/voxel_solid.gdshader")
	mat.set_shader_parameter("atlas", BlockTex.array())
	m.surface_set_material(0, mat)
	return m


static func clear() -> void:
	_tex_cache.clear()
	_mesh_cache.clear()
	_atlas_tex = null
	_atlas_img = null
	_mat = null
