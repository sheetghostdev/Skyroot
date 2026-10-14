"""Skyroot building pieces: rustic lashed poles, boards, wattle-and-daub, thatch.

    blender -b --python tools/blender/build_pieces.py [-- <piece names...>] [nopreview]

Each piece -> assets/models/build/<name>.glb made of top-level mesh objects
"Part_00", "Part_01", ... in the exact install order (Godot reveals them one by one as
materials are added).  Every part keeps its own origin at its bounding-box centre; the
node translations place it in the piece frame (piece origin as documented per piece).
Ambient occlusion is baked progressively: a part only receives occlusion from itself
and the parts installed before it, so half-built pieces never show phantom shadows.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from craft_lib import *  # noqa: E402,F401,F403

ARGS = cli_args()
PIECES = {}

POLE_R = 0.045
STICK_R = 0.0135
ROPE_R = 0.0058


def piece(fn):
    PIECES[fn.__name__[6:]] = fn
    return fn


# ----------------------------------------------------------------------------
# element builders (each returns faces; materials are per-part lists)
# ----------------------------------------------------------------------------

def pole(bm, p0, p1, r=POLE_R, seed=0, seg=8, n=None, ends=("cut", "cut"), wobble=0.006, bend=0.008,
         taper=0.9, bend_dir=None, bark=0, end=1):
    L = (V(p1) - V(p0)).length
    n = n or max(4, int(L / 0.22) + 2)
    pts = rod_path(p0, p1, n=n, wobble=wobble, bend=bend, bend_dir=bend_dir, seed=seed)
    return wood_rod(bm, pts, r, r * taper, seg=seg, seed=seed, end0=ends[0], end1=ends[1], cap_inner=1,
                    noise_amp=0.05, bark_mat=bark, end_mat=end)


def loop_pts(center, u, v, hu, hv, n=8, power=2.6, phase=0.0, wob=None):
    center, u, v = V(center), V(u).normalized(), V(v).normalized()
    pts = []
    for i in range(n):
        a = phase + TAU * i / n
        c, s = math.cos(a), math.sin(a)
        x = math.copysign(abs(c) ** (2 / power), c) * hu
        y = math.copysign(abs(s) ** (2 / power), s) * hv
        q = center + u * x + v * y
        if wob:
            q += wob(i, a)
        pts.append(q)
    return pts


def rope_loop(bm, center, u, v, hu, hv, rr=ROPE_R, n=8, power=2.6, phase=0.0, mat=0, wob=None):
    return rope_path_tube(bm, loop_pts(center, u, v, hu, hv, n=n, power=power, phase=phase, wob=wob), rr,
                          seg=4, mat=mat, closed=True, twist_rate=80.0)


def rope_coil(bm, center, axis, radius, turns, pitch, rr=ROPE_R, n_per_turn=8, mat=0, phase=0.0, tail=None):
    pts = helix_points(center, axis, radius, turns, pitch, n_per_turn=n_per_turn, phase=phase,
                       start_offset=-pitch * turns / 2)
    if tail:
        pts.append(pts[-1] + V(tail))
    return rope_path_tube(bm, pts, rr, seg=4, mat=mat, closed=False, twist_rate=80.0)


# ----------------------------------------------------------------------------
# painting
# ----------------------------------------------------------------------------

def daub_color(c, seed=0.0):
    p = c.p
    lump = nz(p * 7.0 + V((seed, 0, 0)), 1.0, 2)
    fine = nz(p * 23.0 + V((0, seed, 0)), 1.0, 1)
    base = mix(col("#7A5A43"), col("#A3815F"), clamp(0.5 + 0.55 * lump))
    base = mix(base, col("#5C4232"), 0.3 * clamp(-fine))
    base = mix(base, col("#B49272"), 0.25 * clamp(fine) * clamp(c.n.z + 0.3))
    # drier, paler upper lip of each band
    if c.n.z > 0.5:
        base = mix(base, col("#B89878"), 0.3)
    return base


def straw_color(c, seed=0.0):
    p = c.p
    k = c.tag("k")
    butt = c.tag("h")
    base = mix(col("#DCC27C"), col("#A88444"), 0.1 + 0.9 * (k % 1.0))
    if k >= 1.0:
        base = sc(base, 0.82)                              # alternate bundles a shade darker
    base = mix(base, col("#F0E2A8"), 0.4 * clamp(nz(p * 16.0, 1.0, 1)) * clamp(c.n.z))
    base = mix(base, col("#7A6238"), 0.7 * butt)          # cut butt ends, weathered
    base = mix(base, col("#5E4E32"), 0.4 * clamp(-c.n.z))
    return base


def piece_painter(seed, ground=True):
    def extra(c):
        a = ao_shade(c.ao, 0.85)
        g = 1.0
        if ground:
            g = 0.82 + 0.18 * smoothstep(0.0, 0.35, c.p.z)
        if c.m == "Daub":
            return sc(daub_color(c, seed), a * g)
        if c.m == "Straw":
            return sc(straw_color(c, seed), a)
        if c.m in ("Bark", "WoodEnd", "Wood") and ground and c.p.z < 0.35:
            return None if g > 0.999 else _ground_dirt(c, seed, a, g)
        return None
    return wood_painter(seed=seed, ao_s=0.85, extra=extra)


def _ground_dirt(c, seed, a, g):
    if c.m == "WoodEnd":
        base = wood_end_color(c, c.tag("rr"), seed)
    elif c.m == "Bark":
        base = bark_color(c, seed)
    else:
        base = plank_color(c, seed)
    base = mix(base, col("soil"), 0.35 * (1.0 - smoothstep(0.0, 0.35, c.p.z)))
    return sc(base, a * g)


def finish_piece(name, parts, ground_z=None, seed=1.0, ao_dist=0.25, ground=True):
    painter = piece_painter(seed, ground=ground)
    for i, o in enumerate(parts):
        bvh = bvh_of(parts[:i + 1], ground_z=ground_z)
        ao = bake_ao(o, bvh, rays=36, dist=ao_dist)
        paint(o, painter, ao=ao)
    for o in parts:
        origin_to_bbox_center(o)
    total = sum(tri_count(o) for o in parts)
    print(f"[build] {name}: {len(parts)} parts, {total} tris" + ("  <-- OVER BUDGET" if total > 2500 else ""))
    for o in parts:
        print(f"    {o.name}: {tri_count(o)} tris  mats={[m.name for m in o.data.materials]}")
    return total


def new_part(i, bm, mats):
    return make_obj(f"Part_{i:02d}", bm, mats)


# ----------------------------------------------------------------------------
# 1. platform
# ----------------------------------------------------------------------------

BOARD_X = [-0.83, -0.5, -0.17, 0.17, 0.5, 0.83]


@piece
def build_platform():
    parts = []
    beam_z = -0.085
    for i, y in enumerate((-0.75, 0.75)):
        bm = new_bm()
        pole(bm, (-1.0, y, beam_z), (1.0, y, beam_z), r=POLE_R, seed=10 + i, seg=8, n=8, wobble=0.004, bend=0.004,
             bend_dir=(0, 1, 0))
        parts.append(new_part(i, bm, ["Bark", "WoodEnd"]))
    widths = [0.285, 0.30, 0.29, 0.295, 0.305, 0.285]
    for k, x in enumerate(BOARD_X):
        bm = new_bm()
        T = 0.04
        plank(bm, (x, -0.995, -T / 2), (x, 0.995, -T / 2), widths[k], T, up=(0, 0, 1), seed=20 + k, mat=0,
              end_mat=1, rings=6, wobble=0.005, width_var=0.05, corner=0.3)
        parts.append(new_part(2 + k, bm, ["Wood", "WoodEnd"]))
    # lashings: two diagonal turns per crossing - an X over the board top, passing down
    # outside the board edges and diagonally under the beam
    for j, y in enumerate((-0.75, 0.75)):
        bm = new_bm()
        for k, x in enumerate(BOARD_X):
            hw = widths[k] / 2 + ROPE_R * 0.9
            c = POLE_R + ROPE_R * 1.1
            top = ROPE_R * 0.85
            bot = beam_z - POLE_R - ROPE_R * 0.9
            for sgn in (1, -1):
                pts = [V((x - sgn * (hw - 0.03), y - c, top)),
                       V((x + sgn * (hw - 0.03), y + c, top)),
                       V((x + sgn * hw, y + c, -0.025)),
                       V((x + sgn * hw * 0.8, y + c * 0.85, beam_z - 0.025)),
                       V((x, y, bot)),
                       V((x - sgn * hw * 0.8, y - c * 0.85, beam_z - 0.025)),
                       V((x - sgn * hw, y - c, -0.025))]
                rope_path_tube(bm, pts, ROPE_R, seg=4, mat=0, closed=True, twist_rate=80.0)
        parts.append(new_part(8 + j, bm, ["Rope"]))
    finish_piece("platform", parts, ground_z=None, seed=3.0, ground=False)
    return parts


# ----------------------------------------------------------------------------
# 2. post
# ----------------------------------------------------------------------------

@piece
def build_post():
    parts = []
    bm = new_bm()
    pole(bm, (0, 0, 0.0), (0.0, 0.0, 2.0), r=0.052, seed=31, seg=9, n=11, wobble=0.008, bend=0.012,
         ends=("cut", "round"), taper=0.92)
    # fork: two short prongs spreading in X (a beam resting along Y sits in the crotch)
    top = V((0.0, 0.0, 2.02))
    for sx, sd in ((-1, 32), (1, 33)):
        d = V((sx * 0.42, 0.04 * sx, 1.0)).normalized()
        pts = [top - V((0, 0, 0.03)), top + d * 0.07, top + d * 0.16 + V((sx * 0.008, 0, 0)), top + d * 0.205]
        wood_rod(bm, pts, 0.036, 0.029, seg=7, seed=sd, end0="open", end1="cut", cap_inner=1, noise_amp=0.04)
    parts.append(new_part(0, bm, ["Bark", "WoodEnd"]))
    bm = new_bm()
    rope_coil(bm, (0, 0, 1.935), (0, 0, 1), 0.052 + ROPE_R * 0.9, 3.2, 0.0125, n_per_turn=9,
              tail=(0.02, -0.035, -0.06))
    parts.append(new_part(1, bm, ["Rope"]))
    finish_piece("post", parts, ground_z=0.0, seed=5.0)
    return parts


# ----------------------------------------------------------------------------
# 3. railing
# ----------------------------------------------------------------------------

UPR_R = 0.026
RAIL_Z = 0.95


def forked_upright(bm, x, seed):
    """Thick stick upright with a small fork at the top that cradles the rail (along X)."""
    crotch = 0.842
    pts = rod_path((x, 0, 0.0), (x, 0, crotch), n=6, wobble=0.004, bend=0.006, seed=seed)
    wood_rod(bm, pts, UPR_R, UPR_R * 0.92, seg=7, seed=seed, end0="cut", end1="round", cap_inner=1, noise_amp=0.05)
    top = V((x, 0, crotch))
    for sy in (-1, 1):
        d = V((0.0, sy * 0.72, 1.0)).normalized()
        sp = [top - V((0, 0, 0.02)), top + d * 0.06, top + d * 0.165]
        wood_rod(bm, sp, UPR_R * 0.82, UPR_R * 0.72, seg=6, seed=seed + sy, end0="open", end1="cut", cap_inner=0,
                 noise_amp=0.03)


@piece
def build_railing():
    parts = []
    for i, x in enumerate((-0.9, 0.9)):
        bm = new_bm()
        forked_upright(bm, x, 40 + i)
        parts.append(new_part(i, bm, ["Bark", "WoodEnd"]))
    bm = new_bm()
    pole(bm, (-1.0, 0, RAIL_Z), (1.0, 0, RAIL_Z), r=0.042, seed=45, seg=8, n=9, wobble=0.004, bend=0.01,
         bend_dir=(0, 0, 1))
    parts.append(new_part(2, bm, ["Bark", "WoodEnd"]))
    bm = new_bm()
    for x in (-0.9, 0.9):
        # two turns round the rail and the fork prongs, plus a frapping turn under the rail
        for t, dx in enumerate((-0.03, 0.03)):
            rope_loop(bm, (x + dx, 0, 0.909), (0, 1, 0), (0, 0, 1), 0.092, 0.090, n=8, power=2.5,
                      phase=0.2 * t)
        rope_loop(bm, (x, 0, 0.815), (1, 0, 0), (0, 1, 0), UPR_R + ROPE_R, UPR_R + ROPE_R, n=7, power=2.0)
    parts.append(new_part(3, bm, ["Rope"]))
    finish_piece("railing", parts, ground_z=0.0, seed=7.0)
    return parts


# ----------------------------------------------------------------------------
# 4. ladder
# ----------------------------------------------------------------------------

RUNG_Z = [0.35, 0.8, 1.25, 1.7, 2.15]


def ladder_lash(bm, x, z, rail_r, rung_r, rung_y, sx):
    """X-pattern lashing (two diagonal turns) + one frapping turn at a rail/rung crossing."""
    # loop plane: diagonal in XZ, depth along Y enclosing rail (y=0) and rung (y=rung_y)
    back = rail_r + ROPE_R * 0.9
    front = rung_y - rung_r - ROPE_R * 0.9
    cy = (back + front) / 2
    hv = (back - front) / 2
    hu = (rail_r + ROPE_R * 1.4) * 1.414
    for d in ((1, 0, 1), (-1, 0, 1)):
        rope_loop(bm, (x, cy, z), d, (0, 1, 0), hu, hv, n=8, power=2.6)


@piece
def build_ladder():
    parts = []
    rail_r = 0.038
    for i, x in enumerate((-0.22, 0.22)):
        bm = new_bm()
        pole(bm, (x, 0, 0.0), (x + 0.004 * (1 if i else -1), 0, 2.5), r=rail_r, seed=50 + i, seg=7, n=11,
             wobble=0.006, bend=0.01, bend_dir=(1, 0, 0))
        parts.append(new_part(i, bm, ["Bark", "WoodEnd"]))
    rung_r = 0.0165
    rung_y = -(rail_r + rung_r) * 0.92
    for k, z in enumerate(RUNG_Z):
        bm = new_bm()
        pts = rod_path((-0.29, rung_y, z), (0.29, rung_y, z + 0.004 * math.sin(k)), n=6, wobble=0.003,
                       bend=0.006, bend_dir=(0, 0, -1), seed=55 + k)
        wood_rod(bm, pts, rung_r, rung_r * 0.9, seg=6, seed=55 + k, cap_inner=0, noise_amp=0.05)
        parts.append(new_part(2 + k, bm, ["Bark", "WoodEnd"]))
    for j, zs in enumerate((RUNG_Z[:3], RUNG_Z[3:])):
        bm = new_bm()
        for z in zs:
            for x in (-0.22, 0.22):
                ladder_lash(bm, x, z, rail_r, rung_r, rung_y, 1 if x > 0 else -1)
        parts.append(new_part(7 + j, bm, ["Rope"]))
    finish_piece("ladder", parts, ground_z=0.0, seed=9.0)
    return parts


# ----------------------------------------------------------------------------
# 5/6. wattle and daub
# ----------------------------------------------------------------------------

DAUB_T = 0.072
WEAVE_A = 0.050


def wattle_rod(bm, x0, x1, z, posts, phase, seed, r=0.0125):
    """Horizontal rod weaving in front of / behind successive posts."""
    n = max(4, int((x1 - x0) / 0.2) + 2)
    pts = []
    for i in range(n):
        t = i / (n - 1)
        x = lerp(x0, x1, t)
        # weave: smooth sinusoid, in front of / behind alternate posts (posts 0.95 apart)
        y = WEAVE_A * math.cos(math.pi * (x - posts[0]) / 0.95 + phase * math.pi)
        zz = z + 0.012 * nz(V((x * 2.0, seed, 0.3)), 1.0, 1)
        pts.append(V((x, y, zz)))
    return wood_rod(bm, pts, r * 1.08, r * 0.92, seg=5, seed=seed, cap_inner=0, noise_amp=0.04)


def daub_slab(bm, x0, x1, z0, z1, seed, mat=0, rings=None, round_ends=(True, True), top_round=True,
              bottom_ground=False, thick=DAUB_T, posts=()):
    """Lumpy hand-pressed plaster band covering both faces of the wattle.
    10-point cross-section swept along X; the lower edge tucks in (it sits under the lip of
    the band below), the upper edge is a rounded lumpy lip."""
    L = x1 - x0
    nr = rings or max(5, int(L / 0.21) + 2)
    off = V((seed * 3.3, seed * 1.1, 0.7))
    H = z1 - z0
    lay_h = tag_layer(bm, "h")
    cen, profs = [], []
    for i in range(nr):
        t = i / (nr - 1)
        x = lerp(x0, x1, t) + (0.02 * nz(V((t * 3.0, seed, 1.0)), 1.0, 1) if 0 < i < nr - 1 else 0.0)
        endk = 1.0
        if (round_ends[0] and i == 0) or (round_ends[1] and i == nr - 1):
            endk = 0.72
        T = thick
        # (y, z) going round: front from bottom to top, over the lip, back from top to bottom, under
        pts2 = [(-T * 0.86, z0 - 0.035), (-T * 1.02, z0 + H * 0.10), (-T * 1.03, z0 + H * 0.45),
                (-T * 0.99, z0 + H * 0.84), (-T * 0.72, z1 + 0.010), (T * 0.72, z1 + 0.010),
                (T * 0.99, z0 + H * 0.84), (T * 1.03, z0 + H * 0.45), (T * 1.02, z0 + H * 0.10),
                (T * 0.86, z0 - 0.035)]
        if bottom_ground:
            pts2[0] = (-T * 1.02, z0)
            pts2[9] = (T * 1.02, z0)
        pr = []
        for j, (yy, zz) in enumerate(pts2):
            q = V((x, yy, zz))
            lump = nz(q * 8.5 + off, 1.0, 2)
            lump2 = nz(q * 19.0 + off * 1.7, 1.0, 1)
            if j not in (0, 9) or bottom_ground:
                yy = yy * endk + math.copysign(0.010 * lump + 0.004 * lump2, yy)
            if j in (4, 5) and top_round:
                zz += 0.016 * lump
            if j in (1, 2, 3, 6, 7, 8):
                zz += 0.02 * lump2
            for px in posts:
                if abs(x - px) < 0.14 and j in (2, 7):
                    yy += math.copysign(0.008 * (1 - abs(x - px) / 0.14), yy)
            pr.append((yy, zz))
        cen.append(V((x, 0, 0)))
        profs.append(list(reversed(pr)))
    frames = [(V((1, 0, 0)), V((0, 1, 0)), V((0, 0, 1)))] * nr
    res = sweep(bm, cen, profs, frames=frames, cap0="flat", cap1="flat", mat=mat)
    for v in faces_verts(res["side"] + res["cap0"] + res["cap1"]):
        v[lay_h] = 0.0
    return res


@piece
def build_wall():
    parts = []
    posts = (-0.95, 0.0, 0.95)
    for i, x in enumerate(posts):
        bm = new_bm()
        r = 0.05 if i != 1 else 0.046
        pole(bm, (x, 0, 0.0), (x + 0.006 * (i - 1), 0, 2.30 + 0.03 * (i % 2)), r=r, seed=60 + i, seg=7, n=7,
             wobble=0.006, bend=0.008, bend_dir=(0, 1, 0))
        parts.append(new_part(i, bm, ["Bark", "WoodEnd"]))
    for k, z in enumerate((0.3, 0.6, 0.9, 1.2, 1.5, 1.8)):
        bm = new_bm()
        wattle_rod(bm, -0.985, 0.985, z, list(posts), k % 2, 70 + k)
        parts.append(new_part(3 + k, bm, ["Bark", "WoodEnd"]))
    bands = [(0.0, 0.37), (0.37, 0.73), (0.73, 1.1), (1.1, 1.47), (1.47, 1.83), (1.83, 2.2)]
    for k, (z0, z1) in enumerate(bands):
        bm = new_bm()
        daub_slab(bm, -0.925, 0.925, z0, z1 + (0.0 if k == 5 else 0.01), seed=80 + k, bottom_ground=(k == 0),
                  posts=(0.0,))
        parts.append(new_part(9 + k, bm, ["Daub"]))
    finish_piece("wall", parts, ground_z=0.0, seed=11.0, ao_dist=0.3)
    return parts


@piece
def build_doorway():
    parts = []
    for i, x in enumerate((-0.95, 0.95)):
        bm = new_bm()
        pole(bm, (x, 0, 0.0), (x + 0.005 * (1 if i else -1), 0, 2.30), r=0.05, seed=90 + i, seg=7, n=9,
             wobble=0.006, bend=0.008, bend_dir=(0, 1, 0))
        parts.append(new_part(i, bm, ["Bark", "WoodEnd"]))
    bm = new_bm()
    pole(bm, (-1.0, 0, 1.955), (1.0, 0, 1.950), r=0.054, seed=93, seg=8, n=9, wobble=0.004, bend=0.008,
         bend_dir=(0, 0, 1))
    parts.append(new_part(2, bm, ["Bark", "WoodEnd"]))
    # rods: left lower, left upper(+above lintel), right lower, right upper(+above lintel)
    specs = [(-1, 0.6, False), (-1, 1.3, True), (1, 0.6, False), (1, 1.3, True)]
    for k, (side, z, above) in enumerate(specs):
        bm = new_bm()
        x0, x1 = (-0.985, -0.47) if side < 0 else (0.47, 0.985)
        post = -0.95 if side < 0 else 0.95
        wattle_rod(bm, x0, x1, z, [post], k % 2, 100 + k)
        wattle_rod(bm, x0, x1, z + 0.1, [post], (k + 1) % 2, 110 + k, r=0.011)
        if above:
            xa0, xa1 = (-0.985, -0.02) if side < 0 else (0.02, 0.985)
            wattle_rod(bm, xa0, xa1, 2.09, [post], k % 2, 120 + k, r=0.011)
        parts.append(new_part(3 + k, bm, ["Bark", "WoodEnd"]))
    # daub patches: left lower, left upper (+ strip above lintel), right lower, right upper
    for k, (side, lower) in enumerate(((-1, True), (-1, False), (1, True), (1, False))):
        bm = new_bm()
        x0, x1 = (-0.925, -0.45) if side < 0 else (0.45, 0.925)
        if lower:
            daub_slab(bm, x0, x1, 0.0, 0.48, seed=130 + k, bottom_ground=True, rings=5)
            daub_slab(bm, x0, x1, 0.48, 0.96, seed=150 + k, rings=5)
        else:
            daub_slab(bm, x0, x1, 0.95, 1.43, seed=130 + k, rings=5)
            daub_slab(bm, x0, x1, 1.43, 1.90, seed=150 + k, rings=5)
            xa0, xa1 = (-0.925, 0.002) if side < 0 else (-0.002, 0.925)
            daub_slab(bm, xa0, xa1, 2.0, 2.2, seed=140 + k, rings=6,
                      round_ends=(side < 0, side > 0))
        parts.append(new_part(7 + k, bm, ["Daub"]))
    finish_piece("doorway", parts, ground_z=0.0, seed=13.0, ao_dist=0.3)
    return parts


# ----------------------------------------------------------------------------
# 7. roof (lean-to thatch)
# ----------------------------------------------------------------------------

PITCH = math.radians(25.0)
SLOPE_L = 2.2
RUN = SLOPE_L * math.cos(PITCH)


def slope_frame():
    """Returns (origin, s_dir, h_dir): s along the slope (up toward +Y), h normal to the slope."""
    s_dir = V((0, math.cos(PITCH), math.sin(PITCH)))
    h_dir = V((0, -math.sin(PITCH), math.cos(PITCH)))
    return s_dir, h_dir


def S(x, s, h):
    """Slope coords -> world.  s=0 at the slope centre; low edge s=-1.1 at y=-RUN/2."""
    s_dir, h_dir = slope_frame()
    base = V((0, 0, 0)) + s_dir * (s + SLOPE_L / 2) + V((0, -RUN / 2, 0))
    return V((x, 0, 0)) + base + h_dir * h


RAFTER_R = 0.045
PURLIN_R = 0.017
PURLIN_S = (-0.72, 0.0, 0.72)


def thatch_course(bm, k, n_courses=8, seed=0, mat=0):
    """One thatch course: a slab along X whose butt edge is serrated into bundles."""
    step = SLOPE_L / n_courses
    s0 = -SLOPE_L / 2 + k * step - (0.07 if k == 0 else 0.0)
    L = step * 1.8
    if k == n_courses - 1:
        L = SLOPE_L / 2 - s0 + 0.03
    hb = 2 * RAFTER_R + 1.8 * PURLIN_R                 # thatch bed on top of the purlins
    lift = 0.05
    Tb, Tt = 0.105, 0.03
    rng = random.Random(seed)
    NX = 21
    xs = [-1.12 + 2.24 * i / (NX - 1) for i in range(NX)]
    lay_h = tag_layer(bm, "h")
    lay_k = tag_layer(bm, "k")
    rings = []
    for i, x in enumerate(xs):
        tuft = 0.012 + 0.03 * hash01(i * 3.1 + k * 7.7 + seed) + (0.012 if i % 2 == 0 else 0.0)
        if i in (0, NX - 1):
            tuft = 0.015
        j1 = tuft + 0.015 * nz(V((x * 4.0, k * 1.7, seed)), 1.0, 1) + rng.uniform(-0.008, 0.008)
        j2 = 0.012 * nz(V((x * 5.0, k * 2.3, seed + 3)), 1.0, 1)
        pts_sh = [
            (s0 + L, hb),                                   # top end, bottom
            (s0 + 0.03 + j1 * 0.3, hb + lift),              # butt, bottom
            (s0 - 0.02 - j1, hb + lift + Tb * 0.40 + j2),   # butt tips (shaggy, overhanging)
            (s0 + 0.05 - j1 * 0.2, hb + lift + Tb + j2),    # butt, top
            (s0 + L, hb + Tt),                              # top end, top
        ]
        ring = []
        for j, (ss, hh) in enumerate(pts_sh):
            v = bm.verts.new(S(x, ss, hh))
            v[lay_h] = 1.0 if j == 2 else (0.5 if j in (1, 3) else 0.0)
            v[lay_k] = (i % 2) + 0.95 * hash01(i * 1.7 + k * 5.3 + seed)
            ring.append(v)
        rings.append(ring)
    faces = []
    m = len(rings[0])
    for i in range(len(rings) - 1):
        A, B = rings[i], rings[i + 1]
        for j in range(m):
            j2 = (j + 1) % m
            f = bm.faces.new((A[j], B[j], B[j2], A[j2]))
            f.smooth = True
            faces.append(f)
    for R_, flip in ((rings[0], True), (rings[-1], False)):
        f = bm.faces.new(R_ if flip else list(reversed(R_)))
        f.smooth = False
        faces.append(f)
    for f in faces:
        f.material_index = mat
    bmesh.ops.recalc_face_normals(bm, faces=faces)
    return faces


@piece
def build_roof():
    parts = []
    for i, x in enumerate((-0.9, 0.9)):
        bm = new_bm()
        pole(bm, S(x, -1.16, RAFTER_R), S(x + 0.004, 1.14, RAFTER_R), r=RAFTER_R, seed=150 + i, seg=6, n=7,
             wobble=0.005, bend=0.012, bend_dir=(0, 0, -1))
        parts.append(new_part(i, bm, ["Bark", "WoodEnd"]))
    for k, s in enumerate(PURLIN_S):
        bm = new_bm()
        pts = rod_path(S(-1.13, s, 2 * RAFTER_R + PURLIN_R * 0.85), S(1.13, s + 0.01, 2 * RAFTER_R + PURLIN_R * 0.85),
                       n=6, wobble=0.004, bend=0.012, bend_dir=(0, 0, -1), seed=160 + k)
        wood_rod(bm, pts, PURLIN_R, PURLIN_R * 0.85, seg=5, seed=160 + k, cap_inner=0, noise_amp=0.05)
        parts.append(new_part(2 + k, bm, ["Bark", "WoodEnd"]))
    for k in range(8):
        bm = new_bm()
        thatch_course(bm, k, seed=170 + k)
        parts.append(new_part(5 + k, bm, ["Straw"]))
    bm = new_bm()
    s_dir, h_dir = slope_frame()
    top_h = 2 * RAFTER_R + 1.85 * PURLIN_R + ROPE_R * 0.8
    bot_h = -ROPE_R * 0.8
    for s in PURLIN_S:
        for x in (-0.9, 0.9):
            c = S(x, s, (top_h + bot_h) / 2)
            for d in ((1 if x < 0 else -1),):
                u = (V((1, 0, 0)) + s_dir * d).normalized()
                rope_loop(bm, c, u, h_dir, (RAFTER_R + ROPE_R * 1.4) * 1.414, (top_h - bot_h) / 2,
                          n=7, power=2.6)
    parts.append(new_part(13, bm, ["Rope"]))
    finish_piece("roof", parts, ground_z=None, seed=17.0, ao_dist=0.25, ground=False)
    return parts


# ----------------------------------------------------------------------------
# 8. shelf
# ----------------------------------------------------------------------------

@piece
def build_shelf():
    parts = []
    leg_r = 0.026
    legs = [(-0.95, -0.152), (0.95, -0.152), (-0.95, 0.152), (0.95, 0.152)]
    for i, (x, y) in enumerate(legs):
        bm = new_bm()
        pts = rod_path((x, y, 0.0), (x + 0.004 * (i - 1.5), y, 1.0), n=6, wobble=0.004, bend=0.006, seed=180 + i)
        wood_rod(bm, pts, leg_r, leg_r * 0.88, seg=7, seed=180 + i, cap_inner=1, noise_amp=0.05)
        parts.append(new_part(i, bm, ["Bark", "WoodEnd"]))
    T = 0.04
    for k, z in enumerate((0.35, 0.85)):
        bm = new_bm()
        plank(bm, (-1.0, 0.0, z + T / 2), (1.0, 0.0, z + T / 2), 0.25, T, up=(0, 0, 1), seed=190 + k, mat=0,
              end_mat=1, rings=6, wobble=0.004, width_var=0.04, corner=0.3)
        parts.append(new_part(4 + k, bm, ["Wood", "WoodEnd"]))
    bm = new_bm()
    for z in (0.35, 0.85):
        for (x, y) in legs:
            # collar turns the board rests on + a diagonal turn over the board corner
            rope_coil(bm, (x, y, z - 0.012), (0, 0, 1), leg_r + ROPE_R * 0.9, 1.6, 0.011, n_per_turn=7)
            sy = 1 if y > 0 else -1
            rope_loop(bm, (x, y - sy * 0.035, z + T * 0.4), (0, 1, 0), (0, 0, 1), 0.06, T * 0.5 + ROPE_R * 1.6,
                      n=7, power=2.6)
    parts.append(new_part(6, bm, ["Rope"]))
    finish_piece("shelf", parts, ground_z=0.0, seed=19.0)
    return parts


# ----------------------------------------------------------------------------
# 9. sleeping mat
# ----------------------------------------------------------------------------

MAT_L, MAT_W, MAT_T = 1.9, 0.8, 0.04


def straw_bundle(bm, x, w, y0, y1, z, t, seed, mat=0, phase=0):
    """A flattened straw bundle running along Y with an over/under weave undulation."""
    n = 6
    pts, profs = [], []
    lay_k = tag_layer(bm, "k")
    rng = random.Random(seed)
    for i in range(n):
        u = i / (n - 1)
        y = lerp(y0, y1, u)
        zz = z + 0.004 * math.sin(u * math.pi * 5 + phase * math.pi)
        pts.append(V((x + 0.004 * nz(V((u * 3, seed, 0)), 1.0, 1), y, zz)))
        profs.append(prof_ellipse(t / 2 * (1.0 + 0.1 * math.sin(u * 9 + seed)), w / 2 * (1.0 + 0.04 * math.sin(u * 7 + seed)), 6))
    frames = [(V((0, 1, 0)), V((0, 0, 1)), V((1, 0, 0)))] * n
    res = sweep(bm, pts, profs, frames=frames, cap0="flat", cap1="flat", len0=0.006, len1=0.006, mat=mat)
    kk = rng.random()
    for v in faces_verts(res["side"] + res["cap0"] + res["cap1"]):
        v[lay_k] = kk
    return res


@piece
def build_sleeping_mat():
    parts = []
    strip = MAT_L / 6
    for k in range(6):
        bm = new_bm()
        x0 = -MAT_L / 2 + k * strip
        nb = 3
        bw = strip / nb
        for b in range(nb):
            bx = x0 + bw * (b + 0.5)
            straw_bundle(bm, bx, bw * 1.12, -MAT_W / 2, MAT_W / 2, MAT_T / 2, MAT_T, seed=200 + k * 3 + b,
                         phase=(k * nb + b) % 2)
        if k == 5:
            # rolled straw pillow at the +X end
            px = MAT_L / 2 - 0.14
            n = 6
            pts = [V((px, lerp(-0.34, 0.34, i / (n - 1)), MAT_T + 0.062)) for i in range(n)]
            profs = []
            for i in range(n):
                pr = []
                for s_ in range(10):
                    a = TAU * s_ / 10
                    rr = 0.066 * (1.0 + 0.07 * math.sin(a * 3 + i)) * (0.93 if i in (0, n - 1) else 1.0)
                    pr.append((math.cos(a) * rr * 0.9, math.sin(a) * rr))
                profs.append(pr)
            frames = [(V((0, 1, 0)), V((0, 0, 1)), V((1, 0, 0)))] * n
            res = sweep(bm, pts, profs, frames=frames, cap0="flat", cap1="flat", len0=-0.012, len1=-0.012,
                        mat=0, cap_inner=1)
            lay_k = tag_layer(bm, "k")
            for v in faces_verts(res["side"] + res["cap0"] + res["cap1"]):
                v[lay_k] = 0.4
        parts.append(new_part(k, bm, ["Straw"]))
    bm = new_bm()
    # binding: cords along both long edges and two woven cords running the length of the mat
    for yc, amp in ((-(MAT_W / 2 - 0.012), 0.010), (MAT_W / 2 - 0.012, 0.010), (-0.18, 0.006), (0.18, 0.006)):
        n = 19
        pts = [V((lerp(-MAT_L / 2 + 0.01, MAT_L / 2 - 0.01, i / (n - 1)), yc,
                  MAT_T + 0.002 + amp * math.cos(i * math.pi))) for i in range(n)]
        rope_path_tube(bm, pts, 0.0058 if abs(yc) > 0.3 else 0.0045, seg=4, mat=0, cap="round", twist_rate=60)
    # pillow ties
    px = MAT_L / 2 - 0.14
    for y in (-0.21, 0.21):
        rope_loop(bm, (px, y, MAT_T + 0.062), (1, 0, 0), (0, 0, 1), 0.0595 + ROPE_R, 0.066 + ROPE_R, n=8, power=2.0)
    parts.append(new_part(6, bm, ["Rope"]))
    finish_piece("sleeping_mat", parts, ground_z=0.0, seed=23.0, ao_dist=0.12, ground=False)
    return parts


# ----------------------------------------------------------------------------

def main():
    only = [a for a in ARGS if a in PIECES]
    for name, fn in PIECES.items():
        if only and name not in only:
            continue
        reset()
        parts = fn()
        export(f"build/{name}.glb", parts, quiet=True)
        info = glb_summary(os.path.join(MODEL_DIR, "build", f"{name}.glb"))
        print(f"[glb] build/{name}.glb nodes: " + ", ".join(f"{r['name']}" for r in info["nodes"]))
        if "nopreview" not in ARGS:
            tall = name in ("post", "ladder")
            preview(f"build_{name}", parts, elev=24, azim=-35, size=(600, 800) if tall else (800, 600),
                    samples=24, dist_mul=3.0 if tall else 3.3)
            if "more" in ARGS:
                preview(f"build_{name}_b", parts, elev=35, azim=140, size=(600, 800) if tall else (800, 600),
                        samples=20, dist_mul=3.0 if tall else 3.3)


main()
