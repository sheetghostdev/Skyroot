"""Skyroot food items: tuber, tuber_roasted, mushroom, mushroom_roasted.

    blender -b --python tools/blender/items_food.py [-- <item names...>] [nopreview] [close]
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


# ----------------------------------------------------------------------------
# tuber
# ----------------------------------------------------------------------------

def tuber_geo(bm, shrink=1.0, split=False, seed=3):
    """Knobbly root lying along X.  Fruit = body/tail/hairs, Plant = stem stub.
    tag k: 0 skin, 1 split flesh, 0.5 split lips."""
    M = {"Fruit": 0, "Plant": 1}
    lay = tag_layer(bm, "k")
    SEG = 16 if split else 12
    xs = [-0.054, -0.046, -0.031, -0.012, 0.009, 0.028, 0.043, 0.053]
    rs = [0.011, 0.020, 0.027, 0.0305, 0.030, 0.026, 0.0195, 0.011]
    off = V((seed * 3.1, seed * 1.7, 0.4))
    cen, profs = [], []
    for i, (x, r) in enumerate(zip(xs, rs)):
        x *= shrink
        r *= shrink
        c = V((x, 0.0, 0.0012 * math.sin(i * 1.3)))
        pr = []
        for s in range(SEG):
            a = TAU * s / SEG
            d = V((0, math.sin(a), math.cos(a)))
            k = 1.0 + 0.16 * nz((c + d * r) * 30.0 + off, 1.0, 2) + 0.09 * nz((c + d * r) * 80.0 + off, 1.0, 1)
            rr = r * k
            pr.append((math.cos(a) * rr * 0.9, math.sin(a) * rr))
        cen.append(c)
        profs.append(pr)
    frames = [(V((1, 0, 0)), V((0, 0, 1)), V((0, -1, 0)))] * len(xs)
    res = sweep(bm, cen, profs, frames=frames, cap0="round", cap1="round", len0=0.010 * shrink,
                len1=0.009 * shrink, cap_rings=1, mat=M["Fruit"])
    for v in faces_verts(res["side"] + res["cap0"] + res["cap1"]):
        v[lay] = 0.0
    if split:
        # open a split along the top: push the top column in, lift its neighbours as lips
        rings = res["rings"]
        for ri in range(2, len(rings) - 3):
            xr = rings[ri][0].co.x
            w = math.sin(math.pi * clamp((xr + 0.034) / 0.066))
            if w <= 0:
                continue
            top = rings[ri][0]
            top.co.z -= 0.012 * w
            top.co.y += 0.002 * math.sin(ri * 2.0) * w
            top[lay] = 1.0
            for nb in (rings[ri][1], rings[ri][SEG - 1]):
                nb.co.z += 0.0035 * w
                nb[lay] = 0.5
    # root tail
    t0 = V((xs[0] * shrink - 0.006, 0, -0.002))
    tail = [t0, t0 + V((-0.012, 0.002, -0.004)), t0 + V((-0.022, 0.006, -0.010)), t0 + V((-0.030, 0.012, -0.013))]
    sweep(bm, tail, [prof_ellipse(r_, r_, 5) for r_ in (0.0055, 0.0035, 0.002, 0.0011)], up=(0, 0, 1),
          cap0="open", cap1="point", len1=0.002, mat=M["Fruit"])
    # stem stub (cut leaf stalks)
    s0 = V((xs[-1] * shrink + 0.004, 0, 0.004))
    for k, d in enumerate((V((0.8, 0.1, 0.6)), V((0.7, -0.35, 0.55)))):
        d = d.normalized()
        sweep(bm, [s0, s0 + d * 0.007, s0 + d * 0.014], prof_ellipse(0.0028 - k * 0.0006, 0.0028 - k * 0.0006, 5),
              cap0="open", cap1="flat", mat=M["Plant"])
    # a few root hairs
    for p0, d in (((-0.02, 0.026, -0.006), (0.1, 0.7, -0.7)), ((0.015, -0.027, -0.004), (0.2, -0.6, -0.75)),
                  ((0.032, 0.02, -0.01), (0.4, 0.5, -0.75))):
        p0 = V(p0) * shrink
        d = V(d).normalized()
        sweep(bm, [p0, p0 + d * 0.008, p0 + d * 0.014 + V((0.003, 0, 0))], prof_ellipse(0.0009, 0.0009, 3),
              cap0="open", cap1="point", len1=0.001, mat=M["Fruit"])
    return res


@item
def make_tuber():
    bm = new_bm()
    tuber_geo(bm)

    def paint_fn(c):
        a = ao_shade(c.ao, 0.85)
        if c.m == "Plant":
            return sc(mix(col("#7A8A45"), col("#C8C890"), 0.3 if c.n.x > 0.7 else 0.0), a)
        p = c.p
        m1 = nz(p * 40.0, 1.0, 2)
        base = mix(col("#8A3550"), col("#5E2440"), 0.45 + 0.4 * m1)
        base = mix(base, col("#A4485A"), 0.3 * clamp(nz(p * 18.0 + V((3, 1, 0)), 1.0, 1)))
        eye = nz(p * 75.0 + V((7, 2, 1)), 1.0, 1)
        if eye > 0.55:
            base = mix(base, col("#3E1E28"), min(0.8, (eye - 0.55) * 3.5))
        # a little dry soil on the underside
        base = mix(base, col("#8A6C52"), 0.35 * clamp(-c.n.z) * (0.5 + 0.5 * nz(p * 60.0, 1.0, 1)))
        return sc(base, a)
    return make_obj("tuber", bm, ["Fruit", "Plant"]), paint_fn, 0.02


@item
def make_tuber_roasted():
    bm = new_bm()
    tuber_geo(bm, shrink=0.94, split=True)

    def paint_fn(c):
        a = ao_shade(c.ao, 0.85)
        if c.m == "Plant":
            return sc(col("#2C221C"), a)
        p = c.p
        k = c.tag("k")
        if k >= 0.99:
            base = mix(col("tuber_flesh"), col("#F2C766"), 0.35 + 0.3 * nz(p * 90.0, 1.0, 1))
            return sc(base, 0.85 + 0.15 * c.ao)
        m1 = 0.5 + 0.5 * nz(p * 45.0, 1.0, 2)
        base = mix(col("#4A2A26"), col("#24150F"), m1)
        blister = nz(p * 110.0 + V((5, 1, 2)), 1.0, 1)
        if blister > 0.35:
            base = mix(base, col("#7A4A30"), min(0.7, (blister - 0.35) * 2.0))
        char = nz(p * 30.0 + V((1, 8, 3)), 1.0, 1)
        if char > 0.3:
            base = mix(base, col("charcoal"), min(0.85, (char - 0.3) * 2.2))
        if 0.4 < k < 0.6:
            base = mix(base, col("#C99A5A"), 0.45)        # toasted lips of the split
        return sc(base, a)
    return make_obj("tuber_roasted", bm, ["Fruit", "Plant"]), paint_fn, 0.02


# ----------------------------------------------------------------------------
# mushroom
# ----------------------------------------------------------------------------

def mushroom_geo(bm, s=1.0, wobble=0.0, seed=1):
    """Upright mushroom (stem along Z).  tag k: 0 cap top, 1 gills, 2 stem, 3 spot."""
    lay = tag_layer(bm, "k")
    SEG = 14
    cap = [(0.0095, 0.0490), (0.0200, 0.0500), (0.0300, 0.0510), (0.0370, 0.0525), (0.0405, 0.0565),
           (0.0395, 0.0640), (0.0330, 0.0730), (0.0200, 0.0800), (0.0080, 0.0830)]
    cen, profs = [], []
    off = V((seed * 2.3, seed, 0.5))
    for i, (r, z) in enumerate(cap):
        r *= s
        z *= s
        pr = []
        for j in range(SEG):
            a = TAU * j / SEG
            rr = r
            if i in (3, 4, 5) and wobble:
                rr *= 1.0 + wobble * nz(V((math.cos(a) * 2, math.sin(a) * 2, i * 0.4)) + off, 1.0, 1)
            pr.append((math.cos(a) * rr, math.sin(a) * rr))
        dz = (0.0025 * wobble * 40 * nz(V((i, 0.3, seed)), 1.0, 1)) if (wobble and i in (3, 4)) else 0.0
        cen.append(V((0, 0, z + dz)))
        profs.append(pr)
    frames = [(V((0, 0, 1)), V((1, 0, 0)), V((0, 1, 0)))] * len(cap)
    res = sweep(bm, cen, profs, frames=frames, cap0="flat", cap1="point", len0=0.0, len1=-0.0, mat=0,
                pole1=V((0, 0, 0.0845 * s)))
    for k, ring in enumerate(res["rings"]):
        for v in ring:
            v[lay] = 1.0 if k <= 2 else 0.0
    for v in faces_verts(res["cap0"]):
        if v[lay] != 1.0:
            v[lay] = 1.0
    for v in faces_verts(res["cap1"]):
        v[lay] = 0.0
    # stem
    st = [(0.0120, 0.000), (0.0132, 0.007), (0.0118, 0.020), (0.0102, 0.036), (0.0096, 0.051)]
    cen = [V((0.0006 * math.sin(i), 0, z * s)) for i, (r, z) in enumerate(st)]
    res2 = sweep(bm, cen, [prof_ellipse(r * s, r * s, 10) for r, z in st], frames=[(V((0, 0, 1)), V((1, 0, 0)), V((0, 1, 0)))] * len(st),
                 cap0="point", cap1="open", pole0=V((0, 0, -0.0015 * s)), mat=0)
    for v in faces_verts(res2["side"] + res2["cap0"]):
        v[lay] = 2.0
    return cap


def cap_point(cap, s, a, frac):
    """Point on the cap's upper surface: frac 0 = top, 1 = rim edge."""
    pts = [(r * s, z * s) for r, z in cap[4:]][::-1] + [(0.0, 0.0845 * s)]
    pts = [(0.0, 0.0845 * s)] + [(r * s, z * s) for r, z in reversed(cap[4:])]
    idx = frac * (len(pts) - 1)
    i0 = min(int(idx), len(pts) - 2)
    t = idx - i0
    r = lerp(pts[i0][0], pts[i0 + 1][0], t)
    z = lerp(pts[i0][1], pts[i0 + 1][1], t)
    dr = pts[i0 + 1][0] - pts[i0][0]
    dz = pts[i0 + 1][1] - pts[i0][1]
    n2 = V((dz, -dr)).normalized() if (dr or dz) else V((0, 1))
    # outward normal in (r,z): rotate tangent
    nrm = V((math.cos(a) * -n2.x, math.sin(a) * -n2.x, -n2.y))
    if nrm.z < 0:
        nrm = -nrm
    return V((math.cos(a) * r, math.sin(a) * r, z)), nrm.normalized()


