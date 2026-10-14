"""Extra helpers for Skyroot's character / item / building-piece scripts.

Builds on tools/blender/common.py (palette, materials, export, previews) and adds:
  * sweep(): lofts arbitrary 2D profiles along a path (open or closed), with
    round / flat / pointed caps -> limbs, fingers, planks, ropes, straw...
  * per-vertex "tags" (bmesh float layers) that painters can read back
  * ray-cast ambient occlusion baked per face corner
  * paint() with AO, corner normals and tags
  * shared material builders used by items AND building pieces so a "pole"
    item looks like the poles in a wall: wood_rod(), plank(), rope helpers
  * glb inspection (node names / translations / triangle counts)
"""
import bpy
import bmesh
import json
import math
import os
import random
import struct
import sys
from mathutils import Vector, Matrix, Quaternion, Euler, noise
from mathutils.bvhtree import BVHTree

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)
import common as C  # noqa: E402
from common import (pal, hexcol, lerp_col, mul_col, nz, material, new_object, reset,  # noqa: E402,F401
                    set_origin, triangle_count, export_glb, render_preview, MODEL_DIR,
                    PREVIEW_DIR, select_only, blob, bezier_points, ao_factor)

V = Vector
TAU = math.tau


# ----------------------------------------------------------------------------
# small utils
# ----------------------------------------------------------------------------

def cli_args():
    return sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []


def wanted(name, args):
    return (not args) or (name in args)


def clamp(x, a=0.0, b=1.0):
    return a if x < a else b if x > b else x


def lerp(a, b, t):
    return a + (b - a) * t


def smoothstep(e0, e1, x):
    t = clamp((x - e0) / (e1 - e0)) if e1 != e0 else (1.0 if x >= e1 else 0.0)
    return t * t * (3.0 - 2.0 * t)


def mix(c1, c2, t):
    t = clamp(t)
    return (c1[0] + (c2[0] - c1[0]) * t, c1[1] + (c2[1] - c1[1]) * t,
            c1[2] + (c2[2] - c1[2]) * t, 1.0)


def sc(c, f):
    return (c[0] * f, c[1] * f, c[2] * f, 1.0)


def grey(v):
    return (v, v, v, 1.0)


def col(h):
    """Palette name or '#rrggbb' -> linear RGBA."""
    return pal(h)


def n3(p, s=1.0, o=0.0, octaves=2):
    """Noise in [-1,1] at vector p * s offset by scalar o."""
    return nz(V(p) * s + V((o, o * 0.37, o * 0.71)), 1.0, octaves)


def rand_unit(rng):
    while True:
        v = V((rng.uniform(-1, 1), rng.uniform(-1, 1), rng.uniform(-1, 1)))
        if 0.05 < v.length <= 1.0:
            return v.normalized()


# ----------------------------------------------------------------------------
# frames & profiles
# ----------------------------------------------------------------------------

def perp(v):
    a = V((0, 0, 1)) if abs(v.z) < 0.9 else V((1, 0, 0))
    return v.cross(a).normalized()


def path_frames(pts, up=None, closed=False):
    """Parallel-transport frames (t, n, b) along pts.  n starts as `up` projected."""
    pts = [V(p) for p in pts]
    N = len(pts)
    out = []
    prev = None
    for i in range(N):
        if closed:
            a, c = pts[i - 1], pts[(i + 1) % N]
            tan = (c - pts[i]).normalized() + (pts[i] - a).normalized()
        elif i == 0:
            tan = pts[1] - pts[0]
        elif i == N - 1:
            tan = pts[-1] - pts[-2]
        else:
            tan = (pts[i + 1] - pts[i]).normalized() + (pts[i] - pts[i - 1]).normalized()
        if tan.length < 1e-9:
            tan = pts[min(i + 1, N - 1)] - pts[max(i - 1, 0)]
        t = tan.normalized()
        if prev is None:
            if up is not None and abs(V(up).normalized().dot(t)) < 0.999:
                u = V(up)
                n = u - t * u.dot(t)
            else:
                n = perp(t)
        else:
            n = prev - t * prev.dot(t)
            if n.length < 1e-6:
                n = perp(t)
        n.normalize()
        b = t.cross(n).normalized()
        out.append((t, n, b))
        prev = n
    return out


def path_frames_up(pts, up, closed=False):
    """Frames whose n is always `up` projected (no parallel transport) - for paths
    that should keep a fixed 'up' (planks, flat ropes on a surface)."""
    pts = [V(p) for p in pts]
    N = len(pts)
    out = []
    for i in range(N):
        if closed:
            tan = (pts[(i + 1) % N] - pts[i]).normalized() + (pts[i] - pts[i - 1]).normalized()
        elif i == 0:
            tan = pts[1] - pts[0]
        elif i == N - 1:
            tan = pts[-1] - pts[-2]
        else:
            tan = (pts[i + 1] - pts[i]).normalized() + (pts[i] - pts[i - 1]).normalized()
        t = tan.normalized()
        u = V(up(i) if callable(up) else up)
        n = u - t * u.dot(t)
        if n.length < 1e-6:
            n = perp(t)
        n.normalize()
        out.append((t, n, t.cross(n).normalized()))
    return out


def prof_ellipse(rn, rb, seg, phase=0.0, power=2.0):
    """Ellipse/superellipse profile, CCW in the (n, b) plane.  power>2 -> boxier."""
    pts = []
    e = 2.0 / power
    for s in range(seg):
        a = phase + TAU * s / seg
        c, si = math.cos(a), math.sin(a)
        pts.append((math.copysign(abs(c) ** e, c) * rn, math.copysign(abs(si) ** e, si) * rb))
    return pts


def prof_rrect(hn, hb, r, m=2):
    """Rounded rectangle (half extents hn x hb, corner radius r, m points/corner) CCW."""
    r = min(r, hn * 0.999, hb * 0.999)
    pts = []
    corners = [(hn - r, hb - r, 0.0), (-hn + r, hb - r, 0.5 * math.pi),
               (-hn + r, -hb + r, math.pi), (hn - r, -hb + r, 1.5 * math.pi)]
    for cx, cy, a0 in corners:
        for j in range(m):
            a = a0 + (0.5 * math.pi) * (j / (m - 1) if m > 1 else 0.5)
            pts.append((cx + r * math.cos(a), cy + r * math.sin(a)))
    return pts


