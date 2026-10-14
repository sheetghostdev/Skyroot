"""Skyroot crops, 4 growth stages each (s0 sprout .. s3 harvest-ready):
    crop_tuber_s0..s3  leafy root vegetable ("skyroot tuber", purple-red skin)
    crop_grain_s0..s3  barley-like grain clump
    crop_fiber_s0..s3  tall slender flax-like fibre grass with blue-violet flowers

    blender -b --python tools/blender/nature_crops.py

Materials: Plant (stems/leaves/flowers), Fruit (tuber, grain heads + awns).  Origin bottom centre at soil level.
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

PLANT, FRUIT = 0, 1
STEM, LEAF, HEAD, PETIOLE, PETAL, FCENTER, AWN, BUD, TUBER = range(9)
UP = V((0, 0, 1))
GA = math.pi * (3 - math.sqrt(5))


def spiral(n, radius, rng, jitter=0.35):
    out = []
    for k in range(n):
        r = radius * math.sqrt((k + 0.5) / n) * (1 + rng.uniform(-jitter, jitter) * 0.5)
        a = k * GA + rng.uniform(-0.3, 0.3)
        out.append(V((math.cos(a) * r, math.sin(a) * r, 0.0)))
    return out


def ovate(t):
    return math.sin(math.pi * min(1.0, 0.05 + 0.95 * t ** 0.72)) ** 0.75


def lanceolate(t):
    return (1.0 - t ** 1.8) * min(1.0, 0.35 + t * 3.0)


def ruffled_blade(P, base, d, length, width, bend, segs, fold, part, mat, tint, profile, ruffle=0.0, freq=5.0,
                  side_hint=None, twist=0.0):
    """Blade with a wavy margin (ruffle tilts the cross-section side vector)."""
    faces, pts = P.blade(base, d, length, width, bend=bend, segs=segs, fold=fold, part=part, mat=mat, tint=tint,
                         profile=profile, side_hint=side_hint, twist=twist)
    if ruffle > 0:
        # displace the outer verts of the last created faces along the local normal
        vs = set(v for f in faces for v in f.verts)
        for v in vs:
            t = v[P.tw]
            dz = ruffle * width * math.sin(t * freq * math.pi + (v.co.x + v.co.y) * 40.0) * smoothstep(0.1, 0.4, t)
            v.co.z += dz
    return faces, pts


# ----------------------------------------------------------------------------
# tuber
# ----------------------------------------------------------------------------

def tuber_leaf(P, base, az, length, width, elev, droop, tint, pet_frac=0.38, pet_r=0.006):
    a = az
    d = V((math.cos(a) * math.cos(elev), math.sin(a) * math.cos(elev), math.sin(elev)))
    pl = length * pet_frac
    pe = base + d * pl
    pts = N.bezier_points(base, base + d * pl * 0.35 + V((0, 0, pl * 0.15)), base + d * pl * 0.7 + V((0, 0, pl * 0.1)),
                          pe, 4)
    P.tube(pts, [pet_r, pet_r * 0.9, pet_r * 0.8, pet_r * 0.7], segs=4, part=PETIOLE, mat=PLANT, tint=tint,
           tw=(0.0, 0.35))
    d2 = (d + V((0, 0, -0.15))).normalized()
    ruffled_blade(P, pe - d * 0.01, d2, length * (1 - pet_frac), width, bend=droop, segs=6, fold=0.4,
                  part=LEAF, mat=PLANT, tint=tint, profile=ovate, ruffle=0.12, freq=6.0)


def tuber_body(P, center, radius, height, seed, show=True):
    P.blob(center, radius, squash=(1.0, 1.0, height), freq=4, amp=0.06, nscale=2.5, seed=seed, part=TUBER, mat=FRUIT,
           tint=0.5)
    # taproot (hidden in soil)
    c = V(center)
    pts = [c + V((0, 0, -radius * height * 0.6)), c + V((0.005, 0, -radius * height - 0.04)),
           c + V((0.01, 0.005, -radius * height - 0.1))]
    P.tube(pts, [radius * 0.45, radius * 0.18, 0.002], segs=5, part=TUBER, mat=FRUIT, tint=0.5, cap_start=False)


def tuber_flower_stalk(P, base, h, lean, rng):
    top = base + V((lean.x, lean.y, h))
    pts = N.bezier_points(base, base + V((0, 0, h * 0.4)), base + V((lean.x * 0.5, lean.y * 0.5, h * 0.8)), top, 6)
    P.tube(pts, [0.004, 0.0035, 0.003, 0.0028, 0.0025, 0.002], segs=3, part=STEM, mat=PLANT, tint=0.6)
    # small umbel of pale star flowers
    nfl = 7
    for k in range(nfl):
        a = k / nfl * math.tau + rng.uniform(-0.3, 0.3)
        r = 0.025 if k else 0.0
        fc = top + V((math.cos(a) * r, math.sin(a) * r, 0.012 - r * 0.25))
        P.tube([top - V((0, 0, 0.005)), fc], [0.0012, 0.001], segs=3, part=STEM, mat=PLANT, tint=0.6,
               cap_start=False, cap_end=False)
        nrm = (V((math.cos(a) * r * 6, math.sin(a) * r * 6, 1.0))).normalized()
        P.flower(fc, nrm, 0.011, petals=5, cup=0.2, part=PETAL, mat=PLANT, tint=rng.random(), rot0=rng.uniform(0, 1))


def crop_tuber(stage, seed=1):
    rng = random.Random(seed + stage * 17)
    P = PlantBM(seed + stage)
    if stage == 0:
        # sprout: short stem + two cotyledons + first true leaf bud
        P.tube([V((0, 0, -0.01)), V((0.002, 0, 0.025)), V((0.004, 0.002, 0.045))], [0.003, 0.0026, 0.0022], segs=4,
               part=PETIOLE, mat=PLANT, tint=0.5)
        top = V((0.004, 0.002, 0.045))
        for k, a in enumerate((0.3, 0.3 + math.pi)):
            d = V((math.cos(a), math.sin(a), 0.55))
            P.blade(top, d, 0.042, 0.016, bend=0.5, segs=4, fold=0.3, part=LEAF, mat=PLANT, tint=0.3 + k * 0.2,
                    profile=ovate)
        d = V((math.cos(1.9), math.sin(1.9), 1.4))
        P.blade(top, d, 0.028, 0.011, bend=0.3, segs=3, fold=0.35, part=LEAF, mat=PLANT, tint=0.8, profile=ovate)
    else:
        n_leaves, L, W, h_tub, r_tub = {1: (5, 0.15, 0.055, None, 0.0), 2: (8, 0.31, 0.10, -0.012, 0.03),
                                        3: (10, 0.42, 0.13, 0.0, 0.058)}[stage]
        if r_tub:
            tuber_body(P, V((0, 0, h_tub - r_tub * 0.35)), r_tub, 1.15, seed)
        crown = V((0, 0, (h_tub + r_tub * 0.7) if r_tub else 0.0))
        for k in range(n_leaves):
            a = k * GA * 1.0 + rng.uniform(-0.2, 0.2)
            young = k >= n_leaves - 3  # inner, younger leaves stand more upright
            elev = math.radians(rng.uniform(62, 74) if young else rng.uniform(40, 56))
            ll = L * (rng.uniform(0.6, 0.75) if young else rng.uniform(0.88, 1.08))
            ww = W * (0.75 if young else rng.uniform(0.9, 1.1))
            base = crown + V((math.cos(a), math.sin(a), 0)) * (0.006 + r_tub * 0.25)
            tuber_leaf(P, base, a, ll, ww, elev, droop=rng.uniform(0.6, 0.9) if not young else 0.35,
                       tint=rng.random(), pet_r=0.0035 + 0.0025 * stage)
        if stage == 3:
            tuber_flower_stalk(P, crown, 0.43, V((0.03, -0.02, 0)), rng)
            tuber_flower_stalk(P, crown + V((0.01, 0.01, 0)), 0.36, V((-0.05, 0.04, 0)), rng)
    return P


# ----------------------------------------------------------------------------
# grain (barley-like)
# ----------------------------------------------------------------------------

def grain_head(P, top, axis, length, ripe, rng):
    axis = axis.normalized()
    n = 7
    pts = [top + axis * (length * k / (n - 1)) for k in range(n)]
    side = axis.cross(UP)
    if side.length < 1e-3:
        side = V((1, 0, 0))
    side.normalize()
    rmax = 0.0085

    def rmod(i, p, d):
        t = i / (n - 1)
        bump = 1.0 + 0.22 * abs(math.sin(t * math.pi * 5 + (0.0 if d.dot(side) > 0 else 1.5)))
        return bump * (1.0 + 0.35 * abs(d.dot(side)))  # two-row head: wider across

    radii = [rmax * (0.55 + 0.45 * math.sin(math.pi * min(1.0, 0.15 + 0.9 * k / (n - 1)))) for k in range(n)]
    radii[-1] = 0.002
    P.tube(pts, radii, segs=5, part=HEAD, mat=FRUIT, tint=rng.random(), rmod=rmod, tw=(0.2, 1.0), cap_start=True)
    # awns: long bristles along the head axis
    for k in range(7):
        t = 0.25 + 0.7 * k / 6
        p = top + axis * length * t
        sd = side * (1 if k % 2 else -1)
        start = p + sd * rmax * 0.8
        dirn = (axis + sd * rng.uniform(0.12, 0.3)).normalized()
        if ripe:
            dirn = (dirn + V((0, 0, 0.25))).normalized()  # awns of nodding heads splay up a little
        alen = length * rng.uniform(0.9, 1.3)
        tip = start + dirn * alen
        w = sd.cross(dirn).normalized() * 0.0012
        v1 = P.bm.verts.new(start - w)
        v2 = P.bm.verts.new(start + w)
        v3 = P.bm.verts.new(tip)
        for v, tv in ((v1, 0.0), (v2, 0.0), (v3, 1.0)):
            v[P.tw] = tv
        f = P.bm.faces.new((v1, v2, v3))
        P._tag([f], AWN, FRUIT, rng.random())


def grain_stalk(P, base, height, lean_dir, lean, ripe, green_head, rng, nleaves=2):
    lean_dir = lean_dir.normalized()
    h = height
    if ripe:
        # neck arches over: head hangs
        P0 = base
        P1 = base + UP * h * 0.5 + lean_dir * lean * 0.2
        P2 = base + UP * h * 0.95 + lean_dir * (lean * 0.6)
        P3 = base + UP * h * 0.97 + lean_dir * (lean + 0.06)
    else:
        P0 = base
        P1 = base + UP * h * 0.45 + lean_dir * lean * 0.15
        P2 = base + UP * h * 0.8 + lean_dir * lean * 0.55
        P3 = base + UP * h + lean_dir * lean
    pts = N.bezier_points(P0, P1, P2, P3, 7)
    radii = [lerp(0.0042, 0.0026, k / 6) for k in range(7)]
    P.tube(pts, radii, segs=3, part=STEM, mat=PLANT, tint=rng.random(), cap_start=False, cap_end=False)
    top = pts[-1]
    tan = (pts[-1] - pts[-2]).normalized()
    if ripe:
        axis = (tan + lean_dir * 0.6 + V((0, 0, -1.1))).normalized()   # nodding head
    else:
        axis = (tan + V((0, 0, 0.3))).normalized()
    grain_head(P, top - axis * 0.004, axis, rng.uniform(0.075, 0.09), ripe, rng)
    # stalk leaves
    for k in range(nleaves):
        t = 0.22 + 0.25 * k + rng.uniform(-0.04, 0.04)
        p, tn = N.point_at(pts, t)
        a = rng.uniform(0, math.tau)
        d = (V((math.cos(a), math.sin(a), 0)) * 0.55 + UP * 0.8).normalized()
        P.blade(p, d, rng.uniform(0.17, 0.24), 0.0085, bend=rng.uniform(1.0, 1.5), segs=3, fold=0.3, part=LEAF,
                mat=PLANT, tint=rng.random(), profile=lanceolate)


def crop_grain(stage, seed=2):
    rng = random.Random(seed + stage * 31)
    P = PlantBM(seed + stage)
    if stage == 0:
        for k, p in enumerate(spiral(8, 0.035, rng)):
            for j in range(2):
                a = rng.uniform(0, math.tau)
                d = (V((math.cos(a), math.sin(a), 0)) * rng.uniform(0.1, 0.3) + UP).normalized()
                P.blade(p, d, rng.uniform(0.045, 0.08) * (1.0 if j == 0 else 0.7), 0.0035, bend=0.4, segs=3, fold=0.3,
                        part=LEAF, mat=PLANT, tint=rng.random(), profile=lanceolate)
    elif stage == 1:
        for k, p in enumerate(spiral(6, 0.05, rng)):
            a0 = math.atan2(p.y, p.x) if p.length > 1e-4 else rng.uniform(0, math.tau)
            for j in range(4):
                a = a0 + rng.uniform(-0.9, 0.9)
                spread = rng.uniform(0.25, 0.75)
                d = (V((math.cos(a), math.sin(a), 0)) * spread + UP).normalized()
                P.blade(p + V((0, 0, 0.005 * j)), d, rng.uniform(0.16, 0.27), 0.0075, bend=rng.uniform(0.9, 1.5),
                        segs=4, fold=0.3, part=LEAF, mat=PLANT, tint=rng.random(), profile=lanceolate)
    else:
        ripe = stage == 3
        n = 11
        H = 0.62 if stage == 2 else 0.7
        for k, p in enumerate(spiral(n, 0.075, rng)):
            ang = math.atan2(p.y, p.x) if p.length > 1e-4 else 0.0
            ld = V((math.cos(ang), math.sin(ang), 0)) + V((rng.uniform(-0.3, 0.3), rng.uniform(-0.3, 0.3), 0))
            lean = (0.04 + 0.6 * p.length) * (1.6 if ripe else 1.0) + rng.uniform(0.0, 0.03)
            grain_stalk(P, p, H * rng.uniform(0.88, 1.05), ld, lean, ripe, not ripe, rng, nleaves=2)
        # a few basal leaves
        for k in range(5):
            a = rng.uniform(0, math.tau)
            d = (V((math.cos(a), math.sin(a), 0)) * 0.7 + UP).normalized()
            P.blade(V((math.cos(a) * 0.03, math.sin(a) * 0.03, 0)), d, rng.uniform(0.18, 0.26), 0.008,
                    bend=1.4, segs=3, fold=0.3, part=LEAF, mat=PLANT, tint=rng.random(), profile=lanceolate)
    return P


# ----------------------------------------------------------------------------
# fibre (flax-like)
# ----------------------------------------------------------------------------

def fiber_stem(P, base, height, lean_dir, lean, stage, rng):
    pts = N.bezier_points(base, base + UP * height * 0.4 + lean_dir * lean * 0.1,
                          base + UP * height * 0.75 + lean_dir * lean * 0.5, base + UP * height + lean_dir * lean, 6)
    pts = N.wobble(pts, 0.008, 6.0, rng.randint(0, 999), fix_start=1)
    r0 = 0.0028 if stage >= 2 else 0.002
    P.tube(pts, [lerp(r0, r0 * 0.55, k / 5) for k in range(6)], segs=3, part=STEM, mat=PLANT, tint=rng.random(),
           cap_start=False, cap_end=True)
    nl = 2 if stage >= 2 else 3
    for k in range(nl):
        t = 0.2 + 0.5 * k / max(1, nl - 1) + rng.uniform(-0.05, 0.05)
        p, tn = N.point_at(pts, t)
        a = rng.uniform(0, math.tau)
        d = (V((math.cos(a), math.sin(a), 0)) * 0.6 + UP).normalized()
        P.blade(p, d, rng.uniform(0.05, 0.08) * (1.4 if stage >= 2 else 1.0), 0.004, bend=0.6, segs=2, fold=0.2,
                part=LEAF, mat=PLANT, tint=rng.random(), profile=lanceolate)
    top = pts[-1]
    tan = (pts[-1] - pts[-2]).normalized()
    if stage == 2:
        for k in range(rng.choice((1, 2))):
            a = rng.uniform(0, math.tau)
            d = (tan + V((math.cos(a), math.sin(a), 0)) * 0.6).normalized()
            q = top + d * 0.03
            P.tube([top - tan * 0.01, q], [0.0012, 0.0011], segs=3, part=STEM, mat=PLANT, tint=0.5, cap_start=False,
                   cap_end=False)
            P.blob(q + d * 0.006, 0.0065, squash=(1, 1, 1.35), freq=1, amp=0.05, part=BUD, mat=PLANT,
                   rot=d.to_track_quat("Z", "Y").to_matrix(), tint=rng.random())
    elif stage == 3:
        nf = rng.choice((1, 2, 2, 3))
        for k in range(nf):
            a = k / nf * math.tau + rng.uniform(-0.4, 0.4)
            d = (tan + V((math.cos(a), math.sin(a), 0)) * (0.0 if nf == 1 else 0.8)).normalized()
            q = top + d * (0.035 if nf > 1 else 0.012)
            P.tube([top - tan * 0.01, q], [0.0013, 0.0011], segs=3, part=STEM, mat=PLANT, tint=0.5, cap_start=False,
                   cap_end=False)
            nrm = (d + V((math.cos(a), math.sin(a), 0)) * 0.25 + V((0, 0, 0.4))).normalized()
            P.flower(q, nrm, rng.uniform(0.015, 0.019), petals=5, cup=0.3, part=PETAL, mat=PLANT, tint=rng.random(),
                     notch=0.5, rot0=rng.uniform(0, 1))
        if rng.random() < 0.6:  # a bud still to open
            a = rng.uniform(0, math.tau)
            d = (tan + V((math.cos(a), math.sin(a), 0)) * 0.7).normalized()
            q = top + d * 0.025
            P.tube([top - tan * 0.005, q], [0.0011, 0.001], segs=3, part=STEM, mat=PLANT, tint=0.5, cap_start=False,
                   cap_end=False)
            P.blob(q + d * 0.005, 0.0055, squash=(1, 1, 1.4), freq=1, amp=0.05, part=BUD, mat=PLANT,
                   rot=d.to_track_quat("Z", "Y").to_matrix(), tint=rng.random())


def crop_fiber(stage, seed=3):
    rng = random.Random(seed + stage * 13)
    P = PlantBM(seed + stage)
    if stage == 0:
        for k, p in enumerate(spiral(10, 0.04, rng)):
            h = rng.uniform(0.03, 0.055)
            top = p + V((rng.uniform(-0.005, 0.005), rng.uniform(-0.005, 0.005), h))
            P.tube([p - V((0, 0, 0.005)), (p + top) / 2, top], [0.0016, 0.0014, 0.0012], segs=3, part=STEM, mat=PLANT,
                   tint=rng.random())
            for a in (rng.uniform(0, math.tau),):
                for s in (0, math.pi):
                    d = V((math.cos(a + s), math.sin(a + s), 0.8))
                    P.blade(top, d, 0.016, 0.004, bend=0.4, segs=2, fold=0.2, part=LEAF, mat=PLANT, tint=rng.random(),
                            profile=ovate)
    else:
        n, H = {1: (12, 0.24), 2: (14, 0.74), 3: (15, 0.96)}[stage]
        for k, p in enumerate(spiral(n, 0.085, rng)):
            ang = math.atan2(p.y, p.x) if p.length > 1e-4 else 0.0
            ld = V((math.cos(ang), math.sin(ang), 0))
            lean = (0.02 + 0.45 * p.length) * (H / 0.9) + rng.uniform(0, 0.02)
            fiber_stem(P, p, H * rng.uniform(0.85, 1.05), ld, lean, stage, rng)
    return P


# ----------------------------------------------------------------------------
# painting
# ----------------------------------------------------------------------------

def crop_color_fn(kind, stage, ao, part, tint, tw):
    leaf = pal("leaf")
    leaf_l = pal("leaf_light")
    leaf_d = pal("leaf_dark")
    grass = pal("grass")
    grass_l = pal("grass_light")
    grass_d = pal("grass_dark")
    straw = pal("straw")
    grain = pal("grain")
    grain_g = pal("grain_green")
    tub = pal("tuber")
    soil = pal("soil_dark")

    def fn(vi, p, n, m, pi):
        pt = part[pi]
        tn = tint[pi]
        t = tw[vi]
        a = ao[vi]
        jit = (tn - 0.5)
        if pt in (LEAF, STEM, PETIOLE):
            if kind == "tuber":
                base_c = mix(leaf_d, leaf, 0.45 + 0.4 * tn)
                col = mix(base_c, shift(leaf, ds=0.05, dv=0.08), smoothstep(0.2, 1.0, t) * 0.6)
                if pt == PETIOLE or (pt == LEAF and t < 0.12):
                    col = mix(shift(tub, dv=0.15, ds=-0.05), col, smoothstep(0.0, 0.45, t) if pt == PETIOLE else 0.6)
                if pt == STEM:
                    col = mix(grass, leaf_l, 0.4)
            elif kind == "grain":
                if stage == 3:
                    dry = 0.55 + 0.45 * smoothstep(0.0, 0.6, t) if pt == STEM else 0.55 + 0.35 * t
                    col = mix(mix(grass, grain_g, 0.5), mix(straw, grain, 0.35 + 0.3 * tn), dry)
                else:
                    col = mix(grass_d, grass, 0.4 + 0.5 * t)
                    col = mix(col, grass_l, 0.25 * t * tn)
                    if stage == 2 and pt == STEM:
                        col = mix(col, grain_g, 0.25 * t)
            else:  # fiber
                col = mix(grass_d, mix(grass, pal("leaf_warm"), 0.15 * tn), 0.35 + 0.55 * t)
                col = shift(col, dh=0.02 * jit, ds=-0.05)
            col = shift(col, dh=0.015 * jit, dv=0.08 * jit)
        elif pt == HEAD:
            if stage == 3:
                col = mix(shift(grain, dv=-0.12), shift(grain, dv=0.06, ds=-0.05), t)
            else:
                col = mix(shift(grain_g, dv=-0.12), shift(grain_g, dv=0.06), t)
            col = shift(col, dh=0.01 * jit, dv=0.08 * jit)
        elif pt == AWN:
            col = mix(grain, straw, 0.5 + 0.5 * t) if stage == 3 else mix(grain_g, grass_l, 0.5 * t)
        elif pt == TUBER:
            top = smoothstep(-0.02, 0.06, p.z)
            col = mix(shift(tub, dv=-0.25), shift(tub, dv=0.12, ds=0.05), top)
            col = scale_col(col, 1.0 + 0.08 * n1(V((p.x * 3, p.y * 3, p.z * 30)), 1.0, 5, 1))
            col = mix(col, soil, 0.6 * (1.0 - smoothstep(-0.03, 0.005, p.z)))
        elif pt == PETAL:
            if kind == "fiber":
                col = mix(shift(pal("flower_p"), dv=0.12, ds=-0.2), pal("flower_p"), 0.4 + 0.6 * t)
                col = shift(col, dh=0.02 * jit, dv=0.06 * jit)
            else:
                col = mix(pal("flower_y"), pal("flower_w"), 0.35 + 0.65 * t) if t < 0.3 else pal("flower_w")
        elif pt == BUD:
            col = mix(grass, shift(pal("flower_p"), dv=-0.1), 0.35 if stage == 3 else 0.12)
        else:
            col = leaf
        # soil-contact darkening and AO
        col = mix(col, scale_col(col, 0.55), 1.0 - smoothstep(0.0, 0.06, p.z))
        return scale_col(col, 0.5 + 0.5 * a)
    return fn


def finish(P, name, kind, stage, ao_dist=0.12):
    ob = P.to_object(name, ["Plant", "Fruit"], smooth=True)
    # drop unused material slot for single-material stages
    used = set(p.material_index for p in ob.data.polygons)
    ao = N.bake_ao([ob], samples=16, dist=ao_dist, ground=0.0, bias=0.002)[ob.name]
    part = N.face_attr(ob, "part")
    tint = N.face_attr(ob, "tint", 0.5)
    tw = N.attr_values(ob, "tw", 0.5)
    N.paint_ex(ob, crop_color_fn(kind, stage, ao, part, tint, tw))
    N.strip_plant_attrs(ob)
    if used == {0}:
        ob.data.materials.pop(index=1)
    return ob


def main():
    builders = {"tuber": crop_tuber, "grain": crop_grain, "fiber": crop_fiber}
    for kind, fn in builders.items():
        for stage in range(4):
            N.reset()
            P = fn(stage)
            ob = finish(P, f"Crop_{kind.capitalize()}_S{stage}", kind, stage,
                        ao_dist=0.05 + 0.04 * stage)
            N.export_glb(f"nature/crop_{kind}_s{stage}.glb", [ob])
            bb = [ob.matrix_world @ V(c) for c in ob.bound_box]
            print(f"[crop_{kind}_s{stage}] height {max(v.z for v in bb):.2f} "
                  f"width {max(v.x for v in bb) - min(v.x for v in bb):.2f} zmin {min(v.z for v in bb):.2f}")
            N.preview(f"crop_{kind}_s{stage}", [ob], views=((18, 35),), dist_mul=2.8 if stage else 3.5)


main()
