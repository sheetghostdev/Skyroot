"""Skyroot plants: berry_bush, mushroom_cluster, grass_tuft, fern, flowers_a, wild_grain.

    blender -b --python tools/blender/nature_plants.py
"""
import os
import sys
import math
import random

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bpy
import bmesh
from mathutils import Vector, Matrix
from mathutils.bvhtree import BVHTree

import nature_lib as N
from nature_lib import V, clamp, smoothstep, lerp, n1, pal, mix, shift, scale_col, PlantBM, Clump, RockPart
import nature_crops as CR
import nature_tree as TR

UP = V((0, 0, 1))
GA = math.pi * (3 - math.sqrt(5))
STEM, LEAF, HEAD, PETIOLE, PETAL, FCENTER, AWN, BUD, TUBER = range(9)


# ----------------------------------------------------------------------------
# berry bush
# ----------------------------------------------------------------------------

def berry_bush(seed=4):
    rng = random.Random(seed)
    # woody stems
    sbm = bmesh.new()
    tl = sbm.verts.layers.float.new("tipw")
    clumps = []
    centers = []
    # dome of clumps: ring of 6 low + 4 mid + 2 top
    layout = []
    for k in range(6):
        a = k / 6 * math.tau + rng.uniform(-0.2, 0.2)
        layout.append((a, 0.33, 0.27, rng.uniform(0.25, 0.29)))
    for k in range(4):
        a = (k + 0.5) / 4 * math.tau + rng.uniform(-0.25, 0.25)
        layout.append((a, 0.2, 0.5, rng.uniform(0.25, 0.28)))
    layout.append((0.0, 0.03, 0.66, 0.25))
    layout.append((2.2, 0.15, 0.63, 0.2))
    for k, (a, r, z, R) in enumerate(layout):
        c = V((math.cos(a) * r, math.sin(a) * r, z))
        clumps.append(Clump(c, R, squash=(1.0, 1.0, 0.85), amp=0.17, nscale=1.15, octaves=2, seed=seed * 9 + k, freq=3,
                            flat_bottom=0.4))
        centers.append(c)
    # stems from the ground up into some clumps
    for k in range(6):
        c = centers[k]
        base = V((rng.uniform(-0.05, 0.05), rng.uniform(-0.05, 0.05), -0.03))
        tip = c * 0.85 + V((0, 0, -0.05))
        pts = N.bezier_points(base, base + V((0, 0, 0.12)), tip * 0.6 + V((0, 0, 0.05)), tip, 5)
        rr, _ = N.tube_ex(sbm, pts, [0.022, 0.018, 0.014, 0.01, 0.006], segs=5, noise_amp=0.08, seed=seed + k,
                          cap_start=True, cap_end=True)
        TR.set_tip(rr, tl, 0.2, 0.9)
    bush = N.new_object("Bush", sbm, mats=["Bark", "Leaves"], smooth=True)
    lbm = bmesh.new()
    N.build_clumps(lbm, clumps, mat=1)
    # join leaves into the bush mesh (one object "Bush" with Bark + Leaves materials)
    lme = bpy.data.meshes.new("tmpleaves")
    lbm.to_mesh(lme)
    lbm.free()
    lob = bpy.data.objects.new("tmpleaves", lme)
    bpy.context.scene.collection.objects.link(lob)
    lob.data.materials.append(N.material("Bark"))
    lob.data.materials.append(N.material("Leaves"))
    for p in lob.data.polygons:
        p.use_smooth = True
    bush = N.join([bush, lob], "Bush")
    # berries: clusters on the outer surface
    bpy.context.view_layer.update()
    bvh = N.world_bvh([bush])
    bm = bmesh.new()
    part = bm.faces.layers.int.new("part")
    nb = 0
    tries = 0
    berry_pts = []
    while nb < 40 and tries < 400:
        tries += 1
        a = rng.uniform(0, math.tau)
        el = rng.uniform(-0.15, 0.85)
        d = V((math.cos(a) * math.cos(el), math.sin(a) * math.cos(el), math.sin(el)))
        target = V((0, 0, 0.42))
        org = target + d * 2.0
        hit = bvh.ray_cast(org, -d, 3.0)
        if hit[0] is None or hit[1].z < -0.35 or hit[0].z < 0.12:
            continue
        p0, n0 = hit[0], hit[1]
        if any((p0 - q).length < 0.09 for q in berry_pts):
            continue
        berry_pts.append(p0)
        ncl = rng.choice((2, 3, 3, 4))
        t1 = n0.orthogonal().normalized()
        t2 = n0.cross(t1)
        for j in range(ncl):
            if nb >= 48:
                break
            ang = j / ncl * math.tau + rng.uniform(-0.3, 0.3)
            off = (t1 * math.cos(ang) + t2 * math.sin(ang)) * (0.026 if ncl > 1 else 0.0)
            r = rng.uniform(0.017, 0.021)
            c = p0 + off + n0 * r * 0.55
            faces = N.PlantBM.__new__(N.PlantBM)
            tmp = bmesh.new()
            bmesh.ops.create_icosphere(tmp, subdivisions=1, radius=1.0)
            vm = {}
            for v in tmp.verts:
                q = v.co.normalized()
                vm[v] = bm.verts.new(c + V((q.x * r, q.y * r, q.z * r * 0.92)))
            for f in tmp.faces:
                nf = bm.faces.new([vm[v] for v in f.verts])
                nf[part] = nb
            tmp.free()
            nb += 1
    berries = N.new_object("Berries", bm, mats=["Fruit"], smooth=True)
    berries.parent = bush
    bpy.context.view_layer.update()
    # paint
    ao_b = N.bake_ao([bush], occluders=[berries], samples=24, dist=0.45, ground=0.0)[bush.name]
    clump_idx = N.attr_values(bush, "clump")
    tints = TR.leaf_tints(len(clumps), random.Random(seed))
    tints = [shift(t, ds=0.08, dv=-0.06) for t in tints]
    lf = TR.leaf_fn(ao_b, clump_idx, tints, zlo=0.0, zhi=1.5)
    bf = TR.bark_fn(ao_b, N.cavity(bush), [0.3] * len(bush.data.vertices), "branch")
    N.paint_ex(bush, lambda vi, p, n, m, pi: lf(vi, p, n, m, pi) if m == "Leaves" else bf(vi, p, n, m, pi))
    ao_r = N.bake_ao([berries], occluders=[bush], samples=12, dist=0.06, ground=0.0)[berries.name]
    bpart = N.face_attr(berries, "part")
    brng = random.Random(seed + 5)
    btint = [brng.uniform(-1, 1) for _ in range(nb + 1)]
    berry = pal("berry")

    def berry_fn(vi, p, n, m, pi):
        j = btint[bpart[pi]]
        col = shift(berry, dh=0.012 * j, dv=0.1 * j)
        col = mix(shift(col, dv=-0.35), shift(col, dv=0.18, ds=-0.1), 0.5 + 0.5 * n.z)
        return scale_col(col, 0.55 + 0.45 * ao_r[vi])
    N.paint_ex(berries, berry_fn)
    for o in (bush, berries):
        N.strip_plant_attrs(o)
    print(f"[berry_bush] berries: {nb}")
    return bush, berries