def prof_d(top, bottom, hb, seg, sole_round=0.5):
    """'D' profile: elliptic top (height `top` above centre), flat-ish bottom at -bottom."""
    pts = []
    for s in range(seg):
        a = TAU * s / seg
        c, si = math.cos(a), math.sin(a)
        if c >= 0:
            pts.append((top * c, hb * si))
        else:
            e = sole_round
            pts.append((-bottom * abs(c) ** e, hb * math.copysign(abs(si) ** e, si)))
    return pts


def prof_scale(prof, fn, fb=None):
    fb = fn if fb is None else fb
    return [(x * fn, y * fb) for x, y in prof]


# ----------------------------------------------------------------------------
# tags: per-vertex float layers readable by the painter
# ----------------------------------------------------------------------------

TAG_NAMES = ("u", "a", "len", "w", "rr", "tw", "hair", "k", "s", "h")


def new_bm():
    """bmesh with every tag layer pre-created (adding a layer later would invalidate
    vertex references held by the builders)."""
    bm = bmesh.new()
    for n in TAG_NAMES:
        bm.verts.layers.float.new("tag_" + n)
    return bm


def tag_layer(bm, name):
    key = "tag_" + name
    lay = bm.verts.layers.float.get(key)
    if lay is None:
        if len(bm.verts):
            raise RuntimeError(f"tag layer {key} missing - create the bmesh with new_bm()")
        lay = bm.verts.layers.float.new(key)
    return lay


def tag(bm, verts, name, value):
    lay = tag_layer(bm, name)
    for v in verts:
        v[lay] = value(v) if callable(value) else value


def strip_tags(obj):
    me = obj.data
    for a in [a.name for a in me.attributes if a.name.startswith("tag_")]:
        me.attributes.remove(me.attributes[a])


# ----------------------------------------------------------------------------
# sweep
# ----------------------------------------------------------------------------

def sweep(bm, centers, profiles, frames=None, up=None, closed=False,
          cap0="flat", cap1="flat", len0=None, len1=None, cap_rings=2,
          mat=0, cap_mat0=None, cap_mat1=None, rnoise=None, smooth=True,
          tags=None, flat_caps=False, cap_inner=0, pole0=None, pole1=None):
    """Loft `profiles` (list of 2D point lists in the (n,b) plane, or one shared list)
    along `centers`.

    caps: 'open' | 'flat' (fan, pole displaced by len) | 'round' (elliptic cap of
    length len) | 'point'.  cap_inner>0 adds that many inner concentric rings on flat
    caps (for wood end rings).  rnoise=(amp, scale, seed) radial noise.
    tags: dict name -> fn(k_ring_param u in [0,1], angle_index, vert) or constant; the
    built-ins 'u' (0..1 along path incl. caps) and 'a' (angle 0..1) are always written.
    Returns dict(rings, side, cap0, cap1, ring_u).
    """
    centers = [V(c) for c in centers]
    N = len(centers)
    if frames is None:
        frames = path_frames(centers, up=up, closed=closed)
    if profiles and isinstance(profiles[0], tuple):
        profiles = [profiles] * N
    m = len(profiles[0])
    # arc length param
    acc = [0.0]
    for i in range(1, N):
        acc.append(acc[-1] + (centers[i] - centers[i - 1]).length)
    total = acc[-1] if acc[-1] > 0 else 1.0
    specs = []

    def prof_radius(p):
        return max(max(abs(x) for x, y in p), max(abs(y) for x, y in p))

    if not closed and cap0 == "round":
        L = len0 if len0 is not None else prof_radius(profiles[0])
        t = frames[0][0]
        for k in range(cap_rings, 0, -1):
            phi = (math.pi / 2) * k / (cap_rings + 1)
            specs.append((centers[0] - t * L * math.sin(phi), frames[0], profiles[0], math.cos(phi), -L * math.sin(phi)))
    for i in range(N):
        specs.append((centers[i], frames[i], profiles[i], 1.0, acc[i]))
    if not closed and cap1 == "round":
        L = len1 if len1 is not None else prof_radius(profiles[-1])
        t = frames[-1][0]
        for k in range(1, cap_rings + 1):
            phi = (math.pi / 2) * k / (cap_rings + 1)
            specs.append((centers[-1] + t * L * math.sin(phi), frames[-1], profiles[-1], math.cos(phi), total + L * math.sin(phi)))
    lay_u = tag_layer(bm, "u")
    lay_a = tag_layer(bm, "a")
    rings = []
    ring_u = []
    if rnoise:
        amp, nsc, seed = rnoise
        off = V((seed * 13.1, seed * 7.7, seed * 3.3))
    for c, (t, n, b), prof, s, u in specs:
        ring = []
        for j, (x, y) in enumerate(prof):
            d = n * (x * s) + b * (y * s)
            if rnoise and d.length > 1e-9:
                d = d * (1.0 + amp * nz((c + d) * nsc + off, 1.0, 2))
            v = bm.verts.new(c + d)
            v[lay_u] = u / total
            v[lay_a] = j / m
            ring.append(v)
        rings.append(ring)
        ring_u.append(u / total)
    side = []
    nr = len(rings)
    last = nr if closed else nr - 1
    for k in range(last):
        A, B = rings[k], rings[(k + 1) % nr]
        for s in range(m):
            s2 = (s + 1) % m
            side.append(bm.faces.new((A[s], A[s2], B[s2], B[s])))
    c0, c1 = [], []
    if not closed:
        for which in (0, 1):
            mode = cap0 if which == 0 else cap1
            if mode == "open":
                continue
            R = rings[0] if which == 0 else rings[-1]
            t = frames[0][0] if which == 0 else frames[-1][0]
            sgn = -1.0 if which == 0 else 1.0
            cen = V((0, 0, 0))
            for v in R:
                cen += v.co
            cen /= len(R)
            L = len0 if which == 0 else len1
            if mode == "round":
                Lr = L if L is not None else prof_radius(profiles[0 if which == 0 else -1])
                pole_co = (centers[0] if which == 0 else centers[-1]) + t * sgn * Lr
            elif mode == "point":
                explicit = pole0 if which == 0 else pole1
                pole_co = V(explicit) if explicit is not None else cen + t * sgn * (L if L is not None else 0.0)
            else:  # flat
                pole_co = cen + t * sgn * (L or 0.0)
            ring_list = [R]
            if mode == "flat" and cap_inner > 0:
                for k in range(1, cap_inner + 1):
                    f = 1.0 - k / (cap_inner + 1)
                    ring_list.append([bm.verts.new(cen.lerp(v.co, f) + t * sgn * (L or 0.0) * (1 - f)) for v in R])
                for k in range(len(ring_list) - 1):
                    A, B = ring_list[k], ring_list[k + 1]
                    for s in range(m):
                        s2 = (s + 1) % m
                        f = bm.faces.new((A[s2], A[s], B[s], B[s2])) if which == 0 else bm.faces.new((A[s], A[s2], B[s2], B[s]))
                        (c0 if which == 0 else c1).append(f)
                for k in range(1, len(ring_list)):
                    for v in ring_list[k]:
                        v[lay_u] = 0.0 if which == 0 else 1.0
                        v[lay_a] = 0.0
            pole = bm.verts.new(pole_co)
            pole[lay_u] = (0.0 if which == 0 else 1.0)
            pole[lay_a] = 0.0
            Rl = ring_list[-1]
            for s in range(m):
                s2 = (s + 1) % m
                if which == 0:
                    f = bm.faces.new((Rl[s2], Rl[s], pole))
                else:
                    f = bm.faces.new((Rl[s], Rl[s2], pole))
                (c0 if which == 0 else c1).append(f)
    for f in side:
        f.material_index = mat
        f.smooth = smooth
    for f in c0:
        f.material_index = mat if cap_mat0 is None else cap_mat0
        f.smooth = smooth and not flat_caps
    for f in c1:
        f.material_index = mat if cap_mat1 is None else cap_mat1
        f.smooth = smooth and not flat_caps
    if tags:
        allv = [v for r in rings for v in r]
        for name, val in tags.items():
            tag(bm, allv, name, val)
    return dict(rings=rings, side=side, cap0=c0, cap1=c1, ring_u=ring_u, frames=frames)


