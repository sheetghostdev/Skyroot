"""Skyroot wooden hand items: stick, pole, twig, branch, limb, handle, spindle, hearth_board, torch.

    blender -b --python tools/blender/items_wood.py [-- <item names...>] [nopreview]

Each item -> assets/models/items/<name>.glb : one mesh object, origin at its geometric
centre, real-world scale, long axis along Blender X.  Preview: previews/items_wood.png
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
    """Rotation matrix taking local +Z to direction d."""
    return V(d).normalized().to_track_quat("Z", "Y").to_matrix()


# ----------------------------------------------------------------------------

@item
def make_stick():
    bm = new_bm()
    pts = rod_path((-0.3, 0, 0), (0.3, 0, 0), n=9, wobble=0.004, bend=0.014, bend_dir=(0, 1, 0.3), seed=3)
    wood_rod(bm, pts, 0.0135, 0.0115, seg=8, seed=3, noise_amp=0.06, cap_inner=1)
    base = pts[6]
    d = V((0.5, 0.55, 0.35)).normalized()
    wood_rod(bm, [base, base + d * 0.014, base + d * 0.026], 0.0055, 0.0046, seg=6, seed=4, end0="open",
             end1="cut", noise_amp=0.0, cap_inner=0)
    return make_obj("stick", bm, ["Bark", "WoodEnd"]), wood_painter(seed=3.0), 0.03


@item
def make_pole():
    bm = new_bm()
    pts = rod_path((-1.0, 0, 0), (1.0, 0, 0), n=12, wobble=0.008, bend=0.012, bend_dir=(0.2, 1, 0), seed=11)
    wood_rod(bm, pts, 0.043, 0.037, seg=10, seed=11, noise_amp=0.05, cap_inner=2)
    for t, d in ((0.3, (0.3, 0.7, 0.6)), (0.68, (-0.2, -0.6, 0.75))):
        base = pts[0].lerp(pts[-1], t)
        dv = V(d).normalized()
        wood_rod(bm, [base, base + dv * 0.035, base + dv * 0.058], 0.0125, 0.0105, seg=6, seed=12,
                 end0="open", end1="cut", noise_amp=0.0, cap_inner=0)
    return make_obj("pole", bm, ["Bark", "WoodEnd"]), wood_painter(seed=11.0), 0.08


@item
def make_twig():
    bm = new_bm()
    pts = rod_path((-0.175, 0, 0), (0.175, 0, 0), n=8, wobble=0.004, bend=0.012, bend_dir=(0, 1, 0), seed=21)
    wood_rod(bm, pts, 0.0062, 0.0028, seg=6, seed=21, end0="cut", end1="point", noise_amp=0.05, cap_inner=0)
    for idx, d, L in ((3, (0.75, 0.62, 0.15), 0.075), (5, (0.8, -0.55, 0.2), 0.055)):
        b = pts[idx]
        dv = V(d).normalized()
        sp = [b, b + dv * L * 0.5 + V((0, 0, 0.004)), b + dv * L]
        wood_rod(bm, sp, 0.0030, 0.0016, seg=5, seed=22 + idx, end0="open", end1="point", noise_amp=0.0,
                 cap_inner=0)
        ellipsoid(bm, sp[-1] + dv * 0.0015, (0.0026, 0.0026, 0.0042), seg=5, rings=3, mat=0, rot=dir_rot(dv))
    dv = (pts[-1] - pts[-2]).normalized()
    ellipsoid(bm, pts[-1] + dv * 0.002, (0.0024, 0.0024, 0.0042), seg=5, rings=3, mat=0, rot=dir_rot(dv))
    return make_obj("twig", bm, ["Bark", "WoodEnd"]), wood_painter(seed=21.0), 0.015


def leafy(bm, tips, radii, mat, seed, leaves=8):
    for i, (tp, r) in enumerate(zip(tips, radii)):
        foliage_clump(bm, tp, r, seed=seed + i, mat=mat, leaves=leaves, leaf_rings=2)


@item
def make_branch():
    bm = new_bm()
    pts = rod_path((-0.56, 0, -0.04), (0.40, 0.0, 0.05), n=9, wobble=0.012, bend=0.03, bend_dir=(0, 0.4, 1), seed=31)
    wood_rod(bm, pts, 0.019, 0.007, seg=8, seed=31, end0="cut", end1="point", cap_inner=1, noise_amp=0.05)
    tips = [pts[-1]]
    for idx, d, L in ((4, (0.55, 0.8, 0.25), 0.34), (6, (0.65, -0.72, 0.2), 0.28)):
        b = pts[idx]
        dv = V(d).normalized()
        sp = rod_path(b, b + dv * L, n=4, wobble=0.006, seed=idx)
        wood_rod(bm, sp, 0.009, 0.004, seg=6, seed=32 + idx, end0="open", end1="point", cap_inner=0, noise_amp=0.0)
        tips.append(sp[-1])
    leafy(bm, tips, (0.13, 0.11, 0.105), 2, 40, leaves=9)
    return make_obj("branch", bm, ["Bark", "WoodEnd", "Leaves"]), wood_painter(seed=31.0), 0.08


@item
def make_limb():
    bm = new_bm()
    pts = rod_path((-1.1, 0, -0.10), (0.92, 0.05, 0.10), n=10, wobble=0.02, bend=0.05, bend_dir=(0, 0.3, 1), seed=71)
    wood_rod(bm, pts, 0.048, 0.013, seg=6, seed=71, end0="cut", end1="point", cap_inner=1, noise_amp=0.05)
    tips = [pts[-1]]
    for idx, d, L in ((3, (0.5, 0.85, 0.3), 0.58), (4, (0.55, -0.8, 0.35), 0.66), (6, (0.6, 0.75, 0.4), 0.5),
                      (7, (0.7, -0.65, 0.3), 0.42)):
        b = pts[idx]
        dv = V(d).normalized()
        sp = rod_path(b, b + dv * L, n=4, wobble=0.015, bend=0.03, bend_dir=(0, 0, 1), seed=idx + 70)
        wood_rod(bm, sp, 0.017, 0.006, seg=5, seed=72 + idx, end0="open", end1="point", cap_inner=0, noise_amp=0.0)
        tips.append(sp[-1])
    for i, (tp, r) in enumerate(zip(tips, (0.24, 0.21, 0.22, 0.20, 0.19))):
        foliage_clump(bm, tp, r, seed=80 + i, mat=2, leaves=6, leaf_rings=2, leaf_len=r * 1.1)
    return make_obj("limb", bm, ["Bark", "WoodEnd", "Leaves"]), wood_painter(seed=71.0), 0.15


@item
def make_handle():
    """Shaped (carved) handle: faceted wood, thicker grip end, a little bark left."""
    bm = new_bm()
    xs = [-0.225, -0.205, -0.15, -0.07, 0.02, 0.11, 0.19, 0.225]
    rs = [0.0158, 0.0175, 0.0172, 0.0160, 0.0150, 0.0142, 0.0136, 0.0126]
    pts = [V((x, 0.0006 * math.sin(x * 9), 0)) for x in xs]
    profs = []
    for i, r in enumerate(rs):
        pr = prof_ellipse(r, r * 1.04, 8, phase=0.1 * math.sin(i))
        profs.append(pr)
    res = sweep(bm, pts, profs, up=(0, 0, 1), cap0="flat", cap1="flat", mat=0, cap_mat0=1, cap_mat1=1,
                cap_inner=1, len0=0.0, len1=0.0)
    for f in res["side"]:
        f.smooth = False
    for f in res["cap0"] + res["cap1"]:
        f.smooth = False
    # bark left in a few facets near the thick end
    seg = 8
    for k, s_ in ((0, 1), (0, 2), (1, 2), (1, 5), (2, 5), (2, 6), (3, 1), (4, 6), (0, 6)):
        res["side"][k * seg + s_].material_index = 2
    tag(bm, faces_verts(res["side"] + res["cap0"] + res["cap1"]), "len", 0.45)
    for capf in (res["cap0"], res["cap1"]):
        vs = faces_verts(capf)
        cc = V((0, 0, 0))
        for v in vs:
            cc += v.co
        cc /= len(vs)
        rim = max((v.co - cc).length for v in vs)
        tag(bm, vs, "rr", lambda v, cc=cc, rim=rim: (v.co - cc).length / rim)

    def extra(c):
        if c.m == "Wood":
            u = c.tag("u") * 0.45
            ang = c.tag("a") * TAU
            g = nz(V((u * 6.0, math.cos(ang) * 2.0, math.sin(ang) * 2.0)), 1.0, 2)
            base = mix(col("wood"), col("wood_dark"), 0.35 + 0.3 * g)
            base = mix(base, col("wood_end"), 0.25 * clamp(c.n.z))
            # darker, oiled grip end
            base = sc(base, 0.86 + 0.14 * smoothstep(-0.2, -0.05, c.p.x))
            return sc(base, ao_shade(c.ao, 0.8))
        return None
    return make_obj("handle", bm, ["Wood", "WoodEnd", "Bark"]), wood_painter(seed=5.0, extra=extra), 0.03


@item
def make_spindle():
    bm = new_bm()
    xs = [-0.25, -0.235, -0.17, -0.06, 0.06, 0.17, 0.235, 0.25]
    rs = [0.0030, 0.0042, 0.0054, 0.0060, 0.0060, 0.0055, 0.0045, 0.0034]
    pts = [V((x, 0, 0)) for x in xs]
    res = sweep(bm, pts, [prof_ellipse(r, r, 7) for r in rs], up=(0, 0, 1), cap0="round", cap1="round",
                len0=0.004, len1=0.003, cap_rings=1, mat=0)
    tag(bm, faces_verts(res["side"] + res["cap0"] + res["cap1"]), "len", 0.5)

    def extra(c):
        u = c.tag("u") * 0.5
        ang = c.tag("a") * TAU
        g = nz(V((u * 9.0, math.cos(ang) * 1.5, math.sin(ang) * 1.5)), 1.0, 2)
        base = mix(col("wood_end"), col("wood"), 0.45 + 0.35 * g)
        # hands have polished the middle
        base = sc(base, 1.0 + 0.06 * (1.0 - abs(c.p.x) / 0.25))
        # scorched tip from drilling
        base = mix(base, col("#3A2A20"), smoothstep(0.215, 0.25, c.p.x) * 0.85)
        return sc(base, ao_shade(c.ao, 0.7))
    return make_obj("spindle", bm, ["Wood"]), wood_painter(seed=6.0, extra=extra), 0.02


@item
def make_hearth_board():
    bm = new_bm()
    T = 0.02
    sx, sy = 0.055, 0.019      # burn socket (near the +Y edge)
    xs = [-0.15, -0.115, -0.08, -0.045, -0.012, 0.018, 0.032, 0.043, 0.049, 0.055, 0.061, 0.067, 0.078,
          0.094, 0.12, 0.15]
    ys = [-0.035, -0.022, -0.010, 0.000, 0.008, 0.0135, 0.019, 0.0245, 0.029, 0.035]

    def notch_w(y):
        return 0.0045 + 0.0035 * clamp((y - sy) / (0.035 - sy))

    def ztop(x, y):
        z = T / 2 + 0.0010 * nz(V((x * 25.0, y * 25.0, 1.0)), 1.0, 2) + 0.0005 * math.sin(y * 420.0)
        d = math.hypot(x - sx, y - sy)
        if d < 0.0115:
            z -= 0.0080 * math.sqrt(max(0.0, 1.0 - (d / 0.0115) ** 2))
        if y > sy - 0.001:
            hw = notch_w(y)
            if abs(x - sx) < hw:
                k = clamp((y - sy) / (0.035 - sy))
                depth = lerp(0.0068, 0.0165, k) * (1.0 - (abs(x - sx) / hw) ** 1.5)
                z = min(z, T / 2 - depth)
        return z

    def yedge(x, y):
        # irregular split edges
        if abs(y) > 0.034:
            return y + 0.0025 * nz(V((x * 14.0, y * 3.0, 4.0)), 1.0, 1)
        return y
    top = [[bm.verts.new((x, yedge(x, y), ztop(x, y))) for x in xs] for y in ys]
    bot = [[bm.verts.new((x, yedge(x, y), -T / 2 + 0.0008 * nz(V((x * 20.0, y * 20.0, 7.0)), 1.0, 1))) for x in xs] for y in ys]
    faces_top, faces_bot, faces_side, faces_end = [], [], [], []
    nx, ny = len(xs), len(ys)
    for j in range(ny - 1):
        for i in range(nx - 1):
            faces_top.append(bm.faces.new((top[j][i], top[j][i + 1], top[j + 1][i + 1], top[j + 1][i])))
            faces_bot.append(bm.faces.new((bot[j][i], bot[j + 1][i], bot[j + 1][i + 1], bot[j][i + 1])))
    # boundary loop CCW from above: bottom row (y min) left->right, right column up, top row right->left, left col down
    loop = [(0, i) for i in range(nx)] + [(j, nx - 1) for j in range(1, ny)] + \
           [(ny - 1, i) for i in range(nx - 2, -1, -1)] + [(j, 0) for j in range(ny - 2, 0, -1)]
    for k in range(len(loop)):
        a, b = loop[k], loop[(k + 1) % len(loop)]
        f = bm.faces.new((bot[a[0]][a[1]], bot[b[0]][b[1]], top[b[0]][b[1]], top[a[0]][a[1]]))
        if a[1] == b[1] and a[1] in (0, nx - 1):
            faces_end.append(f)
        else:
            faces_side.append(f)
    for f in faces_top + faces_bot + faces_side:
        f.material_index = 0
        f.smooth = False
    for f in faces_end:
        f.material_index = 1
        f.smooth = False
    for f in faces_top + faces_side:
        c = f.calc_center_median()
        d = math.hypot(c.x - sx, c.y - sy)
        if d < 0.0125 or (c.y > sy and abs(c.x - sx) < notch_w(c.y) * 1.1 and c.z < T / 2 - 0.0015):
            f.material_index = 2
    lay_w = tag_layer(bm, "w")
    for v in bm.verts:
        v[lay_w] = v.co.y

    def extra(c):
        a = ao_shade(c.ao, 0.8)
        d = math.hypot(c.p.x - sx, c.p.y - sy)
        if c.m == "Wood":
            g = nz(V((c.p.x * 4.0, c.p.y * 140.0, c.p.z * 40.0)), 1.0, 2)
            base = mix(col("wood"), col("wood_dark"), 0.3 + 0.35 * g)
            if c.n.z < -0.5:
                base = sc(base, 0.85)
            # soot halo around the socket, plus a used older socket mark
            base = mix(base, col("#3B2C24"), 0.85 * smoothstep(0.034, 0.010, d))
            d2 = math.hypot(c.p.x + 0.045, c.p.y - sy)
            base = mix(base, col("#5A4030"), 0.6 * smoothstep(0.016, 0.004, d2))
            # grain lines along the board
            base = sc(base, 0.93 + 0.07 * math.sin(c.p.y * 520.0 + 3.0 * nz(c.p * 30.0, 1.0, 1)))
            return sc(base, a)
        if c.m == "WoodEnd":
            return sc(mix(col("wood_end"), col("wood_ring"), 0.5 + 0.5 * math.sin(c.p.z * 900.0 + c.p.y * 300.0)), a)
        if c.m == "Charcoal":
            base = mix(col("charcoal"), col("#5A3A2A"), 0.3 * smoothstep(0.002, 0.012, d))
            return sc(base, a)
        return None
    return make_obj("hearth_board", bm, ["Wood", "WoodEnd", "Charcoal"]), wood_painter(seed=9.0, extra=extra), 0.02


@item
def make_torch():
    bm = new_bm()
    M = {"Bark": 0, "WoodEnd": 1, "Straw": 2, "Rope": 3, "Charcoal": 4}
    pts = rod_path((-0.275, 0, 0), (0.22, 0, 0), n=7, wobble=0.003, bend=0.006, seed=61)
    wood_rod(bm, pts, 0.0145, 0.0132, seg=8, seed=61, end0="cut", end1="open", cap_inner=1)
    # straw head
    RX = [(0.090, 0.0150), (0.110, 0.0240), (0.145, 0.0330), (0.190, 0.0370), (0.230, 0.0350), (0.252, 0.0305),
          (0.268, 0.0240), (0.280, 0.0150)]
    SEG = 16
    cen, profs = [], []
    for i, (x, r) in enumerate(RX):
        cen.append(V((x, 0, 0)))
        pr = []
        for s in range(SEG):
            a = TAU * s / SEG + 0.08 * i
            rr = r * (1.0 if s % 2 == 0 else 0.84) * (1.0 + 0.07 * nz(V((x * 30.0, math.cos(a), math.sin(a))), 1.0, 1))
            if i >= 5:
                rr *= 1.0 + 0.18 * nz(V((s * 0.9, i * 1.3, 2.0)), 1.0, 1)
            pr.append((math.cos(a) * rr, math.sin(a) * rr))
        profs.append(pr)
    frames = [(V((1, 0, 0)), V((0, 0, 1)), V((0, -1, 0)))] * len(RX)
    res = sweep(bm, cen, profs, frames=frames, cap0="point", cap1="point", len0=-0.012, len1=0.004,
                mat=M["Straw"])
    for k in range(len(RX) - 1):
        for s in range(SEG):
            if RX[k][0] >= 0.229:
                res["side"][k * SEG + s].material_index = M["Charcoal"]
    for f in res["cap1"]:
        f.material_index = M["Charcoal"]
    lay = tag_layer(bm, "k")
    for v in faces_verts(res["side"] + res["cap0"] + res["cap1"]):
        v[lay] = 1.0
    # rope bindings
    for x, r in ((0.122, 0.0285), (0.205, 0.0372)):
        ring = [V((x + 0.002 * math.sin(a * 2), math.sin(a) * r, math.cos(a) * r)) for a in [TAU * i / 10 for i in range(10)]]
        rope_path_tube(bm, ring, 0.0042, seg=4, mat=M["Rope"], closed=True, twist_rate=90)

    def extra(c):
        if c.m == "Straw":
            ang = c.tag("a") * TAU
            st = nz(V((math.cos(ang) * 3.0, math.sin(ang) * 3.0, c.p.x * 8.0)), 1.0, 1)
            colh = hash01(round(c.tag("a") * 160.0) + 3.0)
            base = mix(col("straw"), col("#A88A4A"), clamp(0.25 + 0.35 * st + 0.45 * (colh - 0.5)))
            # scorched toward the burnt end
            base = mix(base, col("#4A3626"), smoothstep(0.17, 0.235, c.p.x) * 0.85)
            return sc(base, ao_shade(c.ao, 0.8))
        if c.m == "Charcoal":
            t = 0.5 + 0.5 * nz(c.p * 90.0, 1.0, 1)
            base = mix(col("charcoal"), col("#5E4636"), 0.35 * t)
            if t > 0.8:
                base = mix(base, col("#8A8580"), 0.5)        # a little white ash
            return sc(base, ao_shade(c.ao, 0.6))
        return None
    return make_obj("torch", bm, ["Bark", "WoodEnd", "Straw", "Rope", "Charcoal"]), wood_painter(seed=61.0, extra=extra), 0.03


if __name__ == "__main__":
    run_items(REG, ARGS, "items_wood", cols=3)