# ----------------------------------------------------------------------------
# mushrooms
# ----------------------------------------------------------------------------

def mushroom(name, base, height, cap_r, lean, seed):
    """Mesh object with origin at the stem base.  Materials: Fruit (cap, spots), Plant (stem)."""
    rng = random.Random(seed)
    bm = bmesh.new()
    part = bm.faces.layers.int.new("part")
    base = V(base)
    top = base + V((lean.x, lean.y, height))
    stem_pts = N.bezier_points(base + V((0, 0, -0.01)), base + V((0, 0, height * 0.4)),
                               top - V((lean.x * 0.3, lean.y * 0.3, height * 0.25)), top, 5)
    sr = cap_r * 0.24
    rings, faces = N.tube_ex(bm, stem_pts, [sr * 1.45, sr * 1.1, sr * 0.95, sr * 0.9, sr * 0.85], segs=8,
                             noise_amp=0.05, seed=seed, cap_start=True, cap_end=False, mat=1)
    for f in faces:
        f[part] = 0
    # cap: surface of revolution around the stem tip axis
    axis = (stem_pts[-1] - stem_pts[-2]).normalized()
    axis = (axis + UP * 1.5).normalized()
    a0 = axis.orthogonal().normalized()
    b0 = axis.cross(a0)
    H = cap_r * rng.uniform(0.6, 0.75)
    prof = [(0.0, H), (0.42, H * 0.93), (0.74, H * 0.7), (0.95, H * 0.35), (1.0, H * 0.08), (0.9, -H * 0.02),
            (0.55, H * 0.06), (0.22, H * 0.12)]
    segs = 14
    ring_list = []
    cap_base = top - axis * H * 0.15
    for k, (pr, pz) in enumerate(prof):
        ring = []
        for s in range(segs):
            ang = s / segs * math.tau
            wob = 1.0 + 0.05 * n1(V((math.cos(ang), math.sin(ang), k * 0.3)), 1.5, seed, 2)
            p = cap_base + (a0 * math.cos(ang) + b0 * math.sin(ang)) * pr * cap_r * wob + axis * pz
            ring.append(bm.verts.new(p))
        ring_list.append(ring)
    tip = ring_list[0]
    # collapse first ring to the apex
    apex = bm.verts.new(cap_base + axis * H * 1.02)
    for s in range(segs):
        f = bm.faces.new((apex, ring_list[1][s], ring_list[1][(s + 1) % segs]))
        f[part] = 1
    for v in tip:
        bm.verts.remove(v)
    for k in range(1, len(ring_list) - 1):
        A, B = ring_list[k], ring_list[k + 1]
        for s in range(segs):
            s2 = (s + 1) % segs
            f = bm.faces.new((A[s2], A[s], B[s], B[s2]))
            f[part] = 1 if k < 4 else 2  # 2 = gills / underside
    last = ring_list[-1]
    cc = bm.verts.new(cap_base + axis * H * 0.1)
    for s in range(segs):
        f = bm.faces.new((last[(s + 1) % segs], last[s], cc))
        f[part] = 2
    # spots
    nsp = rng.randint(6, 8)
    for j in range(nsp):
        ang = rng.uniform(0, math.tau)
        t = rng.uniform(0.15, 0.8)
        pr = t
        k = t * 3.0
        pz = lerp(H, H * 0.45, t ** 1.6)
        p = cap_base + (a0 * math.cos(ang) + b0 * math.sin(ang)) * pr * cap_r * 0.98 + axis * pz
        nrm = ((a0 * math.cos(ang) + b0 * math.sin(ang)) * t * 1.3 + axis).normalized()
        rs = cap_r * rng.uniform(0.13, 0.2)
        tmp = bmesh.new()
        bmesh.ops.create_icosphere(tmp, subdivisions=1, radius=1.0)
        rot = nrm.to_track_quat("Z", "Y").to_matrix()
        vm = {}
        for v in tmp.verts:
            q = v.co.normalized()
            q = V((q.x * rs, q.y * rs, q.z * rs * 0.32))
            vm[v] = bm.verts.new(p + rot @ q)
        for f in tmp.faces:
            nf = bm.faces.new([vm[v] for v in f.verts])
            nf[part] = 3
        tmp.free()
    for f in bm.faces:
        if f[part] in (1, 2, 3):
            f.material_index = 0
        else:
            f.material_index = 1
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    # recalc may flip the open-ended stem tube / caps inconsistently; stem has no hole at top (hidden in cap)
    for v in bm.verts:
        v.co -= base
    ob = N.new_object(name, bm, mats=["Fruit", "Plant"], smooth=True)
    ob.location = base
    return ob