def tube_r(bm, pts, radii, seg=8, up=None, **kw):
    """Round tube with per-point radii (ellipse profile)."""
    pts = [V(p) for p in pts]
    if not isinstance(radii, (list, tuple)):
        radii = [radii] * len(pts)
    profs = [prof_ellipse(r, r, seg) for r in radii]
    return sweep(bm, pts, profs, up=up, **kw)


def ellipsoid(bm, center, radii, seg=10, rings=6, mat=0, deform=None, rot=None, smooth=True):
    """Lat/long ellipsoid with poles on local Z.  deform(local_unit_dir, co)->co."""
    center = V(center)
    rx, ry, rz = radii
    R = rot.to_matrix() if isinstance(rot, (Euler, Quaternion)) else (rot if rot is not None else Matrix.Identity(3))
    verts = []
    bottom = None
    top = None

    def mk(d):
        co = V((d.x * rx, d.y * ry, d.z * rz))
        if deform:
            co = deform(d, co)
        return bm.verts.new(center + R @ co)
    bottom = mk(V((0, 0, -1)))
    for i in range(1, rings):
        th = math.pi * i / rings - math.pi / 2
        ring = []
        for s in range(seg):
            a = TAU * s / seg
            d = V((math.cos(th) * math.cos(a), math.cos(th) * math.sin(a), math.sin(th)))
            ring.append(mk(d))
        verts.append(ring)
    top = mk(V((0, 0, 1)))
    faces = []
    for s in range(seg):
        s2 = (s + 1) % seg
        faces.append(bm.faces.new((verts[0][s2], verts[0][s], bottom)))
    for i in range(len(verts) - 1):
        A, B = verts[i], verts[i + 1]
        for s in range(seg):
            s2 = (s + 1) % seg
            faces.append(bm.faces.new((A[s], A[s2], B[s2], B[s])))
    for s in range(seg):
        s2 = (s + 1) % seg
        faces.append(bm.faces.new((verts[-1][s], verts[-1][s2], top)))
    for f in faces:
        f.material_index = mat
        f.smooth = smooth
    return faces


def ico(bm, center, radius, subdiv=1, squash=(1, 1, 1), noise_amp=0.0, noise_scale=1.5, seed=0,
        mat=0, rot=None, smooth=True):
    """Noisy icosphere (rocks, clods, berries, foliage)."""
    faces = blob(bm, center, radius, subdiv=subdiv, noise_amp=noise_amp, noise_scale=noise_scale,
                 squash=squash, seed=seed)
    if rot is not None:
        Rm = rot.to_matrix() if isinstance(rot, (Euler, Quaternion)) else rot
        cen = V(center)
        done = set()
        for f in faces:
            for v in f.verts:
                if v not in done:
                    v.co = cen + Rm @ (v.co - cen)
                    done.add(v)
    for f in faces:
        f.material_index = mat
        f.smooth = smooth
    return faces


def faces_verts(faces):
    s = []
    seen = set()
    for f in faces:
        for v in f.verts:
            if v not in seen:
                seen.add(v)
                s.append(v)
    return s


def transform_faces(faces, M):
    for v in faces_verts(faces):
        v.co = M @ v.co


def mirror_bm_x(bm):
    for v in bm.verts:
        v.co.x = -v.co.x
    bmesh.ops.reverse_faces(bm, faces=list(bm.faces))


# ----------------------------------------------------------------------------
# ambient occlusion
# ----------------------------------------------------------------------------

_DIRS = {}


def hemi_dirs(n=36, seed=11):
    key = (n, seed)
    if key not in _DIRS:
        rng = random.Random(seed)
        k = max(2, int(round(math.sqrt(n))))
        out = []
        for i in range(k):
            for j in range(k):
                u1 = (i + rng.random()) / k
                u2 = (j + rng.random()) / k
                r = math.sqrt(u1)
                th = TAU * u2
                out.append(V((r * math.cos(th), r * math.sin(th), math.sqrt(max(0.0, 1.0 - u1)))))
        _DIRS[key] = out
    return _DIRS[key]


def bvh_of(objs, ground_z=None, ground_size=50.0):
    verts, polys = [], []
    for o in objs:
        mw = o.matrix_world
        base = len(verts)
        verts.extend(mw @ v.co for v in o.data.vertices)
        polys.extend([base + i for i in p.vertices] for p in o.data.polygons)
    if ground_z is not None:
        b = len(verts)
        g = ground_size
        verts.extend([V((-g, -g, ground_z)), V((g, -g, ground_z)), V((g, g, ground_z)), V((-g, g, ground_z))])
        polys.append([b, b + 1, b + 2, b + 3])
    return BVHTree.FromPolygons(verts, polys, epsilon=0.0)


