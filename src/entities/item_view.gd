extends EntityView
## A stack lying on the ground: the item, slowly turning and bobbing (a few of
## them for a bigger stack).  It drops from where it was let go.

var pivot: Node3D
var _t := 0.0
var _wait := 0.0


func _build() -> void:
	pivot = Node3D.new()
	add_child(pivot)
	var d := data()
	var id := String(d["i"])
	var n := 1 if int(d["n"]) == 1 else (2 if int(d["n"]) < 8 else 3)
	var model := ItemModels.mesh(id, d.get("d", {}))
	if model:
		# the real thing (a touch larger than life, so it catches the eye)
		for xf in ItemModels.pile(id, n, d.get("d", {})):
			var mi := MeshInstance3D.new()
			mi.mesh = model
			mi.transform = Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * 1.2), Vector3(0, 0.04, 0)) * (xf as Transform3D)
			pivot.add_child(mi)
	else:
		var mesh := Icons.mesh(id, d.get("d", {}))
		var b := ItemDB.block_of(id)
		var is_block := b >= 0 and Blocks.shape[b] == Blocks.Shape.CUBE
		var s := 0.24 if is_block else 0.36
		for i in n:
			var mi := MeshInstance3D.new()
			mi.mesh = mesh
			mi.scale = Vector3.ONE * s
			mi.position = Vector3(i * 0.06, s * 0.5 + 0.05 + i * 0.03, -i * 0.05)
			mi.rotation.y = i * 0.6
			pivot.add_child(mi)
	_t = randf() * 10.0
	_wait = float(d.get("w", 0)) / 1000.0
	if _wait > 0.0:
		visible = false   # still part of something falling (a toppling tree)
		return
	_drop_in()


func _on_raft() -> RaftView:
	var rid := int(data().get("raft", -1))
	return RaftView.find(rid) if rid >= 0 else null


func _drop_in() -> void:
	if int(data().get("raft", -1)) >= 0:
		return     # placed on the deck every frame instead
	var from = data().get("from", null)
	if from is Vector3 and (from as Vector3).distance_to(position) > 0.05:
		_fall_from(from)


func _fall_from(from: Vector3) -> void:
	var to := position
	position = from
	var dist := absf(from.y - to.y)
	var tw := create_tween()
	tw.tween_property(self, "position", to, clampf(sqrt(dist / 14.0) + 0.12, 0.15, 1.6)).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)


func _moved(xf: Transform3D) -> void:
	if int(data().get("raft", -1)) >= 0:
		return
	var from := position
	transform = xf
	_fall_from(from)


func _process(delta: float) -> void:
	_t += delta
	if _wait > 0.0:
		_wait -= delta
		if _wait <= 0.0:
			visible = true
			_drop_in()
	pivot.rotation.y = _t * 0.8
	pivot.position.y = sin(_t * 2.0) * 0.03 + 0.03
	# lying on a raft's deck: where this machine draws the raft
	var raft := _on_raft()
	if raft:
		global_transform = raft.view_xf() * Transform3D(Basis(), data().get("rp", Vector3.ZERO))