def mushroom_cluster(seed=6):
    rng = random.Random(seed)
    # mossy base mound + a little rotten twig
    bm = bmesh.new()
    lay = bm.verts.layers.float.new("mossw")
    part = RockPart((0, 0, -0.06), (0.2, 0.16, 0.12), N.random_planes(10, rng, (0.9, 1.0)), subdiv=3, seed=seed,
                    bevel=0.0)
    N.build_rock_parts(bm, [part])
    for v in bm.verts:
        v.co += N.nvec(v.co, 6.0, seed) * 0.012
    bm.normal_update()
    for v in bm.verts:
        v[lay] = clamp(0.5 + 0.9 * (v.co.z - 0.0) / 0.06 + 0.25 * n1(v.co, 9.0, seed, 2))
    N.split_by_field(bm, "mossw")
    for f in bm.faces:
        f.material_index = 1 if f.material_index == 1 else 0
    base = N.new_object("MushroomBase", bm, mats=["Soil", "Moss"], smooth=True)
    bpy.context.view_layer.update()
    bvh = N.world_bvh([base])
    specs = [(0.03, -0.02, 0.11, 0.045, (0.01, -0.006)), (-0.07, 0.035, 0.085, 0.036, (-0.018, 0.01)),
             (0.085, 0.05, 0.065, 0.03, (0.016, 0.012)), (-0.02, -0.085, 0.05, 0.026, (-0.004, -0.016))]
    mushrooms = []
    for i, (x, y, h, r, ln) in enumerate(specs):
        hit = N.raycast_down(bvh, x, y, 1.0)
        z = hit.z if hit else 0.0
        m = mushroom(f"Mushroom_{i}", V((x, y, z - 0.006)), h, r, V(ln), seed * 10 + i)
        m.parent = base
        m.matrix_parent_inverse = Matrix.Identity(4)
        mushrooms.append(m)
    bpy.context.view_layer.update()
    # paint
    ao_base = N.bake_ao([base], occluders=mushrooms, samples=20, dist=0.12, ground=0.0)[base.name]
    mw = N.attr_values(base, "mossw")
    moss_fn = N.rock_color_fn(ao_base, N.cavity(base), mw, seed=seed)
    soil = pal("soil")

    def base_fn(vi, p, n, m, pi):
        if m == "Moss":
            return moss_fn(vi, p, n, "Moss", pi)
        col = mix(pal("soil_dark"), soil, 0.5 + 0.5 * n1(p, 12.0, seed, 2))
        return scale_col(col, 0.5 + 0.5 * ao_base[vi])
    N.paint_ex(base, base_fn)
    cap = pal("mush_cap")
    spot = pal("mush_spot")
    stem = pal("mush_stem")
    for i, mo in enumerate(mushrooms):
        ao = N.bake_ao([mo], occluders=[base] + [x for x in mushrooms if x is not mo], samples=16, dist=0.06,
                       ground=0.0)[mo.name]
        part = N.face_attr(mo, "part")
        j = (i * 0.37) % 1.0 - 0.5

        def fn(vi, p, n, m, pi, ao=ao, part=part, j=j, mo=mo):
            pt = part[pi]
            if pt == 1:
                col = shift(cap, dh=0.015 * j, dv=0.12 * j)
                col = mix(shift(col, dv=-0.25), shift(col, dv=0.12, ds=-0.05), 0.5 + 0.5 * n.z)
            elif pt == 2:
                col = mix(shift(stem, dv=-0.25), pal("mush_spot"), 0.4)
            elif pt == 3:
                col = shift(spot, dv=0.05 * j)
            else:
                h = clamp((p.z - mo.matrix_world.translation.z) / 0.08)
                col = mix(shift(stem, dv=-0.2, ds=0.1), stem, 0.4 + 0.6 * h)
            return scale_col(col, 0.5 + 0.5 * ao[vi])
        N.paint_ex(mo, fn)
    for o in [base] + mushrooms:
        N.strip_plant_attrs(o)
    return base, mushrooms