def bake_ao(obj, bvh, rays=36, dist=0.3, bias=0.002, power=1.0):
    """Per-loop ambient visibility in [0,1] (1 = open) for obj against bvh."""
    me = obj.data
    mw = obj.matrix_world
    nm = mw.to_3x3().inverted().transposed()
    dirs = hemi_dirs(rays)
    cn = me.corner_normals
    out = [1.0] * len(me.loops)
    cache = {}
    verts = me.vertices
    for li, loop in enumerate(me.loops):
        vi = loop.vertex_index
        nl = cn[li].vector
        key = (vi, round(nl.x, 2), round(nl.y, 2), round(nl.z, 2))
        val = cache.get(key)
        if val is None:
            p = mw @ verts[vi].co
            n = (nm @ nl).normalized()
            t = perp(n)
            b = n.cross(t)
            o = p + n * bias
            occ = 0.0
            for d in dirs:
                w = t * d.x + b * d.y + n * d.z
                hit = bvh.ray_cast(o, w, dist)
                if hit[0] is not None:
                    occ += (1.0 - hit[3] / dist) ** power
            val = 1.0 - occ / len(dirs)
            cache[key] = val
        out[li] = val
    return out


# ----------------------------------------------------------------------------
# painting
# ----------------------------------------------------------------------------

class PaintCtx:
    __slots__ = ("p", "n", "m", "pi", "vi", "li", "ao", "obj", "_tags", "lp")

    def tag(self, name, default=0.0):
        t = self._tags.get(name)
        return t[self.vi] if t is not None else default


def paint(obj, fn, ao=None):
    """fn(ctx) -> RGBA; ctx has p (world pos), lp (local pos), n (world corner normal),
    m (material name), pi, vi, li, ao, tag(name)."""
    me = obj.data
    if "Col" in me.color_attributes:
        attr = me.color_attributes["Col"]
    else:
        attr = me.color_attributes.new(name="Col", type="FLOAT_COLOR", domain="CORNER")
    me.color_attributes.active_color = attr
    try:
        me.color_attributes.render_color_index = me.color_attributes.find("Col")
    except Exception:
        pass
    mw = obj.matrix_world
    nm = mw.to_3x3().inverted().transposed()
    mats = [m.name if m else "" for m in me.materials]
    tags = {}
    for a in me.attributes:
        if a.name.startswith("tag_") and a.domain == "POINT":
            vals = [0.0] * len(me.vertices)
            a.data.foreach_get("value", vals)
            tags[a.name[4:]] = vals
    cn = me.corner_normals
    ctx = PaintCtx()
    ctx.obj = obj
    ctx._tags = tags
    cols = [0.0] * (len(me.loops) * 4)
    loops = me.loops
    verts = me.vertices
    for poly in me.polygons:
        ctx.m = mats[poly.material_index] if mats else ""
        ctx.pi = poly.index
        for li in poly.loop_indices:
            vi = loops[li].vertex_index
            ctx.vi = vi
            ctx.li = li
            ctx.lp = verts[vi].co
            ctx.p = mw @ verts[vi].co
            ctx.n = (nm @ cn[li].vector).normalized()
            ctx.ao = ao[li] if ao is not None else 1.0
            c = fn(ctx)
            cols[li * 4:li * 4 + 4] = (c[0], c[1], c[2], 1.0)
    attr.data.foreach_set("color", cols)


# ----------------------------------------------------------------------------
# objects
# ----------------------------------------------------------------------------

def make_obj(name, bm, mats, smooth=None):
    """bmesh -> object (keeps per-face smooth flags set by builders)."""
    me = bpy.data.meshes.new(name)
    bm.normal_update()
    bm.to_mesh(me)
    bm.free()
    obj = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(obj)
    for m in mats:
        me.materials.append(material(m) if isinstance(m, str) else m)
    if smooth is not None:
        for p in me.polygons:
            p.use_smooth = smooth
    me.update()
    return obj


def origin_to_bbox_center(obj):
    bb = [obj.matrix_world @ V(c) for c in obj.bound_box]
    mn = V((min(v.x for v in bb), min(v.y for v in bb), min(v.z for v in bb)))
    mx = V((max(v.x for v in bb), max(v.y for v in bb), max(v.z for v in bb)))
    set_origin(obj, (mn + mx) / 2)
    return (mn + mx) / 2


def center_item(obj):
    """Move geometry so its bbox centre sits at the object origin, object at world 0."""
    c = origin_to_bbox_center(obj)
    obj.location = (0, 0, 0)
    return c


def weighted_normals(obj, weight=50, keep_sharp=True):
    select_only(obj)
    mod = obj.modifiers.new("wn", "WEIGHTED_NORMAL")
    mod.mode = "FACE_AREA"
    mod.weight = weight
    mod.keep_sharp = keep_sharp
    bpy.ops.object.modifier_apply(modifier=mod.name)


def tri_count(obj):
    return sum(len(p.vertices) - 2 for p in obj.data.polygons)


# ----------------------------------------------------------------------------
# glb inspection
# ----------------------------------------------------------------------------

def glb_json(path):
    with open(path, "rb") as f:
        data = f.read()
    magic, ver, length = struct.unpack_from("<4sII", data, 0)
    clen, ctype = struct.unpack_from("<I4s", data, 12)
    return json.loads(data[20:20 + clen].decode("utf-8"))


def glb_summary(path):
    js = glb_json(path)
    nodes = js.get("nodes", [])
    meshes = js.get("meshes", [])
    acc = js.get("accessors", [])
    mats = js.get("materials", [])
    rows = []
    total = 0
    for nd in nodes:
        tris = 0
        mnames = []
        attrs = set()
        if "mesh" in nd:
            for prim in meshes[nd["mesh"]]["primitives"]:
                tris += acc[prim["indices"]]["count"] // 3
                if "material" in prim:
                    mnames.append(mats[prim["material"]]["name"])
                attrs |= set(prim["attributes"].keys())
        total += tris
        rows.append(dict(name=nd.get("name"), t=[round(x, 4) for x in nd.get("translation", [0, 0, 0])],
                         r=nd.get("rotation"), s=nd.get("scale"), children=nd.get("children", []),
                         tris=tris, mats=mnames, attrs=sorted(attrs)))
    scenes = js.get("scenes", [{}])
    roots = scenes[0].get("nodes", [])
    return dict(nodes=rows, total=total, roots=[nodes[i].get("name") for i in roots])


def export(path, objs, quiet=False):
    for o in objs:
        strip_tags(o)
    full = export_glb(path, objs)
    info = glb_summary(full)
    if not quiet:
        print(f"[glb] {path}: {info['total']} tris, roots={info['roots']}")
        for r in info["nodes"]:
            print(f"   - {r['name']}: t={r['t']} tris={r['tris']} mats={r['mats']} attrs={r['attrs']}")
    return info


# ----------------------------------------------------------------------------
# previews
# ----------------------------------------------------------------------------

