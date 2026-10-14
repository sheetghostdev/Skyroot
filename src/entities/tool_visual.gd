class_name ToolVisual
extends RefCounted
## A hafted tool: wooden handle + the actual knapped head + cord binding.


static func make(id: String, d: Dictionary) -> Node3D:
	var root := Node3D.new()
	root.name = "Tool_" + id
	var handle_len := 0.46
	var handle := MeshInstance3D.new()
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var segs := 8
	var rings := 6
	for r in rings + 1:
		var f := float(r) / rings
		var x := -handle_len * 0.5 + handle_len * f
		var rad := lerpf(0.0155, 0.013, f) * (1.0 + 0.05 * sin(f * 9.0))
		for s in segs:
			var a := float(s) / segs * TAU
			var nrm := Vector3(0, cos(a), sin(a))
			st.set_normal(nrm)
			st.set_color(ProcMesh.BARK.lerp(ProcMesh.WOOD, 0.35 + 0.1 * sin(a * 3.0 + f * 5.0)).srgb_to_linear())
			st.add_vertex(Vector3(x, cos(a) * rad, sin(a) * rad))
	for r in rings:
		for s in segs:
			var a := r * segs + s
			var b := r * segs + (s + 1) % segs
			var c := (r + 1) * segs + s
			var e := (r + 1) * segs + (s + 1) % segs
			st.add_index(a)
			st.add_index(b)
			st.add_index(c)
			st.add_index(b)
			st.add_index(e)
			st.add_index(c)
	handle.mesh = st.commit()
	handle.material_override = Models.material_for("Wood")
	root.add_child(handle)
	var head_d: Dictionary = d.get("head", {})
	var head := MeshInstance3D.new()
	head.mesh = Knap.build_mesh(int(head_d.get("seed", 3)), head_d.get("cuts", []))
	head.material_override = Models.material_for("Stone")
	# Knapped head: X = length, Z = width.  Mount it across the handle end, bit pointing forward (+Y).
	var tip_x := handle_len * 0.5 - 0.03
	if id == "digger":
		head.transform = Transform3D(Basis.from_euler(Vector3(PI * 0.5, 0.0, PI * 0.5)), Vector3(tip_x, 0.03, 0.0))
	else:
		head.transform = Transform3D(Basis.from_euler(Vector3(0.0, 0.0, PI * 0.5)), Vector3(tip_x, 0.035, 0.0))
	root.add_child(head)
	var wraps := int(d.get("wraps", 7))
	var bind := MeshInstance3D.new()
	var tor := CylinderMesh.new()
	tor.top_radius = 0.021
	tor.bottom_radius = 0.021
	tor.height = clampf(wraps * 0.0045, 0.015, 0.06)
	tor.radial_segments = 10
	bind.mesh = tor
	var rope := Models.material_for("Rope")
	bind.material_override = rope
	bind.rotation.z = PI * 0.5
	bind.position = Vector3(tip_x, 0.0, 0.0)
	root.add_child(bind)
	_paint_rope(bind)
	return root


static func _paint_rope(mi: MeshInstance3D) -> void:
	# CylinderMesh has no vertex colours; give the binding its own flat material.
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.72, 0.62, 0.42)
	m.roughness = 0.95
	mi.material_override = m
