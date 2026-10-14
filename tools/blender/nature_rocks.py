"""Skyroot rocks: boulder_a/b/c, flat_stone, outcrop (+ Loose_0..7 cobbles).

    blender -b --python tools/blender/nature_rocks.py
"""
import os
import sys
import math
import random

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bpy
import bmesh
from mathutils import Vector, Matrix

import nature_lib as N
from nature_lib import V, clamp, smoothstep, lerp, n1, RockPart


def shape_and_embed(bm, embed=0.15, squash_low=0.55, lean=(0.0, 0.0), spin=0.0):
    """Squash the lower half (bottom-heavy), lean/spin, centre footprint, sink to z=-embed."""
    zs = [v.co.z for v in bm.verts]
    zc = (min(zs) + max(zs)) * 0.5
    for v in bm.verts:
        if v.co.z < zc:
            v.co.z = zc + (v.co.z - zc) * squash_low
    rot = Matrix.Rotation(spin, 4, "Z") @ Matrix.Rotation(lean[0], 4, "X") @ Matrix.Rotation(lean[1], 4, "Y")
    for v in bm.verts:
        v.co = rot @ v.co
    xs = [v.co.x for v in bm.verts]
    ys = [v.co.y for v in bm.verts]
    zmin = min(v.co.z for v in bm.verts)
    off = V((-(min(xs) + max(xs)) / 2, -(min(ys) + max(ys)) / 2, -embed - zmin))
    for v in bm.verts:
        v.co += off


def boulder(name, parts, seed, moss=0.5, embed=0.15, squash_low=1.0, lean=(0, 0), spin=0.0, warp=0.025, target=1100):
    bm = bmesh.new()
    N.build_rock_parts(bm, parts)
    shape_and_embed(bm, embed, squash_low, lean, spin)
    N.densify(bm, 0.06, min_nz=0.1)
    w = N.moss_field(bm, seed=seed, amount=moss, zmin=0.08)
    ob = N.rock_object(name, bm, seed=seed, moss_w=w, dissolve=2.0, warp=warp, target_tris=target)
    N.paint_rock(ob, seed=seed)
    return ob


# ----------------------------------------------------------------------------
# flat stone: polytope slab with an exactly flat top at z = 0.45
# ----------------------------------------------------------------------------

ZT = 0.45


def flat_stone(seed=5):
    rng = random.Random(seed)
    TOPU = 0.45  # top plane height in unit space
    planes = [(V((0, 0, -1)), 0.62)]
    for k in range(12):  # steep sides
        a = k / 12 * math.tau + rng.uniform(-0.15, 0.15)
        planes.append((V((math.cos(a), math.sin(a), rng.uniform(-0.15, 0.1))).normalized(), rng.uniform(0.88, 0.95)))
    for k in range(9):  # weathered shoulders: depth chosen so the flat top reaches rho ~0.8 (unit)
        a = (k + 0.5) / 9 * math.tau + rng.uniform(-0.2, 0.2)
        e = math.radians(rng.uniform(38, 56))
        rho = rng.uniform(0.79, 0.84)
        d = rho * math.cos(e) + TOPU * math.sin(e)
        planes.append((V((math.cos(a) * math.cos(e), math.sin(a) * math.cos(e), math.sin(e))), d))
    for k in range(6):  # lower facets
        a = k / 6 * math.tau + rng.uniform(-0.4, 0.4)
        e = math.radians(rng.uniform(-40, -22))
        planes.append((V((math.cos(a) * math.cos(e), math.sin(a) * math.cos(e), math.sin(e))), rng.uniform(0.74, 0.84)))
    part = RockPart((0, 0, ZT - TOPU * 0.55), (0.57, 0.43, 0.55), planes, subdiv=3, top_clamp=ZT,
                    seed=seed, bevel=0.022)
    bm = bmesh.new()
    N.build_rock_parts(bm, [part])
    N.densify(bm, 0.06, min_nz=2.0, face_filter=lambda f: f.calc_center_median().z < 0.3)

    def central(p):
        return p.z > ZT - 0.002  # never warp the work surface

    def excl(p):
        # never moss on the flat work surface itself (only on the shoulders / sides)
        return 2.0 if p.z > ZT - 0.012 else 0.0

    def top_face(f):
        return all(v.co.z > ZT - 1e-4 for v in f.verts)

    w = N.moss_field(bm, seed=seed, amount=0.0, nz_min=0.25, exclude=excl, zmin=0.5, skirt=0.95, skirt_h=0.2)
    ob = N.rock_object("FlatStone", bm, seed=seed, moss_w=w, dissolve=2.0, warp=0.03, keep=central,
                       cushion=0.01, target_tris=None, zclamp=ZT, protect=top_face)

    def worn_top(p, n, col):
        if p.z > ZT - 0.004:
            r = math.hypot(p.x / 0.45, p.y / 0.33)
            col = N.mix(col, N.pal("stone_light"), 0.28 * (1.0 - N.smoothstep(0.3, 1.0, r)))
            col = N.scale_col(col, 1.0 + 0.06 * n1(p, 6.0, seed + 21, 2))
        return col

    N.paint_rock(ob, seed=seed, warm=0.004, extra=worn_top)
    return ob


