"""Skyroot earth / fire / container hand items.

    blender -b --python tools/blender/items_earth.py [-- <item names...>] [nopreview] [close]

charcoal, ash, earth, clay_raw, compost, potsherds, satchel
-> assets/models/items/<name>.glb (one mesh, origin at centre, real scale).
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from craft_lib import *  # noqa: E402,F401,F403

ARGS = cli_args()
REG = {}


def item(fn):
    REG[fn.__name__[5:]] = fn
    return fn


def clod(bm, center, radius, seed, squash=(1.0, 1.0, 0.7), subdiv=3, amp=0.28, scale=1.6, mat=0, flat_bottom=True,
         crumble=0.0):
    """Lumpy clod: displaced icosphere with a flattened base and optional crumbly facets."""
    faces = ico(bm, center, radius, subdiv=subdiv, squash=squash, noise_amp=amp, noise_scale=scale, seed=seed, mat=mat)
    c = V(center)
    vs = faces_verts(faces)
    rng = random.Random(seed)
    for v in vs:
        if crumble:
            q = v.co - c
            # quantise the radius a little -> chunky crumbs
            k = 1.0 + crumble * nz(q * 55.0 + V((seed, 0, 0)), 1.0, 1)
            v.co = c + q * k
        if flat_bottom and v.co.z < c.z - radius * squash[2] * 0.55:
            v.co.z = lerp(v.co.z, c.z - radius * squash[2] * 0.62, 0.8)
    return faces


# ----------------------------------------------------------------------------

@item
def make_charcoal():
    """3-4 chunky lumps of charcoal: blocky split-wood pieces with bark ridges and checking."""
    bm = new_bm()
    rng = random.Random(4)
    lumps = [((-0.024, -0.012, 0.0), 0.060, 0.021, 0.35), ((0.028, 0.004, 0.0), 0.052, 0.019, -0.55),
             ((-0.002, 0.027, 0.0), 0.044, 0.017, 1.35), ((0.010, -0.033, 0.0), 0.034, 0.015, 2.4)]
    lay = tag_layer(bm, "k")
    for i, ((x, y, z), L, r, rot) in enumerate(lumps):
        SEG = 6
        n = 4
        cen, profs = [], []
        for j in range(n):
            t = j / (n - 1)
            cen.append(V((lerp(-L / 2, L / 2, t), 0, 0)))
            pr = []
            for s_ in range(SEG):
                a = TAU * s_ / SEG + 0.3 * i
                rr = r * (1.0 + 0.10 * math.sin(a * 3 + j * 1.7 + i)) * (1.0 - 0.10 * abs(2 * t - 1))
                pr.append((math.cos(a) * rr, math.sin(a) * rr * 0.9))
            profs.append(pr)
        frames = [(V((1, 0, 0)), V((0, 0, 1)), V((0, -1, 0)))] * n
        res = sweep(bm, cen, profs, frames=frames, cap0="flat", cap1="flat", len0=r * 0.15, len1=r * 0.2, mat=0,
                    cap_inner=1)
        for f in res["side"] + res["cap0"] + res["cap1"]:
            f.smooth = False
        # chip one end off at an angle
        for v in res["rings"][-1] + faces_verts(res["cap1"]):
            v.co.x -= 0.006 * (v.co.z / r + 1.0)
        M = Matrix.Translation(V((x, y, z + r * 0.85))) @ Matrix.Rotation(rot, 4, "Z") @ Matrix.Rotation(
            rng.uniform(-0.4, 0.4), 4, "X")
        for v in faces_verts(res["side"] + res["cap0"] + res["cap1"]):
            v.co = M @ v.co
            v[lay] = i
        for v in faces_verts(res["cap0"] + res["cap1"]):
            v[lay] = i + 10

    def paint_fn(c):
        a = ao_shade(c.ao, 0.7)
        p = c.p
        k = c.tag("k")
        base = mix(col("#2B2827"), col("#141212"), 0.5 + 0.5 * nz(p * 70.0, 1.0, 2))
        # checking: cross-grain cracks
        u = c.tag("u")
        crack = abs(math.sin(u * 22.0 + 1.3 * k))
        base = mix(base, col("#060505"), 0.7 * smoothstep(0.12, 0.0, crack))
        if k >= 10:
            # end grain: growth rings in silvery grey
            rr = (p - V((p.x, p.y, p.z))).length
            base = mix(col("#3A3634"), col("#1A1717"), 0.5 + 0.5 * math.sin(c.tag("u") * 3.0 + nz(p * 200.0, 1.0, 1) * 4.0))
        # silvery sheen on up-facing facets
        base = mix(base, col("#6A6662"), 0.4 * clamp(c.n.z) ** 2)
        return sc(base, a)
    return make_obj("charcoal", bm, ["Charcoal"]), paint_fn, 0.02


@item
def make_ash():
    """A small soft grey pile with a couple of charcoal bits."""
    bm = new_bm()
    M = {"Ash": 0, "Charcoal": 1}
    SEG, RINGS = 16, 5
    R = 0.06
    H = 0.022
    centre = bm.verts.new((0, 0, H))
    rings = []
    rng = random.Random(3)
    for k in range(1, RINGS + 1):
        t = k / RINGS
        ring = []
        for s in range(SEG):
            a = TAU * s / SEG
            rr = R * t * (1.0 + 0.12 * nz(V((math.cos(a) * 1.5, math.sin(a) * 1.5, 3.0)), 1.0, 2))
            z = H * (1 - t ** 1.7) * (1.0 + 0.25 * nz(V((math.cos(a) * 3 * t, math.sin(a) * 3 * t, 1.0)), 1.0, 1))
            ring.append(bm.verts.new((math.cos(a) * rr, math.sin(a) * rr, max(0.0, z))))
        rings.append(ring)
    faces = []
    for s in range(SEG):
        faces.append(bm.faces.new((centre, rings[0][s], rings[0][(s + 1) % SEG])))
    for k in range(RINGS - 1):
        A, B = rings[k], rings[k + 1]
        for s in range(SEG):
            s2 = (s + 1) % SEG
            faces.append(bm.faces.new((A[s], B[s], B[s2], A[s2])))
    bottom = bm.verts.new((0, 0, 0))
    for s in range(SEG):
        faces.append(bm.faces.new((rings[-1][(s + 1) % SEG], rings[-1][s], bottom)))
    for f in faces:
        f.material_index = M["Ash"]
        f.smooth = True
    for i, (x, y, r) in enumerate(((0.018, -0.010, 0.008), (-0.022, 0.014, 0.006), (0.004, 0.026, 0.005))):
        z = H * (1 - (math.hypot(x, y) / R) ** 1.7) * 0.85
        ico(bm, (x, y, z), r, subdiv=1, squash=(1.4, 1.0, 0.7), noise_amp=0.25, seed=i + 5, mat=M["Charcoal"])

    def paint_fn(c):
        a = ao_shade(c.ao, 0.8)
        if c.m == "Charcoal":
            return sc(charcoal_color(c), a)
        p = c.p
        base = mix(col("#7E7A75"), col("#A8A49D"), 0.5 + 0.5 * nz(p * 90.0, 1.0, 2))
        base = mix(base, col("#6E6A66"), 0.3 * smoothstep(0.012, 0.0, p.z))
        speck = nz(p * 300.0, 1.0, 1)
        if speck > 0.55:
            base = mix(base, col("#3A3634"), 0.6)
        return sc(base, a)
    return make_obj("ash", bm, ["Ash", "Charcoal"]), paint_fn, 0.02


def soil_painter(base_hex="soil", dark_hex="soil_dark", light_hex="#7A5E48", bits=None):
    def fn(c):
        a = ao_shade(c.ao, 0.85)
        if c.m == "Stone":
            return sc(mix(col("stone"), col("stone_light"), 0.5 + 0.5 * nz(c.p * 200.0, 1.0, 1)), a)
        if c.m == "Leaves":
            return sc(mix(col("#7A6A30"), col("leaf_dark"), 0.5 + 0.5 * nz(c.p * 150.0, 1.0, 1)), a)
        if c.m == "Plant":
            return sc(col("#A08A5A"), a)
        p = c.p
        n1 = nz(p * 60.0, 1.0, 2)
        base = mix(col(base_hex), col(dark_hex), 0.4 + 0.45 * n1)
        base = mix(base, col(light_hex), 0.35 * clamp(c.n.z) * (0.5 + 0.5 * nz(p * 140.0, 1.0, 1)))
        speck = nz(p * 260.0, 1.0, 1)
        if bits and speck > 0.5:
            base = mix(base, col(bits), 0.5)
        return sc(base, a)
    return fn


@item
def make_earth():
    bm = new_bm()
    M = {"Soil": 0, "Plant": 1}
    clod(bm, (0, 0, 0.03), 0.055, seed=12, squash=(1.1, 0.95, 0.68), amp=0.30, crumble=0.10, mat=M["Soil"])
    rng = random.Random(12)
    for i in range(5):
        a = rng.uniform(0, TAU)
        r = rng.uniform(0.055, 0.075)
        clod(bm, (math.cos(a) * r, math.sin(a) * r, 0.008), rng.uniform(0.008, 0.014), seed=20 + i, subdiv=2,
             squash=(1.0, 1.0, 0.8), amp=0.3, mat=M["Soil"])
    # a couple of fine roots
    for p0, d in (((0.03, 0.035, 0.03), (0.3, 0.8, -0.2)), ((-0.05, -0.01, 0.025), (-0.9, -0.2, -0.3))):
        p0, d = V(p0), V(d).normalized()
        sweep(bm, [p0, p0 + d * 0.015 + V((0, 0, 0.004)), p0 + d * 0.03], prof_ellipse(0.0012, 0.0012, 3),
              cap0="open", cap1="point", len1=0.002, mat=M["Plant"])
    return make_obj("earth", bm, ["Soil", "Plant"]), soil_painter("soil", "soil_dark", "#7A5E48"), 0.03


@item
def make_clay_raw():
    bm = new_bm()
    M = {"Clay": 0, "Stone": 1}
    clod(bm, (0, 0, 0.026), 0.048, seed=33, squash=(1.12, 0.92, 0.66), amp=0.20, scale=1.3, mat=M["Clay"])
    clod(bm, (0.034, 0.024, 0.016), 0.022, seed=34, squash=(1.0, 0.9, 0.7), amp=0.2, scale=1.3, mat=M["Clay"], subdiv=2)
    rng = random.Random(33)
    for i in range(4):
        a = rng.uniform(0, TAU)
        r = rng.uniform(0.02, 0.045)
        z = 0.026 + 0.026 * math.sqrt(max(0.0, 1 - (r / 0.055) ** 2)) * 0.8
        ico(bm, (math.cos(a) * r, math.sin(a) * r * 0.8, z + 0.002), rng.uniform(0.0055, 0.0075), subdiv=2,
            squash=(1.2, 1.0, 0.75), noise_amp=0.2, seed=40 + i, mat=M["Stone"])

    def paint_fn(c):
        a = ao_shade(c.ao, 0.85)
        if c.m == "Stone":
            return sc(mix(col("stone_dark"), col("stone"), 0.5 + 0.5 * nz(c.p * 200.0, 1.0, 1)), a)
        p = c.p
        base = mix(col("clay"), col("#8A4E36"), 0.4 + 0.4 * nz(p * 45.0, 1.0, 2))
        base = mix(base, col("clay_dry"), 0.4 * clamp(c.n.z) * (0.5 + 0.5 * nz(p * 110.0, 1.0, 1)))
        # finger-smoothed sheen streaks
        base = sc(base, 1.0 + 0.06 * math.sin(p.x * 180.0 + p.z * 90.0))
        return sc(base, a)
    return make_obj("clay_raw", bm, ["Clay", "Stone"]), paint_fn, 0.03


@item
def make_compost():
    bm = new_bm()
    M = {"Soil": 0, "Leaves": 1}
    clod(bm, (0, 0, 0.026), 0.052, seed=51, squash=(1.1, 1.0, 0.62), amp=0.34, crumble=0.16, mat=M["Soil"])
    rng = random.Random(51)
    for i in range(7):
        a = rng.uniform(0, TAU)
        r = rng.uniform(0.0, 0.045)
        z = 0.026 + 0.032 * math.sqrt(max(0.0, 1 - (r / 0.06) ** 2)) * 0.95
        base = V((math.cos(a) * r, math.sin(a) * r, z))
        d = V((rng.uniform(-1, 1), rng.uniform(-1, 1), rng.uniform(-0.2, 0.3))).normalized()
        leaf_mesh(bm, base - d * 0.006, d, V((0, 0, 1)), 0.016, 0.006, thick=0.0012, rings=1, curl=rng.uniform(-0.6, 0.6),
                  mat=M["Leaves"])
    for i in range(4):
        a = rng.uniform(0, TAU)
        r = rng.uniform(0.05, 0.07)
        clod(bm, (math.cos(a) * r, math.sin(a) * r, 0.006), rng.uniform(0.006, 0.010), seed=60 + i, subdiv=2,
             squash=(1.0, 1.0, 0.8), amp=0.3, mat=M["Soil"])
    return make_obj("compost", bm, ["Soil", "Leaves"]), soil_painter("#4A3424", "#22170F", "#5E4632", bits="#7A6A3A"), 0.03


@item
def make_potsherds():
    """Three curved terracotta fragments of a pot wall, with a rim on one."""
    bm = new_bm()
    lay = tag_layer(bm, "k")
    R, T = 0.075, 0.007
    shards = [((-0.030, -0.010, 0.0), 0.2, (-0.45, 0.40), (0.000, 0.055), True),
              ((0.034, 0.008, 0.0), 2.4, (-0.38, 0.34), (0.000, 0.045), False),
              ((0.000, 0.040, 0.0), 4.4, (-0.30, 0.28), (0.000, 0.036), False)]
    for si, ((cx, cy, cz), rot, (a0, a1), (z0, z1), rim) in enumerate(shards):
        rng = random.Random(si * 7 + 1)
        NA, NZ = 6, 4
        outer, inner = [], []
        for j in range(NZ):
            tz = j / (NZ - 1)
            row_o, row_i = [], []
            for i in range(NA):
                ta = i / (NA - 1)
                # jagged break outline: shrink the extent irregularly
                ja = lerp(a0, a1, ta)
                zz = lerp(z0, z1, tz)
                if 0 < i < NA - 1 and j in (0, NZ - 1):
                    zz += (0.004 if j == 0 else -0.006) * rng.uniform(0.0, 1.0)
                if 0 < j < NZ - 1 and i in (0, NA - 1):
                    ja += (0.05 if i == 0 else -0.05) * rng.uniform(0.0, 1.0)
                prof_r = R * (1.0 - 0.18 * (zz / 0.06) ** 2)          # pot belly curvature
                o = V((math.cos(ja) * prof_r, math.sin(ja) * prof_r, zz))
                n = V((math.cos(ja), math.sin(ja), 0.25 * zz / 0.06)).normalized()
                th = T * (1.6 if (rim and j == NZ - 1) else 1.0)
                row_o.append(bm.verts.new(o))
                row_i.append(bm.verts.new(o - n * th))
            outer.append(row_o)
            inner.append(row_i)
        faces = []
        for j in range(NZ - 1):
            for i in range(NA - 1):
                faces.append(bm.faces.new((outer[j][i], outer[j][i + 1], outer[j + 1][i + 1], outer[j + 1][i])))
                faces.append(bm.faces.new((inner[j][i], inner[j + 1][i], inner[j + 1][i + 1], inner[j][i + 1])))
        loop = [(0, i) for i in range(NA)] + [(j, NA - 1) for j in range(1, NZ)] + \
               [(NZ - 1, i) for i in range(NA - 2, -1, -1)] + [(j, 0) for j in range(NZ - 2, 0, -1)]
        edge_faces = []
        for k in range(len(loop)):
            a, b = loop[k], loop[(k + 1) % len(loop)]
            edge_faces.append(bm.faces.new((outer[a[0]][a[1]], inner[a[0]][a[1]], inner[b[0]][b[1]], outer[b[0]][b[1]])))
        for f in faces:
            f.smooth = True
        for f in edge_faces:
            f.smooth = False
        allf = faces + edge_faces
        # lay the shard down: rotate so it rests on its outer curve, then place
        vs = faces_verts(allf)
        cen = V((0, 0, 0))
        for v in vs:
            cen += v.co
        cen /= len(vs)
        n_mid = V((cen.x, cen.y, 0)).normalized()
        Rm = n_mid.to_track_quat("-Z", "Y").to_matrix().to_4x4()
        M = Matrix.Translation(V((cx, cy, cz))) @ Matrix.Rotation(rot, 4, "Z") @ Rm @ Matrix.Translation(-cen)
        for v in vs:
            v.co = M @ v.co
        minz = min(v.co.z for v in vs)
        for v in vs:
            v.co.z -= minz
        for v in faces_verts(edge_faces):
            v[lay] = 2.0
        for f in faces:
            pass
        for row in inner:
            for v in row:
                if v[lay] != 2.0:
                    v[lay] = 1.0

    def paint_fn(c):
        a = ao_shade(c.ao, 0.8)
        k = c.tag("k")
        p = c.p
        if k == 2.0 and abs(c.n.z) < 0.9:
            base = mix(col("#D08A64"), col("#B87050"), 0.5 + 0.5 * nz(p * 300.0, 1.0, 1))
            return sc(base, a)
        base = mix(col("terracotta"), col("#9A4A2E"), 0.4 + 0.4 * nz(p * 60.0, 1.0, 2))
        if k == 1.0:
            base = mix(base, col("#7A3C26"), 0.35)       # inner wall, sooty
        # a painted band on the outer surface
        if k == 0.0:
            base = mix(base, col("#E8D2A8"), 0.6 * smoothstep(0.35, 0.8, math.sin(p.x * 140.0 + p.y * 60.0)))
        return sc(base, a)
    return make_obj("potsherds", bm, ["Ceramic"]), paint_fn, 0.02


@item
def make_satchel():
    """A small cloth bag gathered at the neck and tied with rope (Cloth = neutral, tintable)."""
    bm = new_bm()
    M = {"Cloth": 0, "Rope": 1}
    SEG = 14
    prof = [(0.000, 0.000), (0.060, 0.008), (0.095, 0.035), (0.105, 0.075), (0.098, 0.115), (0.075, 0.150),
            (0.040, 0.178), (0.026, 0.190), (0.030, 0.205), (0.050, 0.228), (0.044, 0.245)]
    cen, profs = [], []
    for i, (r, z) in enumerate(prof[1:], 1):
        pr = []
        for s in range(SEG):
            a = TAU * s / SEG
            rr = r
            if z > 0.17:
                rr *= 1.0 + 0.22 * math.sin(a * 7 + i)              # gathered pleats
            else:
                rr *= 1.0 + 0.05 * nz(V((math.cos(a) * 2, math.sin(a) * 2, z * 20)), 1.0, 1)
            pr.append((math.cos(a) * rr, math.sin(a) * rr * 0.85))
        cen.append(V((0.0, 0.0, z)))
        profs.append(pr)
    frames = [(V((0, 0, 1)), V((1, 0, 0)), V((0, 1, 0)))] * len(cen)
    res = sweep(bm, cen, profs, frames=frames, cap0="point", cap1="point", pole0=V((0, 0, 0.0)),
                pole1=V((0, 0, 0.232)), mat=M["Cloth"])
    # slump: flatten the bottom
    for v in faces_verts(res["side"] + res["cap0"] + res["cap1"]):
        if v.co.z < 0.02:
            v.co.z = max(0.0, v.co.z * 0.5)
    # rope tie + dangling ends
    ring = []
    for i in range(10):
        a = TAU * i / 10
        ring.append(V((math.cos(a) * 0.031, math.sin(a) * 0.027, 0.191 + 0.003 * math.sin(a * 2))))
    rope_path_tube(bm, ring, 0.0045, seg=4, mat=M["Rope"], closed=True, twist_rate=90)
    for d, L in ((V((0.6, -0.8, -0.5)), 0.07), (V((0.85, -0.3, -0.6)), 0.055)):
        d = d.normalized()
        p0 = V((0.028, -0.02, 0.19))
        pts = [p0, p0 + d * L * 0.5 + V((0.01, 0, 0)), p0 + d * L + V((0.015, 0, -0.01))]
        rope_path_tube(bm, pts, 0.0042, seg=4, mat=M["Rope"], twist_rate=90)
    # rotate so the bag lies on its side along X (long axis X)
    Mr = Matrix.Rotation(math.radians(-90), 4, "Y") @ Matrix.Rotation(math.radians(8), 4, "X")
    for v in bm.verts:
        v.co = Mr @ v.co
    minz = min(v.co.z for v in bm.verts)
    for v in bm.verts:
        v.co.z -= minz
    # sag onto the ground
    for v in bm.verts:
        if v.co.z < 0.03:
            v.co.z = max(0.0, v.co.z - 0.01 * (1 - v.co.z / 0.03))

    def paint_fn(c):
        a = ao_shade(c.ao, 0.9)
        if c.m == "Rope":
            return sc(rope_color(c), a)
        p = c.p
        weave = 1.0 + 0.03 * math.sin(p.x * 900.0) * math.sin(p.y * 900.0 + p.z * 900.0)
        base = grey(0.74 * weave * (1.0 + 0.04 * nz(p * 30.0, 1.0, 2)))
        # a patch and a darker worn bottom
        if (p - V((-0.05, -0.06, 0.06))).length < 0.022:
            base = grey(0.62)
        base = sc(base, 0.9 + 0.1 * smoothstep(0.0, 0.05, p.z))
        return sc(base, a)
    return make_obj("satchel", bm, ["Cloth", "Rope"]), paint_fn, 0.05


if __name__ == "__main__":
    run_items(REG, ARGS, "items_earth", cols=4)