def preview(name, objs, **kw):
    """render_preview showing only `objs` (other meshes hidden from render)."""
    scene = bpy.context.scene
    bpy.context.view_layer.update()
    show = set(o.name for o in objs)
    hidden = []
    for o in scene.objects:
        if o.type in ("MESH", "FONT", "CURVE") and o.name not in show and not o.hide_render:
            o.hide_render = True
            hidden.append(o)
    try:
        return render_preview(name, objs=objs, **kw)
    finally:
        for o in hidden:
            o.hide_render = False


def label(text, loc, size=0.08, rot_z=0.0):
    cu = bpy.data.curves.new("lbl_" + text, "FONT")
    cu.body = text
    cu.size = size
    cu.align_x = "CENTER"
    ob = bpy.data.objects.new("lbl_" + text, cu)
    ob.location = loc
    ob.rotation_euler = (math.radians(60), 0, rot_z)
    bpy.context.scene.collection.objects.link(ob)
    m = bpy.data.materials.get("LabelMat") or bpy.data.materials.new("LabelMat")
    m.use_nodes = True
    m.node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value = (0.02, 0.02, 0.03, 1)
    cu.materials.append(m)
    return ob


def contact_sheet(name, objs, cols=4, cell=1.0, fill=0.85, size=(1200, 900), elev=42, azim=20,
                  samples=20, labels=True, dist_mul=2.3):
    """Lay copies of `objs` out on a grid (each scaled to fit a cell) and render."""
    made = []
    rows = (len(objs) + cols - 1) // cols
    for i, o in enumerate(objs):
        cpy = o.copy()
        cpy.data = o.data
        bpy.context.scene.collection.objects.link(cpy)
        bb = [V(c) for c in o.bound_box]
        mn = V((min(v.x for v in bb), min(v.y for v in bb), min(v.z for v in bb)))
        mx = V((max(v.x for v in bb), max(v.y for v in bb), max(v.z for v in bb)))
        ext = max(mx.x - mn.x, mx.y - mn.y, (mx.z - mn.z) * 1.4)
        s = cell * fill / max(ext, 1e-4)
        r, c = divmod(i, cols)
        cx = (c - (cols - 1) / 2) * cell
        cy = ((rows - 1) / 2 - r) * cell * 1.05
        cen = (mn + mx) / 2
        cpy.scale = (s, s, s)
        cpy.rotation_euler = (0, 0, 0)
        cpy.location = V((cx, cy, 0)) - V((cen.x, cen.y, mn.z)) * s
        made.append(cpy)
        if labels:
            made.append(label(o.name, (cx, cy - cell * 0.47, 0.0), size=cell * 0.075))
    bpy.context.view_layer.update()
    # hide originals
    for o in objs:
        o.hide_render = True
    try:
        kw = dict(elev=elev, azim=azim, size=size, samples=samples)
        if dist_mul:
            kw["dist_mul"] = dist_mul
        out = preview(name, made, **kw)
    finally:
        for o in objs:
            o.hide_render = False
        for o in made:
            bpy.data.objects.remove(o, do_unlink=True)
    return out


# ----------------------------------------------------------------------------
# shared surface colouring
# ----------------------------------------------------------------------------

def ao_shade(ao, strength=0.75, floor=0.0):
    """Map baked visibility to a multiplier."""
    return max(floor, 1.0 - strength * (1.0 - ao))


def hash01(x):
    v = math.sin(x * 12.9898 + 78.233) * 43758.5453
    return v - math.floor(v)


def bark_color(ctx, seed=0.0, axis_u=None, shade=1.0):
    """Bark: per-column fissures along the rod (tags u/len/a), lighter ridges, lichen spots."""
    u = ctx.tag("u") * ctx.tag("len", 1.0)
    a = ctx.tag("a")
    ang = a * TAU
    ca, sa = math.cos(ang), math.sin(ang)
    colh = hash01(round(a * 720.0) + seed * 3.1)           # stable per profile column
    fiss = smoothstep(0.55, 0.9, colh) * (0.6 + 0.4 * nz(V((u * 3.0, colh * 5.0, seed)), 1.0, 1))
    blot = nz(V((ca * 1.5 + seed, sa * 1.5, u * 1.6)), 1.0, 2)
    c = mix(col("bark"), col("bark_light"), clamp(0.35 + 0.45 * blot))
    c = mix(c, col("bark_dark"), clamp(0.75 * fiss + 0.15))
    lich = nz(V((ca * 2.5 + 7.0 + seed, sa * 2.5, u * 4.0)), 1.0, 1)
    if lich > 0.48:
        c = mix(c, col("#A3AC80"), min(0.6, (lich - 0.48) * 2.4))
    c = sc(c, 0.9 + 0.14 * max(0.0, ctx.n.z))
    return sc(c, shade)


def wood_end_color(ctx, rel_r, seed=0.0):
    """Cut end: pale wood with growth rings, darker bark-adjacent rim and pith."""
    rings = 0.5 + 0.5 * math.sin(rel_r * 26.0 + nz(ctx.p * 40.0 + V((seed, 0, 0)), 1.0, 1) * 1.5)
    c = mix(col("wood_end"), col("wood_ring"), 0.45 * rings)
    c = mix(c, col("wood_dark"), smoothstep(0.75, 1.0, rel_r) * 0.6)
    c = mix(c, col("wood_ring"), (1.0 - smoothstep(0.0, 0.12, rel_r)) * 0.6)
    return c


def plank_color(ctx, seed=0.0, base=None):
    """Hewn plank wood: streaky grain along the board, per-board tint, darker edges."""
    k = ctx.tag("k")
    base = base or mix(col("wood"), col("#B89A78"), 0.5 * k)
    if k > 0.7:
        base = mix(base, col("#A89C88"), 0.35)            # a weathered, greyer board
    u = ctx.tag("u") * ctx.tag("len", 2.0)
    w = ctx.tag("w")
    g = nz(V((u * 0.9 + seed + k * 7.0, w * 16.0, seed * 2.0)), 1.0, 3)
    c = mix(base, col("wood_dark"), clamp(0.3 + 0.5 * g))
    streak = nz(V((u * 3.5 + k * 3.0, w * 30.0, 1.7)), 1.0, 1)
    c = mix(c, col("wood_end"), 0.25 * clamp(streak))
    # knots
    kn = nz(V((u * 2.2 + k * 11.0, w * 6.0, 4.4)), 1.0, 1)
    if kn > 0.62:
        c = mix(c, col("#6E5038"), min(0.7, (kn - 0.62) * 3.0))
    # edges and undersides darker
    upness = ctx.n.z
    c = sc(c, 0.86 + 0.14 * clamp(upness))
    return c


