"""Skyroot misc nature props: mossy_log, hanging_roots, hanging_vines.

    blender -b --python tools/blender/nature_misc.py
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
from nature_lib import V, clamp, smoothstep, lerp, n1, pal, mix, shift, scale_col, PlantBM
import nature_tree as TR

UP = V((0, 0, 1))
BARK, WOOD, WOODEND, MOSS = 0, 1, 2, 3


# ----------------------------------------------------------------------------
# mossy log
# ----------------------------------------------------------------------------

def mossy_log(seed=14):
    rng = random.Random(seed)
    L = 1.4
    R = 0.14
    SINK = 0.05
    NS = 14
    NR = 13
    bm = bmesh.new()
    lay = bm.verts.layers.float.new("mossw")
    rings = []
    centers = []
    for i in range(NR):
        t = i / (NR - 1)
        x = lerp(-L / 2, L / 2, t)
        c = V((x, 0.035 * math.sin(t * math.pi * 1.3 + 0.4), R - SINK - 0.012 * math.sin(t * math.pi)))
        centers.append(c)
        r = R * lerp(1.04, 0.95, t) * (1.0 + 0.04 * math.sin(t * 9.0))
        ring = []
        for s in range(NS):
            a = s / NS * math.tau
            d = V((0, math.cos(a), math.sin(a)))
            rr = r * (1.0 + 0.07 * n1(V((x * 2.0, math.cos(a) * 1.2, math.sin(a) * 1.2)), 1.0, seed, 2)
                      + 0.035 * n1(V((x * 0.6, math.cos(a * 3) * 2, math.sin(a * 3) * 2)), 1.0, seed + 1, 1))
            p = c + d * rr
            if p.z < -SINK + 0.02:  # flatten the sunk underside
                p.z = lerp(p.z, -SINK + 0.02, 0.6)
            ring.append(bm.verts.new(p))
        rings.append(ring)
    for i in range(NR - 1):
        N.bridge_rings(bm, rings[i], rings[i + 1])
    # broken (+x) end: jagged ring pushed in/out along the axis, splintered cap
    last = rings[-1]
    cL = centers[-1]
    for s, v in enumerate(last):
        v.co.x += rng.uniform(-0.06, 0.07) + 0.04 * math.sin(s * 2.3)
    inner = []
    for s, v in enumerate(last):
        off = v.co - V((v.co.x, cL.y, cL.z))
        q = V((v.co.x, cL.y, cL.z)) + off * 0.62
        q.x += rng.uniform(-0.05, 0.08)
        inner.append(bm.verts.new(q))
    for s in range(NS):
        s2 = (s + 1) % NS
        f = bm.faces.new((last[s], last[s2], inner[s2], inner[s]))
        f.material_index = WOOD
    tipc = bm.verts.new(V((cL.x + 0.03, cL.y, cL.z)))
    for s in range(NS):
        f = bm.faces.new((inner[s], inner[(s + 1) % NS], tipc))
        f.material_index = WOOD
    # splinters
    for k in range(4):
        s = rng.randrange(NS)
        v0 = last[s].co.copy()
        dirn = V((1.0, rng.uniform(-0.2, 0.2), rng.uniform(-0.1, 0.25))).normalized()
        lenk = rng.uniform(0.08, 0.16)
        side = (last[(s + 1) % NS].co - last[s].co)
        a = bm.verts.new(v0 - side * 0.05 - (v0 - V((v0.x, cL.y, cL.z))).normalized() * 0.03)
        b = bm.verts.new(v0 + side * 0.6 - (v0 - V((v0.x, cL.y, cL.z))).normalized() * 0.03)
        c = bm.verts.new(v0 + side * 0.25 + (v0 - V((v0.x, cL.y, cL.z))).normalized() * 0.005)
        tip = bm.verts.new(v0 + side * 0.25 + dirn * lenk)
        for fv in ((a, b, tip), (b, c, tip), (c, a, tip)):
            f = bm.faces.new(fv)
            f.material_index = WOOD
    # weathered (-x) end: end grain with a soft rotten hollow
    first = rings[0]
    c0 = centers[0]
    prev = first
    for k, f_ in enumerate((0.86, 0.6, 0.34)):
        ring = []
        for v in first:
            off = v.co - V((v.co.x, c0.y, c0.z))
            q = V((v.co.x, c0.y, c0.z)) + off * f_
            q.x += 0.01 + (0.025 if k == 2 else 0.0)
            ring.append(bm.verts.new(q))
        for s in range(NS):
            s2 = (s + 1) % NS
            fc = bm.faces.new((prev[s2], prev[s], ring[s], ring[s2]))
            fc.material_index = BARK if k == 0 else WOODEND
        prev = ring
    cc = bm.verts.new(V((c0.x + 0.06, c0.y, c0.z)))
    for s in range(NS):
        fc = bm.faces.new((prev[(s + 1) % NS], prev[s], cc))
        fc.material_index = WOODEND
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    # moss on top of the bark (not on the end faces)
    bm.normal_update()
    for v in bm.verts:
        bark_only = all(f.material_index == BARK for f in v.link_faces)
        if not bark_only:
            v[lay] = 0.0
            continue
        up = smoothstep(0.15, 0.75, v.normal.z)
        brk = 0.5 + 0.5 * clamp(n1(v.co, 3.0, seed, 3) * 1.4, -1, 1)
        endfade = 1.0 - smoothstep(0.52, 0.68, abs(v.co.x))
        v[lay] = clamp(up * (0.3 + 0.8 * brk) * endfade + 0.1)
    N.split_by_field(bm, "mossw", moss_index=MOSS, stone_index=BARK)
    ob = N.new_object("MossyLog", bm, mats=["Bark", "Wood", "WoodEnd", "Moss"], smooth=True)
    me = ob.data
    bmc = bmesh.new()
    bmc.from_mesh(me)
    N.moss_cushion_bm(bmc, 0.02, seed=seed)
    bmc.to_mesh(me)
    bmc.free()
    N.smooth_by_angle(ob, 50.0)
    # centre the footprint on the origin (origin = bottom centre at ground level)
    xs = [v.co.x for v in me.vertices]
    ys = [v.co.y for v in me.vertices]
    me.transform(Matrix.Translation(V((-(min(xs) + max(xs)) / 2, -(min(ys) + max(ys)) / 2, 0))))
    centers = [c + V((-(min(xs) + max(xs)) / 2, -(min(ys) + max(ys)) / 2, 0)) for c in centers]
    # paint
    ao = N.bake_ao([ob], samples=24, dist=0.35, ground=0.0)[ob.name]
    cav = N.cavity(ob)
    mw = N.attr_values(ob, "mossw")
    bark_f = TR.bark_fn(ao, cav, [0.15] * len(me.vertices), "log")
    moss_f = N.rock_color_fn(ao, cav, mw, seed=seed)
    wood = pal("wood")
    wend = pal("wood_end")
    wring = pal("wood_ring")
    wdark = pal("wood_dark")

    def fn(vi, p, n, m, pi):
        a = ao[vi]
        if m == "Moss":
            return moss_f(vi, p, n, "Moss", pi)
        if m == "Wood":
            col = mix(shift(wood, dv=-0.12, ds=-0.1), shift(wend, ds=-0.15), 0.5 + 0.5 * n1(p, 14.0, seed, 2))
            return scale_col(col, 0.5 + 0.5 * a)
        if m == "WoodEnd":
            pc = N.PS["pc"]
            r = math.hypot(pc.y - centers[0].y, pc.z - centers[0].z) / R
            band = int(r * 6.0)
            col = shift(wend, ds=-0.2, dv=-0.12) if band % 2 == 0 else shift(wring, ds=-0.15, dv=-0.1)
            col = mix(col, shift(wdark, dv=-0.35), 1.0 - smoothstep(0.1, 0.45, r))  # rotten core
            return scale_col(col, 0.5 + 0.5 * a)
        col = bark_f(vi, p, n, m, pi)
        g = smoothstep(0.0, 0.6, mw[vi] if vi < len(mw) else 0.0) * 0.4
        col = mix(col, shift(pal("moss"), ds=-0.3, dv=-0.25), g)
        return col
    N.paint_ex(ob, fn)
    N.strip_plant_attrs(ob)
    return ob


# ----------------------------------------------------------------------------
# hanging roots / vines (origin at the top, hanging down -z)
# ----------------------------------------------------------------------------

def hang_path(start, length, rng, sway=0.12, spread=None, n=None, gnarl=0.05, seed=0):
    """Polyline from start hanging down `length`, with a short outward spread near the top."""
    n = n or max(6, int(length / 0.18))
    spread = spread if spread is not None else V((rng.uniform(-1, 1), rng.uniform(-1, 1), 0)).normalized() * 0.15
    pts = []
    for i in range(n):
        t = i / (n - 1)
        z = -length * t
        out = spread * (1.0 - (1.0 - min(1.0, t * 3.0)) ** 2)  # leaves the ceiling at an angle, then hangs
        sw = V((math.sin(t * 5.0 + seed) * sway * t, math.cos(t * 3.7 + seed * 1.3) * sway * t, 0))
        p = V(start) + out + sw + V((0, 0, z))
        if i > 0:
            p += N.nvec(p, 3.0, seed) * gnarl * min(1.0, t * 4)
        pts.append(p)
    pts[0] = V(start)
    return pts


def hanging_roots(seed=21):
    rng = random.Random(seed)
    bm = bmesh.new()
    tl = bm.verts.layers.float.new("tipw")
    roots = [(V((0.0, 0.0, 0.0)), 3.9, 0.06), (V((0.18, 0.1, 0.0)), 2.6, 0.045), (V((-0.15, 0.16, 0.0)), 3.2, 0.05),
             (V((-0.2, -0.12, 0.0)), 1.6, 0.032), (V((0.1, -0.22, 0.0)), 2.2, 0.04), (V((0.3, -0.05, 0.0)), 1.8, 0.03),
             (V((-0.32, 0.0, 0.0)), 2.9, 0.038)]
    for k, (st, length, r0) in enumerate(roots):
        spread = V((st.x, st.y, 0)) * 0.9 + V((rng.uniform(-0.1, 0.1), rng.uniform(-0.1, 0.1), 0))
        pts = hang_path(st + V((0, 0, 0.02)), length, rng, sway=0.16 + 0.04 * k, spread=spread, gnarl=0.0,
                        seed=seed + k, n=max(8, int(length / 0.16)))
        # gnarl: low-frequency kinks that grow with depth
        pts = [p if i == 0 else p + N.nvec(V((p.x * 0.5, p.y * 0.5, p.z * 1.6)), 1.0, seed + k * 3) * 0.16 *
               min(1.0, i / 3.0) for i, p in enumerate(pts)]
        n = len(pts)
        radii = [r0 * (1.0 - 0.9 * (i / (n - 1)) ** 0.6) + 0.003 for i in range(n)]
        radii[0] *= 1.35
        # tip curls slightly
        pts[-1] = pts[-1] + V((rng.uniform(-0.05, 0.05), rng.uniform(-0.05, 0.05), 0.04))
        rr, _ = N.tube_ex(bm, pts, radii, segs=6, noise_amp=0.14, noise_scale=7.0, seed=seed + k, cap_start=False,
                          cap_end=True, tip_len=1.0)
        TR.set_tip(rr, tl, 0.0, 1.0)
        # side roots
        for j in range(rng.choice((1, 2, 2))):
            t = rng.uniform(0.25, 0.6)
            p, tan = N.point_at(pts, t)
            sl = length * rng.uniform(0.2, 0.38)
            od = V((rng.uniform(-1, 1), rng.uniform(-1, 1), 0)).normalized()
            sp = N.bezier_points(p, p + od * sl * 0.35 + V((0, 0, -sl * 0.1)), p + od * sl * 0.45 + V((0, 0, -sl * 0.5)),
                                 p + od * sl * 0.4 + V((0, 0, -sl)), 6)
            sp = N.wobble(sp, 0.05, 2.5, seed + k * 7 + j, fix_start=1)
            rs = radii[int(t * (n - 1))] * 0.6
            rsb, _ = N.tube_ex(bm, sp, [lerp(rs, 0.0025, (q / 5) ** 0.8) for q in range(6)], segs=5, noise_amp=0.1,
                               seed=seed + 50 + k * 3 + j, cap_start=True, cap_end=True, tip_len=1.0)
            TR.set_tip(rsb, tl, t, 1.0)
    for v in bm.verts:  # nothing above the ceiling
        if v.co.z > 0.0:
            v.co.z = 0.0
    ob = N.new_object("HangingRoots", bm, mats=["Bark"], smooth=True)
    ao = N.bake_ao([ob], samples=16, dist=0.3, ground=None, ceiling=0.0)[ob.name]
    tw = N.attr_values(ob, "tipw")
    cav = N.cavity(ob)
    bark = pal("bark")
    bd = pal("bark_dark")
    pale = shift(pal("bark_light"), ds=-0.25, dv=0.1)
    soil = pal("soil_dark")

    def fn(vi, p, n, m, pi):
        t = tw[vi]
        col = mix(bd, bark, 0.5 + 0.5 * n1(V((p.x * 6, p.y * 6, p.z * 1.5)), 1.0, seed, 2))
        col = mix(col, pale, 0.55 * smoothstep(0.15, 1.0, t))
        col = mix(col, soil, 0.6 * (1.0 - smoothstep(-0.35, -0.02, p.z) * 0 - smoothstep(-0.3, 0.0, -p.z - 0.0)))
        col = scale_col(col, 1.0 + 0.2 * clamp(cav[vi] * 2.0, -1, 1))
        return scale_col(col, 0.5 + 0.5 * ao[vi])
    N.paint_ex(ob, fn)
    N.strip_plant_attrs(ob)
    return ob


def hanging_vines(seed=31):
    rng = random.Random(seed)
    P = PlantBM(seed)
    vines = [(V((0.05, 0.0, 0.0)), 3.4), (V((0.2, 0.12, 0.0)), 2.3), (V((-0.16, 0.1, 0.0)), 2.9),
             (V((-0.12, -0.18, 0.0)), 1.6), (V((0.15, -0.2, 0.0)), 2.0), (V((0.32, -0.02, 0.0)), 1.5),
             (V((-0.3, -0.02, 0.0)), 2.6)]
    for k, (st, length) in enumerate(vines):
        spread = V((st.x, st.y, 0)) * 0.6
        pts = hang_path(st + V((0, 0, 0.02)), length, rng, sway=0.07, spread=spread, gnarl=0.025, seed=seed + k,
                        n=max(8, int(length / 0.2)))
        n = len(pts)
        P.tube(pts, [lerp(0.013, 0.006, i / (n - 1)) for i in range(n)], segs=4, part=0, mat=0, tint=rng.random(),
               cap_start=False, cap_end=True)
        tint = rng.random()
        # leaves along the vine, alternating, getting smaller toward the tip
        nl = int(length / 0.075)
        for j in range(nl):
            t = 0.03 + 0.95 * j / max(1, nl - 1)
            p, tan = N.point_at(pts, t)
            a = j * 2.4 + rng.uniform(-0.5, 0.5)
            out = V((math.cos(a), math.sin(a), 0))
            d = (out * 1.0 + V((0, 0, rng.uniform(-0.6, 0.1)))).normalized()
            size = rng.uniform(0.08, 0.11) * (1.0 - 0.4 * t)
            N.plant_diamond(P, p, d, size, size * 0.36, fold=0.35, droop=rng.uniform(0.3, 0.7), part=1, mat=0,
                            tint=tint + rng.uniform(-0.15, 0.15))
    ob = P.to_object("HangingVines", ["Plant"], smooth=True)
    for v in ob.data.vertices:
        if v.co.z > 0.0:
            v.co.z = 0.0
    ao = N.bake_ao([ob], samples=16, dist=0.15, ground=None, ceiling=0.0)[ob.name]
    part = N.face_attr(ob, "part")
    tint = N.face_attr(ob, "tint", 0.5)
    tw = N.attr_values(ob, "tw", 0.5)
    leaf = pal("leaf")
    leaf_d = pal("leaf_dark")
    leaf_l = pal("leaf_light")

    def fn(vi, p, n, m, pi):
        j = tint[pi] - 0.5
        depth = clamp(-p.z / 3.0)
        if part[pi] == 0:
            col = mix(shift(leaf_d, dh=0.03, dv=-0.1), mix(leaf, pal("bark_light"), 0.3), 0.4 + 0.4 * depth)
        else:
            col = mix(leaf_d, mix(leaf, leaf_l, 0.4 + 0.4 * j), 0.45 + 0.55 * tw[vi])
            col = mix(col, pal("leaf_warm"), 0.25 * depth)
        col = shift(col, dh=0.02 * j, dv=0.1 * j)
        col = mix(col, scale_col(col, 0.6), 1.0 - smoothstep(-0.25, -0.02, p.z) * 0 - smoothstep(-0.2, 0.0, -p.z))
        return scale_col(col, 0.5 + 0.5 * ao[vi])
    N.paint_ex(ob, fn)
    N.strip_plant_attrs(ob)
    return ob


def main():
    N.reset()
    log = mossy_log()
    N.report_tris([log])
    bb = [log.matrix_world @ V(c) for c in log.bound_box]
    print(f"[mossy_log] x {min(v.x for v in bb):.2f}..{max(v.x for v in bb):.2f} y {min(v.y for v in bb):.2f}.."
          f"{max(v.y for v in bb):.2f} z {min(v.z for v in bb):.3f}..{max(v.z for v in bb):.2f}")
    N.export_glb("nature/mossy_log.glb", [log])
    N.preview("mossy_log", [log], views=((22, 35), (30, 140), (18, 250)), dist_mul=2.6)

    for name, fn in (("hanging_roots", hanging_roots), ("hanging_vines", hanging_vines)):
        N.reset()
        ob = fn()
        N.report_tris([ob])
        bb = [ob.matrix_world @ V(c) for c in ob.bound_box]
        print(f"[{name}] z {min(v.z for v in bb):.2f}..{max(v.z for v in bb):.3f} "
              f"width {max(v.x for v in bb) - min(v.x for v in bb):.2f}")
        N.export_glb(f"nature/{name}.glb", [ob])
        N.preview(name, [ob], views=((4, 35), (-20, 120)), ground=False, ceiling=True, dist_mul=3.4)


main()
