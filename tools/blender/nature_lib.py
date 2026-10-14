"""Helpers for Skyroot's nature models (trees, rocks, plants).

Builds on common.py (palette, tube/blob/paint/export/preview).  Adds:
  * tube_ex()      tubes with per-ring segment counts, radius modulation, flattening
  * Clump          displaced foliage blobs with an analytic inside() test (hidden-face culling)
  * bake_ao()      ray-cast ambient occlusion per vertex across several objects (+ ground plane)
  * paint_ex()     vertex painting with vertex index available (AO lookup, per-face colour)
  * cavity()       convex/concave measure per vertex (edge highlights, crevice darkening)
  * blade()/strip  thin double-sided leaf / grass geometry
  * rock_bm()      faceted "polytope" boulder shapes
  * preview()      Cycles previews with the ground at z=0 (embedded props read correctly)
"""
import sys
import os
import math
import random
import colorsys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import bpy
import bmesh
from mathutils import Vector, Matrix, noise
from mathutils.bvhtree import BVHTree

import common as C
from common import (pal, hexcol, lerp_col, mul_col, reset, material, new_object, select_only,
                    smooth_by_angle, flat, triangle_count, nz, bezier_points, export_glb,
                    render_preview, srgb_to_lin)

V = Vector
UP = Vector((0, 0, 1))


# ----------------------------------------------------------------------------
# math / colour
# ----------------------------------------------------------------------------

def clamp(x, a=0.0, b=1.0):
    return a if x < a else b if x > b else x


def smoothstep(e0, e1, x):
    t = clamp((x - e0) / (e1 - e0)) if e1 != e0 else (1.0 if x >= e1 else 0.0)
    return t * t * (3.0 - 2.0 * t)


def lerp(a, b, t):
    return a + (b - a) * t


def lin_to_srgb(c):
    c = max(0.0, c)
    return 12.92 * c if c <= 0.0031308 else 1.055 * c ** (1 / 2.4) - 0.055


def shift(col, dh=0.0, ds=0.0, dv=0.0):
    """Hue/saturation/value shift of a linear colour (done in sRGB HSV)."""
    r, g, b = (lin_to_srgb(x) for x in col[:3])
    h, s, v = colorsys.rgb_to_hsv(min(r, 1), min(g, 1), min(b, 1))
    h = (h + dh) % 1.0
    s = clamp(s * (1.0 + ds))
    v = clamp(v * (1.0 + dv))
    r, g, b = colorsys.hsv_to_rgb(h, s, v)
    return (srgb_to_lin(r), srgb_to_lin(g), srgb_to_lin(b), 1.0)


def mix(a, b, t):
    return lerp_col(a, b, clamp(t))


def scale_col(c, f):
    return (c[0] * f, c[1] * f, c[2] * f, 1.0)


def nvec(p, scale=1.0, seed=0):
    off = Vector((seed * 7.31, seed * 3.17, seed * 5.53))
    return noise.noise_vector(Vector(p) * scale + off, noise_basis="PERLIN_ORIGINAL")


def n1(p, scale=1.0, seed=0, octaves=2):
    off = Vector((seed * 4.13, seed * 9.71, seed * 2.37))
    return nz(Vector(p) * scale + off, 1.0, octaves)


def wobble(pts, amp, scale=1.0, seed=0, fix_start=1, ramp=True):
    """Perturb a polyline with smooth noise; first `fix_start` points stay put."""
    out = []
    n = len(pts)
    for i, p in enumerate(pts):
        p = Vector(p)
        if i < fix_start:
            out.append(p)
            continue
        w = (i / max(1, n - 1)) if ramp else 1.0
        out.append(p + nvec(p, scale, seed) * amp * w)
    return out


def rot_about(vec, axis, ang):
    return Matrix.Rotation(ang, 3, Vector(axis).normalized()) @ Vector(vec)


def polyline_length(pts):
    return sum((Vector(pts[i + 1]) - Vector(pts[i])).length for i in range(len(pts) - 1))


def resample(pts, n):
    """Resample polyline to n points evenly by arc length."""
    pts = [Vector(p) for p in pts]
    d = [0.0]
    for i in range(1, len(pts)):
        d.append(d[-1] + (pts[i] - pts[i - 1]).length)
    L = d[-1]
    out = []
    j = 0
    for k in range(n):
        s = L * k / (n - 1)
        while j < len(pts) - 2 and d[j + 1] < s:
            j += 1
        seg = d[j + 1] - d[j]
        t = 0.0 if seg < 1e-9 else (s - d[j]) / seg
        out.append(pts[j].lerp(pts[j + 1], clamp(t)))
    return out


def point_at(pts, t):
    """Point and tangent at fraction t (0..1) along polyline by arc length."""
    pts = [Vector(p) for p in pts]
    d = [0.0]
    for i in range(1, len(pts)):
        d.append(d[-1] + (pts[i] - pts[i - 1]).length)
    s = d[-1] * clamp(t)
    for i in range(len(pts) - 1):
        if d[i + 1] >= s or i == len(pts) - 2:
            seg = d[i + 1] - d[i]
            u = 0.0 if seg < 1e-9 else (s - d[i]) / seg
            return pts[i].lerp(pts[i + 1], clamp(u)), (pts[i + 1] - pts[i]).normalized()
    return pts[-1], (pts[-1] - pts[-2]).normalized()


# ----------------------------------------------------------------------------
# tubes
# ----------------------------------------------------------------------------

