"""Generates every block / surface texture (32x32, tileable where it matters).

    python3 tools/art/gen_blocks.py [preview.png]

Writes assets/textures/blocks.png (an atlas, 16 tiles per row) and
assets/textures/blocks.json (tile name -> index, plus each tile's average colour,
used for break particles).  The game splits the atlas into a Texture2DArray.
"""
import json
import math
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(__file__))
from pixlib import (S, atlas, avg_color, blank, blob, fbm, hexc, jitter, line, mix, put, ramp, rnd,
                    shade, sheet, vnoise, white)

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
TILES = []


def tile(name):
    def deco(fn):
        TILES.append((name, fn))
        return fn
    return deco


# ---------------------------------------------------------------------------
# Earth
# ---------------------------------------------------------------------------

DIRT = ["#4b3221", "#5a3d27", "#694830", "#795638", "#896243"]


def dirt_base(seed):
    n = fbm(seed, ((4, 0.5), (8, 0.3), (32, 0.2)))
    img = ramp(DIRT, n * 0.9 + 0.05, steps=5)
    r = rnd(seed)
    # pebbles and root fibres
    for _ in range(9):
        x, y = r.randrange(S), r.randrange(S)
        c = r.choice(["#8d7a66", "#7a6a5a", "#9b8670", "#3e2a1c"])
        put(img, x, y, c)
        if r.random() < 0.5:
            put(img, x + 1, y, shade(hexc(c), 0.8))
    return img


@tile("dirt")
def _():
    return dirt_base(11)


GRASS = ["#3a5823", "#45662a", "#517431", "#5d8138", "#6a8d40", "#7a9a4a"]


def grass_top(seed):
    n = fbm(seed, ((4, 0.45), (8, 0.3), (32, 0.25)))
    img = ramp(GRASS, n * 0.85 + 0.08, steps=6)
    r = rnd(seed + 1)
    # short blade strokes: a light pixel with a dark one under it
    for _ in range(70):
        x, y = r.randrange(S), r.randrange(S)
        put(img, x, y, "#8aa85a" if r.random() < 0.55 else "#34521f")
        if r.random() < 0.6:
            put(img, x, y + 1, "#40612a")
    for _ in range(4):  # a few tiny flowers / seed heads
        x, y = r.randrange(S), r.randrange(S)
        put(img, x, y, r.choice(["#d9d27a", "#c7c9a1"]))
    return img


@tile("grass_top")
def _():
    return grass_top(21)


@tile("grass_side")
def _():
    img = dirt_base(12)
    top = grass_top(21)
    r = rnd(5)
    for x in range(S):
        h = 3 + int(2.5 * (math.sin(x * 0.9) * 0.5 + 0.5)) + r.randrange(0, 3)
        if r.random() < 0.18:
            h += r.randrange(2, 5)
        for y in range(h):
            img[y, x] = top[y, x]
        # shadowed lip under the turf
        put(img, x, h, shade(img[h % S, x], 0.72), wrap=False)
    return img


@tile("farmland")
def _():
    n = fbm(31, ((4, 0.5), (16, 0.5)))
    img = ramp(["#3a261a", "#47301f", "#563a26", "#644530"], n, steps=4)
    for y in range(S):
        f = (y % 8)
        k = [0.7, 0.85, 1.05, 1.12, 1.1, 1.0, 0.9, 0.78][f]
        img[y, :, :3] *= k
    return jitter(img, 4, 0.05)


@tile("farmland_wet")
def _():
    n = fbm(31, ((4, 0.5), (16, 0.5)))
    img = ramp(["#24180f", "#2f2015", "#3a281a", "#463121"], n, steps=4)
    for y in range(S):
        k = [0.7, 0.85, 1.05, 1.12, 1.1, 1.0, 0.9, 0.78][y % 8]
        img[y, :, :3] *= k
    return jitter(img, 5, 0.05)


STONE = ["#57534f", "#65615c", "#726e69", "#807b75", "#8e8983", "#9c968f"]


