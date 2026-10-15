"""Generates the item icons (32x32 pixel art).  They are also extruded into the
3D models you hold and see lying on the ground.

    python3 tools/art/gen_items.py [preview.png]

Writes assets/textures/items.png (atlas, 16 per row) and items.json (key -> index).
Keys are item ids, or "id@variant" for tool materials (stone / flint) and vessel
contents (water / stew).
"""
import json
import math
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(__file__))
import gen_blocks
from pixlib import (S, atlas, bevel, blank, blob, fbm, hexc, jitter, line, mix, outline, poly, put, ramp,
                    rnd, shade, sheet, white)

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
ICONS = []
BLOCK_TILES = dict(gen_blocks.build())

MATS = {
    "stone": ["#55504b", "#6e6863", "#88827b", "#a29b93", "#bdb6ad"],
    "flint": ["#23272e", "#353b45", "#4b5462", "#66717f", "#8f9bab"],
}
WOOD = ["#4a3421", "#5e4329", "#735333", "#87633d", "#9b7547"]
CLAY_RAW = ["#5f6a74", "#77838d", "#8d99a3", "#a2aeb6", "#b8c2c9"]
FIRED = ["#7a3a22", "#93492c", "#a95937", "#bd6b45", "#cf8257"]


def icon(name):
    def deco(fn):
        ICONS.append((name, fn))
        return fn
    return deco


def lit_fill(img, pts, cols, seed=0, light=(-0.6, -0.8), noise=0.25, steps=None):
    """Polygon filled with a ramp shaded by a light direction and a little noise."""
    xs = [p[0] for p in pts]
    ys = [p[1] for p in pts]
    cx, cy = (min(xs) + max(xs)) / 2, (min(ys) + max(ys)) / 2
    w = max(1, max(xs) - min(xs))
    h = max(1, max(ys) - min(ys))
    n = fbm(seed, ((4, 0.6), (8, 0.4)))

    def col(x, y):
        dx = (x - cx) / w * 2
        dy = (y - cy) / h * 2
        t = 0.55 - (dx * light[0] + dy * light[1]) * 0.35 + (n[y % S, x % S] - 0.5) * noise
        return ramp(cols, np.array([[t]]), steps=steps or len(cols))[0, 0]
    poly(img, pts, col)


def finish(img, line_col="#1b1611"):
    return outline(bevel(img), line_col)


def stroke(img, x0, y0, x1, y1, w, cols, seed=1):
    """A thick stroke (sticks, handles) lit along its length."""
    dx, dy = x1 - x0, y1 - y0
    ln = max(1e-3, math.hypot(dx, dy))
    nx, ny = -dy / ln, dx / ln
    pts = [(x0 + nx * w / 2, y0 + ny * w / 2), (x1 + nx * w / 2, y1 + ny * w / 2),
           (x1 - nx * w / 2, y1 - ny * w / 2), (x0 - nx * w / 2, y0 - ny * w / 2)]
    r = rnd(seed)

    def col(x, y):
        # across-the-stroke position for a cylindrical shade
        t = ((x + 0.5 - x0) * nx + (y + 0.5 - y0) * ny) / max(1.0, w) + 0.5
        k = 0.3 + 0.6 * (1 - abs(t - 0.35) * 1.6) + (r.random() - 0.5) * 0.15
        return ramp(cols, np.array([[k]]))[0, 0]
    poly(img, pts, col)


# ---------------------------------------------------------------------------
# Iso blocks
# ---------------------------------------------------------------------------

def iso(top, left, right, h=1.0):
    img = blank()
    T = BLOCK_TILES[top]
    L = BLOCK_TILES[left]
    R = BLOCK_TILES[right]
    top_y = 1 + (1 - h) * 16
    A, Bp, C, D = (16, top_y), (30, top_y + 7), (16, top_y + 14), (2, top_y + 7)
    bottom = 31

    def sample(tex, u, v):
        return tex[min(S - 1, max(0, int(v * S))), min(S - 1, max(0, int(u * S)))]

    for y in range(S):
        for x in range(S):
            px, py = x + 0.5, y + 0.5
            # top rhombus: solve p = A + u*(B-A) + v*(D-A)
            ux, uy = Bp[0] - A[0], Bp[1] - A[1]
            vx, vy = D[0] - A[0], D[1] - A[1]
            det = ux * vy - uy * vx
            u = ((px - A[0]) * vy - (py - A[1]) * vx) / det
            v = (ux * (py - A[1]) - uy * (px - A[0])) / det
            if 0 <= u < 1 and 0 <= v < 1:
                img[y, x] = shade(sample(T, u, v), 1.05)
                continue
            # left face: D..C on top, down to bottom
            if px <= 16 and px >= 2:
                fu = (px - 2) / 14.0
                ytop = D[1] + fu * (C[1] - D[1])
                ybot = ytop + (bottom - C[1])
                if ytop <= py < ybot:
                    fv = (py - ytop) / (ybot - ytop)
                    c = sample(L, fu, fv)
                    if c[3] > 0:
                        img[y, x] = shade(c, 0.8)
                    continue
            if px > 16 and px <= 30:
                fu = (px - 16) / 14.0
                ytop = C[1] + fu * (Bp[1] - C[1])
                ybot = ytop + (bottom - C[1])
                if ytop <= py < ybot:
                    fv = (py - ytop) / (ybot - ytop)
                    c = sample(R, fu, fv)
                    if c[3] > 0:
                        img[y, x] = shade(c, 0.62)
    return outline(img, "#15110d")


