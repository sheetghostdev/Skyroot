"""Small pixel-art toolkit used by the texture generators.

Every texture is a 32x32 RGBA numpy array (uint8 after `to_img`, float 0..1 while
being painted).  Noise is tileable so block faces repeat without seams.
"""
import math
import random

import numpy as np
from PIL import Image

S = 32


def hexc(h, a=1.0):
    h = h.lstrip("#")
    return np.array([int(h[0:2], 16) / 255.0, int(h[2:4], 16) / 255.0, int(h[4:6], 16) / 255.0, a])


def blank(fill=None):
    img = np.zeros((S, S, 4))
    if fill is not None:
        img[:, :] = hexc(fill) if isinstance(fill, str) else fill
    return img


# ---------------------------------------------------------------------------
# Noise (tileable)
# ---------------------------------------------------------------------------

def vnoise(cells, seed, size=S):
    """Tileable value noise with `cells` lattice cells across the tile."""
    rng = np.random.default_rng(seed)
    g = rng.random((cells, cells))
    out = np.zeros((size, size))
    for y in range(size):
        fy = y / size * cells
        y0 = int(fy) % cells
        y1 = (y0 + 1) % cells
        ty = fy - int(fy)
        ty = ty * ty * (3 - 2 * ty)
        for x in range(size):
            fx = x / size * cells
            x0 = int(fx) % cells
            x1 = (x0 + 1) % cells
            tx = fx - int(fx)
            tx = tx * tx * (3 - 2 * tx)
            a = g[y0, x0] * (1 - tx) + g[y0, x1] * tx
            b = g[y1, x0] * (1 - tx) + g[y1, x1] * tx
            out[y, x] = a * (1 - ty) + b * ty
    return out


def fbm(seed, octaves=((4, 0.55), (8, 0.3), (16, 0.15)), size=S):
    out = np.zeros((size, size))
    tot = 0.0
    for i, (cells, w) in enumerate(octaves):
        out += vnoise(cells, seed * 31 + i * 7, size) * w
        tot += w
    out /= tot
    lo, hi = out.min(), out.max()
    return (out - lo) / max(1e-6, hi - lo)


def white(seed, size=S):
    return np.random.default_rng(seed).random((size, size))


# ---------------------------------------------------------------------------
# Colour ramps
# ---------------------------------------------------------------------------

def ramp(colors, t, steps=None):
    """Map t (array 0..1) through a list of hex colours.  `steps` quantises the
    result into that many bands for a crisp pixel-art look."""
    cols = [hexc(c) if isinstance(c, str) else np.asarray(c) for c in colors]
    t = np.clip(t, 0.0, 1.0)
    if steps:
        t = np.floor(t * steps) / max(1, steps - 1)
        t = np.clip(t, 0.0, 1.0)
    n = len(cols) - 1
    out = np.zeros(t.shape + (4,))
    seg = np.minimum((t * n).astype(int), n - 1)
    f = t * n - seg
    for i in range(n):
        m = seg == i
        out[m] = cols[i] * (1 - f[m])[:, None] + cols[i + 1] * f[m][:, None]
    return out


def shade(img, k):
    """Multiply rgb by k (array or scalar), keeping alpha."""
    out = img.copy()
    out[..., :3] = np.clip(out[..., :3] * (k[..., None] if isinstance(k, np.ndarray) else k), 0, 1)
    return out


def mix(a, b, t):
    return a * (1 - t) + b * t


# ---------------------------------------------------------------------------
# Drawing
# ---------------------------------------------------------------------------

def put(img, x, y, col, wrap=True):
    if wrap:
        x %= S
        y %= S
    elif x < 0 or y < 0 or x >= S or y >= S:
        return
    c = hexc(col) if isinstance(col, str) else np.asarray(col, dtype=float)
    if c[3] >= 1.0 or img[y, x, 3] == 0:
        img[y, x] = c
    else:
        a = c[3]
        img[y, x, :3] = img[y, x, :3] * (1 - a) + c[:3] * a
        img[y, x, 3] = max(img[y, x, 3], a)


def blob(img, cx, cy, rx, ry, col_fn, wrap=True):
    """Filled ellipse; col_fn(dx, dy) -> colour, with dx,dy in -1..1."""
    for y in range(int(math.floor(cy - ry - 1)), int(math.ceil(cy + ry + 1)) + 1):
        for x in range(int(math.floor(cx - rx - 1)), int(math.ceil(cx + rx + 1)) + 1):
            dx = (x + 0.5 - cx) / max(0.01, rx)
            dy = (y + 0.5 - cy) / max(0.01, ry)
            if dx * dx + dy * dy <= 1.0:
                c = col_fn(dx, dy)
                if c is not None:
                    put(img, x, y, c, wrap)


