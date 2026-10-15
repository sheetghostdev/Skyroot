class_name VoxelBody
extends RefCounted
## Axis-aligned box physics against the block grid and rafts (a SolidFrame):
## move along Y, then X, then Z, clipping against every solid box in the way.
## Steps up low ledges (farmland, beds) on its own, and while sneaking it won't
## walk off an edge.

const STEP := 0.6

var half := 0.3          # half width
var height := 1.8
var on_ground := false
var hit_wall := false


func box_at(p: Vector3) -> AABB:
	return AABB(Vector3(p.x - half, p.y, p.z - half), Vector3(half * 2.0, height, half * 2.0))


func move(vd: SolidFrame, pos: Vector3, motion: Vector3, sneak_guard: bool) -> Dictionary:
	## Returns {"pos", "motion" (what was actually moved)}.
	var box := box_at(pos)
	var want := motion
	var region := box.merge(AABB(box.position + motion, box.size)).grow(0.05)
	var boxes := vd.solid_boxes(region)
	# Y
	var dy := _clip(boxes, box, motion.y, 1)
	box.position.y += dy
	var landed := motion.y < 0.0 and dy > motion.y + 1e-5
	on_ground = landed
	# X and Z, with the sneak guard keeping you on what you stand on
	var dx := _clip(boxes, box, motion.x, 0)
	if sneak_guard and on_ground_check(vd, box, Vector3(dx, 0, 0)) == false:
		dx = 0.0
	box.position.x += dx
	var dz := _clip(boxes, box, motion.z, 2)
	if sneak_guard and on_ground_check(vd, box, Vector3(0, 0, dz)) == false:
		dz = 0.0
	box.position.z += dz
	hit_wall = absf(dx - want.x) > 1e-4 or absf(dz - want.z) > 1e-4
	# step up onto something low
	if hit_wall and (on_ground or _ground_below(vd, box)) and not sneak_guard:
		var stepped := _try_step(vd, box_at(pos), motion)
		if not stepped.is_empty():
			return stepped
	return {"pos": Vector3(box.position.x + half, box.position.y, box.position.z + half), "motion": Vector3(dx, dy, dz)}


func _try_step(vd: SolidFrame, start: AABB, motion: Vector3) -> Dictionary:
	var box := start
	var boxes := vd.solid_boxes(box.merge(AABB(box.position + motion + Vector3(0, STEP, 0), box.size)).grow(0.05))
	var up := _clip(boxes, box, STEP, 1)
	if up < 0.05:
		return {}
	box.position.y += up
	var dx := _clip(boxes, box, motion.x, 0)
	box.position.x += dx
	var dz := _clip(boxes, box, motion.z, 2)
	box.position.z += dz
	if Vector2(dx, dz).length() < Vector2(motion.x, motion.z).length() * 0.5:
		return {}
	var down := _clip(boxes, box, -up - 0.01, 1)
	box.position.y += down
	# only a real step: we must end up higher than we started, standing on something
	if box.position.y - start.position.y < 0.05 or box.position.y - start.position.y > STEP + 0.01:
		return {}
	on_ground = true
	hit_wall = false
	return {"pos": Vector3(box.position.x + half, box.position.y, box.position.z + half), "motion": Vector3(dx, box.position.y - start.position.y, dz)}


func _clip(boxes: Array[AABB], box: AABB, d: float, axis: int) -> float:
	if absf(d) < 1e-9:
		return 0.0
	var a1 := (axis + 1) % 3
	var a2 := (axis + 2) % 3
	for b in boxes:
		# only boxes overlapping on the other two axes
		if b.end[a1] <= box.position[a1] + 1e-6 or b.position[a1] >= box.end[a1] - 1e-6:
			continue
		if b.end[a2] <= box.position[a2] + 1e-6 or b.position[a2] >= box.end[a2] - 1e-6:
			continue
		if d > 0.0 and b.position[axis] >= box.end[axis] - 1e-6:
			d = minf(d, b.position[axis] - box.end[axis])
		elif d < 0.0 and b.end[axis] <= box.position[axis] + 1e-6:
			d = maxf(d, b.end[axis] - box.position[axis])
	return d


func _ground_below(vd: SolidFrame, box: AABB) -> bool:
	var probe := AABB(box.position - Vector3(0, 0.08, 0), Vector3(box.size.x, 0.08, box.size.z))
	for b in vd.solid_boxes(probe):
		if b.intersects(probe):
			return true
	return false


func on_ground_check(vd: SolidFrame, box: AABB, move_by: Vector3) -> bool:
	## Would the box still have ground under some part of it after moving?
	if move_by.length() < 1e-6:
		return true
	var moved := AABB(box.position + move_by, box.size)
	var probe := AABB(moved.position + Vector3(0.05, -0.62, 0.05), Vector3(moved.size.x - 0.1, 0.62, moved.size.z - 0.1))
	for b in vd.solid_boxes(probe):
		if b.intersects(probe):
			return true
	return false


func fits(vd: SolidFrame, pos: Vector3, h: float) -> bool:
	var box := AABB(Vector3(pos.x - half, pos.y, pos.z - half), Vector3(half * 2.0, h, half * 2.0)).grow(-0.01)
	for b in vd.solid_boxes(box):
		if b.intersects(box):
			return false
	return true