def bridge_rings(bm, A, B):
    """Connect two vertex rings (possibly different counts) with faces (outward winding)."""
    n, m = len(A), len(B)
    faces = []
    if n == m:
        for s in range(n):
            s2 = (s + 1) % n
            faces.append(bm.faces.new((A[s], A[s2], B[s2], B[s])))
        return faces
    i = j = 0
    while i < n or j < m:
        ua = (i + 1) / n
        ub = (j + 1) / m
        if j >= m or (i < n and ua <= ub):
            faces.append(bm.faces.new((A[i % n], A[(i + 1) % n], B[j % m])))
            i += 1
        else:
            faces.append(bm.faces.new((A[i % n], B[(j + 1) % m], B[j % m])))
            j += 1
    return faces


def tube_ex(bm, pts, radii, segs=8, noise_amp=0.0, noise_scale=3.0, seed=0, rmod=None,
            cap_start=False, cap_end=True, tip_len=0.6, zflat=1.0, twist=0.0, mat=0,
            start_normal=None):
    """Tube along pts.  segs: int or per-point list.  rmod(i, p, d)->radius multiplier.

    Returns (rings, faces)."""
    pts = [Vector(p) for p in pts]
    nP = len(pts)
    seglist = list(segs) if isinstance(segs, (list, tuple)) else [segs] * nP
    off = Vector((seed * 13.1, seed * 7.7, seed * 3.3))
    rings = []
    prev_n = start_normal
    tangents = []
    for i, p in enumerate(pts):
        if i == 0:
            tan = pts[1] - pts[0]
        elif i == nP - 1:
            tan = pts[-1] - pts[-2]
        else:
            tan = (pts[i + 1] - pts[i]).normalized() + (pts[i] - pts[i - 1]).normalized()
        t, n, b = C._frame(tan, prev_n)
        tangents.append(t)
        prev_n = n
        ring = []
        sN = seglist[i]
        for s in range(sN):
            a = (s / sN) * math.tau + twist * i
            d = n * math.cos(a) + b * math.sin(a)
            rr = radii[i]
            if noise_amp > 0:
                rr *= 1.0 + noise_amp * nz(p * noise_scale + d * 0.7 + off)
            if rmod is not None:
                rr *= rmod(i, p, d)
            o = d * rr
            if zflat != 1.0:
                o.z *= zflat
            ring.append(bm.verts.new(p + o))
        rings.append(ring)
    faces = []
    for i in range(nP - 1):
        faces += bridge_rings(bm, rings[i], rings[i + 1])
    if cap_start:
        c = bm.verts.new(pts[0] - tangents[0] * radii[0] * 0.3)
        r = rings[0]
        for s in range(len(r)):
            faces.append(bm.faces.new((r[(s + 1) % len(r)], r[s], c)))
    if cap_end:
        c = bm.verts.new(pts[-1] + tangents[-1] * max(radii[-1], 0.002) * tip_len)
        r = rings[-1]
        for s in range(len(r)):
            faces.append(bm.faces.new((r[s], r[(s + 1) % len(r)], c)))
    for f in faces:
        f.material_index = mat
    return rings, faces


def taper(n, r0, r1, power=1.0):
    return [lerp(r0, r1, (i / (n - 1)) ** power) for i in range(n)]


# ----------------------------------------------------------------------------
# foliage clumps
# ----------------------------------------------------------------------------

def geo_sphere(freq):
    """Geodesic unit sphere: icosahedron with each edge split into `freq` parts (20*freq^2 tris)."""
    tmp = bmesh.new()
    bmesh.ops.create_icosphere(tmp, subdivisions=1, radius=1.0)
    if freq > 1:
        bmesh.ops.subdivide_edges(tmp, edges=tmp.edges[:], cuts=freq - 1, use_grid_fill=True)
        bmesh.ops.triangulate(tmp, faces=[f for f in tmp.faces if len(f.verts) > 3])
    for v in tmp.verts:
        v.co = v.co.normalized()
    return tmp


class Clump:
    """Displaced icosphere blob.  Keeps its parameters so inside() can be tested analytically."""

    def __init__(self, center, radius, squash=(1.0, 1.0, 0.85), amp=0.24, nscale=1.7, seed=0,
                 subdiv=2, flat_bottom=0.35, bottom_level=0.45, tint=None, freq=None, octaves=3):
        self.c = Vector(center)
        self.r = radius
        self.sq = Vector(squash)
        self.amp = amp
        self.ns = nscale
        self.seed = seed
        self.subdiv = subdiv
        self.fb = flat_bottom
        self.bl = bottom_level  # fraction of radius below centre where flattening starts
        self.off = Vector((seed * 5.3 + 11.0, seed * 2.1 - 3.0, seed * 8.7 + 1.0))
        self.tint = tint
        self.freq = freq
        self.oct = octaves
        self.faces = []

    def radial(self, d):
        return self.r * (1.0 + self.amp * nz(d * self.ns + self.off, 1.0, self.oct))

    def build(self, bm, mat=0):
        tmp = geo_sphere(self.freq) if self.freq else None
        if tmp is None:
            tmp = bmesh.new()
            bmesh.ops.create_icosphere(tmp, subdivisions=self.subdiv, radius=1.0)
        vmap = {}
        lvl = -self.bl * self.r * self.sq.z
        for v in tmp.verts:
            d = v.co.normalized()
            q = d * self.radial(d)
            q = Vector((q.x * self.sq.x, q.y * self.sq.y, q.z * self.sq.z))
            if self.fb > 0 and q.z < lvl:
                q.z = lvl + (q.z - lvl) * (1.0 - self.fb)
            vmap[v] = bm.verts.new(self.c + q)
        self.faces = []
        for f in tmp.faces:
            nf = bm.faces.new([vmap[v] for v in f.verts])
            nf.material_index = mat
            self.faces.append(nf)
        tmp.free()
        return self.faces

    def inside(self, p, margin=0.03):
        q = Vector(p) - self.c
        lvl = -self.bl * self.r * self.sq.z
        if self.fb > 0 and q.z < lvl:
            q.z = lvl + (q.z - lvl) / max(1e-3, (1.0 - self.fb))
        q = Vector((q.x / self.sq.x, q.y / self.sq.y, q.z / self.sq.z))
        L = q.length
        if L < 1e-6:
            return True
        return L < self.radial(q / L) - margin / max(1e-3, min(self.sq))