# ----------------------------------------------------------------------------
# grass tuft, fern, flowers
# ----------------------------------------------------------------------------

def grass_tuft(seed=8):
    rng = random.Random(seed)
    P = PlantBM(seed)
    n = 26
    for k in range(n):
        r = 0.05 * math.sqrt(rng.random())
        a = rng.uniform(0, math.tau)
        base = V((math.cos(a) * r, math.sin(a) * r, -0.01))
        out = V((math.cos(a), math.sin(a), 0)) * rng.uniform(0.1, 0.45) + V((rng.uniform(-0.15, 0.15), rng.uniform(-0.15, 0.15), 0))
        d = (out + UP).normalized()
        L = rng.uniform(0.24, 0.36) * (1.0 - 0.3 * (r / 0.05))
        P.blade(base, d, L, rng.uniform(0.008, 0.012), bend=rng.uniform(0.35, 1.1), segs=4, fold=0.35,
                part=LEAF, mat=0, tint=rng.random(), profile=CR.lanceolate, twist=rng.uniform(-0.6, 0.6))
    return P


def fern(seed=9):
    rng = random.Random(seed)
    P = PlantBM(seed)
    nf = 8
    for k in range(nf):
        a = k * GA + rng.uniform(-0.15, 0.15)
        out = V((math.cos(a), math.sin(a), 0))
        inner = k >= nf - 3
        L = rng.uniform(0.7, 0.78) * (0.85 if inner else 1.0)
        elev = math.radians(rng.uniform(70, 80) if inner else rng.uniform(58, 70))
        d = out * math.cos(elev) + UP * math.sin(elev)
        # rachis: arching curve
        p0 = V((0, 0, 0.0)) + out * 0.015
        reach = 0.55 if inner else 0.72
        pts = N.bezier_points(p0, p0 + d * L * 0.5, p0 + out * L * reach * 0.6 + UP * L * 0.82,
                              p0 + out * L * reach + UP * L * (0.62 if inner else 0.45), 6)
        P.tube(pts, [lerp(0.004, 0.0013, i / 5) for i in range(6)], segs=3, part=STEM, mat=0, tint=0.5,
               cap_start=False)
        tint = rng.random()
        npin = 13
        for j in range(npin):
            t = 0.12 + 0.86 * j / (npin - 1)
            p, tan = N.point_at(pts, t)
            side = tan.cross(UP)
            if side.length < 1e-4:
                side = out.cross(UP)
            side.normalize()
            size = 0.125 * math.sin(math.pi * (0.2 + 0.8 * t)) ** 0.6 * (1.0 - 0.4 * t) + 0.015
            size *= 1.0 + 0.08 * rng.uniform(-1, 1)
            for sgn in (-1, 1):
                pd = (side * sgn + tan * 0.6 + UP * 0.05).normalized()
                P.blade(p, pd, size, size * 0.3, bend=0.35, segs=2 if size > 0.07 else 1, fold=0.3, part=LEAF,
                        mat=0, tint=tint,
                        profile=lambda u: math.sin(math.pi * min(1.0, 0.1 + 0.9 * u ** 0.8)) ** 0.8 * (1 - 0.35 * u),
                        side_hint=tan)
    # two young fiddleheads in the middle
    for k in range(2):
        a = rng.uniform(0, math.tau)
        base = V((math.cos(a) * 0.01, math.sin(a) * 0.01, 0))
        h = rng.uniform(0.12, 0.17)
        pts = [base, base + V((0, 0, h * 0.5)), base + V((0.01, 0, h * 0.9))]
        c = base + V((0.02, 0, h))
        for j in range(6):
            ang = j / 5 * math.pi * 1.5
            pts.append(c + V((math.cos(ang) * 0.02 * (1 - j / 8), 0, math.sin(ang) * 0.02 * (1 - j / 8))))
        rot = Matrix.Rotation(a, 3, "Z")
        pts = [base + rot @ (q - base) for q in pts]
        P.tube(pts, [lerp(0.004, 0.0025, i / (len(pts) - 1)) for i in range(len(pts))], segs=4, part=BUD, mat=0,
               tint=0.5, cap_start=False)
    return P


