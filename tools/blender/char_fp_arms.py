"""Skyroot first-person arms: forearm + three hand poses per side.

    blender -b --python tools/blender/char_fp_arms.py [-- nopreview]

Right arm (assets/models/character/fp_arm_r.glb):
  Forearm_R   origin at the elbow (0,0,0), forearm along +Y to the wrist (0,0.27,0)
  HandOpen_R  origin at the wrist, relaxed open hand, palm down (-Z)
  HandGrip_R  fist around a 3.5 cm handle whose axis runs along X through (0,0.355,-0.01)
  HandPinch_R thumb + index pinching, other fingers curled
Left arm (fp_arm_l.glb): mirror image (x negated), *_L names.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from craft_lib import *  # noqa: E402,F401,F403

ARGS = cli_args()

WRIST = V((0.0, 0.27, 0.0))
GRIP_C = V((0.0, 0.355, -0.010))       # handle axis (along X)
GRIP_R = 0.0175
FSEG = 6

# finger table (right hand, wrist-relative):   knuckle (MCP)           spread  lengths (prox, mid, dist)   radii (mcp, pip, dip, tip)
FINGERS = {
    "index":  (V((-0.0265, 0.083, 0.003)), -6.0, (0.036, 0.022, 0.018), (0.0106, 0.0101, 0.0092, 0.0084)),
    "middle": (V((-0.0085, 0.087, 0.004)), -1.0, (0.040, 0.025, 0.019), (0.0109, 0.0104, 0.0094, 0.0085)),
    "ring":   (V((0.0095, 0.084, 0.003)), 4.0, (0.037, 0.023, 0.018), (0.0104, 0.0099, 0.0090, 0.0081)),
    "pinky":  (V((0.0265, 0.077, 0.001)), 10.0, (0.029, 0.019, 0.016), (0.0094, 0.0089, 0.0081, 0.0073)),
}


def rot_about(v, axis, deg):
    return Matrix.Rotation(math.radians(deg), 3, V(axis).normalized()) @ V(v)


def finger_fk(mcp, spread, lengths, flex):
    """Joint positions with flexion (toward -Z) at each joint."""
    d = rot_about(V((0, 1, 0)), (0, 0, 1), -spread)    # spread around Z (negative -> toward -X)
    side = d.cross(V((0, 0, 1))).normalized()           # +X-ish; flex about -side bends toward -Z
    pts = [V(mcp)]
    for L, ang in zip(lengths, flex):
        d = rot_about(d, -side, ang)
        pts.append(pts[-1] + d * L)
    return pts


def finger_wrap(mcp, lengths, center, rj):
    """Joint positions for a finger wrapped round a cylinder along X: every joint after
    the knuckle lies on a circle of radius rj, phalanges are chords (clockwise in Y/Z)."""
    pts = [V(mcp)]
    c = V((mcp.x, center.y, center.z))
    for L in lengths:
        p = pts[-1]
        rel = p - c
        dP = math.hypot(rel.y, rel.z)
        phi = math.atan2(rel.z, rel.y)
        cosd = (dP * dP + rj * rj - L * L) / (2 * dP * rj)
        if cosd > 1.0:
            # too far to reach the circle: head along the clockwise tangent
            beta = math.acos(min(1.0, rj / dP))
            ta = phi - beta
            tpt = c + V((0, math.cos(ta), math.sin(ta))) * rj
            pts.append(p + (tpt - p).normalized() * L)
        else:
            th = phi - math.acos(max(-1.0, cosd))
            pts.append(c + V((0, math.cos(th), math.sin(th))) * rj)
    return pts


def finger_mesh(bm, joints, radii, inner=None, mat=0, tag_k=1.0):
    """Sweep a finger through joints; `inner` = extra point inside the palm."""
    pts = ([V(inner)] if inner is not None else []) + [V(j) for j in joints]
    rr = ([radii[0] * 0.95] if inner is not None else []) + list(radii)
    profs = [prof_ellipse(r * 0.92, r, FSEG) for r in rr]
    res = sweep(bm, pts, profs, up=(0, 0, 1), cap0="open", cap1="round", len1=rr[-1] * 1.05,
                cap_rings=1, mat=mat)
    lay = tag_layer(bm, "k")
    lay_s = tag_layer(bm, "s")
    allv = faces_verts(res["side"] + res["cap1"])
    for v in allv:
        v[lay] = tag_k
    # 's': 1 near the finger tip (nail / pad painting)
    tip = V(joints[-1])
    for v in allv:
        v[lay_s] = smoothstep(0.020, 0.004, (v.co - tip).length)
    return res


def palm_mesh(bm, rings, mat=0):
    """rings: list of (y, z_centre, half_width, half_thick) wrist-relative."""
    cen = [WRIST + V((0, y, z)) for y, z, w, t in rings]
    profs = []
    for y, z, w, t in rings:
        pr = prof_ellipse(t, w, 8, power=2.6)
        # slightly domed back, flatter palm
        pr = [(x * (1.0 if x > 0 else 0.9), yy) for x, yy in pr]
        profs.append(pr)
    res = sweep(bm, cen, profs, up=(0, 0, 1), cap0="flat", cap1="round", len1=0.014, cap_rings=1, mat=mat)
    lay = tag_layer(bm, "k")
    for v in faces_verts(res["side"] + res["cap0"] + res["cap1"]):
        v[lay] = 0.0
    return res


def thumb_mesh(bm, pts, radii, mat=0):
    res = sweep(bm, [WRIST + V(p) for p in pts], [prof_ellipse(r * 0.9, r, FSEG + 1) for r in radii], up=(0, 0, 1),
                cap0="open", cap1="round", len1=radii[-1] * 1.05, cap_rings=1, mat=mat)
    lay = tag_layer(bm, "k")
    lay_s = tag_layer(bm, "s")
    tip = WRIST + V(pts[-1])
    for v in faces_verts(res["side"] + res["cap1"]):
        v[lay] = 2.0
        v[lay_s] = smoothstep(0.020, 0.004, (v.co - tip).length)
    return res


PALM_FLAT = [(-0.010, 0.000, 0.031, 0.0168),
             (0.020, 0.000, 0.036, 0.0158),
             (0.050, 0.001, 0.041, 0.0145),
             (0.074, 0.002, 0.043, 0.0132)]


def build_hand_open():
    bm = new_bm()
    palm_mesh(bm, PALM_FLAT)
    flex = {"index": (8, 12, 7), "middle": (10, 15, 9), "ring": (13, 18, 11), "pinky": (16, 22, 13)}
    for name, (mcp, spread, lens, radii) in FINGERS.items():
        j = finger_fk(mcp, spread, lens, flex[name])
        finger_mesh(bm, [WRIST + p for p in j], radii, inner=WRIST + mcp + V((0, -0.016, 0)))
    thumb_mesh(bm, [(-0.020, 0.010, -0.006), (-0.040, 0.034, -0.014), (-0.057, 0.055, -0.020), (-0.067, 0.074, -0.022)],
               (0.0128, 0.0116, 0.0106, 0.0096))
    return make_obj("HandOpen_R", bm, ["Skin"])


def build_hand_grip():
    bm = new_bm()
    gc = GRIP_C - WRIST
    # palm tilts up toward the knuckles so the handle sits under the knuckle line
    palm_mesh(bm, [(-0.010, 0.000, 0.031, 0.0168),
                   (0.020, 0.004, 0.037, 0.0158),
                   (0.048, 0.012, 0.041, 0.0145),
                   (0.068, 0.018, 0.043, 0.0132)])
    order = {"index": 100.0, "middle": 97.0, "ring": 101.0, "pinky": 108.0}
    for name, (mcp, spread, lens, radii) in FINGERS.items():
        rj = GRIP_R + radii[1] + 0.0028
        a = math.radians(order[name])
        dist = rj + 0.0012
        m = V((mcp.x, gc.y + math.cos(a) * dist, gc.z + math.sin(a) * dist))
        j = finger_wrap(m, lens, gc, rj)
        finger_mesh(bm, [WRIST + p for p in j], radii, inner=WRIST + m + V((0, -0.018, -0.002)))
    # thumb crosses over the front of the index / middle middle phalanges
    thumb_mesh(bm, [(-0.022, 0.012, -0.006), (-0.046, 0.045, -0.018), (-0.051, 0.090, -0.022),
                    (-0.035, 0.128, -0.014), (-0.011, 0.137, -0.008)],
               (0.0128, 0.0120, 0.0112, 0.0104, 0.0096))
    return make_obj("HandGrip_R", bm, ["Skin"])


def build_hand_pinch():
    bm = new_bm()
    palm_mesh(bm, PALM_FLAT)
    flex = {"index": (34, 44, 22), "middle": (60, 95, 55), "ring": (66, 100, 55), "pinky": (72, 100, 55)}
    tips = {}
    for name, (mcp, spread, lens, radii) in FINGERS.items():
        sp = spread if name != "index" else -10.0
        j = finger_fk(mcp, sp, lens, flex[name])
        tips[name] = j[-1]
        finger_mesh(bm, [WRIST + p for p in j], radii, inner=WRIST + mcp + V((0, -0.016, 0)))
    it = tips["index"]
    tip = it + V((-0.004, -0.007, -0.0145))
    thumb_mesh(bm, [(-0.022, 0.012, -0.004), (-0.043, 0.040, -0.014), (-0.044, 0.066, -0.022),
                    (tip.x - 0.010, tip.y - 0.012, tip.z - 0.002), (tip.x, tip.y, tip.z)],
               (0.0126, 0.0117, 0.0108, 0.0100, 0.0094))
    return make_obj("HandPinch_R", bm, ["Skin"])


def build_forearm():
    bm = new_bm()
    M = {"Cloth": 0, "Skin": 1}
    #   y        half-w  half-h  z
    R = [(-0.050, 0.047, 0.044, 0.002),   # sleeve (extends behind the elbow)
         (0.036, 0.046, 0.043, 0.002),
         (0.046, 0.059, 0.055, 0.002),   # rolled cuff
         (0.066, 0.062, 0.058, 0.002),
         (0.081, 0.052, 0.048, 0.002),
         (0.082, 0.043, 0.038, 0.001),   # skin emerges
         (0.160, 0.041, 0.033, 0.001),
         (0.268, 0.030, 0.020, 0.000)]
    cen = [V((0, y, z)) for y, w, h, z in R]
    profs = []
    for i, (y, w, h, z) in enumerate(R):
        pr = prof_ellipse(h, w, 10)
        if 2 <= i <= 4:
            pr = [(x * (1 + 0.07 * math.sin(5 * math.atan2(yy, x) + 0.7 + i)), yy * (1 + 0.07 * math.sin(5 * math.atan2(yy, x) + 0.7 + i))) for x, yy in pr]
        if i == 7:
            # ulnar wrist bump on the pinky side (+X for the right arm)
            pr = [(x, yy * (1.06 if yy > 0 else 1.0)) for x, yy in pr]
        profs.append(pr)
    frames = [(V((0, 1, 0)), V((0, 0, 1)), V((1, 0, 0)))] * len(R)
    res = sweep(bm, cen, profs, frames=frames, cap0="flat", cap1="round", len1=0.014, cap_rings=1, mat=0)
    seg = 10
    # bands 0..4 cloth (incl. the tuck under the roll), then skin
    for k in range(len(res["rings"]) - 1):
        m = "Cloth" if k < 5 else "Skin"
        for s in range(seg):
            res["side"][k * seg + s].material_index = M[m]
    for f in res["cap0"]:
        f.material_index = M["Cloth"]
    for f in res["cap1"]:
        f.material_index = M["Skin"]
    return make_obj("Forearm_R", bm, ["Cloth", "Skin"])


SKIN = col("skin")
SKIN_WARM = col("#DA8E78")
SKIN_PALM = col("#EDBFA0")
NAIL = col("#F0CDB8")
CLOTH = grey(0.78)


def arm_painter(name):
    def fn(c):
        a = ao_shade(c.ao, 0.8)
        p = c.p
        if c.m == "Cloth":
            v = 1.0 + 0.035 * nz(p * 30.0, 1.0, 2)
            # the sleeve above the roll sits a touch in shadow
            if name.startswith("Forearm") and p.y < 0.045:
                v *= 0.92
            return sc(CLOTH, v * a)
        k = c.tag("k")
        s = c.tag("s")
        base = sc(SKIN, 1.0 + 0.03 * nz(p * 40.0, 1.0, 1))
        if name.startswith("Hand"):
            loc = p - WRIST
            if c.n.z < -0.3:
                base = mix(base, SKIN_PALM, 0.35 * min(1.0, -c.n.z))
            if k >= 1.0:
                # warm fingertips, light nail on the back of the tip
                base = mix(base, SKIN_WARM, 0.25 * s)
                if c.n.z > 0.2 and s > 0.4:
                    base = mix(base, NAIL, 0.6 * smoothstep(0.4, 0.9, s))
            if k == 0.0 and c.n.z > 0.2 and loc.y > 0.06:
                base = mix(base, SKIN_WARM, 0.25)      # knuckle flush
        else:
            base = mix(base, SKIN_WARM, 0.10 * smoothstep(0.2, 0.27, p.y))
        return sc(base, a)
    return fn


def finish(obj):
    bvh = bvh_of([obj])
    ao = bake_ao(obj, bvh, rays=36, dist=0.03)
    paint(obj, arm_painter(obj.name), ao=ao)


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
    o.location = V((-obj.location.x, obj.location.y, obj.location.z))
    return o


def main():
    reset()
    fore = build_forearm()
    hands = [build_hand_open(), build_hand_grip(), build_hand_pinch()]
    for o in [fore] + hands:
        finish(o)
    set_origin(fore, (0, 0, 0))
    for h in hands:
        set_origin(h, WRIST)
    right = [fore] + hands
    left = [mirrored(o, o.name[:-2] + "_L") for o in right]
    for o in right + left:
        print(f"   {o.name:12s} tris={tri_count(o):4d} loc={tuple(round(x, 3) for x in o.location)}")
    print(f"[fp] right tris {sum(tri_count(o) for o in right)}  left tris {sum(tri_count(o) for o in left)}")
    export("character/fp_arm_r.glb", right)
    export("character/fp_arm_l.glb", left)
    if "nopreview" in ARGS:
        return
    # previews: each pose from an eye-like position (behind/above/left of the elbow), plus close-ups
    for h in hands:
        show = [fore, h]
        if h.name == "HandGrip_R":
            hb = new_bm()
            tube_r(hb, [GRIP_C + V((-0.09, 0, 0)), GRIP_C + V((0.09, 0, 0))], GRIP_R, seg=16, cap0="flat", cap1="flat")
            ho = make_obj("GhostHandle", hb, ["Wood"])
            paint(ho, lambda c: col("wood_dark"))
            show.append(ho)
        tag_name = h.name.replace("Hand", "").replace("_R", "").lower()
        preview(f"fp_{tag_name}_fpview", show, elev=29, azim=-19, size=(720, 540), samples=24, dist_mul=2.4)
        preview(f"fp_{tag_name}_close", [o for o in show if o is not fore], elev=18, azim=-58, size=(720, 540),
                samples=24, dist_mul=2.6)
        if h.name == "HandGrip_R":
            preview("fp_grip_front", [o for o in show if o is not fore], elev=8, azim=-160, size=(720, 540),
                    samples=20, dist_mul=2.6)
            bpy.data.objects.remove(show[-1], do_unlink=True)
    preview("fp_arms_l_pinch", [left[0], left[3]], elev=29, azim=19, size=(720, 540), samples=20, dist_mul=2.4)


main()
