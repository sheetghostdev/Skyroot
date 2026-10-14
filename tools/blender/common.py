"""Shared helpers for Skyroot's Blender model scripts.

Run any model script with:
    blender -b --python tools/blender/<script>.py

Conventions (see docs/ARTPIPELINE.md):
  * Meters, Blender Z-up (the glTF exporter converts to Godot's Y-up).
  * ALL colour lives in vertex colours (linear FLOAT_COLOR attribute "Col",
    exported as COLOR_0).  Materials are white and exist only to name the
    surface role ("Bark", "Leaves", "Stone"...) so Godot can swap in its own
    shaders by material name.
  * Ground props: origin at bottom centre.  Hand items: origin at centre.
  * Every exported object is a mesh with transforms applied (except where a
    script deliberately keeps a pivot, e.g. tree branches / character parts).
"""
import bpy
import bmesh
import math
import os
import random
from mathutils import Vector, Matrix, noise

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
MODEL_DIR = os.path.join(REPO, "assets", "models")
PREVIEW_DIR = os.path.join(REPO, "tools", "blender", "previews")


def srgb_to_lin(c):
    c = c / 255.0 if c > 1.0 else c
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def hexcol(h):
    """'#rrggbb' -> linear RGBA tuple."""
    h = h.lstrip("#")
    r, g, b = int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16)
    return (srgb_to_lin(r), srgb_to_lin(g), srgb_to_lin(b), 1.0)


# Cohesive, warm, slightly desaturated natural palette.  Keep every model on it.
PALETTE = {
    "grass": "#6F9A45", "grass_light": "#9BBF5A", "grass_dark": "#4E7A3A",
    "leaf": "#5E8F3E", "leaf_light": "#8DB653", "leaf_dark": "#3F6B2E", "leaf_warm": "#B5C96A",
    "bark": "#6B5444", "bark_dark": "#4A3A30", "bark_light": "#8A7058",
    "wood": "#C9A27A", "wood_end": "#D8B58A", "wood_ring": "#A9805A", "wood_dark": "#9C7552",
    "stone": "#8E8A82", "stone_dark": "#6A675F", "stone_light": "#B1ADA3", "moss": "#6E8B3D",
    "soil": "#5C4433", "soil_dark": "#3E2E22", "clay": "#A8664A", "clay_dry": "#C79A7C",
    "skin": "#E0AC85", "cloth": "#C9B48A", "cloth_dark": "#5A5048", "leather": "#7A5236",
    "hair": "#4A3226", "rope": "#C8B07A", "fiber": "#B8B070", "straw": "#D6C27E",
    "charcoal": "#2A2624", "ash": "#9A9690", "terracotta": "#B35A36",
    "berry": "#C2384F", "mush_cap": "#A0583A", "mush_spot": "#EBD9B4", "mush_stem": "#E8DCC0",
    "tuber": "#8E4B5E", "tuber_flesh": "#EBD9A6", "grain": "#D9B85C", "grain_green": "#9DB45A",
    "flower_y": "#E8C547", "flower_w": "#F2EEE0", "flower_p": "#B07CC6",
}


def pal(name, jitter=0.0, rng=None):
    c = hexcol(PALETTE[name]) if name in PALETTE else hexcol(name)
    if jitter > 0.0:
        rng = rng or random
        f = 1.0 + rng.uniform(-jitter, jitter)
        return (c[0] * f, c[1] * f, c[2] * f, 1.0)
    return c


def lerp_col(a, b, t):
    return tuple(a[i] + (b[i] - a[i]) * t for i in range(4))


def mul_col(a, f):
    return (a[0] * f, a[1] * f, a[2] * f, a[3])


# ----------------------------------------------------------------------------
# Scene / objects
# ----------------------------------------------------------------------------

def reset():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    for m in list(bpy.data.materials):
        bpy.data.materials.remove(m)


_MATS = {}