def flowers_a(seed=10):
    rng = random.Random(seed)
    P = PlantBM(seed)
    # basal leaves
    for k in range(9):
        a = rng.uniform(0, math.tau)
        d = V((math.cos(a), math.sin(a), 0.9)).normalized()
        P.blade(V((math.cos(a) * 0.015, math.sin(a) * 0.015, -0.005)), d, rng.uniform(0.07, 0.11), 0.016, bend=1.2,
                segs=3, fold=0.35, part=LEAF, mat=0, tint=rng.random(), profile=CR.ovate)
    kinds = ["daisy", "butter", "daisy", "butter", "daisy", "butter", "daisy"]
    for k, kd in enumerate(kinds):
        a = k * GA + rng.uniform(-0.3, 0.3)
        r = 0.035 * math.sqrt((k + 0.5) / len(kinds))
        base = V((math.cos(a) * r, math.sin(a) * r, 0.0))
        h = rng.uniform(0.15, 0.24)
        lean = V((math.cos(a), math.sin(a), 0)) * rng.uniform(0.02, 0.06)
        pts = N.bezier_points(base, base + V((0, 0, h * 0.4)), base + lean * 0.6 + V((0, 0, h * 0.8)),
                              base + lean + V((0, 0, h)), 5)
        P.tube(pts, [0.0022, 0.002, 0.0018, 0.0016, 0.0015], segs=3, part=STEM, mat=0, tint=rng.random(),
               cap_start=False, cap_end=False)
        top = pts[-1]
        nrm = ((pts[-1] - pts[-2]).normalized() + lean * 4.0 + V((0, 0, 0.6))).normalized()
        tint = 0.0 if kd == "daisy" else 1.0
        if kd == "daisy":
            P.flower(top, nrm, rng.uniform(0.022, 0.026), petals=9, cup=0.12, part=PETAL, mat=0, tint=0.0, notch=0.4,
                     rot0=rng.uniform(0, 1))
            P.blob(top + nrm * 0.004, 0.0065, squash=(1, 1, 0.55), freq=1, amp=0.0, part=FCENTER, mat=0, tint=0.0,
                   rot=nrm.to_track_quat("Z", "Y").to_matrix())
        else:
            P.flower(top, nrm, rng.uniform(0.016, 0.019), petals=5, cup=0.5, part=PETAL, mat=0, tint=1.0, notch=0.75,
                     rot0=rng.uniform(0, 1))
            P.blob(top + nrm * 0.006, 0.004, squash=(1, 1, 0.6), freq=1, amp=0.0, part=FCENTER, mat=0, tint=1.0,
                   rot=nrm.to_track_quat("Z", "Y").to_matrix())
        # a stem leaf
        p, tn = N.point_at(pts, 0.35)
        d = (V((math.cos(a + 1.5), math.sin(a + 1.5), 0)) + UP * 0.6).normalized()
        P.blade(p, d, 0.045, 0.008, bend=0.6, segs=2, fold=0.3, part=LEAF, mat=0, tint=rng.random(),
                profile=CR.lanceolate)
    return P


