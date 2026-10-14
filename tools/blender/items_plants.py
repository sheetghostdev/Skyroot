"""Skyroot plant-material hand items.

    blender -b --python tools/blender/items_plants.py [-- <item names...>] [nopreview] [close]

fiber, cordage, grass, straw, leaves, grain, seeds_grain, seeds_fiber, seed_tree, berries,
food_scraps -> assets/models/items/<name>.glb (one mesh, origin at centre, real scale).
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


def dir_rot(d):
    return V(d).normalized().to_track_quat("Z", "Y").to_matrix()


def strand_tags(bm, faces, k):
    lay = tag_layer(bm, "k")
    for v in faces_verts(faces):
        v[lay] = k


# ----------------------------------------------------------------------------

@item
def make_fiber():
    """Loose hank of pale plant fibres, twisted in the middle, splayed at the ends."""
    bm = new_bm()
    rng = random.Random(5)
    N = 17
    for i in range(N):
        a0 = TAU * i / N + rng.uniform(-0.3, 0.3)
        rad_mid = rng.uniform(0.003, 0.008)
        rad_end = rng.uniform(0.012, 0.032)
        x0 = -0.20 + rng.uniform(-0.012, 0.02)
        x1 = 0.20 + rng.uniform(-0.03, 0.012)
        pts = []
        n = 7
        for j in range(n):
            t = j / (n - 1)
            x = lerp(x0, x1, t)
            spread = lerp(rad_end, rad_mid, 1 - abs(2 * t - 1) ** 1.5)
            a = a0 + 2.2 * (t - 0.5)                    # gentle twist through the hank
            y = math.cos(a) * spread + 0.004 * nz(V((t * 4, i * 1.7, 0.3)), 1.0, 1)
            z = math.sin(a) * spread * 0.55 + 0.006 + 0.004 * nz(V((t * 4, i * 1.7, 5.3)), 1.0, 1)
            if j in (0, n - 1):
                z -= rng.uniform(0.0, 0.008)            # frayed ends droop
            pts.append(V((x, y, z)))
        w = rng.uniform(0.0024, 0.0036)
        h = 0.0009
        prof = [(h, 0.0), (-h, w), (-h, -w)]
        res = sweep(bm, pts, prof, up=(0, 0, 1), cap0="point", cap1="point", len0=0.004, len1=0.004, mat=0)
        strand_tags(bm, res["side"] + res["cap0"] + res["cap1"], rng.random())

    def paint_fn(c):
        k = c.tag("k")
        base = mix(col("fiber"), col("#D8CFA0"), k)
        base = mix(base, col("#9FA86A"), 0.25 * (1 - k) * (0.5 + 0.5 * nz(c.p * 30.0, 1.0, 1)))
        return sc(base, ao_shade(c.ao, 0.8))
    return make_obj("fiber", bm, ["Plant"]), paint_fn, 0.02


@item
def make_cordage():
    """A neat coil of two-ply twisted cord with the loose end tucked over the top."""
    bm = new_bm()
    R0, rr = 0.052, 0.0058
    pts = []
    turns = 2.1
    n = int(27 * turns)
    for i in range(n + 1):
        t = i / n
        a = TAU * turns * t
        r = R0 * (1.0 + 0.03 * math.sin(a * 2.3)) - 0.004 * t
        z = rr + (2 * rr * 1.02) * (a / TAU) * 0.62 + 0.0012 * math.sin(a * 3)
        pts.append(V((math.cos(a) * r, math.sin(a) * r, z)))
    # loose end crosses the coil and trails out
    last = pts[-1]
    a_end = TAU * turns
    out = V((math.cos(a_end), math.sin(a_end), 0))
    side = V((-math.sin(a_end), math.cos(a_end), 0))
    pts += [last + side * 0.018 - out * 0.012 + V((0, 0, 0.006)),
            last + side * 0.040 - out * 0.030 + V((0, 0, 0.007)),
            last + side * 0.062 - out * 0.036 + V((0, 0, 0.001)),
            last + side * 0.085 - out * 0.030 + V((0, 0, -0.006))]
    res = rope_path_tube(bm, pts, rr, seg=6, mat=0, twist_rate=87.0)

    def paint_fn(c):
        return sc(rope_color(c, col("rope"), dark=0.58), ao_shade(c.ao, 0.85))
    return make_obj("cordage", bm, ["Rope"]), paint_fn, 0.025


def bundle(bm, n, seed, length, width, tie_x, mat_blade, mat_band, droop, spread, straight=False, band_mat_k=2.0):
    rng = random.Random(seed)
    lay = tag_layer(bm, "k")
    for i in range(n):
        a = TAU * i / n * 2.618 + rng.uniform(-0.2, 0.2)
        r = 0.006 * math.sqrt((i + 0.5) / n)
        y0, z0 = math.cos(a) * r, math.sin(a) * r + 0.012
        L = length * rng.uniform(0.82, 1.05)
        x0 = -0.5 * length + rng.uniform(-0.01, 0.015)
        base = V((x0, y0 * 1.6, z0))
        # fan out after the tie
        dy = math.cos(a) * spread * rng.uniform(0.4, 1.0)
        dz = math.sin(a) * spread * 0.45 * rng.uniform(0.4, 1.0) + 0.02
        direction = V((1.0, dy, dz)).normalized()
        upv = V((0, -math.sin(a), math.cos(a)))
        if straight:
            # straw: hollow-looking stalks, fanned a little at both ends
            mid = V((x0 + L * 0.5, y0 * 1.2, z0))
            p0 = mid - V((L * 0.5, -dy * 0.35, -dz * 0.2))
            p1 = mid + V((L * 0.5, dy * 0.5, dz * 0.4 - 0.01))
            sp = [p0, p0.lerp(mid, 0.6), mid, mid.lerp(p1, 0.6), p1]
            ww = width * rng.uniform(0.8, 1.15)
            res = sweep(bm, sp, prof_ellipse(ww, ww, 3, phase=rng.uniform(0, 2)), up=(0, 0, 1),
                        cap0="flat", cap1="flat", mat=mat_blade)
        else:
            res = blade_mesh(bm, base, direction, L, width * rng.uniform(0.75, 1.15), up=upv,
                             droop=droop * rng.uniform(0.5, 1.2), rings=3, thick=0.0012,
                             mat=mat_blade, twist=rng.uniform(-0.25, 0.25), fold=0.35, taper=1.0, tip=True)
        for v in faces_verts(res["side"] + res["cap0"] + res["cap1"]):
            v[lay] = rng.random() * 0.9
    # tie band
    ring = []
    for i in range(10):
        a = TAU * i / 10
        ring.append(V((tie_x + 0.003 * math.sin(a * 2), math.cos(a) * 0.0155, math.sin(a) * 0.0125 + 0.012)))
    res = rope_path_tube(bm, ring, 0.0046, seg=4, mat=mat_band, closed=True, twist_rate=110)
    for v in faces_verts(res["side"]):
        v[lay] = band_mat_k


@item
def make_grass():
    bm = new_bm()
    bundle(bm, 17, 7, 0.44, 0.0105, -0.12, 0, 0, droop=0.12, spread=0.10)

    def paint_fn(c):
        a = ao_shade(c.ao, 0.8)
        k = c.tag("k")
        if k >= 2.0:
            return sc(mix(col("grass_dark"), col("#7E8F3F"), 0.5), a)
        u = c.tag("u")
        base = mix(col("grass_dark"), col("grass"), 0.4 + 0.6 * k)
        base = mix(base, col("grass_light"), 0.5 * u * (0.5 + k * 0.5))
        if u < 0.04:
            base = mix(base, col("#C9D79A"), 0.6)       # fresh cut ends
        return sc(base, a)
    return make_obj("grass", bm, ["Plant"]), paint_fn, 0.02


@item
def make_straw():
    bm = new_bm()
    bundle(bm, 21, 9, 0.45, 0.0034, -0.02, 0, 0, droop=0.02, spread=0.06, straight=True)

    def paint_fn(c):
        a = ao_shade(c.ao, 0.8)
        k = c.tag("k")
        if k >= 2.0:
            return sc(col("#B39A5C"), a)
        u = c.tag("u")
        base = mix(col("straw"), col("#B8984F"), 0.2 + 0.6 * k)
        base = mix(base, col("#EADAA0"), 0.35 * u)
        if u < 0.04:
            base = mix(base, col("#9C8048"), 0.4)
        return sc(base, a)
    return make_obj("straw", bm, ["Straw"]), paint_fn, 0.02


@item
def make_leaves():
    """A small loose pile of leaves, mostly green with a few turning."""
    bm = new_bm()
    rng = random.Random(17)
    lay = tag_layer(bm, "k")
    N = 13
    for i in range(N):
        r = 0.085 * math.sqrt(rng.random())
        a = rng.uniform(0, TAU)
        cx, cy = math.cos(a) * r, math.sin(a) * r
        h = 0.028 * (1 - r / 0.1) + 0.004 * i / N
        d_ang = rng.uniform(0, TAU)
        tilt = rng.uniform(-0.25, 0.25)
        d = V((math.cos(d_ang), math.sin(d_ang), tilt)).normalized()
        L = rng.uniform(0.075, 0.10)
        base = V((cx, cy, h)) - d * L * 0.45
        upv = V((rng.uniform(-0.3, 0.3), rng.uniform(-0.3, 0.3), 1.0))
        res = leaf_mesh(bm, base, d, upv, L, L * rng.uniform(0.24, 0.30), thick=0.0016, rings=3,
                        curl=rng.uniform(-0.2, 0.5), droop=rng.uniform(-0.1, 0.12), fold=0.35, mat=0, smooth6=True)
        kk = rng.random()
        for v in faces_verts(res["side"] + res["cap0"] + res["cap1"]):
            v[lay] = kk
        # petiole
        sweep(bm, [base - d * 0.012 + V((0, 0, -0.001)), base + d * 0.004], prof_ellipse(0.0012, 0.0012, 3),
              cap0="point", cap1="open", len0=0.002, mat=0)

    def paint_fn(c):
        a = ao_shade(c.ao, 0.85)
        k = c.tag("k")
        base = leaf_color(c, seed=k * 10.0)
        if k > 0.78:
            base = mix(col("#C9A23E"), col("#B5652E"), (k - 0.78) * 4.0)   # a couple of autumn leaves
        elif k > 0.62:
            base = mix(base, col("leaf_warm"), 0.6)
        u = c.tag("u")
        base = sc(base, 0.92 + 0.12 * (1 - abs(u - 0.5) * 2))
        if c.tag("a") < 0.01 and c.n.z > 0:
            base = mix(base, col("#C9D68A") if k <= 0.78 else col("#E0C070"), 0.35)   # pale midrib
        return sc(base, a)
    return make_obj("leaves", bm, ["Leaves"]), paint_fn, 0.03


@item
def make_grain():
    """A small sheaf of ripe grain stalks with heavy heads, tied with a twist of grass."""
    bm = new_bm()
    M = {"Straw": 0, "Fruit": 1, "Plant": 2}
    rng = random.Random(23)
    lay = tag_layer(bm, "k")
    N = 6
    for i in range(N):
        a = TAU * i / N + rng.uniform(-0.3, 0.3)
        r = 0.004 + 0.003 * (i % 2)
        base = V((-0.20 + rng.uniform(-0.01, 0.01), math.cos(a) * r, math.sin(a) * r + 0.01))
        spread = V((0, math.cos(a), math.sin(a) * 0.5 + 0.25)) * rng.uniform(0.03, 0.07)
        mid = V((0.02, 0, 0.012)) + spread * 0.6 + V((0, base.y, base.z))
        top = V((0.11 + rng.uniform(-0.015, 0.01), 0, 0)) + spread * 1.3 + V((0, 0, 0.012 - 0.02 * rng.random()))
        stalk = bezier_points(base, base + V((0.08, 0, 0)), mid, top, 4)
        sweep(bm, stalk, prof_ellipse(0.0016, 0.0016, 4), up=(0, 0, 1), cap0="flat", cap1="open", mat=M["Straw"])
        # nodding head
        d = (stalk[-1] - stalk[-2]).normalized()
        d = (d + V((0.0, 0.0, -0.35))).normalized()
        hl = rng.uniform(0.085, 0.10)
        ts = [0.0, 0.12, 0.25, 0.38, 0.51, 0.64, 0.77, 0.9]
        hp = [stalk[-1] + d * hl * t for t in ts]
        hr = []
        profs_h = []
        for j, t in enumerate(ts):
            env = 0.0042 + 0.0050 * math.sin(math.pi * min(1.0, 0.15 + t * 0.95)) ** 0.7
            r_ = env * (1.0 if j % 2 else 0.86)        # kernel rows
            profs_h.append(prof_ellipse(r_ * 0.8, r_, 6, phase=(math.pi / 6) * (j % 2)))
        res = sweep(bm, hp, profs_h, up=(0, 0, 1), cap0="open", cap1="point", len1=0.008, mat=M["Fruit"])
        for v in faces_verts(res["side"] + res["cap1"]):
            v[lay] = 1.0
    ring = []
    for i in range(9):
        a = TAU * i / 9
        ring.append(V((-0.115 + 0.003 * math.sin(2 * a), math.cos(a) * 0.0125, math.sin(a) * 0.0110 + 0.011)))
    rope_path_tube(bm, ring, 0.0042, seg=4, mat=M["Plant"], closed=True, twist_rate=110)

    def paint_fn(c):
        a = ao_shade(c.ao, 0.8)
        if c.m == "Fruit":
            u = c.tag("u")
            kern = 1.0 if (round(c.tag("a") * 6) + round(u * 8)) % 2 else 0.0
            base = mix(col("grain"), col("#B88F3C"), 0.35 * kern + 0.15 * nz(c.p * 200.0, 1.0, 1))
            base = mix(base, col("grain_green"), 0.15 * (1 - u))
            return sc(base, a)
        if c.m == "Plant":
            return sc(mix(col("grass_dark"), col("#8A8C45"), 0.5), a)
        u = c.tag("u")
        return sc(mix(col("straw"), col("#C2A35E"), 0.3 + 0.3 * nz(c.p * 50.0, 1.0, 1)), a)
    return make_obj("grain", bm, ["Straw", "Fruit", "Plant"]), paint_fn, 0.02


def dish_leaf(bm, length, width, depth, seg=12, rings=8, mat=0, flat=False):
    """A cupped leaf (closed dish) lying on the ground, tip toward +X."""
    def deform(d, co):
        co = V(co)
        # leaf outline: pinch toward the tip (+X) and slightly at the base
        x = d.x
        co.y *= (1.0 - 0.75 * smoothstep(0.1, 1.0, x)) * (1.0 - 0.25 * smoothstep(-0.4, -1.0, x))
        # cup: push the upper surface down below the rim
        if d.z > 0:
            cup = (1.0 - (d.x ** 2 + d.y ** 2)) * (1.0 if not flat else 0.25)
            co.z = co.z * 0.25 - depth * cup
        return co
    return ellipsoid(bm, (0, 0, 0), (length / 2, width / 2, depth * 0.8), seg=seg, rings=rings, mat=mat,
                     deform=deform)


@item
def make_seeds_grain():
    bm = new_bm()
    M = {"Leaves": 0, "Fruit": 1}
    dish_leaf(bm, 0.085, 0.052, 0.010, mat=M["Leaves"])
    rng = random.Random(31)
    lay = tag_layer(bm, "k")
    placed = []
    tries = 0
    while len(placed) < 13 and tries < 400:
        tries += 1
        x, y = rng.uniform(-0.024, 0.02), rng.uniform(-0.013, 0.013)
        if (x / 0.03) ** 2 + (y / 0.016) ** 2 > 1:
            continue
        if any((x - px) ** 2 + (y - py) ** 2 < 0.0075 ** 2 for px, py, pz in placed):
            continue
        z = -0.002 + 0.0035 * len([1 for px, py, pz in placed if (x - px) ** 2 + (y - py) ** 2 < 0.012 ** 2])
        placed.append((x, y, z))
    for i, (x, y, z) in enumerate(placed):
        rot = Euler((rng.uniform(-0.3, 0.3), rng.uniform(-0.3, 0.3), rng.uniform(0, math.pi))).to_matrix()
        f = ellipsoid(bm, (x, y, z + 0.003), (0.0055, 0.0030, 0.0027), seg=6, rings=4, mat=M["Fruit"], rot=rot)
        for v in faces_verts(f):
            v[lay] = rng.random()

    def paint_fn(c):
        a = ao_shade(c.ao, 0.85)
        if c.m == "Fruit":
            base = mix(col("#E9D9A4"), col("grain"), 0.5 * c.tag("k"))
            base = sc(base, 0.9 + 0.15 * clamp(c.n.z))
            return sc(base, a)
        base = leaf_color(c, 2.0)
        if c.n.z > 0.2:
            base = mix(base, col("leaf_light"), 0.25)
        return sc(base, a)
    return make_obj("seeds_grain", bm, ["Leaves", "Fruit"]), paint_fn, 0.012


@item
def make_seeds_fiber():
    bm = new_bm()
    M = {"Leaves": 0, "Fruit": 1}
    dish_leaf(bm, 0.075, 0.045, 0.005, mat=M["Leaves"], flat=True)
    rng = random.Random(41)
    lay = tag_layer(bm, "k")
    for i in range(22):
        r = 0.013 * math.sqrt(rng.random())
        a = rng.uniform(0, TAU)
        x, y = math.cos(a) * r * 1.4 - 0.004, math.sin(a) * r
        z = 0.0002 + 0.0025 * (1 - r / 0.013)
        f = ellipsoid(bm, (x, y, z), (0.0021, 0.0017, 0.0016), seg=5, rings=3, mat=M["Fruit"],
                      rot=Euler((0, 0, rng.uniform(0, math.pi))).to_matrix())
        for v in faces_verts(f):
            v[lay] = rng.random()

    def paint_fn(c):
        a = ao_shade(c.ao, 0.85)
        if c.m == "Fruit":
            base = mix(col("#2E241E"), col("#5A4632"), 0.6 * c.tag("k"))
            base = mix(base, col("#8C7A66"), 0.35 * clamp(c.n.z) ** 3)
            return sc(base, a)
        return sc(mix(leaf_color(c, 5.0), col("leaf_warm"), 0.15), a)
    return make_obj("seeds_fiber", bm, ["Leaves", "Fruit"]), paint_fn, 0.01


@item
def make_seed_tree():
    """A winged samara pair (two nutlets joined at the stalk, papery veined wings)."""
    bm = new_bm()
    lay = tag_layer(bm, "k")
    for sx in (1, -1):
        nut_c = V((sx * 0.006, 0.0, 0.004))
        f = ellipsoid(bm, nut_c, (0.0075, 0.0055, 0.0048), seg=6, rings=4, mat=0,
                      rot=Euler((0, 0, math.radians(90 + sx * 58))).to_matrix())
        for v in faces_verts(f):
            v[lay] = 1.0
        wd = V((sx * 0.86, 0.5, 0.05)).normalized()
        res = leaf_mesh(bm, nut_c + wd * 0.003, wd, V((0, 0, 1)), 0.042, 0.0105, thick=0.0006, rings=4,
                        curl=0.10, droop=0.03, fold=0.05, mat=0, asym=(0.25, 1.0) if sx > 0 else (1.0, 0.25))
        for f in res["side"] + res["cap0"] + res["cap1"]:
            f.smooth = False
        for v in faces_verts(res["side"] + res["cap0"] + res["cap1"]):
            v[lay] = 0.0
    # little stalk
    res = sweep(bm, [V((0, -0.002, 0.005)), V((0, -0.008, 0.007)), V((0.001, -0.014, 0.006))],
                prof_ellipse(0.0009, 0.0009, 4), cap0="open", cap1="point", len1=0.001, mat=0)
    for v in faces_verts(res["side"] + res["cap1"]):
        v[lay] = 2.0

    def paint_fn(c):
        a = ao_shade(c.ao, 0.8)
        k = c.tag("k")
        if k >= 2.0:
            return sc(col("#6B4E36"), a)
        if k >= 1.0:
            return sc(mix(col("#8A5A3C"), col("#A5704A"), 0.5 + 0.5 * nz(c.p * 200.0, 1.0, 1)), a)
        u = c.tag("u")
        base = mix(col("#B3A35E"), col("#D7C58A"), smoothstep(0.1, 0.8, u))
        base = mix(base, col("#9C7B4E"), 0.35 * (1 - smoothstep(0.0, 0.35, u)))
        vein = 0.5 + 0.5 * math.sin(c.tag("a") * TAU * 2 + u * 18.0)
        base = sc(base, 0.92 + 0.1 * vein)
        return sc(base, a)
    return make_obj("seed_tree", bm, ["Fruit"]), paint_fn, 0.008


@item
def make_berries():
    """A cluster of 8 red berries on short stems along a tiny twig, with two leaves."""
    bm = new_bm()
    M = {"Bark": 0, "Plant": 1, "Fruit": 2, "Leaves": 3}
    lay = tag_layer(bm, "k")
    twig = [V((-0.045, 0, 0.012)), V((-0.01, 0.002, 0.016)), V((0.025, -0.002, 0.018)), V((0.05, 0.001, 0.016))]
    wood_rod(bm, twig, 0.0024, 0.0016, seg=5, seed=2, bark_mat=M["Bark"], end_mat=M["Bark"], end0="cut", end1="point",
             noise_amp=0.0, cap_inner=0)
    rng = random.Random(8)
    centres = [(-0.022, 0.016, 0.012), (-0.008, -0.017, 0.011), (0.004, 0.019, 0.013), (0.016, -0.014, 0.011),
               (0.028, 0.012, 0.012), (0.036, -0.006, 0.010), (0.006, 0.000, 0.024), (-0.012, 0.003, 0.026),
               (0.022, 0.003, 0.026)]
    for i, cc in enumerate(centres[:8]):
        c = V(cc)
        r = rng.uniform(0.0085, 0.0105)
        c.z = max(c.z, r)
        f = ellipsoid(bm, c, (r, r, r * 0.95), seg=7, rings=5, mat=M["Fruit"])
        for v in faces_verts(f):
            v[lay] = rng.random()
        # stem to the twig
        tp = V((c.x * 0.8, 0.0, 0.016))
        top = c + (tp - c).normalized() * r * 0.9
        sweep(bm, [tp, tp.lerp(top, 0.5) + V((0, 0, 0.002)), top], prof_ellipse(0.0008, 0.0008, 3),
              cap0="open", cap1="open", mat=M["Plant"])
    for sx, d in ((1, V((0.3, 0.9, 0.25))), (-1, V((-0.5, -0.8, 0.3)))):
        base = twig[1 if sx > 0 else 2]
        leaf_mesh(bm, base, d, V((0, 0, 1)), 0.036, 0.0135, thick=0.0012, rings=2, curl=0.25, droop=0.1, mat=M["Leaves"])

    def paint_fn(c):
        a = ao_shade(c.ao, 0.8)
        if c.m == "Fruit":
            k = c.tag("k")
            base = mix(col("#A81E35"), col("#7E1428"), 0.5 * k)
            base = mix(base, col("#D9485C"), 0.45 * clamp(c.n.z) ** 3)
            if c.n.z < -0.85:
                base = col("#3A1A1C")                   # little calyx
            return sc(base, a)
        if c.m == "Plant":
            return sc(col("#6E7A3A"), a)
        if c.m == "Leaves":
            return sc(leaf_color(c, 4.0), a)
        return sc(bark_color(c, 2.0), a)
    return make_obj("berries", bm, ["Bark", "Plant", "Fruit", "Leaves"]), paint_fn, 0.012


@item
def make_food_scraps():
    """Peelings and husks: curled tuber peels (skin out, cream in), a dry husk, a stem."""
    bm = new_bm()
    M = {"Fruit": 0, "Plant": 1}
    lay = tag_layer(bm, "k")
    rng = random.Random(13)
    peels = [((-0.02, 0.012, 0.0), 0.3, 0.075, 1.6, 1.0), ((0.022, -0.006, 0.0), 2.1, 0.065, 2.2, 4.0),
             ((-0.004, -0.024, 0.0), 4.0, 0.055, 1.2, 1.0)]
    for (cx, cy, cz), rot, L, curl, kk in peels:
        pts = []
        n = 8
        for j in range(n):
            t = j / (n - 1)
            ang = curl * (t - 0.3) * math.pi
            r = L / (curl * math.pi) if curl else 1.0
            px = math.sin(ang) * r
            pz = (1 - math.cos(ang)) * r * 0.55 + 0.003
            py = 0.006 * math.sin(t * 5.0)
            q = V((px, py, pz))
            q = Matrix.Rotation(rot, 3, "Z") @ q
            pts.append(q + V((cx, cy, cz)))
        w = 0.0068
        prof = [(0.0010, 0.0), (0.0016, w * 0.6), (0.0, w), (-0.0010, 0.0), (0.0, -w), (0.0016, -w * 0.6)]
        profs = []
        for j in range(n):
            t = j / (n - 1)
            f = 0.55 + 0.45 * math.sin(math.pi * (0.08 + 0.84 * t))
            profs.append([(x, y * f * (1.0 + 0.15 * math.sin(j * 2.1))) for x, y in prof])
        res = sweep(bm, pts, profs, up=(0, 0, 1), cap0="flat", cap1="flat", mat=M["Fruit"])
        for v in faces_verts(res["side"] + res["cap0"] + res["cap1"]):
            v[lay] = kk
    # dry husk
    res = leaf_mesh(bm, V((-0.046, -0.002, 0.002)), V((0.95, 0.3, 0.05)), V((0, 0, 1)), 0.075, 0.012, thick=0.0014,
                    rings=3, curl=0.6, droop=-0.04, fold=0.8, mat=M["Plant"], smooth6=True)
    for v in faces_verts(res["side"] + res["cap0"] + res["cap1"]):
        v[lay] = 2.0
    # a bitten-off stem end
    res = sweep(bm, [V((0.03, 0.02, 0.003)), V((0.042, 0.03, 0.006)), V((0.05, 0.042, 0.004))],
                prof_ellipse(0.0022, 0.0022, 5), cap0="flat", cap1="flat", mat=M["Plant"])
    for v in faces_verts(res["side"] + res["cap0"] + res["cap1"]):
        v[lay] = 3.0

    def paint_fn(c):
        a = ao_shade(c.ao, 0.85)
        k = c.tag("k")
        if k in (1.0, 4.0):
            # skin on the top side for peel k=1, on the underside for k=4; flesh opposite
            aidx = c.tag("a")
            skin = (aidx < 0.2 or aidx > 0.8) if k == 1.0 else (0.3 < aidx < 0.7)
            if skin:
                base = mix(col("#7A3548"), col("#5A2436"), 0.5 + 0.5 * nz(c.p * 120.0, 1.0, 1))
            else:
                base = mix(col("tuber_flesh"), col("#D8BE84"), 0.35 + 0.3 * nz(c.p * 90.0, 1.0, 1))
            return sc(base, a)
        if k == 2.0:
            u = c.tag("u")
            base = mix(col("#D8CB98"), col("#B8A46A"), 0.5 + 0.5 * math.sin(c.tag("a") * TAU * 3 + u * 10))
            return sc(base, a)
        return sc(col("#7C7A40"), a)
    return make_obj("food_scraps", bm, ["Fruit", "Plant"]), paint_fn, 0.012


if __name__ == "__main__":
    run_items(REG, ARGS, "items_plants", cols=4)