def material(role, roughness=0.85):
    """White material that reads vertex colour.  `role` names the surface."""
    if role in bpy.data.materials:
        return bpy.data.materials[role]
    m = bpy.data.materials.new(role)
    m.use_nodes = True
    nt = m.node_tree
    bsdf = nt.nodes.get("Principled BSDF")
    vc = nt.nodes.new("ShaderNodeVertexColor")
    vc.layer_name = "Col"
    nt.links.new(vc.outputs["Color"], bsdf.inputs["Base Color"])
    bsdf.inputs["Roughness"].default_value = roughness
    if role.lower().startswith("leaves") or role.lower() in ("grass", "foliage"):
        # a touch of translucency in previews only
        try:
            bsdf.inputs["Subsurface Weight"].default_value = 0.0
        except KeyError:
            pass
    return m


def new_object(name, bm, mats=(), smooth=True, link=True):
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    obj = bpy.data.objects.new(name, me)
    if link:
        bpy.context.scene.collection.objects.link(obj)
    for m in mats:
        me.materials.append(material(m) if isinstance(m, str) else m)
    for p in me.polygons:
        p.use_smooth = smooth
    return obj


def mesh_object(name, verts, faces, mats=(), smooth=True, mat_indices=None):
    me = bpy.data.meshes.new(name)
    me.from_pydata([tuple(v) for v in verts], [], [tuple(f) for f in faces])
    me.update(calc_edges=True)
    obj = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(obj)
    for m in mats:
        me.materials.append(material(m) if isinstance(m, str) else m)
    if mat_indices is not None:
        for p, mi in zip(me.polygons, mat_indices):
            p.material_index = mi
    for p in me.polygons:
        p.use_smooth = smooth
    return obj


def select_only(objs):
    bpy.ops.object.select_all(action="DESELECT")
    if not isinstance(objs, (list, tuple)):
        objs = [objs]
    for o in objs:
        o.select_set(True)
    bpy.context.view_layer.objects.active = objs[0]


def apply_transforms(obj):
    select_only(obj)
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)


def join(objs, name=None):
    objs = [o for o in objs if o is not None]
    select_only(objs)
    bpy.ops.object.join()
    o = bpy.context.view_layer.objects.active
    if name:
        o.name = name
        o.data.name = name
    return o


def set_origin(obj, point):
    """Move object origin to world-space `point` without moving geometry."""
    point = Vector(point)
    mw = obj.matrix_world.copy()
    local = mw.inverted() @ point
    obj.data.transform(Matrix.Translation(-local))
    obj.matrix_world = mw @ Matrix.Translation(local)


def origin_bottom_center(obj):
    bb = [obj.matrix_world @ Vector(c) for c in obj.bound_box]
    cx = (min(v.x for v in bb) + max(v.x for v in bb)) / 2
    cy = (min(v.y for v in bb) + max(v.y for v in bb)) / 2
    set_origin(obj, (cx, cy, min(v.z for v in bb)))
    obj.location = (0, 0, 0) if obj.parent is None else obj.location


def origin_center(obj):
    bb = [obj.matrix_world @ Vector(c) for c in obj.bound_box]
    c = Vector((sum(v.x for v in bb) / 8, sum(v.y for v in bb) / 8, sum(v.z for v in bb) / 8))
    set_origin(obj, c)


def smooth_by_angle(obj, angle_deg=40.0):
    select_only(obj)
    try:
        bpy.ops.object.shade_smooth_by_angle(angle=math.radians(angle_deg))
    except Exception:
        for p in obj.data.polygons:
            p.use_smooth = True


def flat(obj):
    for p in obj.data.polygons:
        p.use_smooth = False


def triangle_count(objs):
    n = 0
    for o in objs:
        if o.type == "MESH":
            for p in o.data.polygons:
                n += len(p.vertices) - 2
    return n


# ----------------------------------------------------------------------------
# Vertex colour painting
# ----------------------------------------------------------------------------