def line(img, x0, y0, x1, y1, col, wrap=False):
    """Bresenham line."""
    x0, y0, x1, y1 = int(round(x0)), int(round(y0)), int(round(x1)), int(round(y1))
    dx = abs(x1 - x0)
    dy = -abs(y1 - y0)
    sx = 1 if x0 < x1 else -1
    sy = 1 if y0 < y1 else -1
    err = dx + dy
    while True:
        c = col(x0, y0) if callable(col) else col
        if c is not None:
            put(img, x0, y0, c, wrap)
        if x0 == x1 and y0 == y1:
            break
        e2 = 2 * err
        if e2 >= dy:
            err += dy
            x0 += sx
        if e2 <= dx:
            err += dx
            y0 += sy


def poly(img, pts, col, wrap=False):
    """Fill a polygon (list of (x, y) in pixel units) with col or col(x, y)."""
    ys = [p[1] for p in pts]
    for y in range(int(math.floor(min(ys))), int(math.ceil(max(ys))) + 1):
        yc = y + 0.5
        xs = []
        n = len(pts)
        for i in range(n):
            (xa, ya), (xb, yb) = pts[i], pts[(i + 1) % n]
            if (ya <= yc < yb) or (yb <= yc < ya):
                xs.append(xa + (yc - ya) / (yb - ya) * (xb - xa))
        xs.sort()
        for i in range(0, len(xs) - 1, 2):
            for x in range(int(math.ceil(xs[i] - 0.5)), int(math.floor(xs[i + 1] - 0.5)) + 1):
                c = col(x, y) if callable(col) else col
                if c is not None:
                    put(img, x, y, c, wrap)


def outline(img, col="#1d1712", diag=False):
    """1px outline around opaque pixels (items)."""
    a = img[..., 3] > 0.5
    out = img.copy()
    c = hexc(col) if isinstance(col, str) else col
    nb = [(1, 0), (-1, 0), (0, 1), (0, -1)]
    if diag:
        nb += [(1, 1), (-1, 1), (1, -1), (-1, -1)]
    for y in range(S):
        for x in range(S):
            if a[y, x]:
                continue
            for dx, dy in nb:
                xx, yy = x + dx, y + dy
                if 0 <= xx < S and 0 <= yy < S and a[yy, xx]:
                    out[y, x] = c
                    break
    return out


def bevel(img, light=1.18, dark=0.78):
    """Lighten pixels lit from the top-left edge, darken the bottom-right edge."""
    a = img[..., 3] > 0.5
    out = img.copy()
    for y in range(S):
        for x in range(S):
            if not a[y, x]:
                continue
            tl = (x == 0 or not a[y, x - 1]) or (y == 0 or not a[y - 1, x])
            br = (x == S - 1 or not a[y, x + 1]) or (y == S - 1 or not a[y + 1, x])
            if tl and not br:
                out[y, x, :3] = np.clip(out[y, x, :3] * light, 0, 1)
            elif br and not tl:
                out[y, x, :3] = out[y, x, :3] * dark
    return out


def jitter(img, seed, amt=0.06):
    """Per-pixel brightness noise."""
    w = white(seed)
    return shade(img, 1.0 + (w - 0.5) * 2 * amt)


def to_img(arr):
    a = np.clip(arr, 0, 1)
    return Image.fromarray((a * 255 + 0.5).astype(np.uint8), "RGBA")


def avg_color(arr):
    m = arr[..., 3] > 0.5
    if not m.any():
        return [0.5, 0.5, 0.5]
    return [float(v) for v in arr[m][:, :3].mean(axis=0)]


def sheet(tiles, cols, scale=4, bg=(40, 44, 52, 255), label=True):
    """Preview sheet of (name, array) tiles, upscaled with nearest neighbour."""
    from PIL import ImageDraw
    rows = (len(tiles) + cols - 1) // cols
    cw = S * scale + 8
    ch = S * scale + (18 if label else 8)
    im = Image.new("RGBA", (cols * cw, rows * ch), bg)
    d = ImageDraw.Draw(im)
    for i, (name, arr) in enumerate(tiles):
        x = (i % cols) * cw + 4
        y = (i // cols) * ch + 4
        t = to_img(arr).resize((S * scale, S * scale), Image.NEAREST)
        im.alpha_composite(t, (x, y))
        if label:
            d.text((x, y + S * scale + 1), name[:20], fill=(220, 220, 220, 255))
    return im


def atlas(tiles, cols=16):
    rows = (len(tiles) + cols - 1) // cols
    im = Image.new("RGBA", (cols * S, rows * S), (0, 0, 0, 0))
    for i, (_name, arr) in enumerate(tiles):
        im.paste(to_img(arr), ((i % cols) * S, (i // cols) * S))
    return im


def rnd(seed):
    return random.Random(seed)
