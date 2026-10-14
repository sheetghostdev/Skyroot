"""Skyroot player body: separate rigid parts (no armature), origins at joint pivots.

    blender -b --python tools/blender/char_body.py [-- nopreview|more]

Output: assets/models/character/body.glb  (+ previews tools/blender/previews/char_body_*.png)
Faces Blender -Y.  Parts are top-level objects; Godot builds the hierarchy by name.
Tunic = "Cloth" painted neutral light grey so Godot can tint it per player.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from craft_lib import *  # noqa: E402,F401,F403
from mathutils.bvhtree import BVHTree  # noqa: E402

ARGS = cli_args()

PIVOTS = {
    "Pelvis": (0.0, 0.0, 0.95),
    "Torso": (0.0, 0.0, 1.00),
    "Head": (0.0, 0.0, 1.47),
    "UpperArm_L": (0.20, 0.0, 1.40),
    "LowerArm_L": (0.22, 0.0, 1.12),
    "Hand_L": (0.23, 0.0, 0.88),
    "UpperLeg_L": (0.10, 0.0, 0.92),
    "LowerLeg_L": (0.10, 0.0, 0.50),
    "Foot_L": (0.10, 0.0, 0.08),
}
for k in list(PIVOTS):
    if k.endswith("_L"):
        x, y, z = PIVOTS[k]
        PIVOTS[k[:-2] + "_R"] = (-x, y, z)

ORDER = ["Pelvis", "Torso", "Head",
         "UpperArm_L", "LowerArm_L", "Hand_L", "UpperArm_R", "LowerArm_R", "Hand_R",
         "UpperLeg_L", "LowerLeg_L", "Foot_L", "UpperLeg_R", "LowerLeg_R", "Foot_R"]

# fixed frames for vertical sweeps: t=+Z, n=-Y (front), b=+X
UPF = (V((0, 0, 1)), V((0, -1, 0)), V((1, 0, 0)))
# downward limb sweeps: t=-Z, n=-Y (front), b = t x n = -X
DNF = (V((0, 0, -1)), V((0, -1, 0)), V((-1, 0, 0)))


def mats_index(names):
    return {n: i for i, n in enumerate(names)}


def set_band_mats(res, seg, band_mats):
    """band_mats[k] = material index for the side faces between ring k and k+1."""
    for k, mi in enumerate(band_mats):
        for s in range(seg):
            res["side"][k * seg + s].material_index = mi


def frame_matrix(normal, up=V((0, 0, 1))):
    """3x3 rotation whose local Y = -normal (into the surface) and local Z ~ up."""
    y = -V(normal).normalized()
    z = V(up) - y * V(up).dot(y)
    z.normalize()
    x = y.cross(z).normalized()
    M = Matrix((x, y, z)).transposed()
    return M


# ----------------------------------------------------------------------------
# Torso: tunic chest, sloped shoulders, laced V-neck
# ----------------------------------------------------------------------------

def build_torso():
    bm = new_bm()
    M = mats_index(["Cloth", "Skin", "Rope"])
    SEG = 14
    #      z      half-depth half-width  y-centre  power
    R = [(0.975, 0.110, 0.146, 0.000, 2.2),
         (1.065, 0.120, 0.152, -0.002, 2.3),
         (1.200, 0.121, 0.140, -0.008, 2.4),
         (1.315, 0.120, 0.150, -0.008, 2.6),
         (1.365, 0.110, 0.174, -0.003, 2.9),
         (1.405, 0.094, 0.192, 0.002, 3.0),
         (1.437, 0.074, 0.160, 0.006, 2.5),
         (1.458, 0.064, 0.094, 0.008, 2.0),
         (1.473, 0.060, 0.073, 0.008, 2.0),
         (1.466, 0.054, 0.062, 0.008, 2.0)]
    cen = [V((0, yc, z)) for z, hd, hw, yc, pw in R]
    profs = []
    for i, (z, hd, hw, yc, pw) in enumerate(R):
        pr = prof_ellipse(hd, hw, SEG, power=pw)
        pr = [(x * (0.93 if x < 0 else 1.0), y) for x, y in pr]
        if z < 1.1:
            # soft folds gathered under the belt
            pr = [(x * (1 + 0.03 * math.sin(7 * math.atan2(y, x))), y * (1 + 0.03 * math.sin(7 * math.atan2(y, x)))) for x, y in pr]
        if i >= 7:
            # V opening: pull the front-centre vertex back
            x0, y0 = pr[0]
            pr[0] = (x0 - (0.020 if i == 7 else 0.024), y0)
        profs.append(pr)
    res = sweep(bm, cen, profs, frames=[UPF] * len(R), cap0="open", cap1="point", len1=-0.03, mat=M["Cloth"])
    # skin inside the V (front two segments of the top bands)
    for k in (6, 7, 8):
        for s in (0, SEG - 1):
            res["side"][k * SEG + s].material_index = M["Skin"]
    for s in (0, SEG - 1):
        res["cap1"][s].material_index = M["Skin"]
    # crossed lace over the V (projected onto the chest surface)
    bm.normal_update()
    bvh = BVHTree.FromBMesh(bm)
    for sx in (1, -1):
        pts = []
        for x, z in ((sx * 0.020, 1.430), (0.0, 1.443), (-sx * 0.022, 1.458)):
            hit = bvh.ray_cast(V((x, -0.5, z)), V((0, 1, 0)), 1.0)
            pts.append(hit[0] + hit[1] * 0.0035)
        rope_path_tube(bm, pts, 0.0032, seg=4, mat=M["Rope"], twist_rate=120)
    return make_obj("Torso", bm, ["Cloth", "Skin", "Rope"])


# ----------------------------------------------------------------------------
# Pelvis: lower tunic with belt, flared hem, trouser crotch underneath
# ----------------------------------------------------------------------------

def build_pelvis():
    bm = new_bm()
    M = mats_index(["Cloth", "Leather", "ClothDark"])
    SEG = 14
    #      z      hd     hw
    R = [(1.065, 0.104, 0.140),
         (1.030, 0.107, 0.142),
         (1.027, 0.124, 0.164),   # belt top
         (0.963, 0.127, 0.168),   # belt bottom
         (0.958, 0.121, 0.166),
         (0.905, 0.132, 0.190),
         (0.848, 0.142, 0.195),
         (0.792, 0.153, 0.204),   # hem
         (0.784, 0.143, 0.194),   # hem underside
         (0.806, 0.108, 0.150)]   # crotch
    bands = ["Cloth", "Leather", "Leather", "Leather", "Cloth", "Cloth", "Cloth", "Cloth", "ClothDark"]
    cen = [V((0, 0.004, z)) for z, hd, hw in R]
    profs = []
    for i, (z, hd, hw) in enumerate(R):
        pr = prof_ellipse(hd, hw, SEG, power=2.4)
        if z < 0.87:
            w = smoothstep(0.87, 0.79, z)
            pr = [(x * (1 + 0.035 * w * math.sin(5 * math.atan2(y, x) + 0.9)),
                   y * (1 + 0.035 * w * math.sin(5 * math.atan2(y, x) + 0.9))) for x, y in pr]
        profs.append(pr)
    res = sweep(bm, cen, profs, frames=[UPF] * len(R), cap0="open", cap1="point", len1=-0.03, mat=0)
    set_band_mats(res, SEG, [M[b] for b in bands])
    for f in res["cap1"]:
        f.material_index = M["ClothDark"]
    # belt knot + two short tails (front, character's left = +X)
    kx, ky, kz = 0.068, -0.127, 0.996
    ellipsoid(bm, (kx, ky - 0.005, kz), (0.019, 0.011, 0.017), seg=6, rings=4, mat=M["Leather"])
    for dx, ln in ((-0.006, 0.075), (0.011, 0.058)):
        pts = [V((kx + dx, ky - 0.009, kz - 0.010)), V((kx + dx * 1.6, ky - 0.012, kz - ln * 0.5)),
               V((kx + dx * 2.2, ky - 0.010, kz - ln))]
        sweep(bm, pts, prof_ellipse(0.0035, 0.009, 4), up=(0, -1, 0), cap0="open", cap1="point",
              len1=0.004, mat=M["Leather"])
    return make_obj("Pelvis", bm, ["Cloth", "Leather", "ClothDark"])


# ----------------------------------------------------------------------------
# Head
# ----------------------------------------------------------------------------

HC = V((0.0, 0.004, 1.618))      # head centre
HR = (0.108, 0.114, 0.120)       # x, y(depth), z radii


def head_deform(d, co):
    jaw = smoothstep(0.05, -0.85, d.z)
    co = V(co)
    co.x *= 1.0 - 0.20 * jaw
    if d.y > 0:
        co.y *= 1.0 - 0.26 * jaw
    else:
        co.y *= 1.0 - 0.05 * jaw
        co.y *= 1.0 - 0.05 * smoothstep(0.6, 0.95, -d.y)
    if d.z < -0.55:
        co.z *= 1.0 - 0.06 * smoothstep(-0.55, -1.0, d.z)
    if d.z < -0.4 and d.y < 0:
        co.y -= 0.008 * smoothstep(-0.4, -0.9, d.z) * smoothstep(0.0, -0.8, d.y)
    # fuller cheeks
    if d.y < 0 and -0.6 < d.z < 0.1:
        k = smoothstep(0.2, 0.6, abs(d.x)) * (1 - smoothstep(0.75, 0.95, abs(d.x)))
        co.x *= 1.0 + 0.03 * k
    return co


def head_point(a, phi, extra=0.0):
    """Point on the deformed head (+extra thickness); a=0 front (-Y), a=90deg +X."""
    d = V((math.sin(a) * math.cos(phi), -math.cos(a) * math.cos(phi), math.sin(phi)))
    p = V((d.x * (HR[0] + extra), d.y * (HR[1] + extra), d.z * (HR[2] + extra)))
    return HC + head_deform(d, p)


def build_head():
    bm = new_bm()
    M = mats_index(["Skin", "Hair", "Eyes"])
    lay_k = tag_layer(bm, "k")
    # neck
    sweep(bm, [V((0, 0.012, 1.428)), V((0, 0.010, 1.500)), V((0, 0.008, 1.560))],
          [prof_ellipse(0.052, 0.056, 10)] * 3, frames=[UPF] * 3, cap0="flat", cap1="open", mat=M["Skin"])
    # skull
    ellipsoid(bm, HC, HR, seg=14, rings=8, mat=M["Skin"], deform=head_deform)
    bm.normal_update()
    bvh = BVHTree.FromBMesh(bm)

    def surf(x, z):
        hit = bvh.ray_cast(V((x, -0.5, z)), V((0, 1, 0)), 1.0)
        return hit[0], hit[1]

    def mark(faces, k):
        for v in faces_verts(faces):
            v[lay_k] = k
    # eyes (slightly below the head's middle = friendlier)
    for sx in (1, -1):
        p, n = surf(sx * 0.040, 1.607)
        Rm = frame_matrix(n)
        mark(ellipsoid(bm, p + n * 0.0012, (0.0105, 0.0062, 0.0142), seg=7, rings=4, mat=M["Eyes"], rot=Rm), 3)
    # brows: thin, gently arched, level (friendly)
    for sx in (1, -1):
        pts = []
        for x, z in ((0.021, 1.6375), (0.040, 1.6425), (0.058, 1.6385)):
            p, n = surf(sx * x, z)
            pts.append(p + n * 0.0025)
        mark(sweep(bm, pts, prof_ellipse(0.0032, 0.0046, 4), up=(0, -1, 0), cap0="point", cap1="point",
                   len0=0.0035, len1=0.0035, mat=M["Hair"])["side"], 4)
    # nose: small soft button
    p, n = surf(0.0, 1.590)
    Rm = frame_matrix(n) @ Matrix.Rotation(math.radians(-14), 3, "X")
    mark(ellipsoid(bm, p + n * 0.0045, (0.0135, 0.0105, 0.0155), seg=8, rings=4, mat=M["Skin"], rot=Rm), 2)
    # mouth: a small smile
    pts = []
    for x, z in ((-0.017, 1.5555), (-0.008, 1.5515), (0.0, 1.5505), (0.008, 1.5515), (0.017, 1.5555)):
        p, n = surf(x, z)
        pts.append(p + n * 0.0008)
    res = sweep(bm, pts, prof_ellipse(0.0016, 0.0024, 4), up=(0, -1, 0), cap0="point", cap1="point",
                len0=0.002, len1=0.002, mat=M["Skin"])
    mark(res["side"] + res["cap0"] + res["cap1"], 5)
    # ears
    for sx in (1, -1):
        mark(ellipsoid(bm, (sx * 0.104, 0.010, 1.604), (0.012, 0.021, 0.028), seg=6, rings=4, mat=M["Skin"],
                       rot=Euler((math.radians(-10), 0, math.radians(sx * -14)))), 6)
    # hair shell with a chunky fringe
    HS = 24

    def hairline(a):
        aa = (a + math.pi) % TAU - math.pi        # -pi..pi, 0 = front
        x = abs(aa)
        h = lerp(1.676, 1.640, smoothstep(0.0, 1.25, x))
        h = lerp(h, 1.588, smoothstep(1.55, 2.3, x))
        h = lerp(h, 1.552, smoothstep(2.3, 3.0, x))
        if x < 1.25:
            # fringe: alternating long / short locks
            j = int(round(a / (TAU / HS)))
            h -= (0.006 + (0.026 if j % 2 == 0 else 0.0)) * (1 - smoothstep(0.8, 1.25, x))
        if 1.3 < x < 1.65:
            h -= 0.016 * (1 - abs((x - 1.47) / 0.18))
        return h

    cols = []
    for j in range(HS):
        a = TAU * j / HS
        h = hairline(a)
        phi0 = math.asin(clamp((h - HC.z) / HR[2], -0.99, 0.99))
        front = 1.0 - smoothstep(0.6, 1.6, abs((a + math.pi) % TAU - math.pi))
        sweep_a = 0.10 * front if (j % 2 == 0) else 0.0
        col_pts = [head_point(a, phi0 - 0.05, -0.010),
                   head_point(a + sweep_a, phi0, 0.006 + 0.006 * front)]
        for r, frac in enumerate((0.18, 0.45, 0.75)):
            phi = lerp(phi0, math.radians(86), frac)
            puff = 0.017 + 0.009 * frac + 0.003 * math.sin(a * 4 + r * 1.7)
            col_pts.append(head_point(a, phi, puff))
        cols.append([bm.verts.new(p) for p in col_pts])
    top = bm.verts.new(HC + V((0, 0.010, HR[2] + 0.021)))
    hair_faces = []
    rows = len(cols[0])
    for j in range(HS):
        A, B = cols[j], cols[(j + 1) % HS]
        for r in range(rows - 1):
            hair_faces.append(bm.faces.new((A[r], B[r], B[r + 1], A[r + 1])))
        hair_faces.append(bm.faces.new((A[-1], B[-1], top)))
    for f in hair_faces:
        f.material_index = M["Hair"]
        f.smooth = True
    # crown tuft
    for pts, rads in (
        ([HC + V((0.004, 0.050, 0.108)), HC + V((0.010, 0.074, 0.119)), HC + V((0.018, 0.096, 0.118))],
         (0.016, 0.011, 0.004)),
    ):
        sweep(bm, pts, [prof_ellipse(rads[0] * 0.7, rads[0], 6), prof_ellipse(rads[1] * 0.7, rads[1], 6),
                        prof_ellipse(rads[2], rads[2], 6)],
              up=(0, 0, 1), cap0="open", cap1="point", len1=0.008, mat=M["Hair"])
    return make_obj("Head", bm, ["Skin", "Hair", "Eyes"])


# ----------------------------------------------------------------------------
# Arms (built for the left side, +X; mirrored for the right)
# ----------------------------------------------------------------------------

def build_upper_arm():
    bm = new_bm()
    p0, p1 = V(PIVOTS["UpperArm_L"]), V(PIVOTS["LowerArm_L"])
    ts = [0.0, 0.25, 0.62, 1.0]
    rs = [(0.058, 0.060), (0.058, 0.057), (0.052, 0.050), (0.047, 0.046)]
    cen = [p0.lerp(p1, t) for t in ts]
    profs = [prof_ellipse(a, b, 10) for a, b in rs]
    sweep(bm, cen, profs, up=(0, -1, 0), cap0="round", cap1="round", len0=0.040, len1=0.046,
          cap_rings=1, mat=0)
    return make_obj("UpperArm_L", bm, ["Cloth"])


def build_lower_arm():
    bm = new_bm()
    M = mats_index(["Cloth", "Skin"])
    p0, p1 = V(PIVOTS["LowerArm_L"]), V(PIVOTS["Hand_L"])
    #   t      rn     rb
    R = [(0.00, 0.045, 0.045),
         (0.06, 0.057, 0.059),
         (0.15, 0.058, 0.060),
         (0.235, 0.050, 0.052),
         (0.255, 0.043, 0.046),
         (0.60, 0.041, 0.045),
         (1.00, 0.032, 0.037)]
    cen = [p0.lerp(p1, t) for t, *_ in R]
    profs = []
    for t, a, b in R:
        pr = prof_ellipse(a, b, 10)
        if 0.0 < t < 0.2:
            pr = [(x * (1 + 0.05 * math.sin(5 * math.atan2(y, x) + 1.0)), y * (1 + 0.05 * math.sin(5 * math.atan2(y, x) + 1.0))) for x, y in pr]
        profs.append(pr)
    res = sweep(bm, cen, profs, up=(0, -1, 0), cap0="round", cap1="round", len0=0.044, len1=0.030,
                cap_rings=1, mat=0)
    # bands: cap->0, 0->1, 1->2, 2->3 cloth; then skin
    set_band_mats(res, 10, [M["Cloth"]] * 4 + [M["Skin"]] * 4)
    for f in res["cap0"]:
        f.material_index = M["Cloth"]
    for f in res["cap1"]:
        f.material_index = M["Skin"]
    return make_obj("LowerArm_L", bm, ["Cloth", "Skin"])


def build_hand():
    bm = new_bm()
    lay_k = tag_layer(bm, "k")
    #   centre                       half-thick  half-width
    R = [((0.230, 0.002, 0.900), 0.018, 0.028),
         ((0.233, 0.000, 0.862), 0.024, 0.043),
         ((0.238, -0.002, 0.822), 0.025, 0.049),
         ((0.239, -0.002, 0.790), 0.023, 0.049),
         ((0.235, -0.001, 0.758), 0.020, 0.046),
         ((0.227, 0.001, 0.735), 0.016, 0.039)]
    cen = [V(c) for c, a, b in R]
    profs = [prof_ellipse(a, b, 8, power=2.5) for c, a, b in R]
    res = sweep(bm, cen, profs, up=(1, 0, 0), cap0="round", cap1="round", len0=0.014, len1=0.018,
                cap_rings=1, mat=0)
    # thumb on the front (-Y) side, angled toward the palm (-X)
    tp = [V((0.226, -0.028, 0.874)), V((0.218, -0.053, 0.847)), V((0.210, -0.064, 0.818))]
    t = sweep(bm, tp, [prof_ellipse(0.0165, 0.0180, 7), prof_ellipse(0.0155, 0.0165, 7), prof_ellipse(0.0140, 0.0145, 7)],
              up=(1, 0, 0), cap0="open", cap1="round", len1=0.013, cap_rings=1, mat=0)
    for v in faces_verts(t["side"] + t["cap1"]):
        v[lay_k] = 1.0
    return make_obj("Hand_L", bm, ["Skin"])


# ----------------------------------------------------------------------------
# Legs
# ----------------------------------------------------------------------------

def build_upper_leg():
    bm = new_bm()
    p0, p1 = V(PIVOTS["UpperLeg_L"]), V(PIVOTS["LowerLeg_L"])
    ts = [0.0, 0.3, 0.7, 1.0]
    rs = [(0.082, 0.078), (0.084, 0.079), (0.071, 0.067), (0.063, 0.060)]
    cen = [p0.lerp(p1, t) for t in ts]
    profs = [prof_ellipse(a, b, 10) for a, b in rs]
    sweep(bm, cen, profs, up=(0, -1, 0), cap0="round", cap1="round", len0=0.058, len1=0.060,
          cap_rings=1, mat=0)
    return make_obj("UpperLeg_L", bm, ["ClothDark"])


def build_lower_leg():
    bm = new_bm()
    M = mats_index(["ClothDark", "Leather", "Rope"])
    x0 = 0.10
    #   z      front  back   width
    R = [(0.500, 0.055, 0.055, 0.055),
         (0.450, 0.057, 0.059, 0.057),
         (0.396, 0.061, 0.067, 0.062),
         (0.383, 0.064, 0.073, 0.066),
         (0.300, 0.060, 0.072, 0.062),
         (0.200, 0.053, 0.059, 0.055),
         (0.100, 0.049, 0.050, 0.049)]
    cen = [V((x0, 0.002, z)) for z, *_ in R]
    profs = []
    for z, fr, bk, w in R:
        pr = prof_ellipse(1.0, w, 10)
        pr = [((x * fr) if x >= 0 else (x * bk), y) for x, y in pr]
        profs.append(pr)
    res = sweep(bm, cen, profs, frames=[DNF] * len(R), cap0="round", cap1="round", len0=0.052, len1=0.044,
                cap_rings=1, mat=0)
    # bands: cap->0, 0->1, 1->2 trousers ; 2->3 (lip) onwards leather
    set_band_mats(res, 10, [M["ClothDark"]] * 3 + [M["Leather"]] * 5)
    for f in res["cap0"]:
        f.material_index = M["ClothDark"]
    for f in res["cap1"]:
        f.material_index = M["Leather"]
    # rope binding: a ring at the top of the wraps and one diagonal turn down the shin
    ring = []
    for i in range(8):
        a = TAU * i / 8
        ring.append(V((x0 + math.sin(a) * 0.068, 0.002 - math.cos(a) * (0.066 if math.cos(a) > 0 else 0.075),
                       0.372 + 0.005 * math.sin(a * 2))))
    rope_path_tube(bm, ring, 0.0055, seg=4, mat=M["Rope"], closed=True, twist_rate=70)
    hel = []
    n = 9
    for i in range(n):
        t = i / (n - 1)
        a = -0.6 + TAU * 1.05 * t
        z = lerp(0.352, 0.150, t)
        rr = lerp(0.069, 0.054, t)
        hel.append(V((x0 + math.sin(a) * rr, 0.002 - math.cos(a) * rr * (1.0 if math.cos(a) > 0 else 1.12), z)))
    rope_path_tube(bm, hel, 0.0048, seg=4, mat=M["Rope"], cap="round", twist_rate=70)
    return make_obj("LowerLeg_L", bm, ["ClothDark", "Leather", "Rope"])


def build_foot():
    bm = new_bm()
    M = mats_index(["Leather", "Rope"])
    x0 = 0.10
    #   y       zc     top    bottom  half-width
    R = [(0.064, 0.046, 0.038, 0.046, 0.038),
         (0.040, 0.056, 0.054, 0.056, 0.047),
         (-0.004, 0.056, 0.058, 0.056, 0.051),
         (-0.052, 0.046, 0.044, 0.046, 0.055),
         (-0.098, 0.036, 0.033, 0.036, 0.055),
         (-0.130, 0.031, 0.027, 0.031, 0.048)]
    cen = [V((x0, y, zc)) for y, zc, *_ in R]
    profs = [prof_d(top, bot, hw, 10, sole_round=0.45) for y, zc, top, bot, hw in R]
    frames = [(V((0, -1, 0)), V((0, 0, 1)), V((-1, 0, 0)))] * len(R)
    sweep(bm, cen, profs, frames=frames, cap0="round", cap1="round", len0=0.016, len1=0.026,
          cap_rings=1, mat=M["Leather"])
    # ankle cuff with a turned-in lip
    C = [(0.050, 0.051, 0.054), (0.160, 0.059, 0.061), (0.170, 0.053, 0.055),
         (0.162, 0.046, 0.048)]
    cen = [V((x0, 0.006, z)) for z, *_ in C]
    profs = [prof_ellipse(fr, w, 10) for z, fr, w in C]
    sweep(bm, cen, profs, frames=[UPF] * len(C), cap0="open", cap1="open", mat=M["Leather"])
    # rope binding round the ankle
    ring = []
    for i in range(8):
        a = TAU * i / 8
        ring.append(V((x0 + math.sin(a) * 0.060, 0.006 - math.cos(a) * 0.062, 0.118 + 0.008 * math.sin(a))))
    rope_path_tube(bm, ring, 0.0056, seg=4, mat=M["Rope"], closed=True, twist_rate=70)
    return make_obj("Foot_L", bm, ["Leather", "Rope"])


# ----------------------------------------------------------------------------
# mirroring
# ----------------------------------------------------------------------------

def mirrored(obj, name):
    me = obj.data.copy()
    me.name = name
    o = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(o)
    bm = bmesh.new()
    bm.from_mesh(me)
    mirror_bm_x(bm)
    bm.to_mesh(me)
    bm.free()
    me.update()
    return o


# ----------------------------------------------------------------------------
# painting
# ----------------------------------------------------------------------------

SKIN = col("skin")
SKIN_WARM = col("#D98D78")
SKIN_LIGHT = col("#EBC2A0")
CLOTH = grey(0.78)
CLOTH_DARK = col("cloth_dark")
LEATHER = col("leather")
LEATHER_DARK = col("#563623")
ROPE = col("rope")
HAIR = col("hair")
HAIR_LIGHT = col("#6E4B36")
EYES = col("#17110F")
LIPS = col("#8E4A40")


def body_painter(name):
    def fn(c):
        m = c.m
        p = c.p
        a = ao_shade(c.ao, 0.85)
        g = 0.90 + 0.10 * clamp(p.z / 1.7)
        if m == "Cloth":
            v = 1.0 + 0.035 * nz(p * 18.0, 1.0, 2)
            base = sc(CLOTH, v)
            if name == "Pelvis":
                base = sc(base, 0.93 + 0.07 * smoothstep(0.79, 0.85, p.z))
            out = sc(base, a * g)
        elif m == "ClothDark":
            v = 1.0 + 0.06 * nz(p * 14.0, 1.0, 2)
            base = sc(CLOTH_DARK, v)
            if name.startswith("UpperLeg") and c.n.y < -0.3:
                base = mix(base, col("#6E6458"), 0.35 * smoothstep(0.62, 0.52, p.z))
            out = sc(base, a * g)
        elif m == "Leather":
            v = nz(p * 22.0, 1.0, 2)
            base = mix(LEATHER, LEATHER_DARK, 0.35 + 0.35 * v)
            if name.startswith("Foot"):
                base = mix(base, LEATHER_DARK, smoothstep(0.016, 0.004, p.z) * 0.8)
                base = sc(base, 0.9 + 0.1 * smoothstep(0.0, 0.08, p.z))
                # scuffed toe
                if p.y < -0.10 and p.z > 0.02:
                    base = mix(base, col("#9A6C4A"), 0.25)
            if name.startswith("LowerLeg"):
                base = sc(base, 0.95 + 0.08 * math.sin(p.z * 60.0 + 1.0))
            if name == "Pelvis":
                base = sc(base, 0.92)
            out = sc(base, a * g)
        elif m == "Rope":
            out = sc(rope_color(c, ROPE), a * g)
        elif m == "Skin":
            k = c.tag("k")
            base = sc(SKIN, 1.0 + 0.025 * nz(p * 30.0, 1.0, 1))
            if name == "Head":
                if k == 5:
                    return LIPS
                for cx in (0.060, -0.060):
                    d = (p - V((cx, -0.088, 1.578))).length
                    base = mix(base, SKIN_WARM, 0.5 * smoothstep(0.034, 0.0, d))
                if k == 2:
                    base = mix(base, SKIN_WARM, 0.35)
                if k == 6:
                    base = mix(base, SKIN_WARM, 0.30)
                if p.z < 1.53 and k == 0:
                    base = sc(base, 0.84 + 0.16 * smoothstep(1.46, 1.53, p.z))
            if name == "Torso":
                base = sc(base, 0.88)
            if name.startswith("Hand"):
                if k == 1:
                    base = mix(base, SKIN_WARM, 0.10)
                if abs(p.z - 0.79) < 0.02:
                    base = mix(base, SKIN_WARM, 0.25)
                if p.z < 0.75:
                    base = mix(base, SKIN_LIGHT, 0.15)
            if name.startswith("LowerArm"):
                base = mix(base, SKIN_WARM, 0.12 * smoothstep(1.0, 0.9, p.z))
            out = sc(base, a * g)
        elif m == "Hair":
            v = nz(V((p.x * 25, p.y * 25, p.z * 60)), 1.0, 2)
            base = mix(HAIR, HAIR_LIGHT, clamp(0.35 + 0.5 * v))
            base = sc(base, 0.82 + 0.28 * clamp((p.z - 1.57) / 0.18))
            out = sc(base, a)
        elif m == "Eyes":
            out = EYES
        else:
            out = (1, 0, 1, 1)
        return out
    return fn


def finish(obj):
    bvh = bvh_of([obj])
    ao = bake_ao(obj, bvh, rays=36, dist=0.08)
    paint(obj, body_painter(obj.name), ao=ao)


def main():
    reset()
    parts = {}
    parts["Torso"] = build_torso()
    parts["Pelvis"] = build_pelvis()
    parts["Head"] = build_head()
    parts["UpperArm_L"] = build_upper_arm()
    parts["LowerArm_L"] = build_lower_arm()
    parts["Hand_L"] = build_hand()
    parts["UpperLeg_L"] = build_upper_leg()
    parts["LowerLeg_L"] = build_lower_leg()
    parts["Foot_L"] = build_foot()
    for k in [k for k in list(parts) if k.endswith("_L")]:
        parts[k[:-2] + "_R"] = mirrored(parts[k], k[:-2] + "_R")
    for name, o in parts.items():
        finish(o)
        set_origin(o, PIVOTS[name])
    objs = [parts[n] for n in ORDER]
    total = 0
    for o in objs:
        total += tri_count(o)
        print(f"   {o.name:12s} tris={tri_count(o):4d} loc={tuple(round(x, 3) for x in o.location)}")
    print(f"[body] total tris {total}")
    zs = [(o.matrix_world @ v.co).z for o in objs for v in o.data.vertices]
    ys = [(o.matrix_world @ v.co).y for o in objs for v in o.data.vertices]
    print(f"[body] z range {min(zs):.3f} .. {max(zs):.3f}  y range {min(ys):.3f} .. {max(ys):.3f}")
    export("character/body.glb", objs)
    if "nopreview" not in ARGS:
        preview("char_body_front34", objs, elev=12, azim=-30, size=(600, 800), samples=24, dist_mul=3.2)
        preview("char_body_side", objs, elev=8, azim=-90, size=(600, 800), samples=24, dist_mul=3.2)
        if "more" in ARGS:
            preview("char_body_front", objs, elev=4, azim=0, size=(600, 800), samples=20, dist_mul=3.2)
            preview("char_body_back", objs, elev=14, azim=160, size=(600, 800), samples=20, dist_mul=3.2)
            preview("char_body_head", [parts["Head"]], elev=6, azim=-25, size=(600, 600), samples=24, dist_mul=3.0)
            preview("char_body_hands", [parts["Hand_L"]], elev=10, azim=-35,
                    size=(600, 600), samples=20, dist_mul=3.5)


main()