def build_clumps(bm, clumps, mat=0, cull=True, margin=0.03, layer="clump", index_offset=0):
    """Build clumps into bm and delete faces hidden inside other clumps of the same mesh.

    Each vertex gets its clump index (+index_offset) in float layer `layer` (for per-clump tint)."""
    lay = bm.verts.layers.float.get(layer) or bm.verts.layers.float.new(layer)
    for k, c in enumerate(clumps):
        c.build(bm, mat)
        for f in c.faces:
            for v in f.verts:
                v[lay] = float(k + index_offset)
    if not cull or len(clumps) < 2:
        return 0
    dead = []
    for i, c in enumerate(clumps):
        others = [o for j, o in enumerate(clumps) if j != i and (o.c - c.c).length < (o.r + c.r) * 1.6]
        if not others:
            continue
        for f in c.faces:
            for o in others:
                if all(o.inside(v.co, margin) for v in f.verts):
                    dead.append(f)
                    break
    if dead:
        bmesh.ops.delete(bm, geom=dead, context="FACES")
    return len(dead)


# ----------------------------------------------------------------------------
# thin geometry: blades, leaves
# ----------------------------------------------------------------------------

def strip(bm, pts, widths, sides, normals, fold=0.25, mat=0, tip=True):
    """Leaf/blade strip.  For each point: centre, half-width, side unit vector, face normal.

    Three columns (left, mid, right); mid lifted by fold*width along the normal (V-fold).
    If tip and last width ~0, ends in a single vertex.  Returns faces."""
    cols = []
    n = len(pts)
    for i in range(n):
        c, w, s, nn = Vector(pts[i]), widths[i], Vector(sides[i]), Vector(normals[i])
        if tip and i == n - 1 and w < 1e-4:
            v = bm.verts.new(c)
            cols.append((v, v, v))
        else:
            cols.append((bm.verts.new(c - s * w), bm.verts.new(c + nn * fold * w), bm.verts.new(c + s * w)))
    faces = []
    for i in range(n - 1):
        a, b = cols[i], cols[i + 1]
        if b[0] is b[1]:
            faces.append(bm.faces.new((a[0], a[1], b[1])))
            faces.append(bm.faces.new((a[1], a[2], b[1])))
        else:
            faces.append(bm.faces.new((a[0], a[1], b[1], b[0])))
            faces.append(bm.faces.new((a[1], a[2], b[2], b[1])))
    for f in faces:
        f.material_index = mat
    return faces


def blade(bm, base, direction, length, width, bend=0.4, bend_dir=None, segs=4, fold=0.3,
          twist=0.0, mat=0, width_profile=None, seed=0):
    """Grass/leaf blade from base along direction, bending toward bend_dir (gravity by default)."""
    base = Vector(base)
    d0 = Vector(direction).normalized()
    bd = Vector(bend_dir).normalized() if bend_dir is not None else Vector((0, 0, -1))
    pts, ws, sides, nors = [], [], [], []
    p = base.copy()
    d = d0.copy()
    side0 = d0.cross(UP)
    if side0.length < 1e-4:
        side0 = Vector((1, 0, 0))
    side0.normalize()
    step = length / segs
    for i in range(segs + 1):
        t = i / segs
        pts.append(p.copy())
        side = rot_about(side0, d, twist * t)
        side = (side - d * side.dot(d)).normalized()
        nrm = side.cross(d).normalized()
        if width_profile:
            w = width * width_profile(t)
        else:
            w = width * (1.0 - t ** 1.6) * (0.75 + 0.25 * math.sin(min(1.0, t * 1.4) * math.pi * 0.5 + 0.5))
        ws.append(w if i < segs else 0.0)
        sides.append(side)
        nors.append(nrm)
        d = (d + bd * bend * (1.0 / segs) * (0.5 + t)).normalized()
        p = p + d * step
    return strip(bm, pts, ws, sides, nors, fold=fold, mat=mat)


def leaf(bm, base, direction, length, width, droop=0.35, segs=5, fold=0.35, curl=0.0, mat=0,
         petiole=0.0, tip_round=0.6):
    """Broad leaf: optional petiole tube length, then a blade with an ovate outline."""
    return blade(bm, base, direction, length, width, bend=droop, segs=segs, fold=fold, twist=curl,
                 mat=mat, width_profile=lambda t: (math.sin(math.pi * min(1.0, t ** 0.75)) ** tip_round)
                 if t < 1.0 else 0.0)


# ----------------------------------------------------------------------------
# rocks
# ----------------------------------------------------------------------------

def fib_dirs(n, rng, jitter=0.25):
    out = []
    ga = math.pi * (3.0 - math.sqrt(5.0))
    for k in range(n):
        z = 1.0 - 2.0 * (k + 0.5) / n
        r = math.sqrt(max(0.0, 1.0 - z * z))
        a = ga * k + rng.uniform(0, math.tau)
        v = Vector((r * math.cos(a), r * math.sin(a), z))
        v += Vector((rng.uniform(-1, 1), rng.uniform(-1, 1), rng.uniform(-1, 1))) * jitter
        out.append(v.normalized())
    return out