def paint(obj, fn):
    """fn(world_pos: Vector, world_normal: Vector, material_name: str, poly_index) -> RGBA (linear)."""
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
    nmat = mw.to_3x3().inverted().transposed()
    mats = [m.name if m else "" for m in me.materials]
    for poly in me.polygons:
        mname = mats[poly.material_index] if mats else ""
        for li in poly.loop_indices:
            vi = me.loops[li].vertex_index
            wp = mw @ me.vertices[vi].co
            wn = (nmat @ (me.vertices[vi].normal if poly.use_smooth else poly.normal)).normalized()
            attr.data[li].color = fn(wp, wn, mname, poly.index)


def paint_solid(obj, col):
    paint(obj, lambda p, n, m, i: col)


def ao_factor(p, n, z0=0.0, z1=1.0, floor=0.55, down=0.75):
    """Cheap ambient-occlusion-ish darkening: low parts and down-facing normals darker."""
    t = 0.0 if z1 <= z0 else max(0.0, min(1.0, (p.z - z0) / (z1 - z0)))
    h = floor + (1.0 - floor) * (t ** 0.6)
    d = 1.0 - (1.0 - down) * max(0.0, -n.z)
    return h * d


def nz(p, scale=1.0, octaves=2):
    """Smooth noise in [-1, 1]."""
    return noise.fractal(Vector(p) * scale, 0.5, 2.0, octaves, noise_basis="PERLIN_ORIGINAL") * 1.6


# ----------------------------------------------------------------------------
# Geometry builders
# ----------------------------------------------------------------------------

def _frame(tangent, prev_normal=None):
    t = tangent.normalized()
    if prev_normal is None:
        up = Vector((0, 0, 1)) if abs(t.z) < 0.95 else Vector((1, 0, 0))
        n = t.cross(up).normalized()
    else:
        # parallel transport
        n = (prev_normal - t * prev_normal.dot(t))
        if n.length < 1e-6:
            up = Vector((0, 0, 1)) if abs(t.z) < 0.95 else Vector((1, 0, 0))
            n = t.cross(up)
        n.normalize()
    b = t.cross(n).normalized()
    return t, n, b


def tube(bm, points, radii, segments=8, cap_start=True, cap_end=True, noise_amp=0.0,
         noise_scale=3.0, seed=0, twist=0.0, flatten=1.0):
    """Append a tube along `points` (list of Vector) with per-point `radii` to bmesh.

    Returns (rings, cap_faces) where rings is a list of lists of BMVerts.
    """
    pts = [Vector(p) for p in points]
    rings = []
    prev_n = None
    off = Vector((seed * 13.1, seed * 7.7, seed * 3.3))
    for i, p in enumerate(pts):
        if i == 0:
            tan = pts[1] - pts[0]
        elif i == len(pts) - 1:
            tan = pts[-1] - pts[-2]
        else:
            tan = (pts[i + 1] - pts[i - 1])
        t, n, b = _frame(tan, prev_n)
        prev_n = n
        ring = []
        r = radii[i]
        for s in range(segments):
            a = (s / segments) * math.tau + twist * i
            d = n * math.cos(a) + b * math.sin(a) * flatten
            rr = r
            if noise_amp > 0:
                rr *= 1.0 + noise_amp * nz(p * noise_scale + d * 0.7 + off)
            ring.append(bm.verts.new(p + d * rr))
        rings.append(ring)
    for i in range(len(rings) - 1):
        a, b2 = rings[i], rings[i + 1]
        for s in range(segments):
            s2 = (s + 1) % segments
            bm.faces.new((a[s], a[s2], b2[s2], b2[s]))
    caps = []
    if cap_start:
        c = bm.verts.new(pts[0] - (pts[1] - pts[0]).normalized() * radii[0] * 0.25)
        for s in range(segments):
            caps.append(bm.faces.new((rings[0][(s + 1) % segments], rings[0][s], c)))
    if cap_end:
        c = bm.verts.new(pts[-1] + (pts[-1] - pts[-2]).normalized() * radii[-1] * 0.25)
        for s in range(segments):
            caps.append(bm.faces.new((rings[-1][s], rings[-1][(s + 1) % segments], c)))
    return rings, caps