def stone_base(seed, cols=STONE):
    n = fbm(seed, ((4, 0.4), (8, 0.35), (16, 0.25)))
    img = ramp(cols, n, steps=6)
    r = rnd(seed)
    w = white(seed + 3)
    # granite speckle: pale feldspar, dark mica
    for y in range(S):
        for x in range(S):
            if w[y, x] > 0.93:
                img[y, x] = hexc("#bfb2a5") if w[y, x] > 0.965 else hexc("#a99a8d")
            elif w[y, x] < 0.05:
                img[y, x] = hexc("#3c3936")
    # a couple of hairline cracks
    for _ in range(2):
        x, y = r.randrange(S), r.randrange(S)
        for _ in range(r.randrange(5, 11)):
            put(img, x, y, shade(img[y % S, x % S], 0.62))
            x += r.choice([-1, 0, 1])
            y += 1
    return img


@tile("stone")
def _():
    return stone_base(41)


@tile("stone_mossy")
def _():
    img = stone_base(42)
    m = fbm(43, ((4, 0.6), (8, 0.4)))
    moss = ramp(["#3c5a26", "#4b6c2e", "#5a7d36"], fbm(44), steps=3)
    sel = m > 0.58
    img[sel] = moss[sel]
    return img


@tile("gravel")
def _():
    img = blank("#3b3631")
    r = rnd(51)
    cols = ["#7d7770", "#8f8880", "#6c665f", "#9d958b", "#857565", "#5e5852"]
    for _ in range(60):
        cx, cy = r.uniform(0, S), r.uniform(0, S)
        rx, ry = r.uniform(1.4, 3.0), r.uniform(1.2, 2.5)
        c = hexc(r.choice(cols))

        def f(dx, dy, c=c):
            k = 1.0 + (-dx - dy) * 0.12
            if dx * dx + dy * dy > 0.7:
                k *= 0.8
            return shade(np.array(c), k)
        blob(img, cx, cy, rx, ry, f)
    return jitter(img, 52, 0.04)


@tile("sand")
def _():
    n = fbm(61, ((4, 0.4), (16, 0.3), (32, 0.3)))
    img = ramp(["#b79f72", "#c4ac7e", "#d0b98a", "#dac597"], n, steps=4)
    w = white(62)
    img[w > 0.95] = hexc("#e8d9b3")
    img[w < 0.04] = hexc("#a48b60")
    return img


CLAY = ["#6d7983", "#7a8791", "#86949e", "#93a0a9", "#9eabb3"]


@tile("clay")
def _():
    n = fbm(71, ((2, 0.4), (8, 0.35), (16, 0.25)))
    # soft horizontal banding of a sediment
    for y in range(S):
        n[y, :] = n[y, :] * 0.75 + (math.sin(y * 0.55) * 0.5 + 0.5) * 0.25
    img = ramp(CLAY, n, steps=5)
    r = rnd(72)
    for _ in range(6):
        x, y = r.randrange(S), r.randrange(S)
        put(img, x, y, "#5e6a73")
        put(img, x + 1, y, "#65717a")
    return img


@tile("clay_raw")
def _():
    # worked clay: smooth, with finger marks
    n = fbm(73, ((4, 0.6), (8, 0.4)))
    return ramp(["#7f8a93", "#8b969f", "#97a2ab", "#a2adb5"], n, steps=4)


@tile("terracotta")
def _():
    n = fbm(74, ((4, 0.5), (8, 0.3), (32, 0.2)))
    img = ramp(["#8f4a2d", "#a05535", "#b0613e", "#bd6e48", "#c77c55"], n, steps=5)
    w = white(75)
    img[w > 0.96] = hexc("#7b3d24")
    return img


@tile("ash")
def _():
    n = fbm(81, ((4, 0.4), (16, 0.6)))
    img = ramp(["#5c5956", "#73706c", "#8b8883", "#a29f99", "#b8b5ae"], n, steps=5)
    w = white(82)
    img[w > 0.97] = hexc("#2d2a28")
    return img


# ---------------------------------------------------------------------------
# Wood
# ---------------------------------------------------------------------------

def bark(seed, cols, ridge_cols):
    n = fbm(seed, ((4, 0.3), (8, 0.3), (16, 0.4)))
    img = ramp(cols, n, steps=len(cols))
    r = rnd(seed)
    # vertical furrows that wander
    for _ in range(7):
        x = r.uniform(0, S)
        for y in range(S):
            x += r.uniform(-0.45, 0.45)
            put(img, int(x), y, ridge_cols[0])
            if r.random() < 0.5:
                put(img, int(x) + 1, y, ridge_cols[1])
    return img