def rock_bm(bm, center, half, seed=0, subdiv=3, planes=11, depth=(0.72, 0.9), roundness=0.22,
            noise_amp=0.06, noise_scale=1.5, bottom=None, bottom_squash=0.25, top_clamp=None,
            mat=0, extra_planes=()):
    """Faceted boulder: intersection of random half-spaces softly blended with a sphere.

    half: half extents (x, y, z).  bottom: world z below which geometry is squashed flat.
    top_clamp: world z above which vertices are clamped flat."""
    rng = random.Random(seed)
    pl = [(n, rng.uniform(*depth)) for n in fib_dirs(planes, rng)]
    pl += list(extra_planes)
    off = Vector((seed * 3.1, seed * 5.7, seed * 1.9))
    tmp = bmesh.new()
    bmesh.ops.create_icosphere(tmp, subdivisions=subdiv, radius=1.0)
    vmap = {}
    center = Vector(center)
    for v in tmp.verts:
        d = v.co.normalized()
        r = 1.0
        for (n, dd) in pl:
            c = d.dot(n)
            if c > 1e-3:
                r = min(r, dd / c)
        r = lerp(r, 1.0, roundness * (1.0 - r) * 2.0) if r < 1.0 else r
        r *= 1.0 + noise_amp * nz(d * noise_scale + off, 1.0, 3)
        co = center + Vector((d.x * r * half[0], d.y * r * half[1], d.z * r * half[2]))
        if bottom is not None and co.z < bottom:
            co.z = bottom + (co.z - bottom) * bottom_squash
        if top_clamp is not None and co.z > top_clamp:
            co.z = top_clamp
        vmap[v] = bm.verts.new(co)
    faces = []
    for f in tmp.faces:
        nf = bm.faces.new([vmap[v] for v in f.verts])
        nf.material_index = mat
        faces.append(nf)
    tmp.free()
    return faces


def planar_dissolve(obj, angle_deg=5.0, delimit=("MATERIAL",)):
    select_only(obj)
    mod = obj.modifiers.new("dis", "DECIMATE")
    mod.decimate_type = "DISSOLVE"
    mod.angle_limit = math.radians(angle_deg)
    mod.delimit = set(delimit)
    bpy.ops.object.modifier_apply(modifier=mod.name)


def triangulate(obj):
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    bmesh.ops.triangulate(bm, faces=bm.faces[:], quad_method="BEAUTY", ngon_method="BEAUTY")
    bm.to_mesh(obj.data)
    bm.free()


def decimate_to(obj, target_tris):
    tris = triangle_count([obj])
    if tris <= target_tris:
        return tris
    select_only(obj)
    mod = obj.modifiers.new("dec", "DECIMATE")
    mod.ratio = max(0.05, target_tris / tris)
    mod.use_collapse_triangulate = True
    bpy.ops.object.modifier_apply(modifier=mod.name)
    return triangle_count([obj])


# ----------------------------------------------------------------------------
# AO / cavity / painting
# ----------------------------------------------------------------------------

def _radinv(k):
    f, r = 0.5, 0.0
    while k:
        r += f * (k & 1)
        k >>= 1
        f *= 0.5
    return r


def _hemi(n):
    out = []
    for k in range(n):
        u1 = (k + 0.5) / n
        u2 = _radinv(k + 1)
        r = math.sqrt(u1)
        phi = math.tau * u2
        out.append((r * math.cos(phi), r * math.sin(phi), math.sqrt(max(0.0, 1.0 - u1))))
    return out


def world_bvh(objs, ground=None, ceiling=None):
    verts, polys = [], []
    for o in objs:
        mw = o.matrix_world
        base = len(verts)
        verts.extend(mw @ v.co for v in o.data.vertices)
        polys.extend([base + i for i in p.vertices] for p in o.data.polygons)
    for z in (ground, ceiling):
        if z is not None:
            s = 60.0
            base = len(verts)
            verts.extend([Vector((-s, -s, z)), Vector((s, -s, z)), Vector((s, s, z)), Vector((-s, s, z))])
            polys.append([base, base + 1, base + 2, base + 3])
    return BVHTree.FromPolygons(verts, polys)


def bake_ao(objs, occluders=(), samples=24, dist=1.0, ground=0.0, ceiling=None, bias=0.004, seed=1):
    """Per-vertex ambient occlusion (1 = open sky) for each object in objs.

    occluders: extra objects that cast occlusion but are not baked."""
    bpy.context.view_layer.update()
    bvh = world_bvh(list(objs) + list(occluders), ground=ground, ceiling=ceiling)
    dirs = _hemi(samples)
    rng = random.Random(seed)
    out = {}
    for o in objs:
        mw = o.matrix_world
        nm = mw.to_3x3().inverted_safe().transposed()
        res = []
        for v in o.data.vertices:
            p = mw @ v.co
            n = nm @ v.normal
            if n.length < 1e-8:
                res.append(1.0)
                continue
            n.normalize()
            t = n.orthogonal().normalized()
            b = n.cross(t)
            a = rng.random() * math.tau
            ca, sa = math.cos(a), math.sin(a)
            t, b = t * ca + b * sa, b * ca - t * sa
            org = p + n * bias
            occ = 0.0
            for (dx, dy, dz) in dirs:
                hit = bvh.ray_cast(org, t * dx + b * dy + n * dz, dist)
                if hit[0] is not None:
                    occ += 1.0 - hit[3] / dist
            res.append(1.0 - occ / len(dirs))
        out[o.name] = res
    return out