# ----------------------------------------------------------------------------
# shared builders (used by items and building pieces)
# ----------------------------------------------------------------------------

def rod_path(p0, p1, n=8, wobble=0.01, bend=0.0, bend_dir=None, seed=0):
    """Gently wobbly polyline from p0 to p1."""
    p0, p1 = V(p0), V(p1)
    d = p1 - p0
    side = perp(d.normalized()) if bend_dir is None else V(bend_dir).normalized()
    side2 = d.normalized().cross(side)
    pts = []
    for i in range(n):
        t = i / (n - 1)
        q = p0 + d * t
        q += side * (bend * math.sin(math.pi * t))
        if 0 < i < n - 1:
            q += side * wobble * nz(V((t * 3.0, seed * 1.3, 0.5)), 1.0, 1)
            q += side2 * wobble * nz(V((t * 3.0, seed * 1.3, 4.5)), 1.0, 1)
        pts.append(q)
    return pts


def wood_rod(bm, pts, r0, r1=None, seg=8, seed=0, bark_mat=0, end_mat=1, noise_amp=0.07,
             end_bevel=0.22, cap_inner=1, end0="cut", end1="cut", taper_pow=1.0, up=None,
             radii=None, length_tag=True):
    """Bark-covered rod along `pts` with bevelled flat cut ends (WoodEnd).

    end0/end1: 'cut' (flat bevelled WoodEnd), 'round' (bark tip), 'point' (twig tip),
    'open'.
    """
    pts = [V(p) for p in pts]
    r1 = r0 if r1 is None else r1
    N = len(pts)
    acc = [0.0]
    for i in range(1, N):
        acc.append(acc[-1] + (pts[i] - pts[i - 1]).length)
    L = acc[-1]
    if radii is None:
        radii = [lerp(r0, r1, (acc[i] / L) ** taper_pow) for i in range(N)]
    # bevel rings at cut ends: shrink the end ring and pull it in a touch
    profs = []
    cen = list(pts)
    frames = path_frames(cen, up=up)
    for i in range(N):
        profs.append(prof_ellipse(radii[i], radii[i], seg, phase=seed * 0.37))
    # add bevel rings
    if end0 == "cut":
        t = frames[0][0]
        cen.insert(0, pts[0] - t * radii[0] * 0.18)
        profs.insert(0, prof_ellipse(radii[0] * (1 - end_bevel), radii[0] * (1 - end_bevel), seg, phase=seed * 0.37))
        frames.insert(0, frames[0])
    if end1 == "cut":
        t = frames[-1][0]
        cen.append(pts[-1] + t * radii[-1] * 0.18)
        profs.append(prof_ellipse(radii[-1] * (1 - end_bevel), radii[-1] * (1 - end_bevel), seg, phase=seed * 0.37))
        frames.append(frames[-1])
    cap0 = {"cut": "flat", "round": "round", "point": "point", "open": "open"}[end0]
    cap1 = {"cut": "flat", "round": "round", "point": "point", "open": "open"}[end1]
    res = sweep(bm, cen, profs, frames=frames, cap0=cap0, cap1=cap1,
                len0=(radii[0] * 2.5 if end0 == "point" else radii[0] * 0.9 if end0 == "round" else 0.0),
                len1=(radii[-1] * 2.5 if end1 == "point" else radii[-1] * 0.9 if end1 == "round" else 0.0),
                cap_rings=1, mat=bark_mat,
                cap_mat0=end_mat if end0 == "cut" else bark_mat,
                cap_mat1=end_mat if end1 == "cut" else bark_mat,
                rnoise=(noise_amp, 9.0 / max(r0, 0.01) * 0.02, seed) if noise_amp else None,
                cap_inner=cap_inner)
    for f in res["cap0"] + res["cap1"]:
        if f.material_index == end_mat:
            f.smooth = False
    if length_tag:
        tag(bm, faces_verts(res["side"] + res["cap0"] + res["cap1"]), "len", L)
    # tag rel radius on cap verts for ring painting
    for capf, c in ((res["cap0"], cen[0]), (res["cap1"], cen[-1])):
        if not capf:
            continue
        vs = faces_verts(capf)
        cc = V((0, 0, 0))
        rim = res["rings"][0] if capf is res["cap0"] else res["rings"][-1]
        for v in rim:
            cc += v.co
        cc /= len(rim)
        rmax = max((v.co - cc).length for v in rim) or 1.0
        tag(bm, vs, "rr", lambda v, cc=cc, rmax=rmax: (v.co - cc).length / rmax)
    return res


def plank(bm, p0, p1, width, thick, up=(0, 0, 1), seed=0, mat=0, end_mat=None, rings=8,
          wobble=0.006, width_var=0.08, corner=0.35, m=2):
    """Rough-hewn board from p0 to p1 (centre line), `width` across, `thick` along up.
    10-point profile: chamfered corners plus a crowned centre line on both faces."""
    p0, p1 = V(p0), V(p1)
    pts = []
    profs = []
    d = p1 - p0
    L = d.length
    upv = V(up).normalized()
    side = d.normalized().cross(upv).normalized()
    for i in range(rings):
        t = i / (rings - 1)
        q = p0 + d * t
        q += side * wobble * nz(V((t * 2.5, seed * 0.7, 0.3)), 1.0, 1)
        q += upv * wobble * 0.4 * nz(V((t * 2.0, seed * 0.7, 3.3)), 1.0, 1)
        pts.append(q)
        w = width * (1.0 + width_var * nz(V((t * 3.0, seed * 1.9, 7.1)), 1.0, 1))
        th = thick * (1.0 + 0.12 * nz(V((t * 3.0, seed * 1.9, 9.7)), 1.0, 1))
        hn, hb = th / 2, w / 2
        r = min(hn, hb) * corner * 2
        sk = 0.15 * th * nz(V((t * 4.0, seed, 2.2)), 1.0, 1)          # slightly twisted / skewed
        crown = 0.08 * th * (1.0 + 0.5 * nz(V((t * 3.0, seed, 5.5)), 1.0, 1))
        off = 0.1 * hb * nz(V((t * 5.0, seed, 8.8)), 1.0, 1)           # wandering ridge line
        pr = [(hn, hb - r), (hn - r, hb), (-hn + r, hb), (-hn, hb - r), (-hn - crown * 0.3, off),
              (-hn, -hb + r), (-hn + r, -hb), (hn - r, -hb), (hn, -hb + r), (hn + crown, off)]
        pr = [(x + sk * (y / hb) * 0.5, y) for x, y in pr]
        profs.append(pr)
    frames = path_frames_up(pts, upv)
    res = sweep(bm, pts, profs, frames=frames, cap0="flat", cap1="flat", mat=mat,
                cap_mat0=end_mat, cap_mat1=end_mat, smooth=True)
    vs = faces_verts(res["side"] + res["cap0"] + res["cap1"])
    tag(bm, vs, "len", L)
    tag(bm, vs, "w", lambda v: (v.co - p0).dot(side))
    tag(bm, vs, "k", hash01(seed * 1.37 + 0.5))
    for capf in (res["cap0"], res["cap1"]):
        cvs = faces_verts(capf)
        cc = V((0, 0, 0))
        for v in cvs:
            cc += v.co
        cc /= len(cvs)
        rmax = max((v.co - cc).length for v in cvs) or 1.0
        tag(bm, cvs, "rr", lambda v, cc=cc, rmax=rmax: (v.co - cc).length / rmax)
    for f in res["cap0"] + res["cap1"]:
        f.smooth = False
    return res