@tile("log_oak")
def _():
    return bark(91, ["#3e2c1d", "#4a3523", "#563e29", "#634731", "#6e5038"], ["#2b1e14", "#352619"])


@tile("log_oak_top")
def _():
    img = blank()
    c = (S - 1) / 2.0
    for y in range(S):
        for x in range(S):
            d = math.hypot(x - c, y - c)
            a = math.atan2(y - c, x - c)
            dd = d + math.sin(a * 5) * 0.4
            if d > 14.6:
                img[y, x] = hexc("#46321f")
            elif d > 13.2:
                img[y, x] = hexc("#5a4129")
            else:
                ring = (dd * 0.9) % 3.0
                base = hexc("#b08a59") if ring > 0.9 else hexc("#94723f")
                img[y, x] = base
    img[int(c), int(c)] = hexc("#6e5430")
    return jitter(img, 92, 0.05)


@tile("log_birch")
def _():
    n = fbm(93, ((4, 0.5), (16, 0.5)))
    img = ramp(["#c9c3b5", "#d6d1c3", "#e2ddd0", "#ebe7db"], n, steps=4)
    r = rnd(94)
    for _ in range(11):
        x, y = r.randrange(S), r.randrange(S)
        ln = r.randrange(2, 7)
        for i in range(ln):
            put(img, x + i, y, "#2a2522" if i % 3 else "#4a433d")
        if r.random() < 0.4:
            put(img, x + 1, y + 1, "#6e6458")
    return img


@tile("log_birch_top")
def _():
    img = blank()
    c = (S - 1) / 2.0
    for y in range(S):
        for x in range(S):
            d = math.hypot(x - c, y - c)
            if d > 14.6:
                img[y, x] = hexc("#d8d2c4")
            elif d > 13.4:
                img[y, x] = hexc("#8d8070")
            else:
                ring = (d * 0.9) % 3.0
                img[y, x] = hexc("#d7bf8f") if ring > 0.9 else hexc("#c3a874")
    return jitter(img, 95, 0.04)


@tile("firewood")
def _():
    # split wood: pale heartwood with grain, a strip of bark along one edge
    img = blank()
    n = fbm(96, ((2, 0.5), (8, 0.5)))
    for y in range(S):
        for x in range(S):
            g = math.sin(x * 0.9 + n[y, x] * 6.0) * 0.5 + 0.5
            img[y, x] = mix(hexc("#a47d4c"), hexc("#c49c66"), g)
    for y in range(S):
        for x in range(0, 4):
            img[y, x] = hexc("#4a3523") if x < 3 else hexc("#3a281a")
    return jitter(img, 97, 0.04)


@tile("firewood_end")
def _():
    img = blank()
    for y in range(S):
        for x in range(S):
            d = math.hypot(x - 31, y - 31)
            ring = d % 3.4
            img[y, x] = hexc("#b48d58") if ring > 1.2 else hexc("#9a7744")
            if x > 28 or y > 28:
                img[y, x] = hexc("#4a3523")
    return jitter(img, 98, 0.04)


@tile("stick")
def _():
    return bark(99, ["#4f3a26", "#5c452e", "#6a5036", "#775b3e"], ["#3a2a1b", "#43311f"])


@tile("charred")
def _():
    n = fbm(101, ((4, 0.4), (16, 0.6)))
    img = ramp(["#141110", "#1f1a17", "#2b2420", "#38302a"], n, steps=4)
    r = rnd(102)
    for _ in range(14):
        x, y = r.randrange(S), r.randrange(S)
        for i in range(r.randrange(2, 6)):
            put(img, x + i, y, "#0b0908")
    return img


@tile("embers")
def _():
    n = fbm(103, ((4, 0.4), (8, 0.6)))
    img = ramp(["#2a120a", "#7a2510", "#c4441a", "#f08a2c", "#ffd36a"], n ** 1.4, steps=5)
    return img


@tile("planks")
def _():
    img = blank()
    n = fbm(104, ((2, 0.5), (16, 0.5)))
    for y in range(S):
        board = y // 8
        for x in range(S):
            g = math.sin(x * 0.7 + board * 2.0 + n[y, x] * 5) * 0.5 + 0.5
            c = mix(hexc("#8a6439"), hexc("#a77c4b"), g)
            if y % 8 == 7:
                c = hexc("#4f3820")
            img[y, x] = c
        off = (board * 13) % S
        img[y, off] = hexc("#5a4126")
    return jitter(img, 105, 0.03)