def cavity(obj):
    """Per-vertex convexity (>0 convex ridge, <0 concave crevice), roughly in [-1, 1]."""
    me = obj.data
    nb = [[] for _ in me.vertices]
    for e in me.edges:
        a, b = e.vertices
        nb[a].append(b)
        nb[b].append(a)
    out = []
    vs = me.vertices
    for v in vs:
        ns = nb[v.index]
        if not ns:
            out.append(0.0)
            continue
        avg = Vector()
        el = 0.0
        for j in ns:
            avg += vs[j].co
            el += (vs[j].co - v.co).length
        avg /= len(ns)
        el /= len(ns)
        out.append(clamp((v.co - avg).dot(v.normal) / max(el, 1e-6) * 2.0, -1.0, 1.0))
    return out


PS = {"pn": Vector((0, 0, 1)), "pc": Vector()}


def paint_ex(obj, fn):
    """fn(vi, world_pos, world_normal, material_name, poly_index) -> linear RGBA.

    The polygon's world normal / centre are available to fn as PS["pn"] / PS["pc"]."""
    bpy.context.view_layer.update()
    me = obj.data
    attr = me.color_attributes.get("Col")
    if attr is None:
        attr = me.color_attributes.new(name="Col", type="FLOAT_COLOR", domain="CORNER")
    me.color_attributes.active_color = attr
    try:
        me.color_attributes.render_color_index = me.color_attributes.find("Col")
    except Exception:
        pass
    mw = obj.matrix_world
    nmat = mw.to_3x3().inverted_safe().transposed()
    mats = [m.name if m else "" for m in me.materials]
    vs = me.vertices
    loops = me.loops
    cols = [0.0] * (len(loops) * 4)
    for poly in me.polygons:
        mname = mats[poly.material_index] if mats else ""
        pn = (nmat @ poly.normal).normalized()
        PS["pn"] = pn
        PS["pc"] = mw @ poly.center
        sm = poly.use_smooth
        for li in poly.loop_indices:
            vi = loops[li].vertex_index
            wp = mw @ vs[vi].co
            wn = (nmat @ vs[vi].normal).normalized() if sm else pn
            c = fn(vi, wp, wn, mname, poly.index)
            cols[li * 4:li * 4 + 4] = (c[0], c[1], c[2], 1.0)
    attr.data.foreach_set("color", cols)


def recalc_normals(obj):
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    bm.to_mesh(obj.data)
    bm.free()


# ----------------------------------------------------------------------------
# objects / hierarchy
# ----------------------------------------------------------------------------

def obj_from_bm(name, bm, mats, smooth=True, origin=None, parent=None):
    """Mesh object from a bmesh built in WORLD coordinates; origin (world) becomes the pivot.

    If parent is given (and has identity rotation/scale), location is set relative to it."""
    if origin is not None:
        o = Vector(origin)
        for v in bm.verts:
            v.co -= o
    ob = new_object(name, bm, mats=mats, smooth=smooth)
    if origin is not None:
        ob.location = Vector(origin)
    if parent is not None:
        ob.parent = parent
        ob.matrix_parent_inverse = Matrix.Identity(4)
        ob.location = (Vector(origin) if origin is not None else Vector()) - parent.matrix_world.translation
    bpy.context.view_layer.update()
    return ob


def reset_scene():
    reset()


def all_meshes():
    return [o for o in bpy.context.scene.objects if o.type == "MESH"]


# ----------------------------------------------------------------------------
# preview
# ----------------------------------------------------------------------------

def _ground_disc(z, radius, col, name="NatGround"):
    bm = bmesh.new()
    bmesh.ops.create_circle(bm, cap_ends=True, radius=radius, segments=48)
    for v in bm.verts:
        v.co.z = z
    g = new_object(name, bm, mats=["PreviewGround"], smooth=False)
    C.paint_solid(g, col)
    return g


def preview(name, objs=None, views=((20, 35),), ground=True, ground_z=0.0, ground_col="#7f8f5c",
            dist_mul=3.4, size=(720, 540), samples=24, hide=(), ceiling=False, target=None, exposure=-1.0):
    """Render previews tools/blender/previews/nature_<name>_<i>.png.  Ground disc at ground_z.

    target: objects used to frame the camera (defaults to objs)."""
    objs = objs or all_meshes()
    target = target or objs
    hidden = []
    for o in hide:
        if not o.hide_render:
            o.hide_render = True
            hidden.append(o)
    temp = []
    if ground:
        _, rad = C._world_bounds(target)
        temp.append(_ground_disc(ground_z, max(6.0, rad * 8), hexcol(ground_col)))
    if ceiling:
        _, rad = C._world_bounds(target)
        cg = _ground_disc(0.0, max(3.0, rad * 0.6), hexcol("#5a4636"), "NatCeiling")
        temp.append(cg)
    outs = []
    # common.render_preview lights very brightly (sun 3.5); pull exposure down so albedo reads
    # closer to how it will look under Godot's default sun.
    bpy.context.scene.view_settings.exposure = exposure
    for k, (elev, azim) in enumerate(views):
        nm = f"nature_{name}" + (f"_{k}" if len(views) > 1 else "")
        outs.append(render_preview(nm, objs=target, elev=elev, azim=azim, size=size, samples=samples,
                                   dist_mul=dist_mul, ground=False))
    for o in temp:
        bpy.data.objects.remove(o, do_unlink=True)
    for o in hidden:
        o.hide_render = False
    return outs


def report_tris(objs):
    tot = 0
    for o in objs:
        t = triangle_count([o])
        tot += t
        print(f"   {o.name:28s} {t:6d}")
    print(f"   {'TOTAL':28s} {tot:6d}")
    return tot


# ----------------------------------------------------------------------------
# rocks v2: polytope shapes, moss cut along a smooth scalar field, stone-only dissolve
# ----------------------------------------------------------------------------