def plant_color_fn(kind, ao, part, tint, tw):
    grass = pal("grass")
    grass_d = pal("grass_dark")
    grass_l = pal("grass_light")
    leaf = pal("leaf")
    leaf_w = pal("leaf_warm")

    def fn(vi, p, n, m, pi):
        pt = part[pi]
        tn = tint[pi]
        t = tw[vi]
        j = tn - 0.5
        if pt in (LEAF, STEM, BUD):
            if kind == "grass":
                col = mix(grass_d, grass, smoothstep(0.0, 0.5, t))
                col = mix(col, mix(grass_l, leaf_w, 0.4 * tn), smoothstep(0.45, 1.0, t) * (0.5 + 0.4 * tn))
            elif kind == "fern":
                col = mix(shift(leaf, dh=0.01, dv=-0.1), mix(leaf, pal("leaf_light"), 0.5), 0.3 + 0.6 * t)
                if pt == BUD:
                    col = mix(pal("leaf_light"), leaf_w, 0.4)
                if pt == STEM:
                    col = mix(pal("leaf_dark"), leaf, 0.5)
            else:
                col = mix(pal("leaf_dark"), mix(grass, pal("leaf_light"), 0.4), 0.35 + 0.6 * t)
            col = shift(col, dh=0.015 * j, dv=0.1 * j)
        elif pt == PETAL:
            if tn < 0.5:  # daisy
                col = mix(shift(pal("flower_w"), dv=-0.1), pal("flower_w"), smoothstep(0.0, 0.6, t))
            else:
                col = mix(shift(pal("flower_y"), dv=-0.15), shift(pal("flower_y"), dv=0.06), smoothstep(0.0, 0.8, t))
        elif pt == FCENTER:
            col = shift(pal("flower_y"), dh=-0.02, dv=-0.05) if tn < 0.5 else shift(pal("flower_y"), dh=0.02, ds=-0.2)
        else:
            col = grass
        col = mix(col, scale_col(col, 0.55), 1.0 - smoothstep(0.0, 0.05, p.z))
        return scale_col(col, 0.5 + 0.5 * ao[vi])
    return fn