# ---------------------------------------------------------------------------
# Plants (cut-out)
# ---------------------------------------------------------------------------

def leaves(seed, cols, hole=0.22):
    n = fbm(seed, ((8, 0.5), (16, 0.5)))
    img = ramp(cols, n, steps=len(cols))
    r = rnd(seed)
    # leaf clusters: brighter top-left, darker bottom-right
    for _ in range(26):
        cx, cy = r.uniform(0, S), r.uniform(0, S)

        def f(dx, dy):
            k = 1.0 + (-dx - dy) * 0.16
            return shade(ramp(cols, np.array([[0.65]]))[0, 0], k)
        blob(img, cx, cy, r.uniform(1.5, 2.8), r.uniform(1.2, 2.4), f)
    h = white(seed + 9)
    hn = vnoise(16, seed + 10)
    img[(h * 0.5 + hn * 0.5) < hole, 3] = 0.0
    return img


@tile("leaves_oak")
def _():
    return leaves(111, ["#2c4d1d", "#365c22", "#416b28", "#4d7a2f", "#5a8936"])


@tile("leaves_birch")
def _():
    return leaves(112, ["#45702a", "#527f31", "#5f8f38", "#6d9e41", "#7cad4b"], 0.26)


@tile("leaves_bush")
def _():
    return leaves(113, ["#2e4f22", "#385d28", "#436b2e", "#4f7a35"], 0.12)


@tile("berries_overlay")
def _():
    img = leaves(113, ["#2e4f22", "#385d28", "#436b2e", "#4f7a35"], 0.12)
    r = rnd(114)
    for _ in range(11):
        x, y = r.randrange(1, S - 2), r.randrange(1, S - 2)
        put(img, x, y, "#3f5fae")
        put(img, x + 1, y, "#2f468a")
        put(img, x, y + 1, "#2f468a")
        put(img, x + 1, y + 1, "#22346a")
        put(img, x, y, "#9db4ec")
    return img


def blades(seed, cols, n=11, hmin=12, hmax=28, curve=0.25, width=1, tips=None):
    img = blank()
    r = rnd(seed)
    for i in range(n):
        x0 = r.uniform(3, S - 4)
        h = r.uniform(hmin, hmax)
        lean = r.uniform(-curve, curve) * h
        c = hexc(r.choice(cols))
        steps = int(h)
        for s in range(steps):
            t = s / max(1, steps - 1)
            x = x0 + lean * t * t
            y = S - 1 - s
            k = 0.75 + 0.35 * t
            for w in range(width):
                put(img, int(x) + w, y, shade(c, k), wrap=False)
        if tips:
            x = x0 + lean
            put(img, int(x), int(S - steps), tips, wrap=False)
    return img


@tile("tallgrass")
def _():
    return blades(121, ["#45662a", "#517431", "#5d8138", "#6a8d40"], n=14, hmin=10, hmax=26)


@tile("tallgrass_dry")
def _():
    return blades(122, ["#a8934f", "#b9a35d", "#c6b06a", "#97843f"], n=13, hmin=10, hmax=24)