def random_planes(n, rng, depth=(0.8, 0.95), jitter=0.3, zscale=1.0):
    out = []
    for d in fib_dirs(n, rng, jitter):
        d = Vector((d.x, d.y, d.z * zscale)).normalized()
        out.append((d, rng.uniform(*depth)))
    return out


class RockPart:
    """Convex rock chunk: a coarse sphere bisected by planes (clean planar facets), scaled to
    half extents, sharp edges bevelled.  Keeps parameters for an analytic inside() test."""

    def __init__(self, center, half, planes, roundness=0.0, subdiv=2, top_clamp=None, warp=0.0,
                 seed=0, bevel=0.03, bevel_angle=32.0):
        self.c = Vector(center)
        self.h = Vector(half)
        self.planes = planes
        self.round = roundness
        self.subdiv = subdiv          # sphere resolution for the uncut (rounded) corners
        self.top = top_clamp
        self.warp = warp
        self.seed = seed
        self.bevel = bevel
        self.bevel_angle = bevel_angle
        self.faces = []

    def unit_r(self, d):
        r = 1.0
        for (n, dd) in self.planes:
            c = d.dot(n)
            if c > 1e-3:
                r = min(r, dd / c)
        return r

    def build(self, bm, mat=0):
        tmp = bmesh.new()
        bmesh.ops.create_icosphere(tmp, subdivisions=self.subdiv, radius=1.0)
        planes = list(self.planes)
        if self.top is not None:
            # express the world-space clamp as one more unit-space plane
            planes.append((Vector((0, 0, 1)), (self.top - self.c.z) / self.h.z))
        for (n, d) in planes:
            geom = tmp.verts[:] + tmp.edges[:] + tmp.faces[:]
            res = bmesh.ops.bisect_plane(tmp, geom=geom, dist=1e-6, plane_co=n * d, plane_no=n,
                                         clear_outer=True)
            cut = [e for e in res["geom_cut"] if isinstance(e, bmesh.types.BMEdge)]
            if cut:
                bmesh.ops.holes_fill(tmp, edges=cut, sides=0)
        for v in tmp.verts:
            v.co = self.c + Vector((v.co.x * self.h.x, v.co.y * self.h.y, v.co.z * self.h.z))
        bmesh.ops.remove_doubles(tmp, verts=tmp.verts[:], dist=1e-4)
        tmp.normal_update()
        if self.bevel > 0:
            sharp = [e for e in tmp.edges if len(e.link_faces) == 2 and e.calc_face_angle(0.0) > math.radians(self.bevel_angle)]
            if sharp:
                bmesh.ops.bevel(tmp, geom=sharp, offset=self.bevel, offset_type="OFFSET", segments=2,
                                profile=0.5, affect="EDGES", clamp_overlap=True)
        bmesh.ops.recalc_face_normals(tmp, faces=tmp.faces[:])
        vmap = {}
        for v in tmp.verts:
            vmap[v.index] = None
        tmp.verts.index_update()
        nv = [bm.verts.new(v.co) for v in tmp.verts]
        self.faces = []
        for f in tmp.faces:
            try:
                nf = bm.faces.new([nv[v.index] for v in f.verts])
            except ValueError:
                continue
            nf.material_index = mat
            self.faces.append(nf)
        tmp.free()
        return self.faces

    def inside(self, p, margin=0.02):
        q = Vector(p) - self.c
        q = Vector((q.x / self.h.x, q.y / self.h.y, q.z / self.h.z))
        L = q.length
        if L < 1e-6:
            return True
        m = margin / min(self.h)
        return L < self.unit_r(q / L) - m


def densify(bm, max_len=0.07, max_iter=6, min_nz=None, face_filter=None):
    """Split long edges until shorter than max_len.  min_nz: only faces whose normal.z exceeds it
    (i.e. where moss can grow) are refined."""
    bm.normal_update()
    def want(f):
        if face_filter is not None and face_filter(f):
            return True
        return min_nz is None or f.normal.z > min_nz
    sel = set(f for f in bm.faces if want(f))
    bmesh.ops.triangulate(bm, faces=[f for f in sel if len(f.verts) > 3], quad_method="BEAUTY",
                          ngon_method="BEAUTY")
    bm.normal_update()
    for _ in range(max_iter):
        faces = [f for f in bm.faces if want(f)]
        long_e = set()
        for f in faces:
            for e in f.edges:
                if e.calc_length() > max_len:
                    long_e.add(e)
        if not long_e:
            break
        bmesh.ops.subdivide_edges(bm, edges=list(long_e), cuts=1, use_grid_fill=False)
        bmesh.ops.triangulate(bm, faces=[f for f in bm.faces if len(f.verts) > 3], quad_method="BEAUTY",
                              ngon_method="BEAUTY")
        bm.normal_update()


def weighted_normals(obj, weight=50):
    """Face-area weighted custom normals: big flat facets shade flat, bevels stay soft."""
    select_only(obj)
    mod = obj.modifiers.new("wn", "WEIGHTED_NORMAL")
    mod.mode = "FACE_AREA"
    mod.weight = weight
    mod.keep_sharp = True
    try:
        bpy.ops.object.modifier_apply(modifier=mod.name)
    except Exception as ex:
        print("weighted normal failed", ex)
        obj.modifiers.remove(mod)


def build_rock_parts(bm, parts, cull=True):
    for p in parts:
        p.build(bm)
    if cull and len(parts) > 1:
        dead = []
        for i, p in enumerate(parts):
            for f in p.faces:
                if any(all(o.inside(v.co) for v in f.verts) for j, o in enumerate(parts) if j != i):
                    dead.append(f)
        if dead:
            bmesh.ops.delete(bm, geom=dead, context="FACES")