def add_spots(bm, cap, s, seed, n=7, size=0.0058):
    lay = tag_layer(bm, "k")
    rng = random.Random(seed)
    for i in range(n):
        a = TAU * i / n + rng.uniform(-0.3, 0.3)
        frac = rng.uniform(0.25, 0.75) if i else 0.05
        p, nrm = cap_point(cap, s, a, frac)
        Rm = nrm.to_track_quat("Z", "Y").to_matrix()
        sz = size * rng.uniform(0.7, 1.2) * s
        f = ellipsoid(bm, p - nrm * 0.0002, (sz, sz * 0.85, 0.0014 * s), seg=6, rings=3, mat=0, rot=Rm)
        for v in faces_verts(f):
            v[lay] = 3.0


def mush_painter(roasted=False):
    def fn(c):
        a = ao_shade(c.ao, 0.85)
        k = c.tag("k")
        p = c.p
        if k == 3.0:
            base = col("mush_spot") if not roasted else col("#B89470")
            return sc(base, 0.9 + 0.1 * c.ao)
        if k == 2.0:
            base = mix(col("mush_stem"), col("#C8B48E"), 0.4 + 0.3 * nz(p * 120.0, 1.0, 1))
            base = mix(base, col("#8A6A4C"), smoothstep(0.012, 0.0, p.z) * 0.6)
            if roasted:
                base = mix(base, col("#8C6238"), 0.6)
            return sc(base, a)
        if k == 1.0:
            gill = 0.5 + 0.5 * math.sin(math.atan2(p.y, p.x) * 28.0)
            base = mix(col("#E4D2AE"), col("#B89A72"), 0.45 * gill)
            if roasted:
                base = mix(base, col("#6E4A2E"), 0.55)
            return sc(base, a)
        top = smoothstep(0.065, 0.085, p.z)
        base = mix(col("mush_cap"), col("#7A3E26"), 0.65 * top)
        base = mix(base, col("#C08260"), 0.3 * smoothstep(0.06, 0.052, p.z))
        base = sc(base, 1.0 + 0.06 * nz(p * 80.0, 1.0, 1))
        if roasted:
            base = mix(base, col("#3A2016"), 0.55)
            ch = nz(p * 70.0 + V((2, 5, 1)), 1.0, 1)
            if ch > 0.3:
                base = mix(base, col("charcoal"), min(0.8, (ch - 0.3) * 2.5))
        return sc(base, a)
    return fn


@item
def make_mushroom():
    bm = new_bm()
    cap = mushroom_geo(bm, s=1.0)
    add_spots(bm, cap, 1.0, seed=4)
    return make_obj("mushroom", bm, ["Fruit"]), mush_painter(False), 0.02


@item
def make_mushroom_roasted():
    bm = new_bm()
    cap = mushroom_geo(bm, s=0.88, wobble=0.09, seed=6)
    add_spots(bm, cap, 0.88, seed=4, n=5, size=0.005)
    # shrivel: squash a touch and shrink the stem waist
    for v in bm.verts:
        if v.co.z < 0.045 * 0.88:
            k = 1.0 - 0.12 * math.sin(math.pi * clamp(v.co.z / (0.045 * 0.88)))
            v.co.x *= k
            v.co.y *= k
    return make_obj("mushroom_roasted", bm, ["Fruit"]), mush_painter(True), 0.02


if __name__ == "__main__":
    run_items(REG, ARGS, "items_food", cols=4)
