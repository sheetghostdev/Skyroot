extends EntityView
class_name KnapView
## A stone laid flat for knapping: a 16 x 16 slab of little cells.  Once you
## have picked what to make, the cells that must go are tinted; the shape that
## stays keeps the stone's own colour.

var mi: MeshInstance3D


func _build() -> void:
	mi = add_mesh(null)


func _refresh(_keys: Array) -> void:
	var d := data()
	var cells: PackedByteArray = d.get("cells", PackedByteArray())
	var r := String(d.get("r", ""))
	var mask: PackedByteArray = ItemDB.knapping[r]["mask"] if ItemDB.knapping.has(r) else PackedByteArray()
	var tex := BlockTex.layer("flint" if String(d.get("mat", "stone")) == "flint" else "granite_knap")
	# the shape stays bright; the cells touching it - the ones to chip - are red;
	# the rest of the waste, which will fall away by itself, is dark
	var ring := PackedByteArray()
	ring.resize(256)
	if not mask.is_empty():
		for i in 256:
			if cells[i] == 1 and mask[i] == 0:
				var x := i % 16
				var z := i / 16
				for o in [[1, 0], [-1, 0], [0, 1], [0, -1]]:
					var nx: int = x + o[0]
					var nz: int = z + o[1]
					if nx >= 0 and nz >= 0 and nx < 16 and nz < 16 and mask[nx + nz * 16] == 1:
						ring[i] = 1
						break
	mi.mesh = grid_mesh(cells, 16, 1, tex, func(i: int) -> Color:
		if mask.is_empty():
			return Color.WHITE
		if mask[i % 256] == 1:
			return Color(1.25, 1.22, 1.15)
		return Color(0.95, 0.38, 0.3) if ring[i % 256] == 1 else Color(0.5, 0.48, 0.47))


static func grid_mesh(vox: PackedByteArray, n: int, layers: int, tex: int, tint: Callable, mat: Material = null) -> ArrayMesh:
	## Cells of a 16 x 16 x layers work grid as little boxes (inner faces culled).
	var s := ChunkMesher.Surf.new()
	var u := 1.0 / n
	var at := func(x: int, y: int, z: int) -> bool:
		if x < 0 or z < 0 or x >= n or z >= n or y < 0 or y >= layers:
			return false
		var i := y * n * n + x + z * n
		return i < vox.size() and vox[i] == 1
	for y in layers:
		for z in n:
			for x in n:
				if not at.call(x, y, z):
					continue
				var i := y * n * n + x + z * n
				var col: Color = tint.call(i)
				var a := Vector3(x * u, y * u, z * u)
				var b := a + Vector3(u, u, u)
				var cull := func(f: int, _a: Vector3, _b: Vector3) -> bool:
					match f:
						0: return at.call(x, y + 1, z)
						1: return true if y == 0 else at.call(x, y - 1, z)
						2: return at.call(x, y, z - 1)
						3: return at.call(x, y, z + 1)
						4: return at.call(x + 1, y, z)
						5: return at.call(x - 1, y, z)
					return false
				ChunkMesher.box_faces(s, a, b, 0.0, Vector3.ZERO, tex, tex, Color(col.r, col.g, col.b, 1.0), cull)
	var m := ArrayMesh.new()
	var arr := s.arrays()
	if not arr.is_empty():
		m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
		m.surface_set_material(0, mat if mat else EntityView.block_mat())
	return m