def bezier_points(p0, p1, p2, p3, n):
    out = []
    for i in range(n):
        t = i / (n - 1)
        u = 1 - t
        out.append(Vector(p0) * u ** 3 + Vector(p1) * 3 * u * u * t + Vector(p2) * 3 * u * t * t + Vector(p3) * t ** 3)
    return out


def blob(bm, center, radius, subdiv=2, noise_amp=0.25, noise_scale=1.5, squash=(1, 1, 1), seed=0):
    """Displaced icosphere appended to bm (foliage clumps, rocks, clods)."""
    tmp = bmesh.new()
    bmesh.ops.create_icosphere(tmp, subdivisions=subdiv, radius=1.0)
    off = Vector((seed * 5.3, seed * 2.1, seed * 8.7))
    center = Vector(center)
    vmap = {}
    for v in tmp.verts:
        d = v.co.normalized()
        r = radius * (1.0 + noise_amp * nz(d * noise_scale + off, 1.0, 3))
        co = Vector((d.x * r * squash[0], d.y * r * squash[1], d.z * r * squash[2])) + center
        vmap[v] = bm.verts.new(co)
    out = []
    for f in tmp.faces:
        out.append(bm.faces.new([vmap[v] for v in f.verts]))
    tmp.free()
    return out


def box(bm, center, size, bevel=0.0):
    tmp = bmesh.new()
    bmesh.ops.create_cube(tmp, size=1.0)
    for v in tmp.verts:
        v.co = Vector((v.co.x * size[0], v.co.y * size[1], v.co.z * size[2])) + Vector(center)
    if bevel > 0:
        bmesh.ops.bevel(tmp, geom=list(tmp.edges), offset=bevel, segments=2, affect="EDGES", profile=0.5)
    vmap = {}
    for v in tmp.verts:
        vmap[v] = bm.verts.new(v.co)
    faces = [bm.faces.new([vmap[v] for v in f.verts]) for f in tmp.faces]
    tmp.free()
    return faces


def cylinder(bm, p0, p1, r0, r1=None, segments=10, caps=True):
    r1 = r0 if r1 is None else r1
    return tube(bm, [Vector(p0), (Vector(p0) + Vector(p1)) / 2, Vector(p1)], [r0, (r0 + r1) / 2, r1],
                segments=segments, cap_start=caps, cap_end=caps)


def displace_mesh(obj, amp, scale, seed=0, axis_weights=(1, 1, 1)):
    off = Vector((seed * 3.7, seed * 1.3, seed * 9.1))
    for v in obj.data.vertices:
        d = nz(v.co * scale + off, 1.0, 3)
        v.co += Vector((v.normal.x * axis_weights[0], v.normal.y * axis_weights[1], v.normal.z * axis_weights[2])) * d * amp


def assign_material_all(obj, role):
    me = obj.data
    me.materials.clear()
    me.materials.append(material(role))
    for p in me.polygons:
        p.material_index = 0


def merge_by_distance(obj, dist=0.0005):
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=dist)
    bm.to_mesh(obj.data)
    bm.free()


def decimate(obj, ratio):
    select_only(obj)
    mod = obj.modifiers.new("dec", "DECIMATE")
    mod.ratio = ratio
    bpy.ops.object.modifier_apply(modifier=mod.name)


# ----------------------------------------------------------------------------
# Export / preview
# ----------------------------------------------------------------------------

def export_glb(path, objs):
    """Export the given objects (and their children) to assets/models/<path>."""
    full = os.path.join(MODEL_DIR, path)
    os.makedirs(os.path.dirname(full), exist_ok=True)
    bpy.ops.object.select_all(action="DESELECT")
    stack = list(objs)
    while stack:
        o = stack.pop()
        o.select_set(True)
        stack.extend(o.children)
    bpy.context.view_layer.objects.active = objs[0]
    kw = dict(filepath=full, export_format="GLB", use_selection=True, export_apply=True,
              export_yup=True, export_normals=True, export_materials="EXPORT",
              export_animations=False, export_cameras=False, export_lights=False)
    props = bpy.ops.export_scene.gltf.get_rna_type().properties.keys()
    if "export_vertex_color" in props:
        kw["export_vertex_color"] = "ACTIVE"
    elif "export_colors" in props:
        kw["export_colors"] = True
    bpy.ops.export_scene.gltf(**kw)
    tris = triangle_count([o for o in bpy.context.selected_objects])
    print(f"[export] {path}: {tris} tris")
    return full