def rope_path_tube(bm, pts, r, seg=5, mat=0, closed=False, flat=1.0, twist_rate=60.0,
                   cap="round", up=None, lobes=True):
    """Rope along a path.  A slightly flattened, twisting two-lobed cross-section reads
    as two-ply twisted cordage.  Tags: 'u' along path, 'tw' twist phase for painting."""
    pts = [V(p) for p in pts]
    N = len(pts)
    acc = [0.0]
    for i in range(1, N + (1 if closed else 0)):
        acc.append(acc[-1] + (pts[i % N] - pts[i - 1]).length)
    profs = []
    for i in range(N):
        ph = acc[i] * twist_rate
        pr = []
        for s in range(seg):
            a = TAU * s / seg
            rr = r * (1.0 + (0.16 * math.cos(2 * (a - ph)) if lobes else 0.0))
            pr.append((math.cos(a) * rr * flat, math.sin(a) * rr))
        profs.append(pr)
    res = sweep(bm, pts, profs, up=up, closed=closed, cap0=cap, cap1=cap,
                len0=r * 0.9, len1=r * 0.9, cap_rings=1, mat=mat)
    total = acc[-1] if acc[-1] > 0 else 1.0
    tag(bm, faces_verts(res["side"] + res["cap0"] + res["cap1"]), "len", total)
    # twist phase per vertex (angle + arc length) for stripe painting
    lay = tag_layer(bm, "tw")
    for k, ring in enumerate(res["rings"]):
        u = res["ring_u"][k] * total
        for s, v in enumerate(ring):
            a = TAU * s / len(ring)
            v[lay] = math.cos(2 * (a - u * twist_rate))
    return res


def rope_color(ctx, base=None, dark=0.62):
    base = base or col("rope")
    tw = ctx.tag("tw")
    f = lerp(dark, 1.06, 0.5 + 0.5 * tw)
    f *= 1.0 + 0.06 * nz(ctx.p * 60.0, 1.0, 1)
    return sc(base, f)


def helix_points(center, axis, radius, turns, pitch, n_per_turn=10, phase=0.0, start_offset=0.0,
                 radius_fn=None):
    """Helix around `axis` through center (rope wraps)."""
    center, axis = V(center), V(axis).normalized()
    u = perp(axis)
    w = axis.cross(u)
    n = max(3, int(n_per_turn * turns) + 1)
    pts = []
    for i in range(n):
        t = i / (n - 1)
        a = phase + TAU * turns * t
        rr = radius_fn(t, a) if radius_fn else radius
        pts.append(center + axis * (start_offset + pitch * turns * t) + (u * math.cos(a) + w * math.sin(a)) * rr)
    return pts


def wrap_rings(bm, center, axis, radius, count, spacing, rope_r, seg=4, n_around=10, mat=0, seed=0,
               squash=None):
    """`count` closed rope rings around an axis (a tidy binding)."""
    center, axis = V(center), V(axis).normalized()
    u = perp(axis)
    w = axis.cross(u)
    out = []
    for k in range(count):
        off = (k - (count - 1) / 2) * spacing
        pts = []
        for i in range(n_around):
            a = TAU * i / n_around + seed * 0.7 + k * 0.4
            rr = radius * (1.0 + 0.04 * math.sin(a * 3 + seed))
            if squash:
                pass
            pts.append(center + axis * (off + 0.15 * spacing * math.sin(a + k)) + (u * math.cos(a) + w * math.sin(a)) * rr)
        res = rope_path_tube(bm, pts, rope_r, seg=seg, mat=mat, closed=True, twist_rate=90.0)
        out.append(res)
    return out


# ----------------------------------------------------------------------------
# item pipeline
# ----------------------------------------------------------------------------

def wood_painter(seed=0.0, ao_s=0.8, extra=None):
    """Bark / WoodEnd / Wood / Leaves / Rope painter used by wood-ish items and building pieces."""
    def fn(c):
        if extra is not None:
            r = extra(c)
            if r is not None:
                return r
        a = ao_shade(c.ao, ao_s)
        m = c.m
        if m == "WoodEnd":
            return sc(wood_end_color(c, c.tag("rr"), seed), a)
        if m == "Bark":
            return sc(bark_color(c, seed), a)
        if m == "Wood":
            return sc(plank_color(c, seed), a)
        if m == "Rope":
            return sc(rope_color(c), a)
        if m == "Leaves":
            return sc(leaf_color(c, seed), a)
        if m == "Charcoal":
            return sc(charcoal_color(c, seed), a)
        return sc(grey(0.5), a)
    return fn


def leaf_color(c, seed=0.0, base=None):
    t = 0.5 + 0.5 * nz(c.p * 6.0 + V((seed, 0, 0)), 1.0, 2)
    cc = mix(col("leaf_dark"), col("leaf"), t)
    cc = mix(cc, col("leaf_light"), clamp(0.6 * c.n.z) * 0.6)
    w = nz(c.p * 13.0 + V((0, seed, 3)), 1.0, 1)
    if w > 0.45:
        cc = mix(cc, col("leaf_warm"), (w - 0.45) * 1.2)
    return cc


def charcoal_color(c, seed=0.0):
    t = 0.5 + 0.5 * nz(c.p * 40.0 + V((seed, 0, 0)), 1.0, 2)
    cc = mix(col("charcoal"), col("#4A4744"), 0.45 * t)
    # silvery sheen on ridges facing up
    cc = mix(cc, col("#6E6C6A"), 0.25 * clamp(c.n.z) * t)
    return cc