for name, (t, l, r) in {
    "dirt": ("dirt", "dirt", "dirt"), "gravel": ("gravel", "gravel", "gravel"), "sand": ("sand", "sand", "sand"),
    "thatch": ("thatch_top", "thatch", "thatch"), "planks": ("planks", "planks", "planks"),
    "brick_block": ("brick", "brick", "brick"), "log_oak": ("log_oak_top", "log_oak", "log_oak"),
    "log_birch": ("log_birch_top", "log_birch", "log_birch"), "clay_block": ("clay", "clay", "clay"),
}.items():
    ICONS.append((name, (lambda t=t, l=l, r=r: iso(t, l, r))))


@icon("straw_bed")
def _():
    return iso("straw_bed", "straw_bed", "straw_bed", 0.45)


def tile_icon(name):
    img = BLOCK_TILES[name].copy()
    return outline(img, "#15110d")


for nm in ["sapling_oak", "sapling_birch"]:
    ICONS.append((nm, (lambda nm=nm: tile_icon(nm))))


@icon("berry_bush")
def _():
    img = blank()
    t = BLOCK_TILES["berries_overlay"]
    blob(img, 16, 18, 12, 10, lambda dx, dy: shade(t[int((dy + 1) * 15) % S, int((dx + 1) * 15) % S], 1.0 - dy * 0.15)
         if t[int((dy + 1) * 15) % S, int((dx + 1) * 15) % S][3] > 0 else hexc("#2e4f22"), wrap=False)
    line(img, 16, 27, 16, 31, "#4a3421")
    return finish(img)


# ---------------------------------------------------------------------------
# Raw materials
# ---------------------------------------------------------------------------

@icon("stone")
def _():
    img = blank()
    lit_fill(img, [(7, 13), (12, 8), (21, 7), (26, 12), (27, 19), (22, 25), (12, 26), (6, 21)], MATS["stone"], 3)
    w = white(4)
    for y in range(S):
        for x in range(S):
            if img[y, x, 3] > 0 and w[y, x] > 0.9:
                img[y, x] = shade(img[y, x], 1.25)
    return finish(img)


@icon("flint")
def _():
    img = blank()
    lit_fill(img, [(6, 15), (10, 8), (17, 5), (25, 9), (27, 17), (23, 25), (14, 27), (7, 22)], MATS["flint"], 5)
    # pale cortex on one side, glints on the flaked faces
    for y in range(S):
        for x in range(S):
            if img[y, x, 3] > 0 and x + y > 40:
                img[y, x] = mix(img[y, x], hexc("#cfc7b8"), 0.65)
    for p in [(13, 11), (14, 11), (18, 9), (12, 16)]:
        put(img, p[0], p[1], "#a9b6c6", wrap=False)
    return finish(img)


@icon("stick")
def _():
    img = blank()
    stroke(img, 5, 27, 26, 5, 3.2, WOOD, 2)
    stroke(img, 17, 14, 22, 15, 2.0, WOOD, 3)
    return finish(img)


@icon("dry_grass")
def _():
    img = blank()
    r = rnd(7)
    for i in range(16):
        x0 = 9 + r.uniform(0, 14)
        x1 = 16 + (x0 - 16) * 0.35
        c = r.choice(["#c8b06a", "#b39a55", "#d9c27e", "#a28a48"])
        line(img, x0, 4 + r.uniform(0, 3), x1, 17, c)
        line(img, x1, 17, 16 + (x0 - 16) * 0.9 + r.uniform(-1, 1), 28, c)
    for x in range(12, 21):
        put(img, x, 17, "#6e5a2b", wrap=False)
        put(img, x, 18, "#5c4a22", wrap=False)
    return finish(img)


