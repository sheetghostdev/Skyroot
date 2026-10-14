"""Skyroot young trees: sapling.glb (~0.9 m) and young_tree.glb (~3 m).  Same species/style as the
centrepiece skyroot_tree (shared bark / leaf painting).

    blender -b --python tools/blender/nature_young_trees.py
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
from nature_lib import V, clamp, smoothstep, lerp, n1, Clump, pal, mix, shift, scale_col
import nature_tree as TR


def flare_rmod(base_z, height, amount, lobes, seed):
    """Radius multiplier for a tube near its base: soft root flare with a few lobes."""
    def rm(i, p, d):
        z = p.z - base_z
        if z > height:
            return 1.0
        a = math.atan2(d.y, d.x)
        lob = sum(A * math.exp(-(TR.angdiff(a, la) / 0.45) ** 2) for la, A in lobes)
        f = math.exp(-max(z, 0.0) / (height * 0.35))
        return 1.0 + amount * f * (1.0 + lob)
    return rm


def grow_branch(bm, tl, base, d, length, r0, segs, seed, up=0.25, droop=0.0, n=6, wob=0.03, tip_r=0.004):
    d = Vector(d).normalized()
    p1 = base + d * length * 0.35
    p2 = base + d * length * 0.7 + V((0, 0, length * up))
    p3 = base + d * length * 0.95 + V((0, 0, length * (up * 1.2 - droop)))
    pts = N.bezier_points(base, p1, p2, p3, n)
    pts = N.wobble(pts, wob, 3.0, seed, fix_start=1)
    radii = [lerp(r0, tip_r, (k / (n - 1)) ** 0.9) for k in range(n)]
    rings, _ = N.tube_ex(bm, pts, radii, segs=segs, noise_amp=0.06, noise_scale=8.0, seed=seed, cap_start=True,
                         cap_end=True, tip_len=1.0)
    TR.set_tip(rings, tl, 0.3, 1.0)
    return pts


def finish(trunk_bm, leaf_clumps, name_bark="Tree", seed=1, leaf_dist=0.8, bark_dist=0.5, zhi=3.0, fresh=0.0,
           scale=1.0):
    bark = N.new_object(name_bark, trunk_bm, mats=["Bark"], smooth=True)
    lbm = bmesh.new()
    N.build_clumps(lbm, leaf_clumps)
    leaves = N.new_object(name_bark + "Leaves", lbm, mats=["Leaves"], smooth=True)
    leaves.parent = bark
    bpy.context.view_layer.update()
    ao_b = N.bake_ao([bark], occluders=[leaves], samples=24, dist=bark_dist, ground=0.0)
    ao_l = N.bake_ao([leaves], occluders=[bark], samples=24, dist=leaf_dist, ground=0.0)
    N.paint_ex(bark, TR.bark_fn(ao_b[bark.name], N.cavity(bark), N.attr_values(bark, "tipw"), "branch"))
    tints = [shift(mix(t, pal("leaf_light"), fresh), dh=-0.01 * fresh) for t in
             TR.leaf_tints(len(leaf_clumps), random.Random(seed))]
    N.paint_ex(leaves, TR.leaf_fn(ao_l[leaves.name], N.attr_values(leaves, "clump"), tints, zlo=0.0, zhi=zhi))
    N.strip_attrs(bark)
    N.strip_attrs(leaves)
    if scale != 1.0:
        for o in (bark, leaves):
            o.data.transform(Matrix.Scale(scale, 4))
    return bark, leaves


# ----------------------------------------------------------------------------

def sapling(seed=3):
    rng = random.Random(seed)
    bm = bmesh.new()
    tl = bm.verts.layers.float.new("tipw")
    H = 0.66
    stem = N.bezier_points(V((0, 0, -0.05)), V((0.0, 0.0, 0.25)), V((0.06, 0.02, 0.45)), V((0.04, -0.02, H)), 8)
    stem = N.wobble(stem, 0.012, 6.0, seed, fix_start=2)
    radii = [lerp(0.016, 0.004, (k / 7) ** 0.9) for k in range(8)]
    rings, _ = N.tube_ex(bm, stem, radii, segs=6, noise_amp=0.05, noise_scale=12.0, seed=seed, cap_start=True,
                         cap_end=True, tip_len=1.0,
                         rmod=flare_rmod(0.0, 0.07, 0.5, [(0.5, 0.6), (2.6, 0.5), (4.4, 0.7)], seed))
    TR.set_tip(rings, tl, 0.0, 0.9)
    clumps = []
    top = stem[-1]
    clumps.append(Clump(top + V((0.0, 0.0, 0.06)), 0.115, squash=(1.0, 1.0, 0.85), amp=0.2, nscale=1.4, octaves=2,
                        seed=seed * 3, freq=3, flat_bottom=0.35))
    twigs = [(0.42, 40, 0.2, 0.088), (0.56, 175, 0.17, 0.082), (0.33, 285, 0.21, 0.09), (0.7, 100, 0.13, 0.075)]
    for k, (t, az, L, R) in enumerate(twigs):
        p, tan = N.point_at(stem, t)
        a = math.radians(az + rng.uniform(-10, 10))
        d = V((math.cos(a), math.sin(a), 0.75))
        tip = grow_branch(bm, tl, p, d, L, radii[int(t * 7)] * 0.6, 5, seed + k * 7, up=0.15, n=4, tip_r=0.002)
        clumps.append(Clump(tip[-1] + V((0, 0, R * 0.25)), R, squash=(1.05, 1.05, 0.8), amp=0.2, nscale=1.5,
                            octaves=2, seed=seed * 3 + k + 1, freq=3, flat_bottom=0.35))
    bark, leaves = finish(bm, clumps, "Sapling", seed=seed, leaf_dist=0.3, bark_dist=0.2, zhi=0.9, fresh=0.35)
    return bark, leaves


def young_tree(seed=11):
    rng = random.Random(seed)
    bm = bmesh.new()
    tl = bm.verts.layers.float.new("tipw")
    lean = V((0.08, 0.05, 0))
    # trunk with a fork at ~1.35 m into two leaders
    trunk = N.bezier_points(V((0, 0, -0.1)), V((0, 0, 0.5)), lean * 0.6 + V((0, 0, 1.0)), lean + V((0, 0, 1.45)), 8)
    trunk = N.wobble(trunk, 0.02, 2.5, seed, fix_start=3)
    radii = [lerp(0.085, 0.055, (k / 7)) for k in range(8)]
    rings, _ = N.tube_ex(bm, trunk, radii, segs=9, noise_amp=0.07, noise_scale=5.0, seed=seed, cap_start=True,
                         cap_end=True, tip_len=1.0,
                         rmod=flare_rmod(0.0, 0.35, 0.55, [(0.4, 0.6), (1.9, 0.4), (3.3, 0.7), (4.9, 0.5)], seed))
    TR.set_tip(rings, tl, 0.0, 0.3)
    fork = trunk[-2]
    leaders = []
    for k, (dx, dy, L) in enumerate([(0.35, -0.12, 1.55), (-0.3, 0.28, 1.35)]):
        d = V((dx, dy, 1.0))
        pts = grow_branch(bm, tl, fork - V((0, 0, 0.12)), d, L, 0.05, 7, seed + 20 + k, up=0.05, n=7, wob=0.05)
        leaders.append(pts)
    clumps = []
    # branches: 4, from trunk and leaders
    specs = [(trunk, 0.62, 200, 0.95, 0.035), (trunk, 0.8, 40, 0.85, 0.032), (leaders[0], 0.45, 320, 0.8, 0.028),
             (leaders[1], 0.4, 120, 0.75, 0.026)]
    for k, (path, t, az, L, r) in enumerate(specs):
        p, tan = N.point_at(path, t)
        a = math.radians(az + rng.uniform(-8, 8))
        d = V((math.cos(a), math.sin(a), 0.55))
        tip = grow_branch(bm, tl, p - d.normalized() * 0.03, d, L, r, 6, seed + 40 + k, up=0.3, n=6, wob=0.04)
        R = rng.uniform(0.42, 0.5)
        clumps.append(Clump(tip[-1] + V((0, 0, R * 0.25)), R, squash=(1.05, 1.05, 0.8), amp=0.22, nscale=1.3,
                            octaves=2, seed=seed * 5 + k, freq=3, flat_bottom=0.4))
        pm, _ = N.point_at(tip, 0.55)
        Rm = R * 0.75
        clumps.append(Clump(pm + V((0, 0, Rm * 0.6)), Rm, squash=(1.1, 1.1, 0.72), amp=0.22, nscale=1.3, octaves=2,
                            seed=seed * 5 + k + 20, freq=3, flat_bottom=0.45))
    for k, pts in enumerate(leaders):
        R = 0.6 - 0.05 * k
        clumps.append(Clump(pts[-1] + V((0, 0, R * 0.3)), R, squash=(1.0, 1.0, 0.85), amp=0.22, nscale=1.2, octaves=2,
                            seed=seed * 5 + 40 + k, freq=4, flat_bottom=0.4))
        pm, _ = N.point_at(pts, 0.6)
        clumps.append(Clump(pm + V((0, 0, 0.2)), 0.48, squash=(1.0, 1.0, 0.8), amp=0.22, nscale=1.3, octaves=2,
                            seed=seed * 5 + 50 + k, freq=3, flat_bottom=0.4))
    top = (leaders[0][-1] + leaders[1][-1]) / 2
    clumps.append(Clump(top + V((0, 0, 0.45)), 0.5, squash=(1.0, 1.0, 0.85), amp=0.24, nscale=1.3, octaves=2,
                        seed=seed * 5 + 60, freq=3, flat_bottom=0.4))
    bark, leaves = finish(bm, clumps, "YoungTree", seed=seed, leaf_dist=1.0, bark_dist=0.8, zhi=3.1, fresh=0.12,
                          scale=0.89)
    return bark, leaves


def main():
    N.reset()
    b, l = sapling()
    N.report_tris([b, l])
    bb = [o.matrix_world @ V(c) for o in (b, l) for c in o.bound_box]
    print(f"[sapling] height {max(v.z for v in bb):.2f} width {max(v.x for v in bb) - min(v.x for v in bb):.2f}")
    N.export_glb("nature/sapling.glb", [b])
    N.preview("sapling", [b, l], views=((14, 35), (25, 160)), dist_mul=3.0)

    N.reset()
    b, l = young_tree()
    N.report_tris([b, l])
    bb = [o.matrix_world @ V(c) for o in (b, l) for c in o.bound_box]
    print(f"[young_tree] height {max(v.z for v in bb):.2f} width {max(v.x for v in bb) - min(v.x for v in bb):.2f}")
    N.export_glb("nature/young_tree.glb", [b])
    N.preview("young_tree", [b, l], views=((12, 35), (20, 200)), dist_mul=3.0)


main()