@tile("fern")
def _():
    img = blank()
    r = rnd(123)
    for f in range(5):
        x0 = r.uniform(10, 22)
        ang = r.uniform(-1.0, 1.0)
        ln = r.uniform(14, 24)
        for s in range(int(ln)):
            t = s / ln
            x = x0 + math.sin(ang) * s * 0.9 + ang * t * t * 4
            y = S - 1 - math.cos(ang * 0.6) * s
            put(img, int(x), int(y), "#3d6a2a", wrap=False)
            if s % 2 == 0 and s > 2:
                w = int((1 - t) * 4) + 1
                for k in range(1, w + 1):
                    put(img, int(x) - k, int(y) - (k // 2), "#4f7f33", wrap=False)
                    put(img, int(x) + k, int(y) - (k // 2), "#5a8c3a", wrap=False)
    return img


def flower(seed, petal, centre):
    img = blades(seed, ["#4b742a", "#588532"], n=5, hmin=8, hmax=16)
    r = rnd(seed + 1)
    for _ in range(4):
        x, y = r.uniform(6, 26), r.uniform(6, 16)
        for dx, dy in ((0, -1), (1, 0), (0, 1), (-1, 0)):
            put(img, int(x) + dx, int(y) + dy, petal, wrap=False)
        put(img, int(x), int(y), centre, wrap=False)
        line(img, int(x), int(y) + 2, int(x) + r.choice([-1, 0, 1]), S - 1, "#4b742a")
    return img


@tile("flower_red")
def _():
    return flower(131, "#c4392f", "#f2c14e")


@tile("flower_yellow")
def _():
    return flower(132, "#e8c33a", "#a6741f")


@tile("flower_blue")
def _():
    return flower(133, "#5d7fd6", "#f0e6a8")


@tile("reeds")
def _():
    img = blades(141, ["#5b7d34", "#6b8c3c", "#4e6e2c"], n=9, hmin=22, hmax=31, curve=0.1, width=1)
    r = rnd(142)
    for _ in range(3):
        x = r.randrange(6, 26)
        y = r.randrange(2, 8)
        for dy in range(5):
            put(img, x, y + dy, "#5a3b22", wrap=False)
            put(img, x + 1, y + dy, "#6e4a2b", wrap=False)
        line(img, x, y + 5, x, S - 1, "#5b7d34")
    return img


@tile("mushroom")
def _():
    img = blank()
    for cx, cy, rr in ((11, 22, 5.5), (21, 25, 4.0)):
        for y in range(int(cy), S):
            put(img, int(cx), y, "#e2d6c0", wrap=False)
            put(img, int(cx) + 1, y, "#cfc1a8", wrap=False)

        def cap(dx, dy):
            if dy > 0.25:
                return None
            k = 1.0 - dy * 0.2 + (-dx) * 0.1
            return shade(hexc("#8a5a35"), k)
        blob(img, cx + 0.5, cy, rr, rr * 0.7, cap, wrap=False)
        put(img, int(cx) - 1, int(cy) - 2, "#c69a6c", wrap=False)
    return img


@tile("sapling_oak")
def _():
    img = blank()
    line(img, 16, 31, 16, 14, "#4f3a26")
    line(img, 17, 31, 17, 18, "#5c452e")
    r = rnd(151)
    for _ in range(9):
        x, y = r.uniform(9, 23), r.uniform(5, 19)
        blob(img, x, y, 2.6, 2.0, lambda dx, dy: shade(hexc("#4d7a2f"), 1 + (-dx - dy) * 0.18), wrap=False)
    return img


@tile("sapling_birch")
def _():
    img = blank()
    line(img, 16, 31, 16, 12, "#d6d1c3")
    line(img, 15, 31, 15, 20, "#b9b2a3")
    r = rnd(152)
    for _ in range(8):
        x, y = r.uniform(10, 22), r.uniform(4, 18)
        blob(img, x, y, 2.2, 1.8, lambda dx, dy: shade(hexc("#6d9e41"), 1 + (-dx - dy) * 0.18), wrap=False)
    return img


@tile("roots")
def _():
    img = blank()
    r = rnd(161)
    for _ in range(7):
        x = r.uniform(2, 30)
        ln = r.randrange(12, 32)
        for y in range(ln):
            x += r.uniform(-0.5, 0.5)
            put(img, int(x), y, "#4a3420" if y < ln - 3 else "#6a4b2e", wrap=False)
    return img


@tile("vines")
def _():
    img = blank()
    r = rnd(162)
    for _ in range(5):
        x = r.uniform(3, 29)
        ln = r.randrange(16, 32)
        for y in range(ln):
            x += r.uniform(-0.4, 0.4)
            put(img, int(x), y, "#3a5f27", wrap=False)
            if y % 3 == 0:
                put(img, int(x) + r.choice([-1, 1]), y, "#4f7a33", wrap=False)
    return img


def crop(seed, stage, leaf, top=None):
    img = blank()
    r = rnd(seed + stage)
    n = [3, 5, 7, 8][stage]
    h = [7, 13, 20, 24][stage]
    for _ in range(n):
        x0 = r.uniform(7, 25)
        ang = r.uniform(-0.6, 0.6)
        ln = r.uniform(h * 0.6, h)
        for s in range(int(ln)):
            x = x0 + math.sin(ang) * s * 0.6
            y = S - 1 - s
            put(img, int(x), y, leaf, wrap=False)
            if stage > 0 and s > ln * 0.4:
                put(img, int(x) + 1, y, shade(hexc(leaf), 1.15), wrap=False)
    if top and stage == 3:
        for _ in range(4):
            x, y = r.uniform(8, 24), r.uniform(4, 12)
            put(img, int(x), int(y), top, wrap=False)
            put(img, int(x) + 1, int(y), top, wrap=False)
    return img


for st in range(4):
    TILES.append(("crop_turnip_%d" % st, (lambda st=st: _turnip(st))))
    TILES.append(("crop_flax_%d" % st, (lambda st=st: crop(171, st, "#5e8a3a", "#6a8fd8"))))


def _turnip(st):
    img = crop(181, st, "#4f8a2f")
    if st == 3:
        blob(img, 16, 30, 5, 3.5, lambda dx, dy: shade(hexc("#d9d1e4"), 1 - dy * 0.2) if dy < 0.3 else None, wrap=False)
        blob(img, 16, 28, 4, 2, lambda dx, dy: hexc("#8e4b9a") if dy < 0.5 else None, wrap=False)
    return img


@tile("wild_turnip")
def _():
    return _turnip(3)


@tile("wild_flax")
def _():
    return crop(171, 3, "#5e8a3a", "#6a8fd8")


# ---------------------------------------------------------------------------
# Built / misc
# ---------------------------------------------------------------------------

@tile("thatch")
def _():
    img = blank("#8a7438")
    r = rnd(191)
    for _ in range(90):
        x, y = r.uniform(-4, S), r.uniform(0, S)
        ln = r.uniform(5, 12)
        c = r.choice(["#c9ab5c", "#b89a4e", "#d6ba6c", "#a5873f"])
        for i in range(int(ln)):
            put(img, int(x + i), int(y + i * 0.25), c)
    for y in range(0, S, 8):
        for x in range(S):
            put(img, x, y, shade(img[y, x], 0.7))
    return img


@tile("thatch_top")
def _():
    img = blank("#8a7438")
    r = rnd(192)
    for _ in range(110):
        x, y = r.uniform(0, S), r.uniform(0, S)
        a = r.uniform(-0.5, 0.5)
        c = r.choice(["#c9ab5c", "#b89a4e", "#d6ba6c", "#a5873f"])
        for i in range(r.randrange(4, 10)):
            put(img, int(x + math.cos(a) * i), int(y + math.sin(a) * i), c)
    return img


@tile("brick")
def _():
    img = blank("#b6a78d")
    n = fbm(201, ((4, 0.5), (16, 0.5)))
    for y in range(S):
        row = y // 8
        for x in range(S):
            if y % 8 == 7:
                continue
            xx = (x + (8 if row % 2 else 0)) % S
            if xx % 16 == 15:
                continue
            brick = (xx // 16) + row * 3
            base = ["#8f3f2a", "#a24a31", "#97442d", "#ab5136"][brick % 4]
            img[y, x] = shade(hexc(base), 0.9 + n[y, x] * 0.25)
    return jitter(img, 202, 0.03)


@tile("water")
def _():
    n = fbm(211, ((4, 0.5), (8, 0.5)))
    img = ramp(["#24527a", "#2c5f8a", "#346b97", "#3d78a4"], n, steps=4)
    for y in range(S):
        for x in range(S):
            if (math.sin(x * 0.6 + n[y, x] * 7) + math.sin(y * 0.45)) > 1.55:
                img[y, x] = hexc("#6ea5cc")
    return img


@tile("torch")
def _():
    img = blank()
    for y in range(10, S):
        for x in range(14, 18):
            img[y, x] = hexc("#5c452e") if x < 16 else hexc("#4f3a26")
    for y in range(6, 11):
        for x in range(13, 19):
            img[y, x] = hexc("#b89a4e") if (x + y) % 2 else hexc("#9c8240")
    return img


@tile("flame")
def _():
    img = blank()
    for y in range(S):
        for x in range(S):
            dx = (x - 15.5) / 9.0
            t = y / S
            w = (1 - t) ** 0.3 * (0.4 + t * 0.9)
            v = abs(dx) / max(0.05, w * 0.95)
            if v < 1.0 and y > 2:
                h = (1 - v) * (0.4 + t * 0.8)
                img[y, x] = ramp(["#c2301a", "#ef6a1e", "#ffae3a", "#fff0a8"], np.array([[min(1.0, h)]]))[0, 0]
                img[y, x, 3] = min(1.0, 0.4 + h)
    return img


@tile("straw_bed")
def _():
    img = blank("#a98d44")
    r = rnd(221)
    for _ in range(140):
        x, y = r.uniform(0, S), r.uniform(0, S)
        c = r.choice(["#d0b363", "#bc9e52", "#e0c675", "#9d8239"])
        for i in range(r.randrange(3, 8)):
            put(img, int(x + i), int(y + r.uniform(-0.5, 0.5)), c)
    return img


@tile("flint")
def _():
    n = fbm(231, ((4, 0.5), (8, 0.5)))
    img = ramp(["#2b2f36", "#363b43", "#424852", "#4e5561", "#5d6572"], n, steps=5)
    r = rnd(232)
    for _ in range(5):  # conchoidal ripples
        cx, cy = r.uniform(0, S), r.uniform(0, S)
        for a in range(0, 360, 12):
            rr = r.uniform(4, 7)
            put(img, int(cx + math.cos(math.radians(a)) * rr), int(cy + math.sin(math.radians(a)) * rr), "#6d7787")
    return img


@tile("granite_knap")
def _():
    return stone_base(233, ["#6a6560", "#78736d", "#86807a", "#948e87"])


@tile("dry_grass")
def _():
    img = blank("#8e7a3e")
    r = rnd(241)
    for _ in range(120):
        x, y = r.uniform(0, S), r.uniform(0, S)
        a = r.uniform(0, math.pi)
        c = r.choice(["#c8b06a", "#b39a55", "#d9c27e", "#a28a48"])
        for i in range(r.randrange(4, 9)):
            put(img, int(x + math.cos(a) * i), int(y + math.sin(a) * i), c)
    return img


@tile("bag")
def _():
    n = fbm(251, ((4, 0.5), (16, 0.5)))
    img = ramp(["#5a3f27", "#6b4c30", "#7c5a3a", "#8b6743"], n, steps=4)
    for y in range(S):
        for x in range(S):
            if (x + y) % 6 == 0:
                img[y, x, :3] *= 0.85
    return img


@tile("cloth")
def _():
    # neutral woven cloth, tinted per player
    img = blank("#d8d4cc")
    for y in range(S):
        for x in range(S):
            if (x % 2) ^ (y % 2):
                img[y, x, :3] *= 0.92
    return jitter(img, 252, 0.03)


@tile("skin")
def _():
    return jitter(blank("#d3a17d"), 253, 0.025)


@tile("hair")
def _():
    n = fbm(254, ((4, 0.5), (16, 0.5)))
    return ramp(["#2e2017", "#3b2a1e", "#4a3526"], n, steps=3)


@tile("leather")
def _():
    n = fbm(255, ((4, 0.5), (16, 0.5)))
    return ramp(["#4b3322", "#5a3e2a", "#684a33"], n, steps=3)


# crack overlay stages
for st in range(8):
    def _crack(st=st):
        img = blank()
        r = rnd(300)
        paths = 3 + st
        for p in range(paths):
            x, y = r.uniform(4, 28), r.uniform(4, 28)
            ln = int(3 + st * 2.2)
            for i in range(ln):
                put(img, int(x), int(y), (0.08, 0.06, 0.05, 0.85), wrap=False)
                x += r.choice([-1, 0, 1])
                y += r.choice([-1, 0, 1, 1])
                if not (0 <= x < S and 0 <= y < S):
                    break
        return img
    TILES.append(("crack_%d" % st, _crack))


def build():
    out = []
    for name, fn in TILES:
        arr = fn()
        assert arr.shape == (S, S, 4), name
        out.append((name, arr))
    return out


def main():
    tiles = build()
    tex_dir = os.path.join(ROOT, "assets", "textures")
    os.makedirs(tex_dir, exist_ok=True)
    atlas(tiles).save(os.path.join(tex_dir, "blocks.png"))
    meta = {"tile": S, "cols": 16, "names": [n for n, _ in tiles],
            "avg": {n: [round(c, 3) for c in avg_color(a)] for n, a in tiles}}
    with open(os.path.join(tex_dir, "blocks.json"), "w") as f:
        json.dump(meta, f, indent=1)
    if len(sys.argv) > 1:
        sheet(tiles, 10).save(sys.argv[1])
    print("blocks:", len(tiles))


if __name__ == "__main__":
    main()