@icon("plant_fiber")
def _():
    img = blank()
    r = rnd(8)
    for i in range(9):
        y0 = 8 + i * 1.8
        amp = r.uniform(1.5, 3.0)
        c = r.choice(["#9aa268", "#868d55", "#b2b37a"])
        for x in range(5, 27):
            put(img, x, int(y0 + math.sin(x * 0.45 + i) * amp), c, wrap=False)
    return finish(img)


@icon("twine")
def _():
    img = blank()
    for ring in range(4):
        rr = 9.5 - ring * 2.0
        for a in range(0, 360, 4):
            x = 16 + math.cos(math.radians(a)) * rr
            y = 16 + math.sin(math.radians(a)) * rr * 0.75
            put(img, int(x), int(y), "#b39d6a" if (a // 12) % 2 else "#8c7748", wrap=False)
            put(img, int(x), int(y) + 1, "#6e5c35", wrap=False)
    line(img, 25, 17, 29, 25, "#9c8656")
    return finish(img)


@icon("clay")
def _():
    img = blank()
    lit_fill(img, [(6, 17), (9, 10), (16, 7), (24, 9), (27, 16), (24, 24), (15, 26), (8, 23)], CLAY_RAW, 9)
    return finish(img)


@icon("firewood")
def _():
    img = blank()
    # a split quarter log, end-on with its length running up and to the right
    lit_fill(img, [(4, 22), (19, 7), (28, 12), (13, 28)], ["#8a6538", "#a47d4c", "#bd935b", "#cfa66c"], 10)
    poly(img, [(4, 22), (19, 7), (21, 8), (6, 24)], "#4a3421")
    for i in range(3):
        line(img, 8 + i * 4, 23 - i, 22 + i * 2, 10 + i, "#8f6b3c")
    return finish(img)


@icon("potsherd")
def _():
    img = blank()
    lit_fill(img, [(5, 18), (12, 10), (16, 16), (11, 23)], FIRED, 11)
    lit_fill(img, [(16, 8), (25, 7), (27, 14), (19, 16)], FIRED, 12)
    lit_fill(img, [(15, 22), (24, 19), (26, 26), (17, 28)], FIRED, 13)
    return finish(img)


@icon("brick_raw")
def _():
    img = blank()
    lit_fill(img, [(4, 14), (20, 8), (28, 12), (12, 18)], CLAY_RAW, 14)
    lit_fill(img, [(4, 14), (12, 18), (12, 25), (4, 21)], CLAY_RAW[:3], 15)
    lit_fill(img, [(12, 18), (28, 12), (28, 19), (12, 25)], CLAY_RAW[1:4], 16)
    return finish(img)


@icon("brick")
def _():
    img = blank()
    lit_fill(img, [(4, 14), (20, 8), (28, 12), (12, 18)], FIRED, 14)
    lit_fill(img, [(4, 14), (12, 18), (12, 25), (4, 21)], FIRED[:3], 15)
    lit_fill(img, [(12, 18), (28, 12), (28, 19), (12, 25)], FIRED[1:4], 16)
    return finish(img)


# ---------------------------------------------------------------------------
# Tool heads and tools
# ---------------------------------------------------------------------------

def blade_pts(ox=0, oy=0, s=1.0):
    return [(ox + 6 * s, oy + 26 * s), (ox + 13 * s, oy + 13 * s), (ox + 24 * s, oy + 4 * s), (ox + 20 * s, oy + 15 * s), (ox + 9 * s, oy + 27 * s)]


def axe_pts(ox=0, oy=0, s=1.0):
    return [(ox + 7 * s, oy + 10 * s), (ox + 16 * s, oy + 4 * s), (ox + 26 * s, oy + 6 * s), (ox + 27 * s, oy + 17 * s),
            (ox + 19 * s, oy + 24 * s), (ox + 12 * s, oy + 20 * s)]


def shovel_pts(ox=0, oy=0, s=1.0):
    return [(ox + 10 * s, oy + 4 * s), (ox + 22 * s, oy + 4 * s), (ox + 25 * s, oy + 12 * s), (ox + 23 * s, oy + 21 * s),
            (ox + 16 * s, oy + 28 * s), (ox + 9 * s, oy + 21 * s), (ox + 7 * s, oy + 12 * s)]


def hoe_pts(ox=0, oy=0, s=1.0):
    return [(ox + 4 * s, oy + 12 * s), (ox + 28 * s, oy + 10 * s), (ox + 26 * s, oy + 16 * s), (ox + 20 * s, oy + 19 * s),
            (ox + 12 * s, oy + 19 * s), (ox + 6 * s, oy + 17 * s)]


def knapped(img, pts, mat, seed):
    lit_fill(img, pts, MATS[mat], seed, noise=0.35)
    # flake scars: a few darker arcs
    r = rnd(seed)
    xs = [p[0] for p in pts]
    ys = [p[1] for p in pts]
    for _ in range(6):
        x = int(r.uniform(min(xs) + 2, max(xs) - 2))
        y = int(r.uniform(min(ys) + 2, max(ys) - 2))
        if img[y, x, 3] > 0:
            put(img, x, y, shade(img[y, x], 0.7), wrap=False)
            if img[y, x + 1, 3] > 0:
                put(img, x + 1, y, shade(img[y, x + 1], 1.2), wrap=False)


def spear_pts(ox=0, oy=0, s=1.0):
    return [(ox + 9 * s, oy + 23 * s), (ox + 14 * s, oy + 13 * s), (ox + 26 * s, oy + 4 * s), (ox + 19 * s, oy + 17 * s), (ox + 11 * s, oy + 25 * s)]


HEADS = {"knife_blade": blade_pts, "axe_head": axe_pts, "shovel_head": shovel_pts, "hoe_head": hoe_pts, "spear_head": spear_pts}
for head, fn in HEADS.items():
    for mat in MATS:
        def _head(fn=fn, mat=mat, head=head):
            img = blank()
            knapped(img, fn(), mat, hash(head) % 97)
            return finish(img)
        ICONS.append(("%s@%s" % (head, mat), _head))


def lashing(img, x, y):
    for i in range(-2, 3):
        put(img, x + i, y - i, "#c9b27a", wrap=False)
        put(img, x + i + 1, y - i, "#8c7748", wrap=False)


def tool(kind, mat):
    img = blank()
    if kind == "knife":
        stroke(img, 4, 28, 13, 19, 3.0, WOOD, 20)
        knapped(img, [(11, 21), (16, 14), (27, 4), (22, 15), (14, 23)], mat, 21)
        lashing(img, 12, 20)
    elif kind == "axe":
        stroke(img, 6, 29, 21, 6, 3.0, WOOD, 22)
        knapped(img, [(10, 11), (17, 6), (27, 7), (28, 17), (21, 21), (15, 16)], mat, 23)
        lashing(img, 17, 12)
    elif kind == "shovel":
        stroke(img, 4, 29, 17, 13, 3.0, WOOD, 24)
        knapped(img, [(14, 9), (21, 4), (28, 7), (28, 14), (21, 19), (15, 15)], mat, 25)
        lashing(img, 16, 14)
    elif kind == "hoe":
        stroke(img, 5, 29, 21, 6, 3.0, WOOD, 26)
        knapped(img, [(14, 6), (27, 3), (28, 9), (22, 13), (17, 11)], mat, 27)
        lashing(img, 19, 9)
    elif kind == "spear":
        stroke(img, 2, 30, 21, 11, 2.4, WOOD, 28)
        knapped(img, [(19, 13), (22, 8), (30, 1), (25, 10), (21, 15)], mat, 29)
        lashing(img, 21, 12)
    return finish(img)


for kind in ["knife", "axe", "shovel", "hoe", "spear"]:
    for mat in MATS:
        ICONS.append(("%s@%s" % (kind, mat), (lambda kind=kind, mat=mat: tool(kind, mat))))


@icon("firestarter")
def _():
    img = blank()
    # a bow drill: a hearth board with a glowing ember at the notch, the drill
    # standing in it, and the bow lying across at an angle
    poly(img, [(3, 26), (27, 23), (28, 28), (4, 31)], lambda x, y: hexc("#9b7547") if y < 28 else hexc("#735333"))
    stroke(img, 11, 6, 13, 26, 2.6, WOOD, 28)
    blob(img, 13, 26, 2.2, 1.4, lambda dx, dy: hexc("#ffb340") if dx * dx + dy * dy < 0.4 else hexc("#d0441a"), wrap=False)
    for i, (x, y) in enumerate([(14, 22), (16, 20), (15, 18)]):
        put(img, x, y, (0.75, 0.75, 0.75, 0.7 - i * 0.15), wrap=False)
    # the bow: an arc from lower left to upper right, string straight across
    a, b = (5, 19), (29, 7)
    pts = []
    for i in range(25):
        t = i / 24.0
        x = a[0] + (b[0] - a[0]) * t
        y = a[1] + (b[1] - a[1]) * t
        bulge = math.sin(t * math.pi) * 5.5
        pts.append((x + bulge * 0.45, y + bulge * 0.9))
    for (x0, y0), (x1, y1) in zip(pts, pts[1:]):
        line(img, x0, y0, x1, y1, "#7a5636")
        line(img, x0, y0 + 1, x1, y1 + 1, "#4e3720")
    line(img, a[0], a[1], 12, 15, "#e8dcb8")
    line(img, 13, 14, b[0], b[1], "#e8dcb8")
    return finish(img)


@icon("torch")
def _():
    img = blank()
    stroke(img, 9, 28, 20, 11, 3.0, WOOD, 30)
    blob(img, 21, 9, 4.5, 4, lambda dx, dy: hexc("#c8b06a") if (dx + dy) < 0.3 else hexc("#9c8240"), wrap=False)
    return finish(img)


@icon("torch_lit")
def _():
    img = blank()
    stroke(img, 9, 28, 20, 11, 3.0, WOOD, 30)
    blob(img, 21, 10, 4.0, 3.5, lambda dx, dy: hexc("#4a3a22"), wrap=False)
    blob(img, 22, 6, 5, 6, lambda dx, dy: ramp(["#ffe9a0", "#ffb340", "#f06a1e", "#c2301a"],
                                               np.array([[min(1.0, math.hypot(dx, dy) * 0.9 + dy * 0.2 + 0.1)]]))[0, 0]
         if dy < 0.6 - abs(dx) * 0.5 else None, wrap=False)
    return outline(bevel(img), "#3a160a")


# ---------------------------------------------------------------------------
# Pottery
# ---------------------------------------------------------------------------

def bowl(cols, fill=None):
    img = blank()
    lit_fill(img, [(3, 13), (29, 13), (26, 21), (20, 26), (12, 26), (6, 21)], cols, 40)
    # the rim seen from above
    blob(img, 16, 13, 13, 3.2, lambda dx, dy: hexc(fill) if fill else shade(hexc(cols[1]), 0.8 - dy * 0.1), wrap=False)
    return finish(img)


@icon("bowl_raw")
def _():
    return bowl(CLAY_RAW)


@icon("bowl")
def _():
    return bowl(FIRED)


@icon("bowl@water")
def _():
    return bowl(FIRED, "#3d78a4")


@icon("bowl@stew")
def _():
    return bowl(FIRED, "#7a5130")


def pot(cols, fill=None):
    img = blank()
    lit_fill(img, [(7, 9), (25, 9), (28, 16), (26, 24), (20, 28), (12, 28), (6, 24), (4, 16)], cols, 41)
    blob(img, 16, 9, 9.5, 2.6, lambda dx, dy: hexc(fill) if fill else shade(hexc(cols[0]), 0.9), wrap=False)
    for x0 in (3, 27):
        put(img, x0, 13, cols[2], wrap=False)
        put(img, x0, 14, cols[1], wrap=False)
    return finish(img)


@icon("pot_raw")
def _():
    return pot(CLAY_RAW)


@icon("pot")
def _():
    return pot(FIRED)


@icon("pot@water")
def _():
    return pot(FIRED, "#3d78a4")


@icon("pot@stew")
def _():
    return pot(FIRED, "#7a5130")


def jar(cols):
    img = blank()
    lit_fill(img, [(12, 4), (20, 4), (20, 8), (26, 13), (27, 21), (22, 28), (10, 28), (5, 21), (6, 13), (12, 8)], cols, 42)
    blob(img, 16, 4, 4.5, 1.4, lambda dx, dy: shade(hexc(cols[0]), 0.8), wrap=False)
    return finish(img)


@icon("jar_raw")
def _():
    return jar(CLAY_RAW)


@icon("jar")
def _():
    return jar(FIRED)


# ---------------------------------------------------------------------------
# Food
# ---------------------------------------------------------------------------

@icon("berries")
def _():
    img = blank()
    poly(img, [(14, 6), (22, 3), (24, 8), (17, 10)], lambda x, y: hexc("#4b7a2f") if y < 7 else hexc("#3a6024"))
    for cx, cy in [(11, 16), (18, 14), (15, 21), (22, 20), (9, 23), (19, 26), (25, 14)]:
        blob(img, cx, cy, 3.6, 3.6, lambda dx, dy: ramp(["#9db4ec", "#4a68c0", "#2f468a", "#1c2a5c"],
                                                         np.array([[0.35 + (dx + dy) * 0.3]]))[0, 0], wrap=False)
        put(img, cx - 1, cy - 1, "#d5e0fa", wrap=False)
    return finish(img)


def mushroom(cap, stem):
    img = blank()
    poly(img, [(13, 15), (19, 15), (20, 27), (12, 27)], lambda x, y: hexc(stem) if x < 17 else shade(hexc(stem), 0.85))
    blob(img, 16, 14, 12, 8, lambda dx, dy: shade(hexc(cap), 1.0 - dy * 0.2 - dx * 0.1) if dy < 0.35 else None, wrap=False)
    put(img, 11, 10, shade(hexc(cap), 1.35), wrap=False)
    put(img, 12, 10, shade(hexc(cap), 1.25), wrap=False)
    return finish(img)


@icon("mushroom")
def _():
    return mushroom("#8a5a35", "#e2d6c0")


@icon("mushroom_roasted")
def _():
    return mushroom("#5a3418", "#a8835a")


def turnip(body, top):
    img = blank()
    blob(img, 16, 20, 9, 8, lambda dx, dy: shade(hexc(top if dy < -0.15 else body), 1.0 - dx * 0.12 - dy * 0.1), wrap=False)
    line(img, 16, 28, 17, 31, "#bdb3a5")
    for dx in (-4, 0, 4):
        line(img, 16, 12, 16 + dx, 3, "#4f8a2f")
        line(img, 17, 12, 17 + dx, 4, "#3c6e22")
    return finish(img)


@icon("turnip")
def _():
    return turnip("#e8e1ee", "#8e4b9a")


@icon("turnip_roasted")
def _():
    img = blank()
    blob(img, 16, 19, 10, 8, lambda dx, dy: shade(hexc("#c78a45" if dy > -0.2 else "#7a4a52"), 1.0 - dx * 0.12 - dy * 0.12), wrap=False)
    for p in [(12, 17), (19, 21), (15, 23)]:
        put(img, p[0], p[1], "#5a3418", wrap=False)
    return finish(img)


def root(cols):
    img = blank()
    stroke(img, 5, 22, 27, 12, 6.0, cols, 50)
    for x in (9, 15, 21):
        line(img, x, 20 - (x - 9) * 0.4, x - 2, 27, "#b9a886")
    return finish(img)


@icon("cattail_root")
def _():
    return root(["#8f7a5a", "#a89270", "#c0aa86", "#d4c19d"])


@icon("cattail_roasted")
def _():
    return root(["#5a3a1f", "#7a522c", "#98693a", "#b1814a"])


@icon("charred_food")
def _():
    img = blank()
    lit_fill(img, [(7, 16), (12, 9), (21, 8), (26, 14), (24, 23), (14, 25)], ["#0e0b0a", "#1d1714", "#2c2420", "#3d322b"], 51)
    return finish(img, "#050404")


def seeds(cols, seed):
    img = blank()
    r = rnd(seed)
    for _ in range(16):
        x, y = r.uniform(8, 24), r.uniform(12, 25)
        blob(img, x, y, 1.8, 1.3, lambda dx, dy: shade(hexc(r.choice(cols)), 1.0 - dy * 0.3), wrap=False)
    return finish(img)


@icon("seeds_turnip")
def _():
    return seeds(["#5a3a28", "#6e4a34", "#7e5a40"], 60)


@icon("seeds_flax")
def _():
    return seeds(["#a5793e", "#b98a4a", "#c99c5c"], 61)


# ---------------------------------------------------------------------------
# The sea
# ---------------------------------------------------------------------------

ICONS.append(("palm_log", lambda: iso("palm_log_top", "palm_log", "palm_log")))
@icon("sapling_palm")
def _():
    # a young palm: a short ringed stem and a fan of fronds, in a tuft of sand
    img = blank()
    blob(img, 16, 27, 8, 3, lambda dx, dy: shade(hexc("#d8c48e"), 1.0 - dy * 0.15), wrap=False)
    stroke(img, 16, 27, 16, 15, 2.4, ["#5a4630", "#6d5639", "#816744"], 89)
    for ang, ln in [(-150, 11), (-120, 12), (-90, 10), (-60, 12), (-30, 11), (-170, 8), (-10, 8)]:
        a = math.radians(ang)
        for i in range(ln):
            t = i / ln
            x = 16 + math.cos(a) * i
            y = 15 + math.sin(a) * i + t * t * 5
            c = ["#2f6b2a", "#3c7f33", "#4d943d"][i % 3]
            put(img, int(x), int(y), c, wrap=False)
            put(img, int(x), int(y) + 1, shade(hexc(c), 0.8), wrap=False)
    return finish(img)


@icon("palm_frond")
def _():
    img = blank()
    # a long midrib with leaflets down both sides
    for i in range(24):
        x = 4 + i
        y = 27 - i * 0.9
        put(img, x, int(y), "#9aa858", wrap=False)
        for j in range(1, 5):
            c = ["#3e6b23", "#4a7a29", "#558a30", "#62983a"][(i + j) % 4]
            if i > 2:
                put(img, x - j // 2, int(y - j), c, wrap=False)
                put(img, x + j // 2, int(y + j), c, wrap=False)
    return finish(img)


@icon("coconut")
def _():
    img = blank()
    lit_fill(img, [(8, 14), (12, 8), (19, 7), (25, 11), (26, 19), (21, 26), (13, 26), (8, 21)], ["#3a2818", "#4a3420", "#5a3f26", "#6b4c2e", "#7a5835"], 50)
    for (x, y) in [(13, 11), (16, 10), (14, 14)]:
        put(img, x, y, "#2a1c10", wrap=False)
    return finish(img)


@icon("seaweed")
def _():
    img = blank()
    r = rnd(51)
    for k in range(4):
        x0 = 9 + k * 4 + r.uniform(-1, 1)
        for y in range(4, 29):
            x = x0 + math.sin(y * 0.35 + k) * 2.0
            c = ["#2f6b3a", "#3a7d45", "#2a5e33", "#4b8a4f"][k]
            put(img, int(x), y, c, wrap=False)
            put(img, int(x) + 1, y, shade(hexc(c), 0.85), wrap=False)
    return finish(img)


@icon("bowl@sea")
def _():
    return bowl(FIRED, "#2a8899")


@icon("raft_floor")
def _():
    # logs lashed side by side, seen from above at a slant
    img = blank()
    for k in range(4):
        y0 = 7 + k * 5
        lit_fill(img, [(4, y0 + 2), (24, y0 - 2), (28, y0 + 1), (8, y0 + 5)], ["#6b5638", "#7a6442", "#87704b", "#937b53"], 60 + k)
    for x in (10, 20):
        line(img, x, 4, x + 2, 27, "#c8b06a")
    return finish(img)


@icon("paddle")
def _():
    img = blank()
    stroke(img, 6, 27, 20, 11, 2.4, WOOD, 61)
    lit_fill(img, [(18, 9), (23, 3), (29, 6), (27, 13), (22, 14)], ["#8a6538", "#a47d4c", "#bd935b", "#cfa66c"], 62)
    return finish(img)


@icon("sail")
def _():
    img = blank()
    stroke(img, 15, 30, 15, 2, 2.2, WOOD, 63)
    lit_fill(img, [(16, 5), (28, 7), (27, 23), (16, 21)], ["#a58a4a", "#b99d57", "#ccb066", "#dcc27a"], 64)
    for y in range(7, 22, 4):
        line(img, 17, y, 27, y + 1, "#8c7442")
    return finish(img)


@icon("steering_oar")
def _():
    img = blank()
    stroke(img, 4, 28, 22, 6, 2.4, WOOD, 65)
    lit_fill(img, [(20, 6), (26, 2), (30, 5), (27, 12), (22, 10)], ["#8a6538", "#a47d4c", "#bd935b", "#cfa66c"], 66)
    line(img, 9, 20, 13, 24, "#c8b06a")
    return finish(img)


@icon("anchor")
def _():
    img = blank()
    lit_fill(img, [(8, 16), (13, 11), (21, 11), (25, 16), (22, 25), (11, 25)], MATS["stone"], 67)
    for i in range(10):
        put(img, 16 + int(math.sin(i * 0.8) * 2), 1 + i, "#b39d6a", wrap=False)
    return finish(img)


def meat(lean, fat, seed):
    img = blank()
    lit_fill(img, [(5, 15), (9, 8), (18, 6), (26, 9), (28, 17), (23, 25), (12, 26), (6, 22)], lean, seed)
    # a rim of fat and a bone end
    for i in range(14):
        a = i / 13.0 * math.pi
        put(img, int(16 + math.cos(a) * 11), int(17 + math.sin(a) * 8), fat, wrap=False)
    blob(img, 8, 21, 3, 3, lambda dx, dy: shade(hexc("#e8e0cc"), 1.0 - dy * 0.15), wrap=False)
    return finish(img)


@icon("meat_raw")
def _():
    return meat(["#7a1f22", "#93282a", "#ab3a37", "#c45550", "#d77a72"], "#efe2d4", 80)


@icon("meat_cooked")
def _():
    return meat(["#4a2614", "#5e321b", "#764224", "#8d5530", "#a46a3e"], "#c99b62", 81)


def crab(body, leg):
    img = blank()
    # legs and claws first, the shell over them
    for side in (-1, 1):
        for k in range(3):
            y = 17 + k * 3
            line(img, 16 + side * 6, y, 16 + side * 12, y + 3, leg)
            line(img, 16 + side * 12, y + 3, 16 + side * 13, y + 6, leg)
        line(img, 16 + side * 6, 13, 16 + side * 10, 8, leg)
        blob(img, 16 + side * 11, 6, 3, 2, lambda dx, dy: shade(hexc(body[2]), 1.0 - dy * 0.2), wrap=False)
    lit_fill(img, [(8, 15), (11, 11), (21, 11), (24, 15), (21, 21), (11, 21)], body, 82)
    put(img, 13, 11, "#111111", wrap=False)
    put(img, 19, 11, "#111111", wrap=False)
    return finish(img)


@icon("crab_raw")
def _():
    return crab(["#4b2a1e", "#6a3a26", "#87502f", "#a3663a", "#bb7c48"], "#7a4a2c")


@icon("crab_cooked")
def _():
    return crab(["#8e2414", "#b2361c", "#d14b26", "#e66a38", "#f08a55"], "#c2482a")


def egg(cols, seed):
    img = blank()
    blob(img, 16, 17, 8, 10, lambda dx, dy: ramp(cols, np.array([[0.75 - dx * 0.25 - dy * 0.3]]), steps=len(cols))[0, 0], wrap=False)
    r = rnd(seed)
    for _ in range(6):
        x, y = int(r.uniform(11, 21)), int(r.uniform(11, 24))
        if img[y, x, 3] > 0:
            put(img, x, y, shade(img[y, x], 0.85), wrap=False)
    return finish(img)


@icon("egg")
def _():
    return egg(["#b39e7c", "#cbb795", "#ddcbaa", "#ebdcc0", "#f5ead6"], 83)


@icon("egg_roasted")
def _():
    return egg(["#6b4a2c", "#86603a", "#a07a4c", "#b89260", "#ccaa78"], 84)


@icon("hide")
def _():
    img = blank()
    lit_fill(img, [(6, 9), (11, 5), (15, 8), (20, 5), (26, 9), (25, 17), (28, 24), (21, 27), (16, 24), (10, 28), (4, 23), (7, 16)],
             ["#4a3424", "#5e432d", "#735538", "#8a6844", "#9e7b52"], 85, noise=0.4)
    return finish(img)


def skin_bag(fill):
    img = blank()
    lit_fill(img, [(9, 12), (13, 9), (20, 9), (24, 13), (26, 22), (22, 28), (11, 28), (7, 22)], ["#4b3322", "#5e412b", "#735236", "#876342", "#9b744e"], 86)
    stroke(img, 14, 9, 17, 3, 2.6, ["#3b2819", "#4b3322", "#5e412b"], 87)
    for i in range(-2, 3):
        put(img, 16 + i, 8, "#c9b27a", wrap=False)
    if fill:
        blob(img, 16, 20, 5, 4, lambda dx, dy: (0.0, 0.0, 0.0, 0.0), wrap=False)
        lit_fill(img, [(12, 18), (20, 18), (21, 22), (16, 25), (11, 22)], ["#3c4f5a", "#4e6773", "#5f7d8a"], 88)
    return finish(img)


@icon("waterskin")
def _():
    return skin_bag(False)


@icon("waterskin@water")
def _():
    return skin_bag(True)


@icon("hand")
def _():
    # the bare hand (first person, nothing held)
    img = blank()
    lit_fill(img, [(10, 31), (10, 18), (13, 14), (22, 14), (24, 18), (24, 31)], ["#9c6b4f", "#b98264", "#d3a17d", "#e3b892"], 70)
    return finish(img)


def build():
    out = []
    for name, fn in ICONS:
        arr = fn()
        assert arr.shape == (S, S, 4), name
        out.append((name, arr))
    return out


def main():
    icons = build()
    tex_dir = os.path.join(ROOT, "assets", "textures")
    os.makedirs(tex_dir, exist_ok=True)
    atlas(icons).save(os.path.join(tex_dir, "items.png"))
    with open(os.path.join(tex_dir, "items.json"), "w") as f:
        json.dump({"tile": S, "cols": 16, "names": [n for n, _ in icons]}, f, indent=1)
    if len(sys.argv) > 1:
        sheet(icons, 10).save(sys.argv[1])
    print("icons:", len(icons))


if __name__ == "__main__":
    main()
