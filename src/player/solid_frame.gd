class_name SolidFrame
extends RefCounted
## What a body bumps into, seen from one frame of reference: the block world
## and every raft.  Riding a raft you move in the raft's own frame, where its
## blocks line up with the axes (and it carries you as it turns); the world's
## blocks and other rafts are then seen at an angle and stand in as the boxes
## around them, which is close enough for a shore or a raft alongside.

var vd: VoxelData
var xf := Transform3D.IDENTITY       # this frame -> world
var raft := -1                       # the raft whose frame this is (-1: the world)
var _inv := Transform3D.IDENTITY
var _rafts: Array = []               # [{"eid", "rel" (raft local -> this frame), "cells"}]


func _init(v: VoxelData, rafts: Array = [], frame_raft := -1) -> void:
	## rafts: [{"eid", "xf" (raft local -> world), "cells"}]
	vd = v
	raft = frame_raft
	for r in rafts:
		if int(r["eid"]) == frame_raft:
			xf = r["xf"]
	_inv = xf.affine_inverse()
	for r in rafts:
		_rafts.append({"eid": int(r["eid"]), "rel": _inv * (r["xf"] as Transform3D), "cells": r["cells"]})


func to_world(p: Vector3) -> Vector3:
	return xf * p


func to_local(p: Vector3) -> Vector3:
	return _inv * p


func solid_boxes(region: AABB) -> Array[AABB]:
	var out: Array[AABB] = []
	if raft < 0:
		out = vd.solid_boxes(region)
	else:
		for b in vd.solid_boxes(xf * region):
			out.append(_inv * b)
	for r in _rafts:
		var cells: Dictionary = r["cells"]
		if int(r["eid"]) == raft:
			out.append_array(Raft.boxes(cells, region))
			continue
		var rel: Transform3D = r["rel"]
		for b in Raft.boxes(cells, rel.affine_inverse() * region):
			out.append(rel * b)
	return out


func raft_under(p: Vector3, half: float) -> int:
	## The raft right under a body's feet at p (this frame), or -1.
	var probe := AABB(p + Vector3(-half + 0.02, -0.12, -half + 0.02), Vector3(half * 2.0 - 0.04, 0.14, half * 2.0 - 0.04))
	var best := -1
	for r in _rafts:
		var rel: Transform3D = r["rel"]
		var lp := rel.affine_inverse() * probe
		for b in Raft.boxes(r["cells"], lp):
			if b.intersects(lp):
				if int(r["eid"]) == raft:
					return raft
				best = int(r["eid"])
				break
	return best
