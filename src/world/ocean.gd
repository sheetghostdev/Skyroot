class_name Ocean
extends Node3D
## The open sea of an archipelago: a water plane out to the horizon, the
## islands far away as coarse shapes (so you can steer for them), and the look
## of being under water.  Near you the real blocks are drawn instead: both
## shaders step aside inside the square of loaded chunks.

const FAR_STEP := 2              # far islands are sampled every this many blocks

var voxels: VoxelView
var sea_y := 30.875
var plane: MeshInstance3D
var plane_mat: ShaderMaterial
var land_mat: ShaderMaterial
var lands: Array[MeshInstance3D] = []
var underwater := false


func _ready() -> void:
	var sea := int(World.geo.get("sea", 30))
	sea_y = sea + 0.85
	plane_mat = ShaderMaterial.new()
	plane_mat.shader = load("res://assets/shaders/ocean.gdshader")
	var pm := PlaneMesh.new()
	pm.size = Vector2(6000, 6000)
	plane = MeshInstance3D.new()
	plane.mesh = pm
	plane.material_override = plane_mat
	plane.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	plane.position.y = sea_y
	add_child(plane)
	land_mat = ShaderMaterial.new()
	land_mat.shader = load("res://assets/shaders/far_land.gdshader")
	for isl in World.geo.get("islands", []):
		var mi := MeshInstance3D.new()
		mi.mesh = _far_island(isl, sea)
		mi.material_override = land_mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mi)
		lands.append(mi)


func _far_island(isl: Dictionary, sea: int) -> ArrayMesh:
	## A heightfield of the island's tops (trees included), every FAR_STEP blocks.
	var vd := World.vox
	var c: Vector2 = isl["c"]
	var r := float(isl["r"]) * 1.25 + 4.0
	var x0 := maxi(0, int(c.x - r))
	var z0 := maxi(0, int(c.y - r))
	var x1 := mini(vd.sx - 1, int(c.x + r))
	var z1 := mini(vd.sz - 1, int(c.y + r))
	var nx := (x1 - x0) / FAR_STEP + 1
	var nz := (z1 - z0) / FAR_STEP + 1
	var hts := PackedFloat32Array()
	var cols := PackedColorArray()
	hts.resize(nx * nz)
	cols.resize(nx * nz)
	for j in nz:
		for i in nx:
			var x := x0 + i * FAR_STEP
			var z := z0 + j * FAR_STEP
			var h := vd.column_height(x, z)
			var y := float(h + 1) if h > sea else -1.0
			hts[i + j * nx] = y
			if y > 0.0:
				var id := vd.get_id(x, h, z)
				cols[i + j * nx] = BlockTex.avg_color(Blocks.face_tex[id * 6]).srgb_to_linear()
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var s := float(FAR_STEP)
	for j in nz:
		for i in nx:
			var y := hts[i + j * nx]
			if y < 0.0:
				continue
			var x := float(x0 + i * FAR_STEP)
			var z := float(z0 + j * FAR_STEP)
			var col := cols[i + j * nx]
			# the top
			_quad(st, Vector3(x, y, z), Vector3(x, y, z + s), Vector3(x + s, y, z + s), Vector3(x + s, y, z), Vector3.UP, col)
			# sides down to the neighbour (or the sea)
			var side := col.darkened(0.25)
			var nbr := [[i + 1, j, Vector3(x + s, 0, z), Vector3(x + s, 0, z + s), Vector3.RIGHT],
				[i - 1, j, Vector3(x, 0, z + s), Vector3(x, 0, z), Vector3.LEFT],
				[i, j + 1, Vector3(x + s, 0, z + s), Vector3(x, 0, z + s), Vector3.BACK],
				[i, j - 1, Vector3(x, 0, z), Vector3(x + s, 0, z), Vector3.FORWARD]]
			for nb in nbr:
				var ni: int = nb[0]
				var nj: int = nb[1]
				var ny := float(sea)
				if ni >= 0 and nj >= 0 and ni < nx and nj < nz and hts[ni + nj * nx] > 0.0:
					ny = hts[ni + nj * nx]
				if ny >= y:
					continue
				var a: Vector3 = nb[2]
				var b: Vector3 = nb[3]
				_quad(st, Vector3(a.x, y, a.z), Vector3(a.x, ny, a.z), Vector3(b.x, ny, b.z), Vector3(b.x, y, b.z), nb[4], side)
	return st.commit()


func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, n: Vector3, col: Color) -> void:
	for v in [a, b, c, a, c, d]:
		st.set_color(col)
		st.set_normal(n)
		st.add_vertex(v)


func _process(_delta: float) -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	plane.global_position = Vector3(cam.global_position.x, sea_y, cam.global_position.z)
	# step aside where the real blocks are drawn
	var r := voxels.radius if voxels else 0
	var cc := voxels.cam_chunk() if voxels else Vector2i(-9999, -9999)
	var cs := VoxelView.CS
	var nmin := Vector2((cc.x - r) * cs, (cc.y - r) * cs)
	var nmax := Vector2((cc.x + r + 1) * cs, (cc.y + r + 1) * cs)
	for m in [plane_mat, land_mat]:
		(m as ShaderMaterial).set_shader_parameter("near_min", nmin)
		(m as ShaderMaterial).set_shader_parameter("near_max", nmax)
	underwater = World.vox.liquid_at(cam.global_position)
	plane.visible = not underwater


func set_colors(day: float, overcast: float) -> void:
	var w := Color(0.10, 0.40, 0.46).lerp(Color(0.02, 0.06, 0.1), 1.0 - day).lerp(Color(0.25, 0.32, 0.36), overcast * 0.5)
	var dcol := Color(0.03, 0.15, 0.22).lerp(Color(0.01, 0.03, 0.06), 1.0 - day)
	plane_mat.set_shader_parameter("water_col", Vector3(w.r, w.g, w.b))
	plane_mat.set_shader_parameter("deep_col", Vector3(dcol.r, dcol.g, dcol.b))