def finish_plant(P, name, kind, ao_dist=0.08):
    ob = P.to_object(name, ["Plant"], smooth=True)
    ao = N.bake_ao([ob], samples=16, dist=ao_dist, ground=0.0, bias=0.002)[ob.name]
    N.paint_ex(ob, plant_color_fn(kind, ao, N.face_attr(ob, "part"), N.face_attr(ob, "tint", 0.5),
                                  N.attr_values(ob, "tw", 0.5)))
    N.strip_plant_attrs(ob)
    return ob


# ----------------------------------------------------------------------------
# wild grain in a rocky crevice
# ----------------------------------------------------------------------------

def wild_grain(seed=12):
    rng = random.Random(seed)
    # stones forming a crevice + soil patch
    bm = bmesh.new()
    parts = [RockPart((-0.13, 0.0, 0.03), (0.15, 0.12, 0.11), N.random_planes(10, rng, (0.68, 0.86)), subdiv=2,
                      seed=seed, bevel=0.012),
             RockPart((0.12, 0.03, 0.02), (0.12, 0.11, 0.09), N.random_planes(9, rng, (0.68, 0.86)), subdiv=2,
                      seed=seed + 1, bevel=0.01),
             RockPart((0.0, -0.13, -0.01), (0.08, 0.07, 0.06), N.random_planes(9, rng, (0.7, 0.88)), subdiv=2,
                      seed=seed + 2, bevel=0.008)]
    N.build_rock_parts(bm, parts)
    N.densify(bm, 0.045, min_nz=0.3)
    w = N.moss_field(bm, seed=seed, amount=0.48, zmin=0.03, scale=6.0)
    stones = N.rock_object("Stones", bm, seed=seed, moss_w=w, dissolve=4.0, warp=0.006, cushion=0.006,
                           target_tris=700)
    # soil patch in the crevice
    sbm = bmesh.new()
    tmp = bmesh.new()
    bmesh.ops.create_circle(tmp, cap_ends=True, radius=1.0, segments=12)
    vm = {}
    for v in tmp.verts:
        q = v.co
        r = 1.0 + 0.15 * n1(q, 2.0, seed, 1)
        vm[v] = sbm.verts.new(V((q.x * 0.11 * r, q.y * 0.09 * r + 0.0, 0.012 + (0.01 if q.length < 0.5 else 0.0))))
    for f in tmp.faces:
        sbm.faces.new([vm[v] for v in f.verts])
    tmp.free()
    bmesh.ops.triangulate(sbm, faces=sbm.faces[:])
    for v in sbm.verts:
        d = math.hypot(v.co.x / 0.11, v.co.y / 0.09)
        v.co.z = 0.022 * (1.0 - d * d) + 0.004 * n1(v.co, 30.0, seed, 1) - 0.004
    soil = N.new_object("SoilPatch", sbm, mats=["Soil"], smooth=True)
    # grain: sparse ripe stalks emerging from the crevice
    P = PlantBM(seed)
    for k in range(6):
        a = k * GA + rng.uniform(-0.4, 0.4)
        r = rng.uniform(0.005, 0.04)
        base = V((math.cos(a) * r, math.sin(a) * r * 0.8, 0.01))
        ld = V((math.cos(a), math.sin(a), 0)) + V((rng.uniform(-0.3, 0.3), rng.uniform(-0.3, 0.3), 0))
        CR.grain_stalk(P, base, rng.uniform(0.55, 0.72), ld, rng.uniform(0.06, 0.16), True, False, rng, nleaves=1)
    for k in range(5):
        a = rng.uniform(0, math.tau)
        d = (V((math.cos(a), math.sin(a), 0)) * 0.8 + UP).normalized()
        P.blade(V((math.cos(a) * 0.02, math.sin(a) * 0.02, 0.012)), d, rng.uniform(0.14, 0.22), 0.009, bend=1.4,
                segs=3, fold=0.3, part=LEAF, mat=0, tint=rng.random(), profile=CR.lanceolate)
    gob = P.to_object("WildGrain", ["Plant", "Fruit"], smooth=True)
    bpy.context.view_layer.update()
    ao_g = N.bake_ao([gob], occluders=[stones, soil], samples=16, dist=0.15, ground=0.0, bias=0.002)[gob.name]
    N.paint_ex(gob, CR.crop_color_fn("grain", 3, ao_g, N.face_attr(gob, "part"), N.face_attr(gob, "tint", 0.5),
                                     N.attr_values(gob, "tw", 0.5)))
    N.paint_rock(stones, seed=seed, occluders=[gob, soil], ao_dist=0.15)
    ao_s = N.bake_ao([soil], occluders=[stones, gob], samples=16, dist=0.1, ground=None)[soil.name]
    N.paint_ex(soil, lambda vi, p, n, m, pi: scale_col(mix(pal("soil_dark"), pal("soil"), 0.5 + 0.5 * n1(p, 25.0, seed, 2)),
                                                       0.45 + 0.55 * ao_s[vi]))
    for o in (gob, stones, soil):
        N.strip_plant_attrs(o)
    ob = N.join([gob, stones, soil], "WildGrain")
    return ob


