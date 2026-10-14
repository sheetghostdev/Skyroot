extends EntityView
## Clay being shaped: the layers built so far, and on the layer you are working
## a faint outline of where clay still has to go.  Clay where it shouldn't be
## shows red.

var mi: MeshInstance3D
var ghost: MeshInstance3D


func _build() -> void:
	mi = add_mesh(null)
	ghost = add_mesh(null, Transform3D.IDENTITY, false)


func _refresh(_keys: Array) -> void:
	var d := data()
	var r := String(d.get("r", ""))
	var vox: PackedByteArray = d.get("vox", PackedByteArray())
	var tex := BlockTex.layer("clay_raw")
	if r == "" or not ItemDB.clayforming.has(r):
		# an unshaped lump
		mi.mesh = boxes_mesh([[Vector3(0.36, 0, 0.38), Vector3(0.64, 0.14, 0.62), "clay_raw"], [Vector3(0.4, 0.14, 0.42), Vector3(0.6, 0.2, 0.58), "clay_raw"]])
		ghost.mesh = null
		return
	var layers: Array = ItemDB.clayforming[r]["layers"]
	var layer := int(d.get("layer", 0))
	mi.mesh = KnapView.grid_mesh(vox, 16, mini(layer + 1, layers.size()), tex, func(i: int) -> Color:
		var l := i / 256
		var target: PackedByteArray = layers[clampi(l, 0, layers.size() - 1)]
		return Color.WHITE if target[i % 256] == 1 else Color(1.0, 0.55, 0.5))
	# the outline of what still has to be filled on this layer
	if layer < layers.size():
		var target2: PackedByteArray = layers[layer]
		var need := PackedByteArray()
		need.resize(256 * (layer + 1))
		for i in 256:
			var k := layer * 256 + i
			if target2[i] == 1 and (k >= vox.size() or vox[k] == 0):
				need[k] = 1
		ghost.mesh = KnapView.grid_mesh(need, 16, layer + 1, tex, func(_i: int) -> Color: return Color.WHITE, _ghost_mat())
	else:
		ghost.mesh = null


func _ghost_mat() -> Material:
	return EntityModels.get_or_build("mat:ghost", func():
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.albedo_color = Color(0.85, 0.95, 1.0, 0.28)
		m.no_depth_test = false
		return m)