def check_flat(ob, zt=ZT, hx=0.30, hy=0.225):
    bvh = N.world_bvh([ob])
    zs = []
    for i in range(25):
        for j in range(19):
            x = -hx + 2 * hx * i / 24
            y = -hy + 2 * hy * j / 18
            hit = N.raycast_down(bvh, x, y, 2.0)
            zs.append(hit.z if hit else -9)
    print(f"[flat_stone] top z over 0.6x0.45 central area: min {min(zs):.4f} max {max(zs):.4f}")
    return min(zs), max(zs)


# ----------------------------------------------------------------------------
# outcrop
# ----------------------------------------------------------------------------

def outcrop(seed=21):
    rng = random.Random(seed)
    P = lambda n, d=(0.8, 0.95), z=1.0: N.random_planes(n, rng, d, 0.3, z)
    parts = [
        RockPart((0.2, 0.05, 0.5), (1.0, 0.78, 0.92), P(14, (0.62, 0.84)), roundness=0.05, seed=seed),       # main
        RockPart((-0.8, -0.08, 0.32), (0.66, 0.62, 0.62), P(11, (0.6, 0.84)), roundness=0.05, seed=seed + 1),  # side
        RockPart((0.05, 0.12, 1.02), (0.58, 0.48, 0.4), P(10, (0.62, 0.84), 1.1), roundness=0.05, seed=seed + 2),  # stacked
        RockPart((1.0, -0.42, 0.08), (0.52, 0.43, 0.3), P(11, (0.62, 0.84), 1.2), roundness=0.05, seed=seed + 3),  # low slab
        RockPart((-0.64, 0.64, 0.08), (0.41, 0.36, 0.27), P(9, (0.62, 0.84)), roundness=0.05, seed=seed + 4),  # small
    ]
    bm = bmesh.new()
    N.build_rock_parts(bm, parts)
    for v in bm.verts:  # fit the spec footprint (~2.6 x 1.8 m, <= ~1.3 m tall)
        v.co.x *= 0.88
        v.co.z *= 0.84
    zmin = min(v.co.z for v in bm.verts)
    xs = [v.co.x for v in bm.verts]
    ys = [v.co.y for v in bm.verts]
    off = V((-(min(xs) + max(xs)) / 2, -(min(ys) + max(ys)) / 2, -0.16 - zmin))
    for v in bm.verts:
        v.co += off
    N.densify(bm, 0.075, min_nz=0.1)
    w = N.moss_field(bm, seed=seed, amount=0.55, zmin=0.06)
    ob = N.rock_object("Outcrop", bm, seed=seed, moss_w=w, dissolve=2.0, warp=0.035, cushion=0.02, target_tris=2600)
    return ob


def loose_stones(main, seed=33):
    rng = random.Random(seed)
    bvh = N.world_bvh([main], ground=0.0)
    spots = [(-0.3, -0.05), (0.3, -0.3), (0.75, -0.45), (-0.95, -0.4), (1.2, 0.2), (-1.2, 0.4),
             (0.4, 0.78), (-0.15, -0.78)]
    stones = []
    for i, (x0, y0) in enumerate(spots):
        size = rng.uniform(0.085, 0.115)
        best = None
        for k in range(40):  # search nearby for a flat-ish resting spot
            x = x0 + (rng.uniform(-1, 1) * 0.12 * k ** 0.5 if k else 0)
            y = y0 + (rng.uniform(-1, 1) * 0.12 * k ** 0.5 if k else 0)
            hit = bvh.ray_cast(V((x, y, 4.0)), V((0, 0, -1)), 10.0)
            if hit[0] is not None and hit[1].z > 0.86:
                best = (x, y, hit[0].z)
                break
        if best is None:
            best = (x0, y0, 0.0)
        x, y, z = best
        half = V((size * 0.5, size * 0.5 * rng.uniform(0.75, 0.95), size * 0.5 * rng.uniform(0.55, 0.75)))
        bm = bmesh.new()
        part = RockPart((0, 0, 0), half * 1.22, N.random_planes(9, rng, (0.7, 0.86)), subdiv=2,
                        seed=seed + i, bevel=min(half) * 0.25)
        N.build_rock_parts(bm, [part])
        rot = Matrix.Rotation(rng.uniform(0, math.tau), 4, "Z") @ Matrix.Rotation(rng.uniform(-0.2, 0.2), 4, "X")
        for v in bm.verts:
            v.co = rot @ v.co
        bmesh.ops.triangulate(bm, faces=bm.faces[:])
        zmin = min(v.co.z for v in bm.verts)
        ob = N.new_object(f"Loose_{i}", bm, mats=["Stone"], smooth=False)
        N.decimate_to(ob, 110)
        ob.location = V((x, y, z - zmin - half.z * 0.3))  # origin at the cobble's centre
        ob.parent = main
        ob.matrix_parent_inverse = Matrix.Identity(4)
        N.smooth_by_angle(ob, 40.0)
        stones.append(ob)
    bpy.context.view_layer.update()
    return stones