def moss_field(bm, seed=0, amount=0.5, nz_min=0.35, scale=2.0, exclude=None, zmin=-99.0, soft=0.25,
               layer_name="mossw", smooth_iter=3, skirt=0.0, skirt_h=0.16):
    """Per-vertex moss weight in [0,1] (0.5 = boundary), stored in a float vertex layer."""
    bm.normal_update()
    bm.verts.index_update()
    lay = bm.verts.layers.float.get(layer_name) or bm.verts.layers.float.new(layer_name)
    for v in bm.verts:
        n = v.normal
        up = smoothstep(nz_min, nz_min + soft + 0.2, n.z)
        brk = 0.5 + 0.5 * clamp(n1(v.co, scale, seed, 3) * 1.5, -1.0, 1.0)
        fine = 0.06 * n1(v.co, scale * 3.3, seed + 5, 2)
        m = up * (0.35 + 0.75 * brk) + fine + (amount - 0.5) * 0.7
        if v.co.z < zmin:
            m -= (zmin - v.co.z) * 6.0
        if skirt > 0:  # moss creeping up from the ground around the base
            sk = (1.0 - smoothstep(skirt_h * 0.4, skirt_h, v.co.z)) * smoothstep(-0.6, 0.0, n.z)
            m = max(m, sk * skirt * (0.3 + 0.9 * brk) + fine)
        if exclude is not None:
            e = exclude(v.co)
            if e > 0:
                m -= e
        v[lay] = clamp(m, 0.0, 1.0)
    for _ in range(smooth_iter):  # Laplacian smoothing of the field -> smooth iso-lines
        vals = {}
        for v in bm.verts:
            nb = [e.other_vert(v)[lay] for e in v.link_edges]
            vals[v.index] = 0.5 * v[lay] + 0.5 * (sum(nb) / len(nb) if nb else v[lay])
        for v in bm.verts:
            v[lay] = vals[v.index]
    for v in bm.verts:
        if abs(v[lay] - 0.5) < 2e-4:
            v[lay] = 0.5 + 2e-4
    return layer_name


def split_by_field(bm, layer_name="mossw", iso=0.5, moss_index=1, stone_index=0):
    """Cut faces along the iso-line of a per-vertex float layer; high side gets moss_index."""
    lay = bm.verts.layers.float[layer_name]
    cross = [e for e in bm.edges if (e.verts[0][lay] - iso) * (e.verts[1][lay] - iso) < 0]
    for e in cross:
        a, b = e.verts
        wa, wb = a[lay], b[lay]
        t = (iso - wa) / (wb - wa)
        _, nv = bmesh.utils.edge_split(e, a, t)
        nv[lay] = iso
    for f in list(bm.faces):
        nvs = [v for v in f.verts if abs(v[lay] - iso) < 1e-6]
        if len(nvs) == 2:
            a, b = nvs
            if any(b in (e.other_vert(a),) for e in a.link_edges if e in f.edges):
                continue
            try:
                bmesh.utils.face_split(f, a, b)
            except ValueError:
                pass
    for f in bm.faces:
        if f.material_index not in (moss_index, stone_index):
            continue
        avg = sum(v[lay] for v in f.verts) / len(f.verts)
        f.material_index = moss_index if avg > iso else stone_index


def dissolve_flat(bm, angle_deg=4.0, only_index=0):
    """Limited dissolve restricted to faces of one material (keeps moss detail)."""
    bm.normal_update()
    edges = [e for e in bm.edges if e.link_faces and all(f.material_index == only_index for f in e.link_faces)]
    verts = [v for v in bm.verts if v.link_faces and all(f.material_index == only_index for f in v.link_faces)]
    bmesh.ops.dissolve_limit(bm, angle_limit=math.radians(angle_deg), use_dissolve_boundaries=False,
                             verts=verts, edges=edges, delimit={"MATERIAL"})
    bmesh.ops.triangulate(bm, faces=[f for f in bm.faces if len(f.verts) > 3], quad_method="BEAUTY",
                          ngon_method="BEAUTY")


def warp_bm(bm, amp, scale=0.8, seed=0, keep=None):
    for v in bm.verts:
        if keep is not None and keep(v.co):
            continue
        v.co += nvec(v.co, scale, seed + 77) * amp


def moss_cushion_bm(bm, height=0.016, iso=0.5, seed=0, layer_name="mossw", keep=None):
    lay = bm.verts.layers.float.get(layer_name)
    if lay is None:
        return
    bm.normal_update()
    moves = []
    for v in bm.verts:
        w = v[lay]
        if w > iso and (keep is None or not keep(v.co)):
            k = smoothstep(iso, iso + 0.3, w)
            moves.append((v, v.normal * height * k * (0.75 + 0.5 * (0.5 + 0.5 * n1(v.co, 7.0, seed)))))
    for v, d in moves:
        v.co += d


