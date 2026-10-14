"""Skyroot centrepiece tree -> assets/models/nature/skyroot_tree.glb

    blender -b --python tools/blender/nature_tree.py

Hierarchy (Blender names == glTF node names):
    Trunk                      origin (0,0,0) at ground, Bark
      BranchS_0 .. BranchS_7   small harvestable branches, origin = attachment point on the trunk surface
        BranchS_i_Leaves       2-3 small clumps, origin = same attachment point
      BranchL_0 .. BranchL_4   large limbs, origin = attachment point
        BranchL_i_Leaves       4-7 clumps, origin = same attachment point
      CrownLeaves              foliage on the upper leaders (not harvestable)
    Roots                      exposed surface roots, origin (0,0,0)
    Stump                      trunk cut flat at 0.55 m (hidden in Godot until the tree is felled)
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
from nature_lib import V, clamp, smoothstep, lerp, n1, nvec, Clump, pal, mix, shift, scale_col

SEED = 7
BUDGET = 15000
LEAN = V((math.cos(math.radians(-15)), math.sin(math.radians(-15)), 0))
PERP = V((-LEAN.y, LEAN.x, 0))
STUMP_Z = 0.55

# buttress lobes: (azimuth deg, amplitude, angular width rad)
LOBES = [(math.radians(a), A, w) for a, A, w in
         [(20, 0.55, 0.30), (97, 0.40, 0.26), (163, 0.62, 0.32), (232, 0.38, 0.25), (300, 0.50, 0.28)]]
# burls / knots on the trunk: (z, azimuth deg, amplitude)
BURLS = [(1.22, 250, 0.10), (0.85, 70, 0.07), (1.95, 130, 0.08)]


def angdiff(a, b):
    return (a - b + math.pi) % math.tau - math.pi


def trunk_center(z):
    zc = max(0.0, z)
    s = zc / 2.9
    return LEAN * (0.30 * s ** 1.6) + PERP * (0.05 * math.sin(zc * 1.7)) + V((0, 0, z))


def trunk_radius(z, th):
    zc = max(z, 0.0)
    rc = 0.30 - 0.034 * zc
    if z > 2.2:
        rc *= lerp(1.0, 0.40, smoothstep(2.2, 2.92, z))
    fl = 1.0 + 0.42 * math.exp(-max(z, -0.1) / 0.26)
    lob = sum(A * math.exp(-(angdiff(th, a) / w) ** 2) for a, A, w in LOBES) * math.exp(-zc / 0.40)
    tw = th + z * 0.55
    nn = 0.06 * n1(V((math.cos(tw) * 1.2, math.sin(tw) * 1.2, z * 1.1)), 1.0, SEED + 1, 2)
    nn += 0.035 * n1(V((math.cos(tw) * 3.2, math.sin(tw) * 3.2, z * 0.5)), 1.0, SEED + 2, 1)
    for bz, ba, bamp in BURLS:
        nn += bamp * math.exp(-((z - bz) / 0.16) ** 2 - (angdiff(th, math.radians(ba)) / 0.45) ** 2)
    return rc * fl * (1.0 + lob) * (1.0 + nn)


TRUNK_Z = [-0.15, -0.04, 0.04, 0.12, 0.21, 0.31, 0.42, STUMP_Z, 0.7, 0.88, 1.1, 1.35, 1.6, 1.85, 2.08, 2.3,
           2.5, 2.66, 2.79, 2.88, 2.94]


def trunk_segs(z):
    return 16 if z < 0.95 else 12


def trunk_rings(bm, zs, extra=0.0, tiplay=None):
    rings = []
    for z in zs:
        c = trunk_center(z)
        n = trunk_segs(z)
        ring = []
        for s in range(n):
            th = s / n * math.tau
            r = trunk_radius(z, th) + extra
            v = bm.verts.new(c + V((math.cos(th) * r, math.sin(th) * r, 0)))
            if tiplay is not None:
                v[tiplay] = 0.0
            ring.append(v)
        rings.append(ring)
    faces = []
    for i in range(len(rings) - 1):
        faces += N.bridge_rings(bm, rings[i], rings[i + 1])
    return rings, faces


def poly_at_height(pts, h):
    """Point on polyline where z first reaches h (pts ascending)."""
    for i in range(len(pts) - 1):
        a, b = pts[i], pts[i + 1]
        if (a.z - h) * (b.z - h) <= 0 and abs(b.z - a.z) > 1e-6:
            t = (h - a.z) / (b.z - a.z)
            return a.lerp(b, t), (b - a).normalized()
    return pts[-1], (pts[-1] - pts[-2]).normalized()


def set_tip(rings, lay, t0=0.0, t1=1.0):
    n = len(rings)
    for i, r in enumerate(rings):
        t = lerp(t0, t1, i / max(1, n - 1))
        for v in r:
            v[lay] = t


class Tree:
    def __init__(self, seed=SEED):
        self.rng = random.Random(seed)
        self.leaders = {}

    # ------------------------------------------------------------------ trunk + leaders
    def build_trunk(self):
        bm = bmesh.new()
        tl = bm.verts.layers.float.new("tipw")
        rings, _ = trunk_rings(bm, TRUNK_Z, tiplay=tl)
        # close the top (hidden inside the leaders)
        top = rings[-1]
        c = bm.verts.new(trunk_center(TRUNK_Z[-1]) + V((0, 0, 0.05)))
        for s in range(len(top)):
            bm.faces.new((top[s], top[(s + 1) % len(top)], c))
        # leaders
        defs = {
            "A": dict(p0=2.02, ctrl=[V((0.10, -0.05, 0.75)), V((0.35, -0.12, 2.0))], tip=V((0.70, -0.38, 5.9)),
                      r=(0.175, 0.045), segs=(10, 8, 6)),
            "B": dict(p0=2.10, ctrl=[V((-0.16, 0.10, 0.65)), V((-0.55, 0.42, 1.95))], tip=V((-0.95, 0.80, 5.45)),
                      r=(0.155, 0.04), segs=(9, 7, 5)),
            "C": dict(p0=2.30, ctrl=[V((0.02, -0.18, 0.55)), V((0.10, -0.70, 1.6))], tip=V((-0.12, -1.05, 5.1)),
                      r=(0.14, 0.035), segs=(8, 7, 5)),
        }
        for k, d in defs.items():
            p0 = trunk_center(d["p0"])
            p1 = p0 + d["ctrl"][0]
            p2 = p0 + d["ctrl"][1]
            pts = N.bezier_points(p0, p1, p2, d["tip"], 12)
            pts = N.wobble(pts, 0.09, 1.3, SEED + ord(k), fix_start=2)
            n = len(pts)
            radii = [lerp(d["r"][0], d["r"][1], (i / (n - 1)) ** 0.85) for i in range(n)]
            segs = [d["segs"][0] if i < 4 else d["segs"][1] if i < 8 else d["segs"][2] for i in range(n)]
            rr, _ = N.tube_ex(bm, pts, radii, segs=segs, noise_amp=0.09, noise_scale=3.0, seed=SEED + ord(k),
                              cap_start=True, cap_end=True, tip_len=1.0)
            set_tip(rr, tl, 0.0, 0.7)
            self.leaders[k] = pts
        self.leaders["T"] = [trunk_center(z) for z in TRUNK_Z]
        self.trunk_bm = bm
        return bm

    # ------------------------------------------------------------------ roots
    def build_roots(self):
        rng = random.Random(SEED + 100)
        bm = bmesh.new()
        tl = bm.verts.layers.float.new("tipw")
        defs = [(20, 2.05, -0.25, 0.13, 1), (97, 1.6, -0.22, 0.11, 0), (163, 2.2, -0.25, 0.135, 1),
                (232, 1.5, -0.22, 0.10, 0), (300, 1.85, -0.25, 0.12, 0), (131, 1.4, -0.22, 0.085, 0)]
        for k, (az, L, zend, r0, fork) in enumerate(defs):
            a = math.radians(az + rng.uniform(-4, 4))
            d = V((math.cos(a), math.sin(a), 0))
            side = V((-d.y, d.x, 0))
            n = 10
            pts, radii = [], []
            for i in range(n):
                t = i / (n - 1)
                rr = lerp(0.16, L, t ** 0.92)
                zc = lerp(0.3, 0.035, smoothstep(0.0, 0.32, t) ** 0.8)
                zc += 0.02 * math.sin(t * math.pi * 2.0 + k) * smoothstep(0.1, 0.4, t)   # gentle arching
                zc += (zend - 0.05) * smoothstep(0.48, 1.0, t)                           # sink into the soil
                wig = 0.2 * n1(V((t * 2.2, k * 3.1, 0.5)), 1.0, SEED + 30, 2) * smoothstep(0.0, 0.4, t)
                pts.append(d * rr + side * wig + V((0, 0, zc)))
                radii.append(r0 * lerp(1.25, 0.45, t ** 0.7))
            rr_, _ = N.tube_ex(bm, pts, radii, segs=7, noise_amp=0.12, noise_scale=4.0, seed=SEED + 40 + k,
                               zflat=0.72, cap_start=True, cap_end=True)
            set_tip(rr_, tl)
            if fork:
                p, tan = N.point_at(pts, 0.45)
                fa = a + math.radians(rng.choice([-1, 1]) * rng.uniform(35, 50))
                fd = V((math.cos(fa), math.sin(fa), 0))
                fl = L * 0.4
                fpts = N.bezier_points(p - tan * 0.05, p + fd * fl * 0.35, p + fd * fl * 0.65 + V((0, 0, -0.06)),
                                       p + fd * fl + V((0, 0, -0.2)), 5)
                fr = [r0 * 0.5 * (1.0 - 0.45 * (i / 4) ** 0.8) for i in range(5)]
                rf, _ = N.tube_ex(bm, fpts, fr, segs=6, noise_amp=0.1, noise_scale=5.0, seed=SEED + 60 + k, zflat=0.72,
                                  cap_start=True, cap_end=True)
                set_tip(rf, tl, 0.45, 1.0)
        return bm

    # ------------------------------------------------------------------ stump
    def build_stump(self):
        bm = bmesh.new()
        zs = [z for z in TRUNK_Z if z <= STUMP_Z + 1e-6]
        rings, side_faces = trunk_rings(bm, zs, extra=0.004)
        for f in side_faces:
            f.material_index = 0
        top = rings[-1]
        c = trunk_center(STUMP_Z)
        prev = top
        bands = [0.93, 0.78, 0.62, 0.47, 0.32, 0.17]
        rmean = sum((v.co - c).length for v in top) / len(top)
        for k, f in enumerate(bands):
            ring = []
            for v in top:
                off = v.co - c
                off.z = 0.0
                circ = off.normalized() * rmean
                o = off.lerp(circ, (1.0 - f) * 0.6) * f
                ring.append(bm.verts.new(c + o))
            for s in range(len(ring)):
                s2 = (s + 1) % len(ring)
                fc = bm.faces.new((prev[s], prev[s2], ring[s2], ring[s]))
                fc.material_index = 0 if k == 0 else 1
            prev = ring
        cv = bm.verts.new(c)
        for s in range(len(prev)):
            fc = bm.faces.new((prev[s], prev[(s + 1) % len(prev)], cv))
            fc.material_index = 1
        bm.normal_update()
        for fc in bm.faces:
            if fc.material_index == 1 or fc.calc_center_median().z > STUMP_Z - 1e-4:
                if fc.normal.z < 0:
                    fc.normal_flip()
        return bm, rmean

    # ------------------------------------------------------------------ branches
    def exit_point(self, axis_pt, d):
        return N.surface_exit(self.trunk_bvh, axis_pt, d, 2.5)

    def small_branch(self, i, h, az, L, r0, droop, ntw):
        rng = random.Random(SEED * 31 + i)
        bm = bmesh.new()
        tl = bm.verts.layers.float.new("tipw")
        a = math.radians(az)
        e = math.radians(rng.uniform(6, 16))
        d0 = V((math.cos(a) * math.cos(e), math.sin(a) * math.cos(e), math.sin(e)))
        axis = trunk_center(h)
        X = self.exit_point(axis, d0)
        S = axis + (X - axis) * 0.45
        bend = math.radians(rng.uniform(-18, 18))
        dh = V((math.cos(a + bend), math.sin(a + bend), 0))
        P1 = X + d0 * L * 0.38
        P2 = X + dh * L * 0.70 + V((0, 0, L * 0.06))
        P3 = X + dh * L * 0.94 + V((0, 0, -droop))
        main = [S] + N.bezier_points(X, P1, P2, P3, 7)
        main = N.wobble(main, 0.035, 2.2, SEED + i * 3, fix_start=2)
        n = len(main)
        radii = [r0 * 1.05] + [r0 * (1.0 - 0.8 * ((k) / (n - 2)) ** 0.9) for k in range(n - 1)]
        rr, _ = N.tube_ex(bm, main, radii, segs=6, noise_amp=0.07, noise_scale=9.0, seed=SEED + i, cap_start=True,
                          cap_end=True, tip_len=1.2)
        set_tip(rr, tl, 0.3, 1.0)
        clumps = []
        tip = main[-1]
        ttan = (main[-1] - main[-2]).normalized()
        R = rng.uniform(0.3, 0.34)
        clumps.append(Clump(tip + ttan * R * 0.2 + V((0, 0, R * 0.2)), R, squash=(1.12, 1.12, 0.72), amp=0.2,
                            nscale=1.25, octaves=2, seed=SEED * 7 + i * 5, freq=3, flat_bottom=0.35))
        side = rng.choice([-1, 1])
        for k in range(ntw):
            t = rng.uniform(0.5, 0.62) if k == 0 else rng.uniform(0.7, 0.8)
            p, tan = N.point_at(main[1:], t)
            ang = side * math.radians(rng.uniform(40, 62))
            side = -side
            td = (Matrix.Rotation(ang, 3, "Z") @ tan)
            td = (td + V((0, 0, rng.uniform(0.15, 0.4)))).normalized()
            tlen = rng.uniform(0.3, 0.42)
            tp = N.bezier_points(p - tan * 0.01, p + td * tlen * 0.4, p + td * tlen * 0.75 + V((0, 0, 0.02)),
                                 p + td * tlen + V((0, 0, -0.03)), 4)
            rt = r0 * (1.0 - 0.8 * t) * 0.62
            rtw, _ = N.tube_ex(bm, tp, [rt, rt * 0.7, rt * 0.4, 0.004], segs=5, noise_amp=0.05, seed=SEED + i * 11 + k,
                               cap_start=True, cap_end=True, tip_len=1.0)
            set_tip(rtw, tl, 0.7, 1.0)
            Rt = rng.uniform(0.23, 0.27)
            ttip = tp[-1]
            clumps.append(Clump(ttip + td * Rt * 0.2 + V((0, 0, Rt * 0.2)), Rt, squash=(1.1, 1.1, 0.75), amp=0.2,
                                nscale=1.3, octaves=2, seed=SEED * 7 + i * 5 + k + 1, freq=3, flat_bottom=0.35))
        length = N.polyline_length(main[1:])
        return bm, X, clumps, length

    def large_branch(self, i, leader, h, az, elev, L, r0, nsub):
        rng = random.Random(SEED * 53 + i)
        bm = bmesh.new()
        tl = bm.verts.layers.float.new("tipw")
        a = math.radians(az)
        e = math.radians(elev)
        d0 = V((math.cos(a) * math.cos(e), math.sin(a) * math.cos(e), math.sin(e)))
        axis, _ = poly_at_height(self.leaders[leader], h)
        X = self.exit_point(axis, d0)
        S = axis + (X - axis) * 0.3
        bend = math.radians(rng.uniform(-15, 15))
        dh = V((math.cos(a + bend), math.sin(a + bend), 0))
        P1 = X + d0 * L * 0.36
        P2 = X + dh * L * 0.6 + V((0, 0, L * 0.45))
        P3 = X + dh * L * 0.72 + V((0, 0, L * 0.66))
        main = [S] + N.bezier_points(X, P1, P2, P3, 10)
        main = N.wobble(main, 0.13, 1.2, SEED + 200 + i, fix_start=2)
        n = len(main)
        radii = [r0 * 1.04] + [r0 * (1.0 - 0.82 * (k / (n - 2)) ** 0.85) for k in range(n - 1)]
        segs = [8 if k < 5 else 6 for k in range(n)]
        rr, _ = N.tube_ex(bm, main, radii, segs=segs, noise_amp=0.08, noise_scale=4.5, seed=SEED + 300 + i,
                          cap_start=True, cap_end=True, tip_len=1.0)
        set_tip(rr, tl, 0.15, 1.0)
        clumps = []
        tip = main[-1]
        ttan = (main[-1] - main[-2]).normalized()
        R = rng.uniform(0.8, 0.92)
        clumps.append(Clump(tip + ttan * R * 0.15 + V((0, 0, R * 0.2)), R, squash=(1.08, 1.08, 0.8), amp=0.22,
                            nscale=1.1, octaves=2, seed=SEED * 11 + i * 13, freq=4, flat_bottom=0.4))
        ts = sorted(rng.uniform(0.36, 0.8) for _ in range(nsub))
        side = rng.choice([-1, 1])
        for k, t in enumerate(ts):
            p, tan = N.point_at(main[1:], t)
            ang = side * math.radians(rng.uniform(32, 55))
            side = -side
            sd = Matrix.Rotation(ang, 3, "Z") @ tan
            sd = (sd + V((0, 0, rng.uniform(0.2, 0.45)))).normalized()
            sl = rng.uniform(0.8, 1.1) * min(1.0, L / 2.8)
            sp = N.bezier_points(p - tan * 0.02, p + sd * sl * 0.4, p + sd * sl * 0.75 + V((0, 0, sl * 0.12)),
                                 p + sd * sl + V((0, 0, sl * 0.15)), 5)
            sp = N.wobble(sp, 0.04, 2.0, SEED + 400 + i * 7 + k, fix_start=1)
            rs = r0 * (1.0 - 0.82 * t) * 0.62
            rsub = [lerp(rs, 0.006, (j / 4) ** 0.85) for j in range(5)]
            rsb, _ = N.tube_ex(bm, sp, rsub, segs=5, noise_amp=0.07, noise_scale=6.0, seed=SEED + 500 + i * 7 + k,
                               cap_start=True, cap_end=True, tip_len=1.0)
            set_tip(rsb, tl, 0.5, 1.0)
            Rs = rng.uniform(0.6, 0.72)
            stp = sp[-1]
            clumps.append(Clump(stp + sd * Rs * 0.12 + V((0, 0, Rs * 0.2)), Rs, squash=(1.0, 1.0, 0.82), amp=0.22,
                                nscale=1.2, octaves=2, seed=SEED * 11 + i * 13 + k + 1, freq=3, flat_bottom=0.4))
        # a flatter clump riding on the limb
        p, tan = N.point_at(main[1:], 0.6)
        Rm = rng.uniform(0.55, 0.65)
        sidev = V((-tan.y, tan.x, 0)).normalized() * rng.uniform(-0.25, 0.25)
        clumps.append(Clump(p + sidev + V((0, 0, Rm * 0.5)), Rm, squash=(1.12, 1.12, 0.7), amp=0.22, nscale=1.2,
                            octaves=2, seed=SEED * 11 + i * 13 + 9, freq=3, flat_bottom=0.45))
        length = N.polyline_length(main[1:])
        return bm, X, clumps, length

    def crown_clumps(self):
        rng = random.Random(SEED + 900)
        A, B, Cc = self.leaders["A"], self.leaders["B"], self.leaders["C"]
        cl = []

        def add(c, r, sq=(1.0, 1.0, 0.8), amp=0.22, freq=4):
            cl.append(Clump(c, r, squash=sq, amp=amp, nscale=1.1, octaves=2, seed=SEED * 17 + len(cl) * 7,
                            freq=freq, flat_bottom=0.4))
        ctr = (A[-1] + B[-1] + Cc[-1]) / 3.0
        add(A[-1] + V((0.1, -0.05, 0.3)), 1.05)
        add(B[-1] + V((-0.1, 0.05, 0.28)), 1.0)
        add(Cc[-1] + V((0.0, -0.1, 0.3)), 0.98)
        add(ctr + V((0.05, 0.0, 0.8)), 1.05)                        # top filler
        add(ctr + V((0.3, -0.1, 1.38)), 0.62, amp=0.26, freq=3)     # top poke-out
        add(ctr + V((-0.35, 0.15, 0.25)), 0.9)                       # inner filler
        for P, out in ((A, V((1.1, -0.25, 0))), (B, V((-0.7, 0.85, 0))), (Cc, V((0.15, -1.1, 0)))):
            pm, _ = N.point_at(P, 0.68)
            add(pm + out + V((0, 0, 0.3)), 0.85, freq=3)           # mid-crown, rounds out the dome
        add(B[-1] + V((-0.85, -0.2, -0.15)), 0.55, amp=0.26, freq=3)  # silhouette poke-outs
        add(A[-1] + V((0.9, 0.35, -0.2)), 0.56, amp=0.26, freq=3)
        add(Cc[-1] + V((-0.6, -0.6, 0.1)), 0.52, amp=0.26, freq=3)
        return cl


# ----------------------------------------------------------------------------
# painting
# ----------------------------------------------------------------------------

def bark_fn(ao, cav, tipw, kind="trunk", seed=SEED):
    bark = pal("bark")
    bd = pal("bark_dark")
    bl = pal("bark_light")
    moss = shift(pal("moss"), ds=-0.25, dv=-0.15)
    soil = pal("soil_dark")

    def fn(vi, p, n, m, pi):
        a = ao[vi]
        c = cav[vi]
        t = tipw[vi]
        st = n1(V((p.x * 7.0, p.y * 7.0, p.z * 1.1)), 1.0, seed + 5, 2)
        col = mix(bd, bark, 0.55 + 0.4 * st)
        if kind in ("trunk", "stump"):
            ang = math.atan2(p.y, p.x)
            fur = math.sin(ang * 7.0 + p.z * 1.3 + 2.0 * n1(V((p.x * 2, p.y * 2, p.z * 0.6)), 1.0, seed + 12))
            col = scale_col(col, 1.0 + 0.1 * fur)
        col = mix(col, bl, clamp(c * 2.2) * 0.45)
        col = scale_col(col, 1.0 + 0.3 * min(0.0, c * 2.2))
        col = shift(col, dh=0.01 * n1(p, 0.6, seed + 8), ds=0.08 * n1(p, 0.9, seed + 6))
        # younger, greyer-lighter bark toward branch tips
        col = mix(col, shift(bl, ds=-0.15), 0.38 * t)
        # mossy, darker base
        if p.z < 1.1 and kind in ("trunk", "roots", "stump"):
            g = (1.0 - smoothstep(0.05, 1.1, p.z)) * smoothstep(-0.3, 0.5, n.z) * (0.45 + 0.55 * n1(p, 3.0, seed + 9))
            if kind == "roots":
                g = smoothstep(-0.1, 0.6, n.z) * (0.35 + 0.5 * n1(p, 2.5, seed + 9)) * (1.0 - smoothstep(0.05, 0.35, p.z) * 0.3)
            col = mix(col, moss, clamp(g) * 0.6)
        col = mix(col, soil, 0.65 * (1.0 - smoothstep(-0.06, 0.08, p.z)))
        return scale_col(col, 0.38 + 0.62 * a)
    return fn


def leaf_tints(n, rng):
    base = [pal("leaf"), pal("leaf"), pal("leaf_light"), pal("leaf_dark"), mix(pal("leaf"), pal("leaf_warm"), 0.35)]
    out = []
    for k in range(n):
        c = rng.choice(base)
        c = shift(c, dh=rng.uniform(-0.012, 0.012), ds=rng.uniform(-0.08, 0.06), dv=rng.uniform(-0.06, 0.05))
        out.append(c)
    return out


def leaf_fn(ao, clump_idx, tints, zlo=1.2, zhi=7.4, seed=SEED):
    ld = pal("leaf_dark")
    lw = pal("leaf_warm")
    deep = shift(pal("leaf_dark"), dh=0.03, dv=-0.25)

    def fn(vi, p, n, m, pi):
        a = ao[vi]
        tint = tints[int(round(clump_idx[vi])) % len(tints)]
        h = smoothstep(zlo, zhi, p.z)
        col = mix(ld, tint, 0.68 + 0.32 * h)
        col = mix(col, lw, 0.22 * smoothstep(0.25, 1.0, n.z) * (0.35 + 0.65 * h))
        col = mix(col, deep, 0.35 * smoothstep(0.1, 0.9, -n.z))
        col = scale_col(col, 1.0 + 0.09 * n1(p, 2.2, seed + 3, 2))
        col = shift(col, dh=0.008 * n1(p, 0.7, seed + 4))
        return scale_col(col, 0.36 + 0.64 * a)
    return fn


def stump_fn(ao, cav, c, rmean, seed=SEED):
    wend = pal("wood_end")
    wring = pal("wood_ring")
    wdark = pal("wood_dark")
    bark_f = None

    def fn(vi, p, n, m, pi):
        a = ao[vi]
        if m == "WoodEnd":
            pc = N.PS["pc"]
            r = (V((pc.x, pc.y, 0)) - V((c.x, c.y, 0))).length / rmean
            band = int(r * 6.0 + 0.15 * n1(pc, 9.0, seed, 1))
            col = wend if band % 2 == 0 else wring
            col = mix(col, wdark, 0.55 * (1.0 - smoothstep(0.0, 0.22, r)))  # heartwood / pith
            col = scale_col(col, 1.0 + 0.06 * n1(p, 12.0, seed + 1, 1))
            return scale_col(col, 0.75 + 0.25 * a)
        return None
    return fn


# ----------------------------------------------------------------------------

def main():
    N.reset()
    T = Tree()
    # trunk (+ leaders)
    tbm = T.build_trunk()
    from mathutils.bvhtree import BVHTree
    tbm.normal_update()
    T.trunk_bvh = BVHTree.FromBMesh(tbm)
    trunk = N.obj_from_bm("Trunk", tbm, ["Bark"])

    roots = N.obj_from_bm("Roots", T.build_roots(), ["Bark"])
    sbm, rmean = T.build_stump()
    stump = N.obj_from_bm("Stump", sbm, ["Bark", "WoodEnd"])

    SMALL = [  # (height, azimuth, length, base radius, droop, twiglets)
        (1.55, 8, 1.18, 0.032, 0.22, 2),
        (2.22, 52, 1.0, 0.028, 0.15, 1),
        (1.80, 100, 1.32, 0.034, 0.25, 2),
        (2.42, 148, 0.95, 0.026, 0.12, 1),
        (1.62, 196, 1.22, 0.031, 0.2, 2),
        (2.08, 243, 1.06, 0.029, 0.18, 1),
        (1.92, 290, 1.38, 0.035, 0.26, 2),
        (2.36, 333, 0.98, 0.026, 0.12, 1),
    ]
    LARGE = [  # (leader, height, azimuth, elevation, length, base radius, sub-branches)
        ("T", 2.36, 205, 38, 3.0, 0.095, 3),
        ("A", 2.62, 62, 42, 2.85, 0.085, 2),
        ("C", 2.85, 290, 42, 3.05, 0.09, 3),
        ("B", 3.02, 128, 44, 2.75, 0.078, 2),
        ("A", 3.22, 352, 42, 2.65, 0.074, 2),
    ]
    branches, leaves = [], []
    info = []
    cidx = 0
    for i, sp in enumerate(SMALL):
        bm, X, clumps, length = T.small_branch(i, *sp)
        b = N.obj_from_bm(f"BranchS_{i}", bm, ["Bark"], origin=X, parent=trunk)
        lbm = bmesh.new()
        N.build_clumps(lbm, clumps, index_offset=cidx)
        cidx += len(clumps)
        lf = N.obj_from_bm(f"BranchS_{i}_Leaves", lbm, ["Leaves"], origin=X, parent=b)
        branches.append(b)
        leaves.append(lf)
        info.append((b.name, X, length, len(clumps)))
    for i, sp in enumerate(LARGE):
        bm, X, clumps, length = T.large_branch(i, *sp)
        b = N.obj_from_bm(f"BranchL_{i}", bm, ["Bark"], origin=X, parent=trunk)
        lbm = bmesh.new()
        N.build_clumps(lbm, clumps, index_offset=cidx)
        cidx += len(clumps)
        lf = N.obj_from_bm(f"BranchL_{i}_Leaves", lbm, ["Leaves"], origin=X, parent=b)
        branches.append(b)
        leaves.append(lf)
        info.append((b.name, X, length, len(clumps)))
    cbm = bmesh.new()
    cc = T.crown_clumps()
    N.build_clumps(cbm, cc, index_offset=cidx)
    cidx += len(cc)
    crown = N.obj_from_bm("CrownLeaves", cbm, ["Leaves"], parent=trunk)
    leaves.append(crown)

    for o in [trunk, roots, stump] + branches + leaves:
        for p in o.data.polygons:
            p.use_smooth = True

    # ---------------- budget: decimate foliage to fit
    bark_objs = [trunk, roots, stump] + branches
    bark_tris = N.triangle_count(bark_objs)
    leaf_tris = N.triangle_count(leaves)
    allow = BUDGET - 150 - bark_tris
    print(f"[tree] bark {bark_tris} tris, leaves {leaf_tris} tris, foliage allowance {allow}")
    if leaf_tris > allow:
        ratio = allow / leaf_tris
        for lf in leaves:
            N.decimate_to(lf, int(N.triangle_count([lf]) * ratio))
    for o in [trunk, roots, stump] + branches + leaves:
        for p in o.data.polygons:
            p.use_smooth = True

    # ---------------- AO + paint
    bpy.context.view_layer.update()
    scene_objs = [trunk, roots] + branches + leaves
    ao_bark = N.bake_ao([trunk, roots] + branches, occluders=leaves, samples=24, dist=1.4, ground=0.0)
    ao_leaf = N.bake_ao(leaves, occluders=[trunk] + branches, samples=20, dist=1.6, ground=0.0)
    # under-canopy clumps: long-range occlusion picks up the shade of the crown above
    small_leaves = [lf for lf in leaves if lf.name.startswith("BranchS_")]
    ao_far = N.bake_ao(small_leaves, occluders=[o for o in leaves if o not in small_leaves] + [trunk] + branches,
                       samples=20, dist=4.0, ground=None, bias=0.01)
    for lf in small_leaves:
        ao_leaf[lf.name] = [a * (0.55 + 0.45 * b) for a, b in zip(ao_leaf[lf.name], ao_far[lf.name])]
    ao_stump = N.bake_ao([stump], occluders=[roots], samples=24, dist=0.8, ground=0.0)
    for o, kind in [(trunk, "trunk"), (roots, "roots")] + [(b, "branch") for b in branches]:
        N.paint_ex(o, bark_fn(ao_bark[o.name], N.cavity(o), N.attr_values(o, "tipw"), kind))
    tints = leaf_tints(cidx, random.Random(SEED + 77))
    for lf in leaves:
        N.paint_ex(lf, leaf_fn(ao_leaf[lf.name], N.attr_values(lf, "clump"), tints))
    sb = bark_fn(ao_stump["Stump"], N.cavity(stump), [0.0] * len(stump.data.vertices), "stump")
    sw = stump_fn(ao_stump["Stump"], None, trunk_center(STUMP_Z), rmean)
    N.paint_ex(stump, lambda vi, p, n, m, pi: sw(vi, p, n, m, pi) if m == "WoodEnd" else sb(vi, p, n, m, pi))
    for o in [trunk, roots, stump] + branches + leaves:
        N.strip_attrs(o)

    # ---------------- report + export
    print("[tree] triangle breakdown:")
    total = N.report_tris([trunk, roots, stump] + branches + leaves)
    for name, X, length, nc in info:
        print(f"[tree] {name}: attach blender ({X.x:.3f}, {X.y:.3f}, {X.z:.3f}) len {length:.2f} m clumps {nc}")
    bb = [o.matrix_world @ V(c) for o in [trunk] + branches + leaves for c in o.bound_box]
    print(f"[tree] bounds x {min(v.x for v in bb):.2f}..{max(v.x for v in bb):.2f} "
          f"y {min(v.y for v in bb):.2f}..{max(v.y for v in bb):.2f} z {min(v.z for v in bb):.2f}..{max(v.z for v in bb):.2f}")
    N.export_glb("nature/skyroot_tree.glb", [trunk, roots, stump])

    # ---------------- previews
    tree_objs = [trunk, roots] + branches + leaves
    N.preview("tree", tree_objs, views=((10, 35), (12, 215), (32, 125)), hide=[stump], dist_mul=2.9)
    k = 2
    N.preview("tree_branch_closeup", tree_objs, views=((8, 100 + 25),), hide=[stump],
              target=[branches[k], leaves[k]], dist_mul=2.6)
    hide = [trunk] + branches + leaves
    N.preview("tree_stump", [stump, roots], views=((30, 35),), hide=hide, dist_mul=1.9)
    N.preview("tree_base", tree_objs, views=((18, 300),), hide=[stump], target=[roots], dist_mul=1.6)


if __name__ == "__main__":
    main()