def finish_item(obj, painter, ao_dist=0.05, rays=30, center=True):
    bvh = bvh_of([obj])
    ao = bake_ao(obj, bvh, rays=rays, dist=ao_dist)
    paint(obj, painter, ao=ao)
    if center:
        center_item(obj)
    return obj


def run_items(registry, args, sheet, cols=4, limit=800):
    """registry: dict name -> fn() returning (obj, painter, ao_dist).  Exports items/<name>.glb."""
    reset()
    built = []
    report = []
    only = [a for a in args if a in registry]
    for name, fn in registry.items():
        if only and name not in only:
            continue
        obj, painter, ao_dist = fn()
        obj.name = name
        obj.data.name = name
        finish_item(obj, painter, ao_dist=ao_dist)
        n = tri_count(obj)
        dims = obj.dimensions
        report.append((name, n, tuple(round(d, 3) for d in dims)))
        flag = "  <-- OVER BUDGET" if n > limit else ""
        print(f"[item] {name:18s} tris={n:4d} dims={tuple(round(d, 3) for d in dims)}{flag}")
        export(f"items/{name}.glb", [obj], quiet=True)
        built.append(obj)
    if built and "nopreview" not in args:
        contact_sheet(sheet, built, cols=cols, size=(1280, 960) if len(built) > 4 else (960, 540))
        if "close" in args:
            for o in built:
                dm = 3.4 if max(o.dimensions) > 4 * sorted(o.dimensions)[1] else 2.4
                preview(f"{sheet}_{o.name}", [o], elev=35, azim=25, size=(640, 480), samples=20, dist_mul=dm)
    return built, report


def leaf_mesh(bm, base, direction, up, length, width, thick=0.0015, rings=2, curl=0.0, droop=0.0,
              fold=0.25, mat=0, tip_round=0.0, twist=0.0, petiole=0.0, asym=(1.0, 1.0), smooth6=False):
    """A small closed leaf: `rings` interior diamond cross-sections between a pointed base and
    tip (8 tris per ring).  `up` is the upper-surface normal; curl bends it, droop sags it."""
    base, d, u = V(base), V(direction).normalized(), V(up).normalized()
    u = (u - d * u.dot(d)).normalized()

    def centre(t):
        ang = curl * t
        dd = d * math.cos(ang) - u * math.sin(ang)
        return base + dd * length * t - u * droop * length * t * t
    pts, profs = [], []
    for i in range(1, rings + 1):
        t = i / (rings + 1)
        t = 0.42 if rings == 1 else t
        pts.append(centre(t))
        w = width * (math.sin(math.pi * t ** 0.75) ** 0.9)
        h = thick * (1.0 - 0.4 * t)
        lo, hi = -w * asym[0], w * asym[1]
        if smooth6:
            # cupped: midrib low, blade rising toward the edges (upper surface concave)
            profs.append([(h - fold * w * 0.15, 0.0), (h + fold * w * 0.35, hi * 0.55), (fold * w * 0.5, hi),
                          (-h * 0.6, 0.0), (fold * w * 0.5, lo), (h + fold * w * 0.35, lo * 0.55)][::1])
            profs[-1] = [profs[-1][0], profs[-1][1], profs[-1][2], profs[-1][3], profs[-1][4], profs[-1][5]]
        else:
            profs.append([(h, (lo + hi) * 0.5 * 0.0), (fold * w * 0.5, hi), (-h, 0.0), (fold * w * 0.5, lo)])
    if len(pts) == 1:
        tan = (centre(0.6) - centre(0.25)).normalized()
        frames = [(tan, (u - tan * u.dot(tan)).normalized(), tan.cross((u - tan * u.dot(tan)).normalized()))]
    else:
        frames = path_frames_up(pts, u)
    return sweep(bm, pts, profs, frames=frames, cap0="point", cap1="point", pole0=centre(0.0),
                 pole1=centre(1.0), mat=mat)


def blade_mesh(bm, base, direction, length, width, up=(0, 0, 1), droop=0.15, rings=4, thick=0.0012,
               mat=0, twist=0.0, fold=0.35, taper=1.0, tip=True):
    """Grass / straw blade (closed thin diamond profile) tapering to a point."""
    base, d = V(base), V(direction).normalized()
    u = V(up)
    u = (u - d * u.dot(d))
    if u.length < 1e-6:
        u = perp(d)
    u.normalize()
    pts, profs = [], []
    n = rings + 1
    for i in range(n):
        t = i / (n - 1)
        q = base + d * length * t - u * droop * length * t * t
        pts.append(q)
        w = width * (1.0 - t ** 1.6 * 0.92) ** taper
        h = thick
        profs.append([(h, 0.0), (fold * w, w), (-h, 0.0), (fold * w, -w)])
    frames = path_frames_up(pts, u)
    if twist:
        frames = [(t_, (n_ * math.cos(twist * k) + b_ * math.sin(twist * k)).normalized(),
                   (b_ * math.cos(twist * k) - n_ * math.sin(twist * k)).normalized()) for k, (t_, n_, b_) in enumerate(frames)]
    return sweep(bm, pts, profs, frames=frames, cap0="flat", cap1="point" if tip else "flat",
                 len1=0.0, mat=mat)


def foliage_clump(bm, center, radius, seed=0, mat=0, leaves=7, blob=False, leaf_len=None, up_bias=0.35,
                  leaf_rings=2):
    """A cluster of individual leaves fanned round `center` (plus an optional small inner blob)."""
    center = V(center)
    rng = random.Random(seed * 7 + 3)
    ll = leaf_len or radius * 0.95
    if blob:
        ico(bm, center, radius * 0.45, subdiv=1, squash=(1.1, 1.0, 0.85), noise_amp=0.15, noise_scale=1.6,
            seed=seed, mat=mat)
    golden = math.pi * (3 - math.sqrt(5))
    for i in range(leaves):
        a = i * golden + rng.uniform(-0.3, 0.3)
        el = lerp(-0.25, 0.85, (i + 0.5) / leaves) * 0.8 + up_bias * 0.3 + rng.uniform(-0.15, 0.15)
        d = V((math.cos(a) * math.cos(el), math.sin(a) * math.cos(el), math.sin(el))).normalized()
        base = center + d * radius * 0.08
        upv = V((0, 0, 1)) - d * d.z
        if upv.length < 1e-3:
            upv = V((1, 0, 0))
        L = ll * rng.uniform(0.8, 1.1)
        leaf_mesh(bm, base, d, upv, L, L * rng.uniform(0.36, 0.44), thick=max(0.0015, L * 0.03),
                  rings=leaf_rings, curl=rng.uniform(-0.2, 0.5), droop=rng.uniform(0.05, 0.2), fold=0.25, mat=mat)
