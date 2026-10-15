class_name Raft
extends RefCounted
## What every machine needs to know about rafts.
##
## A raft is an entity ("raft") with a little grid of its own: "cells" maps a
## local cell (Vector3i) to Vector2i(block id, meta).  Layer 0 is the floor of
## lashed logs, whose top is the deck at local y = 1; things built on the deck
## stand in layer 1 and up, just like on the ground.  The entity's transform
## places the grid in the world (turned about Y only) so the deck sits a hand
## above the sea.  The host moves it (RaftSim); everyone draws it (RaftView)
## and stands on it.

const DECK := 1.0                # local height of the deck (top of the floor logs)
const FREEBOARD := 0.12          # how far the deck stands above the sea surface
const MAX_SPAN := 12             # a raft can reach this many cells from its first one
const MAX_LAYER := 4


static func origin_y(sea: int) -> float:
	## World y of the grid's origin so the deck floats FREEBOARD above the sea.
	return float(sea) + 0.875 + FREEBOARD - DECK


static func cell_boxes(id: int, m: int) -> Array:
	## Collision boxes of one cell's block, block-local, turned for facing blocks.
	var out: Array = []
	for b in Blocks.collide.get(id, []):
		var box: AABB = b
		if Blocks.facing[id] == 1:
			box = Blocks.turn_box(box.position, box.end, m)
		out.append(box)
	return out


static func boxes(cells: Dictionary, region: AABB) -> Array[AABB]:
	## Local collision boxes of every cell touching region (local space).
	var out: Array[AABB] = []
	var a := VoxelData.cell_of(region.position)
	var b := VoxelData.cell_of(region.end)
	for y in range(a.y, b.y + 1):
		for z in range(a.z, b.z + 1):
			for x in range(a.x, b.x + 1):
				var c := Vector3i(x, y, z)
				var v = cells.get(c)
				if v == null:
					continue
				var id: int = (v as Vector2i).x
				if Blocks.solid[id] == 0:
					continue
				for bx in cell_boxes(id, (v as Vector2i).y):
					out.append(AABB((bx as AABB).position + Vector3(c), (bx as AABB).size))
	return out


static func bounds(cells: Dictionary) -> AABB:
	var lo := Vector3(INF, INF, INF)
	var hi := Vector3(-INF, -INF, -INF)
	for c in cells:
		lo = lo.min(Vector3(c))
		hi = hi.max(Vector3(c) + Vector3.ONE)
	if cells.is_empty():
		return AABB()
	return AABB(lo, hi - lo)


static func com(cells: Dictionary) -> Vector3:
	## The middle of the floor (local), which the raft turns about.
	var s := Vector3.ZERO
	var n := 0
	for c in cells:
		if (c as Vector3i).y == 0:
			s += Vector3(c) + Vector3(0.5, 0.0, 0.5)
			n += 1
	return s / maxf(1.0, n) + Vector3(0, DECK, 0)


static func floor_count(cells: Dictionary) -> int:
	var n := 0
	for c in cells:
		if (c as Vector3i).y == 0:
			n += 1
	return n


static func connected(cells: Dictionary) -> bool:
	## Is the floor all in one piece?
	var floor_cells: Array = []
	for c in cells:
		if (c as Vector3i).y == 0:
			floor_cells.append(c)
	if floor_cells.is_empty():
		return true
	var seen := {floor_cells[0]: true}
	var q: Array = [floor_cells[0]]
	while not q.is_empty():
		var p: Vector3i = q.pop_back()
		for d in [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]:
			var n: Vector3i = p + d
			if cells.has(n) and not seen.has(n):
				seen[n] = true
				q.append(n)
	return seen.size() == floor_cells.size()


static func select_box(id: int, m: int) -> AABB:
	## The outline of a cell's block (local to the cell), turned as it stands;
	## a raft's own pieces (mast, oar) are outlined whole.
	var box := Blocks.select_box(id, m)
	if Blocks.has_flag(id, "raft_only") and id != Blocks.id_of("raft_floor"):
		box = Blocks.select_whole.get(id, box)
	if Blocks.facing[id] == 1:
		box = Blocks.turn_box(box.position, box.end, m)
	return box


static func raycast(cells: Dictionary, origin: Vector3, dir: Vector3, max_dist: float) -> Dictionary:
	## A ray (local space) against the raft's cells: {} or {"cell", "normal",
	## "point", "dist", "id"} (local).  Uses each block's selection box.
	dir = dir.normalized()
	var best := {}
	var best_t := max_dist
	for c in cells:
		var v: Vector2i = cells[c]
		var box := select_box(v.x, v.y)
		if not box.has_volume():
			continue
		var r := VoxelData._ray_box(origin, dir, AABB(box.position + Vector3(c), box.size))
		if r.is_empty():
			continue
		var t: float = r["t"]
		if t < best_t:
			best_t = t
			best = {"cell": c, "normal": r["n"], "point": origin + dir * t, "dist": t, "id": v.x}
	return best


static func supported(cells: Dictionary, c: Vector3i) -> bool:
	## Could a block stand in this cell (something under it, on the raft)?
	return c.y >= 1 and cells.has(c + Vector3i.DOWN)


static func floor_ok(cells: Dictionary, c: Vector3i) -> bool:
	## Could another floor section go here (next to the floor, within reach)?
	if c.y != 0 or cells.has(c):
		return false
	if absi(c.x) > MAX_SPAN or absi(c.z) > MAX_SPAN:
		return false
	for d in [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]:
		if cells.has(c + d):
			return true
	return false