def rock_color_fn(ao, cav, mw, seed=0, base="stone", warm=0.0, ground_z=0.0, moss_tint=True, dirt=True,
                  value=1.0, extra=None):
    """paint_ex callback for stone + moss surfaces.  mw: per-vertex moss weights (list) or None."""
    rng = random.Random(seed)
    st = pal(base)
    st_d = pal("stone_dark")
    st_l = pal("stone_light")
    moss = pal("moss")
    moss_d = shift(pal("grass_dark"), ds=-0.1, dv=-0.12)
    moss_l = shift(pal("leaf_warm"), ds=-0.15, dv=-0.1)
    soil = pal("soil")
    hue_off = rng.uniform(-0.008, 0.008) + warm

    def fn(vi, p, n, m, pi):
        a = ao[vi] if ao else 1.0
        c = cav[vi] if cav else 0.0
        w = mw[vi] if mw else 0.0
        if m == "Moss":
            t = 0.5 + 0.5 * n1(p, 3.0, seed + 7, 2)
            col = mix(moss_d, moss, 0.12 + 0.55 * t)
            col = mix(col, moss_l, 0.12 * smoothstep(0.4, 0.95, n.z) * (0.5 + 0.5 * n1(p, 8.0, seed + 3)))
            edge = 1.0 - smoothstep(0.5, 0.7, w)
            col = mix(col, shift(moss_d, dh=0.015, dv=-0.15), 0.5 * edge)
            col = shift(col, ds=-0.12)
            col = scale_col(col, (0.45 + 0.55 * a) * (1.0 + 0.12 * clamp(c * 2, -1, 1)) * value * 0.92)
            return col
        t = 0.5 + 0.5 * clamp(n1(p, 1.3, seed, 3) + 0.4 * n1(p, 4.0, seed + 2, 2), -1, 1)
        col = mix(st_d, st, 0.15 + 0.85 * t)
        pn = PS["pn"]
        ft = n1(pn, 1.6, seed + 11, 1)
        col = scale_col(col, 1.0 + 0.18 * ft)
        col = scale_col(col, 1.0 + 0.10 * clamp(pn.z) - 0.25 * clamp(-pn.z))
        col = shift(col, dh=hue_off + 0.02 * n1(p, 0.7, seed + 5), ds=0.1 + 0.25 * n1(p, 0.9, seed + 9))
        ridge = clamp(c * 3.0, -1.0, 1.0)
        col = mix(col, st_l, 0.5 * max(0.0, ridge)) if ridge > 0 else scale_col(col, 1.0 + 0.4 * ridge)
        col = scale_col(col, 1.0 + 0.08 * clamp(n.z))
        if moss_tint:
            g = smoothstep(0.15, 0.5, w) * 0.4 + smoothstep(0.35, 0.9, n.z) * (0.5 + 0.5 * n1(p, 2.4, seed + 1)) * 0.1
            col = mix(col, shift(moss, ds=-0.35, dv=-0.2), g)
        if dirt:
            h = p.z - ground_z
            col = mix(col, soil, 0.65 * (1.0 - smoothstep(-0.03, 0.16, h)))
        if extra is not None:
            col = extra(p, n, col)
        return scale_col(col, (0.42 + 0.58 * a) * value)
    return fn


def rock_object(name, bm, seed=0, moss_w=None, dissolve=4.0, warp=0.0, warp_scale=0.8, cushion=0.012,
                angle=40.0, keep=None, target_tris=None, zclamp=None, protect=None):
    """Finish a rock bmesh (world coords around origin) whose faces are Stone(0)/Moss(1).

    moss_w: name of a float vertex layer holding the moss field (see moss_field)."""
    if moss_w is not None:
        split_by_field(bm, moss_w)
    prot = [f for f in bm.faces if protect(f)] if protect else []
    for f in prot:
        f.material_index = 2
    if dissolve:
        dissolve_flat(bm, dissolve)
    for f in bm.faces:
        if f.material_index == 2:
            f.material_index = 0
    if warp:
        warp_bm(bm, warp, warp_scale, seed, keep=keep)
    if cushion and moss_w is not None:
        moss_cushion_bm(bm, cushion, seed=seed, keep=keep)
    ob = new_object(name, bm, mats=["Stone", "Moss"], smooth=False)
    if target_tris:
        decimate_to(ob, target_tris)
    if zclamp is not None:
        for v in ob.data.vertices:
            if v.co.z > zclamp:
                v.co.z = zclamp
    smooth_by_angle(ob, angle)
    weighted_normals(ob)
    return ob


def paint_rock(ob, seed=0, occluders=(), ao_dist=0.6, ground_z=0.0, base="stone", warm=0.0, samples=24,
               value=1.0, extra=None):
    ao = bake_ao([ob], occluders=occluders, samples=samples, dist=ao_dist, ground=ground_z)[ob.name]
    cav = cavity(ob)
    mwl = None
    if "mossw" in ob.data.attributes:
        mwl = [d.value for d in ob.data.attributes["mossw"].data]
    paint_ex(ob, rock_color_fn(ao, cav, mwl, seed=seed, base=base, warm=warm, ground_z=ground_z, value=value,
                               extra=extra))


def raycast_down(bvh, x, y, z_top=10.0):
    hit = bvh.ray_cast(Vector((x, y, z_top)), Vector((0, 0, -1)), 50.0)
    return hit[0]


def strip_attrs(obj, names=("mossw", "clump", "tipw", "rootw")):
    """Remove helper attributes before export."""
    for nm in names:
        a = obj.data.attributes.get(nm)
        if a is not None:
            obj.data.attributes.remove(a)


def attr_values(obj, name, default=0.0):
    a = obj.data.attributes.get(name)
    if a is None:
        return [default] * len(obj.data.vertices)
    return [d.value for d in a.data]


def surface_exit(bvh, origin, d, maxd=2.5):
    """First point along the ray from `origin` (inside a set of closed tubes) where it leaves
    every tube.  Counts exiting/entering hits so overlapping tubes are handled."""
    d = Vector(d).normalized()
    hits = []
    o = Vector(origin)
    travelled = 0.0
    for _ in range(64):
        h = bvh.ray_cast(o, d, maxd - travelled)
        if h[0] is None:
            break
        travelled += h[3] + 1e-5
        hits.append((h[0].copy(), 1 if h[1].dot(d) > 0 else -1))
        o = h[0] + d * 1e-5
        if travelled >= maxd:
            break
    depth = sum(x for _, x in hits)
    for p, x in hits:
        depth -= x
        if depth <= 0:
            return p
    return hits[0][0] if hits else Vector(origin)