def _world_bounds(objs):
    pts = []
    for o in objs:
        if o.type == "MESH" and o.visible_get():
            pts += [o.matrix_world @ Vector(c) for c in o.bound_box]
    if not pts:
        return Vector((0, 0, 0)), 1.0
    mn = Vector((min(p.x for p in pts), min(p.y for p in pts), min(p.z for p in pts)))
    mx = Vector((max(p.x for p in pts), max(p.y for p in pts), max(p.z for p in pts)))
    return (mn + mx) / 2, (mx - mn).length / 2


def render_preview(name, objs=None, elev=22.0, azim=35.0, size=(720, 540), samples=24, dist_mul=2.4,
                   ground=True):
    """Cycles CPU still of the scene (or `objs`) to tools/blender/previews/<name>.png."""
    os.makedirs(PREVIEW_DIR, exist_ok=True)
    scene = bpy.context.scene
    objs = objs or [o for o in scene.objects if o.type == "MESH"]
    center, radius = _world_bounds(objs)
    temp = []
    cam_data = bpy.data.cameras.new("PreviewCam")
    cam_data.lens = 50
    cam = bpy.data.objects.new("PreviewCam", cam_data)
    scene.collection.objects.link(cam)
    temp.append(cam)
    d = radius * dist_mul
    e, a = math.radians(elev), math.radians(azim)
    cam.location = center + Vector((math.cos(e) * math.sin(a), -math.cos(e) * math.cos(a), math.sin(e))) * d
    direction = center - cam.location
    cam.rotation_euler = direction.to_track_quat("-Z", "Y").to_euler()
    cam_data.clip_end = d * 10
    scene.camera = cam
    sun_data = bpy.data.lights.new("PreviewSun", "SUN")
    sun_data.energy = 3.5
    sun_data.angle = math.radians(8)
    sun = bpy.data.objects.new("PreviewSun", sun_data)
    sun.rotation_euler = (math.radians(50), math.radians(10), math.radians(40))
    scene.collection.objects.link(sun)
    temp.append(sun)
    if ground:
        gbm = bmesh.new()
        bmesh.ops.create_grid(gbm, x_segments=1, y_segments=1, size=radius * 6)
        zmin = min((o.matrix_world @ Vector(c)).z for o in objs for c in o.bound_box)
        for v in gbm.verts:
            v.co.z = zmin - 0.002
        g = new_object("PreviewGround", gbm, mats=["PreviewGround"], smooth=False)
        paint_solid(g, hexcol("#9a9f8e"))
        temp.append(g)
    world = bpy.data.worlds.new("PreviewWorld")
    world.use_nodes = True
    bg = world.node_tree.nodes.get("Background")
    bg.inputs["Color"].default_value = (0.55, 0.65, 0.8, 1)
    bg.inputs["Strength"].default_value = 0.9
    scene.world = world
    scene.render.engine = "CYCLES"
    scene.cycles.device = "CPU"
    scene.cycles.samples = samples
    try:
        scene.cycles.use_denoising = True
    except Exception:
        pass
    scene.render.resolution_x, scene.render.resolution_y = size
    scene.render.resolution_percentage = 100
    scene.view_settings.view_transform = "AgX" if "AgX" in [i.identifier for i in scene.view_settings.bl_rna.properties["view_transform"].enum_items] else "Filmic"
    out = os.path.join(PREVIEW_DIR, name + ".png")
    scene.render.filepath = out
    bpy.ops.render.render(write_still=True)
    for o in temp:
        bpy.data.objects.remove(o, do_unlink=True)
    print(f"[preview] {out}")
    return out