def main():
    N.reset()
    bush, berries = berry_bush()
    N.report_tris([bush, berries])
    N.export_glb("nature/berry_bush.glb", [bush])
    N.preview("berry_bush", [bush, berries], views=((18, 35), (35, 200)), dist_mul=3.0)

    N.reset()
    base, ms = mushroom_cluster()
    N.report_tris([base] + ms)
    N.export_glb("nature/mushroom_cluster.glb", [base])
    for m in ms:
        p = m.matrix_world.translation
        print(f"[mushroom_cluster] {m.name} at ({p.x:.3f}, {p.y:.3f}, {p.z:.3f}) dims {tuple(round(x, 3) for x in m.dimensions)}")
    N.preview("mushroom_cluster", [base] + ms, views=((25, 35), (18, 160)), dist_mul=2.8)

    for name, fn, kind, ao in (("grass_tuft", grass_tuft, "grass", 0.08), ("fern", fern, "fern", 0.12),
                               ("flowers_a", flowers_a, "flowers", 0.06)):
        N.reset()
        ob = finish_plant(fn(), name.title().replace("_", ""), kind, ao)
        N.report_tris([ob])
        bb = [ob.matrix_world @ V(c) for c in ob.bound_box]
        print(f"[{name}] height {max(v.z for v in bb):.2f} width {max(v.x for v in bb) - min(v.x for v in bb):.2f}")
        N.export_glb(f"nature/{name}.glb", [ob])
        N.preview(name, [ob], views=((22, 35),), dist_mul=3.0)

    N.reset()
    wg = wild_grain()
    N.report_tris([wg])
    bb = [wg.matrix_world @ V(c) for c in wg.bound_box]
    print(f"[wild_grain] height {max(v.z for v in bb):.2f} width {max(v.x for v in bb) - min(v.x for v in bb):.2f}")
    N.export_glb("nature/wild_grain.glb", [wg])
    N.preview("wild_grain", [wg], views=((16, 35), (30, 150)), dist_mul=3.6)


main()
