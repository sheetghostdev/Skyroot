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


HEADS = {"knife_blade": blade_pts, "axe_head": axe_pts, "shovel_head": shovel_pts, "hoe_head": hoe_pts}
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
    return finish(img)


for kind in ["knife", "axe", "shovel", "hoe"]:
    for mat in MATS:
        ICONS.append(("%s@%s" % (kind, mat), (lambda kind=kind, mat=mat: tool(kind, mat))))


@icon("firestarter")
def _():
    img = blank()
    # the bow
    for i in range(24):
        t = i / 23.0
        x = 4 + t * 24
        y = 9 + math.sin(t * math.pi) * -5 + 2
        put(img, int(x), int(y), "#735333", wrap=False)
        put(img, int(x), int(y) + 1, "#5e4329", wrap=False)
    line(img, 4, 11, 28, 11, "#d8cba4")
    # the drill and hearth board
    stroke(img, 16, 8, 16, 26, 2.4, WOOD, 28)
    poly(img, [(6, 25), (26, 25), (26, 29), (6, 29)], lambda x, y: hexc("#9b7547") if y < 27 else hexc("#735333"))
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