def main():
    rng = random.Random(1)
    # ---------------- boulders
    specs = {
        "boulder_a": dict(parts=[RockPart((0, 0, 0), (0.55, 0.47, 0.5), N.random_planes(13, random.Random(3), (0.62, 0.84)),
                                          roundness=0.05, seed=3)],
                          seed=3, moss=0.52, spin=0.4),
        "boulder_b": dict(parts=[RockPart((0, 0, 0), (0.4, 0.36, 0.7), N.random_planes(10, random.Random(8), (0.6, 0.82)),
                                          roundness=0.045, seed=8)],
                          seed=8, moss=0.42, lean=(0.16, -0.1), squash_low=0.75, spin=1.1),
        "boulder_c": dict(parts=[RockPart((-0.24, 0, 0), (0.58, 0.5, 0.36), N.random_planes(12, random.Random(14), (0.62, 0.86), 0.3, 1.3),
                                          roundness=0.05, seed=14),
                                 RockPart((0.38, 0.06, -0.04), (0.42, 0.4, 0.31), N.random_planes(10, random.Random(15), (0.62, 0.86), 0.3, 1.3),
                                          roundness=0.05, seed=15)],
                          seed=14, moss=0.6, spin=-0.3, squash_low=0.6, target=1400),
    }
    for name, sp in specs.items():
        N.reset()
        ob = boulder(name.capitalize(), sp["parts"], sp["seed"], moss=sp["moss"], lean=sp.get("lean", (0, 0)),
                     spin=sp.get("spin", 0.0), squash_low=sp.get("squash_low", 0.55), target=sp.get("target", 700))
        N.export_glb(f"nature/{name}.glb", [ob])
        bb = [ob.matrix_world @ V(c) for c in ob.bound_box]
        print(f"[{name}] size x {max(v.x for v in bb) - min(v.x for v in bb):.2f} "
              f"y {max(v.y for v in bb) - min(v.y for v in bb):.2f} zmin {min(v.z for v in bb):.2f} "
              f"zmax {max(v.z for v in bb):.2f}")
        N.preview(name, [ob], views=((18, 35), (30, 200)))

    # ---------------- flat stone
    N.reset()
    fs = flat_stone()
    check_flat(fs)
    N.export_glb("nature/flat_stone.glb", [fs])
    bb = [fs.matrix_world @ V(c) for c in fs.bound_box]
    print(f"[flat_stone] size x {max(v.x for v in bb) - min(v.x for v in bb):.2f} "
          f"y {max(v.y for v in bb) - min(v.y for v in bb):.2f} zmin {min(v.z for v in bb):.2f} "
          f"zmax {max(v.z for v in bb):.3f}")
    N.preview("flat_stone", [fs], views=((25, 35), (55, 120)))

    # ---------------- outcrop
    N.reset()
    oc = outcrop()
    stones = loose_stones(oc)
    N.paint_rock(oc, seed=21, occluders=stones, ao_dist=0.8)
    for i, s in enumerate(stones):
        N.paint_rock(s, seed=40 + i, occluders=[oc], ao_dist=0.2, value=0.8)
    N.export_glb("nature/outcrop.glb", [oc])
    bb = [oc.matrix_world @ V(c) for c in oc.bound_box]
    print(f"[outcrop] size x {max(v.x for v in bb) - min(v.x for v in bb):.2f} "
          f"y {max(v.y for v in bb) - min(v.y for v in bb):.2f} zmin {min(v.z for v in bb):.2f} "
          f"zmax {max(v.z for v in bb):.2f}  main tris {N.triangle_count([oc])}")
    for s in stones:
        p = s.matrix_world.translation
        dims = s.dimensions
        print(f"[outcrop] {s.name} blender ({p.x:.3f}, {p.y:.3f}, {p.z:.3f}) size {max(dims):.3f} "
              f"tris {N.triangle_count([s])}")
    N.preview("outcrop", [oc] + stones, views=((22, 35), (28, 160), (40, 260)), dist_mul=3.0)


main()
