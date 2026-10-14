"""Shared helpers for the Skyroot audio tools (synth.py, curate.py, check.py).

numpy only.  ffmpeg is optional and only used to decode/encode Ogg Vorbis
(curate.py, check.py).  Everything here is deterministic.

Conventions
-----------
* Sample rate 44100 Hz, float64 signals in [-1, 1].  Mono = shape (n,),
  stereo = shape (n, 2).
* One-shot SFX are trimmed, faded, DC-blocked and loudness-normalised per
  category (K-weighted, 200 ms max window), with a hard peak ceiling of
  -3 dBFS.  Within a category the loudness is matched; peaks land at or
  below -3 dBFS.
* Ambience loops are normalised to a per-loop integrated loudness, also
  with a -3 dBFS peak ceiling, and carry a RIFF 'smpl' loop chunk so Godot's
  WAV importer (loop mode "Detect From WAV", the default) loops them.
"""
import os
import re
import shutil
import struct
import subprocess
import zlib

import numpy as np

SR = 44100
HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
AUDIO_DIR = os.path.join(REPO, "assets", "audio")
SFX_DIR = os.path.join(AUDIO_DIR, "sfx")
AMB_DIR = os.path.join(AUDIO_DIR, "amb")

PEAK_CEIL_DB = -3.0   # normalisation ceiling (sample peak)
QC_PEAK_MAX_DB = -1.0  # hard QC limit (decoded peak)
SEED = 20261014       # global seed; per-sound seeds derive from it


# --------------------------------------------------------------------------
# Manifest
# --------------------------------------------------------------------------
def variants(stem, n):
    return [f"{stem}_{i}" for i in range(1, n + 1)]


SFX_GROUPS = {
    "footsteps": variants("step_grass", 5) + variants("step_wood", 5)
    + variants("step_stone", 5) + variants("step_dirt", 4) + variants("step_water", 3),
    "stone": variants("knap", 5) + ["stone_break"] + variants("stone_drop", 3),
    "wood": variants("chop", 4) + ["wood_split"] + variants("wood_drop", 3)
    + ["branch_snap", "tree_creak", "tree_fall"] + variants("hammer_wood", 3),
    "plants": variants("cut_grass", 3) + variants("rustle", 3) + ["harvest_pop"],
    "earth": variants("dig_soil", 3) + variants("dig_clay", 2) + variants("place_soil", 2)
    + ["compost_turn"],
    "clay": variants("clay_squish", 4) + ["clay_slap", "clay_smooth", "pottery_place",
                                           "pottery_crack", "pottery_tap"],
    "water": ["water_splash", "water_fill"] + variants("drink", 2) + ["sizzle"],
    "fire": ["fire_ignite", "ember_blow", "fire_out"],
    "rope": variants("rope_twist", 3) + ["rope_tighten"],
    "food": variants("eat", 3) + ["berry_pick"],
    "items_ui": ["pickup", "drop_item", "ui_click", "ui_hover", "ui_open", "ui_close",
                 "ui_error"] + variants("page_flip", 3)
    + ["book_open", "book_close", "discovery", "hint", "build_complete"],
    "structure": variants("creak_warn", 3) + ["collapse"],
    "player": ["hurt", "fall_whoosh", "heartbeat"],
}
SFX_NAMES = [n for g in SFX_GROUPS.values() for n in g]
AMB_NAMES = ["wind_soft", "wind_strong", "rain_light", "crickets_night", "pond_lap",
             "fire_small", "fire_large", "mound_smolder", "drill_spin", "water_pour"]
CATEGORY = {n: g for g, names in SFX_GROUPS.items() for n in names}
# Interface sounds get their own loudness group (they are much shorter/denser
# than the diegetic item sounds they are listed with).
CATEGORY.update({n: "ui" for n in ["ui_click", "ui_hover", "ui_open", "ui_close", "ui_error"]})

# Category loudness targets in dB (LKmax: K-weighted, 200 ms window, maximum;
# LUFS-like).  All variants of a stem (knap_1..5 ...) are normalised *jointly*
# to one loudness: min(category target + stem offset, the loudest level every
# variant can reach with its peak at the -3 dBFS ceiling after at most
# LIMIT_DB of look-ahead peak limiting).  So variants always match; stems
# match their category unless they are too transient to get there.
CATEGORY_TARGET = {
    "footsteps": -25.5,
    "stone": -23.0,
    "wood": -22.5,
    "plants": -20.0,
    "earth": -20.0,
    "clay": -19.5,
    "water": -18.0,
    "fire": -17.0,
    "rope": -19.5,
    "food": -21.0,
    "items_ui": -22.0,
    "ui": -25.0,
    "structure": -20.0,
    "player": -17.5,
}
# Per-stem offsets (dB) for sounds meant to sit quieter/louder than siblings.
OFFSET_DB = {
    "ui_hover": -6.0, "hint": -2.0, "discovery": 2.0, "build_complete": 1.0,
    "rustle": -2.0, "clay_smooth": -2.0, "pottery_tap": -2.0, "berry_pick": -1.0,
    "ember_blow": -2.0, "tree_creak": -1.0, "tree_fall": 3.0, "collapse": 3.0,
    "stone_break": 1.5,
}
LIMIT_DB = 3.0                    # max peak limiting used to reach a target
LIMIT_OVERRIDE = {"knap": 1.5}    # keep the knapping transient nearly untouched
# Integrated loudness targets for ambience loops (dB, LUFS-ish, ungated).
AMB_TARGET = {
    "wind_soft": -27.0, "wind_strong": -21.0, "rain_light": -25.0,
    "crickets_night": -32.0, "pond_lap": -29.0, "fire_small": -25.0,
    "fire_large": -20.0, "mound_smolder": -29.0, "drill_spin": -22.0,
    "water_pour": -22.0,
}


def stem_of(name):
    m = re.match(r"^(.*)_(\d+)$", name)
    if m and f"{m.group(1)}_1" in CATEGORY:
        return m.group(1)
    return name


def sfx_target(name):
    return CATEGORY_TARGET[CATEGORY[name]] + OFFSET_DB.get(stem_of(name), 0.0)


def seed_for(name):
    return (zlib.crc32(name.encode("utf-8")) ^ SEED) & 0xFFFFFFFF


def rng_for(name):
    return np.random.default_rng(seed_for(name))


# --------------------------------------------------------------------------
# Filters (RBJ biquads applied through the FFT -> fast, exact up to -160 dB)
# --------------------------------------------------------------------------
def biquad(kind, f0, q=0.7071, gain_db=0.0, sr=SR):
    """RBJ cookbook biquad. kind: lp hp bp notch peak ls hs ap."""
    f0 = float(min(max(f0, 1.0), sr * 0.499))
    A = 10.0 ** (gain_db / 40.0)
    w = 2.0 * np.pi * f0 / sr
    cw, sw = np.cos(w), np.sin(w)
    al = sw / (2.0 * q)
    if kind == "lp":
        b = [(1 - cw) / 2, 1 - cw, (1 - cw) / 2]; a = [1 + al, -2 * cw, 1 - al]
    elif kind == "hp":
        b = [(1 + cw) / 2, -(1 + cw), (1 + cw) / 2]; a = [1 + al, -2 * cw, 1 - al]
    elif kind == "bp":  # constant 0 dB peak gain
        b = [al, 0.0, -al]; a = [1 + al, -2 * cw, 1 - al]
    elif kind == "notch":
        b = [1.0, -2 * cw, 1.0]; a = [1 + al, -2 * cw, 1 - al]
    elif kind == "ap":
        b = [1 - al, -2 * cw, 1 + al]; a = [1 + al, -2 * cw, 1 - al]
    elif kind == "peak":
        b = [1 + al * A, -2 * cw, 1 - al * A]; a = [1 + al / A, -2 * cw, 1 - al / A]
    elif kind in ("ls", "hs"):
        sq = 2 * np.sqrt(A) * al
        if kind == "ls":
            b = [A * ((A + 1) - (A - 1) * cw + sq), 2 * A * ((A - 1) - (A + 1) * cw),
                 A * ((A + 1) - (A - 1) * cw - sq)]
            a = [(A + 1) + (A - 1) * cw + sq, -2 * ((A - 1) + (A + 1) * cw),
                 (A + 1) + (A - 1) * cw - sq]
        else:
            b = [A * ((A + 1) + (A - 1) * cw + sq), -2 * A * ((A - 1) + (A + 1) * cw),
                 A * ((A + 1) + (A - 1) * cw - sq)]
            a = [(A + 1) - (A - 1) * cw + sq, 2 * ((A - 1) - (A + 1) * cw),
                 (A + 1) - (A - 1) * cw - sq]
    else:
        raise ValueError(kind)
    b = np.array(b, float) / a[0]
    a = np.array(a, float) / a[0]
    return b, a


def _decay_len(a, sr=SR):
    r = np.max(np.abs(np.roots(a))) if len(a) > 1 else 0.0
    if r < 1e-9:
        return 8
    r = min(r, 0.999999)
    return int(min(np.ceil(np.log(1e-8) / np.log(r)), 10 * sr)) + 8


def _resp(b, a, nfft):
    z = np.exp(-2j * np.pi * np.arange(nfft // 2 + 1) / nfft)
    num = np.polyval(b[::-1], z)
    den = np.polyval(a[::-1], z)
    return num / den


def filt(x, sections, tail=False):
    """Apply a cascade of (b, a) sections with linear (zero-padded) FFT
    convolution.  Works on (n,) or (n, ch).  tail=True also returns the
    ring-out after the end of x."""
    if isinstance(sections, tuple):
        sections = [sections]
    x = np.asarray(x, float)
    n = x.shape[0]
    pad = sum(_decay_len(a) for _, a in sections)
    nfft = 1 << int(np.ceil(np.log2(max(n + pad, 2))))
    H = np.ones(nfft // 2 + 1, complex)
    for b, a in sections:
        H *= _resp(b, a, nfft)
    if x.ndim == 1:
        y = np.fft.irfft(np.fft.rfft(x, nfft) * H, nfft)
    else:
        y = np.fft.irfft(np.fft.rfft(x, nfft, axis=0) * H[:, None], nfft, axis=0)
    return y[: n + pad] if tail else y[:n]


def lp(x, f, q=0.7071):
    return filt(x, biquad("lp", f, q))


def hp(x, f, q=0.7071):
    return filt(x, biquad("hp", f, q))


def bp(x, f, q=1.0):
    return filt(x, biquad("bp", f, q))


def peq(x, f, q, g):
    return filt(x, biquad("peak", f, q, g))


def lp4(x, f):
    return filt(x, [biquad("lp", f, 0.5412), biquad("lp", f, 1.3066)])


def hp4(x, f):
    return filt(x, [biquad("hp", f, 0.5412), biquad("hp", f, 1.3066)])


def dc_block(x, f=18.0):
    return filt(x, biquad("hp", f, 0.7071))


# --------------------------------------------------------------------------
# Loudness / analysis
# --------------------------------------------------------------------------
_KW = [biquad("hs", 1681.97, 0.7072, 3.9998), biquad("hp", 38.135, 0.5003)]


def k_weight(x):
    return filt(x, _KW)


def _power(x):
    """Per-sample power summed over channels (BS.1770 style)."""
    k = k_weight(x)
    return k * k if k.ndim == 1 else np.sum(k * k, axis=1)


def lk_max(x, win=0.2, sr=SR):
    p = _power(x)
    w = int(win * sr)
    p = np.concatenate([p, np.zeros(w)])
    c = np.cumsum(np.concatenate([[0.0], p]))
    ms = (c[w:] - c[:-w]) / w
    return -0.691 + 10 * np.log10(max(ms.max(), 1e-20))


def lk_int(x):
    return -0.691 + 10 * np.log10(max(np.mean(_power(x)), 1e-20))


def db(v):
    return 20 * np.log10(max(float(v), 1e-12))


def peak_db(x):
    return db(np.max(np.abs(x)))


def rms_db(x):
    return db(np.sqrt(np.mean(np.asarray(x, float) ** 2)))


def env_db(x, hop=0.0025, sr=SR):
    m = x if x.ndim == 1 else np.max(np.abs(x), axis=1)
    h = max(1, int(hop * sr))
    nf = int(np.ceil(len(m) / h))
    m = np.concatenate([m, np.zeros(nf * h - len(m))])
    e = np.sqrt(np.mean(m.reshape(nf, h) ** 2, axis=1))
    return 20 * np.log10(e + 1e-12), h


# --------------------------------------------------------------------------
# One-shot finishing: trim, fades, normalise
# --------------------------------------------------------------------------
def fade(x, fin=0.0, fout=0.0, sr=SR):
    x = np.array(x, float, copy=True)
    for length, at_end in ((fin, False), (fout, True)):
        k = min(int(length * sr), x.shape[0])
        if k <= 1:
            continue
        w = 0.5 - 0.5 * np.cos(np.linspace(0, np.pi, k))
        if at_end:
            w = w[::-1]
            sl = slice(x.shape[0] - k, x.shape[0])
        else:
            sl = slice(0, k)
        x[sl] *= w if x.ndim == 1 else w[:, None]
    return x


def trim(x, lead_rel=-42.0, tail_rel=-52.0, preroll=0.002, fade_in=0.0015,
         fade_out=0.025, max_len=None, sr=SR):
    """Trim leading/trailing silence relative to the peak.  Aware of steady
    noise floors (tail threshold sits 8 dB above a detected floor)."""
    e, h = env_db(x)
    pk = e.max()
    nf = len(e)
    tail_thr = pk + tail_rel
    if nf > 40:
        # a *steady* floor (recording noise/hum) in the last 15 %: cut 8 dB above it
        seg = e[int(nf * 0.85):]
        half = len(seg) // 2
        floor = np.median(seg)
        steady = abs(np.median(seg[:half]) - np.median(seg[half:])) < 3.0
        if steady and floor > pk - 60:
            tail_thr = max(tail_thr, floor + 8.0)
    above = np.where(e > pk + lead_rel)[0]
    start = max(0, above[0] * h - int(preroll * sr)) if len(above) else 0
    above = np.where(e > tail_thr)[0]
    end = min(x.shape[0], (above[-1] + 1) * h) if len(above) else x.shape[0]
    if max_len is not None:
        end = min(end, start + int(max_len * sr))
    y = x[start:end]
    fo = min(fade_out, 0.3 * y.shape[0] / sr)
    return fade(y, fade_in if start > 0 else min(fade_in, 0.0005), fo)


def normalise(x, target_db, measure=lk_max, ceil_db=PEAK_CEIL_DB):
    """Gain to reach target loudness, limited by the sample-peak ceiling."""
    loud = measure(x)
    pk = peak_db(x)
    gain = target_db - loud
    capped = pk + gain > ceil_db
    if capped:
        gain = ceil_db - pk
    return x * 10 ** (gain / 20), gain, capped


def limit(x, ceil_db=PEAK_CEIL_DB, attack=0.003, release=0.08, sr=SR):
    """Look-ahead peak limiter.  The required gain reduction (dB) is spread
    with linear ramps: 12 dB per `attack` s before a peak (look-ahead) and
    12 dB per `release` s after it, so gain changes stay smooth."""
    a = np.abs(x) if x.ndim == 1 else np.max(np.abs(x), axis=1)
    need = np.maximum(0.0, 20 * np.log10(a + 1e-12) - ceil_db)
    if not np.any(need > 0):
        return x
    k = np.arange(len(need), dtype=float)
    s_r = 12.0 / (release * sr)
    s_a = 12.0 / (attack * sr)
    fwd = np.maximum.accumulate(need + k * s_r) - k * s_r
    bwd = np.maximum.accumulate((fwd - k * s_a)[::-1])[::-1] + k * s_a
    g = 10 ** (-bwd / 20)
    return x * (g if x.ndim == 1 else g[:, None])


def limit_circular(x, ceil_db=PEAK_CEIL_DB, pad=0.5, sr=SR):
    """limit() for loops: the gain curve is computed on a wrapped copy, so the
    gain just before the end matches the gain just after the start."""
    k = min(int(pad * sr), x.shape[0])
    ext = np.concatenate([x[-k:], x, x[:k]], axis=0)
    return limit(ext, ceil_db)[k:k + x.shape[0]]


def normalise_loop(y, target_db, max_lim_db=3.0):
    """Integrated-loudness normalisation for loops, with up to max_lim_db of
    seam-safe peak limiting."""
    gain = min(target_db - lk_int(y), PEAK_CEIL_DB - peak_db(y) + max_lim_db)
    y = y * 10 ** (gain / 20)
    if peak_db(y) > PEAK_CEIL_DB:
        y = limit_circular(y)
    return y


def prepare_sfx(x, name, **trim_kw):
    """DC block, trim silence, fade, remove residual DC (no gain change)."""
    x = np.asarray(x, float)
    if not np.all(np.isfinite(x)):
        raise ValueError(f"{name}: non-finite samples")
    x = dc_block(x)
    x = trim(x, **trim_kw)
    h = np.hanning(len(x))
    return x - np.mean(x) * h / np.mean(h)


def normalise_set(xs, names):
    """Normalise all variants of one stem to a single loudness (see
    CATEGORY_TARGET).  Returns (signals, loudness reached, limiting used)."""
    stem = stem_of(names[0])
    lim = LIMIT_OVERRIDE.get(stem, LIMIT_DB)
    ach = [PEAK_CEIL_DB - peak_db(x) + lk_max(x) + lim for x in xs]
    T = min(sfx_target(names[0]), min(ach))
    out, used = [], []
    for x in xs:
        y = x * 10 ** ((T - lk_max(x)) / 20)
        pre = peak_db(y)
        for _ in range(3):
            if peak_db(y) <= PEAK_CEIL_DB + 1e-6:
                break
            y = limit(y)
            y = y * 10 ** ((T - lk_max(y)) / 20)
        if peak_db(y) > PEAK_CEIL_DB:
            y = limit(y)
        used.append(max(0.0, pre - PEAK_CEIL_DB))
        out.append(y)
    return out, T, used


# --------------------------------------------------------------------------
# WAV I/O (16-bit PCM, optional RIFF 'smpl' loop chunk)
# --------------------------------------------------------------------------
def to_pcm16(x, seed=0):
    rng = np.random.default_rng(seed)
    d = (rng.random(x.shape) - rng.random(x.shape))  # TPDF, +-1 LSB
    q = np.round(np.asarray(x, float) * 32767.0 + d)
    return np.clip(q, -32768, 32767).astype("<i2")


def write_wav(path, x, sr=SR, loop=False, seed=0):
    x = np.asarray(x, float)
    ch = 1 if x.ndim == 1 else x.shape[1]
    pcm = to_pcm16(x, seed).tobytes()
    n = x.shape[0]
    fmt = struct.pack("<HHIIHH", 1, ch, sr, sr * ch * 2, ch * 2, 16)
    chunks = [b"fmt " + struct.pack("<I", len(fmt)) + fmt,
              b"data" + struct.pack("<I", len(pcm)) + pcm]
    if loop:
        # smpl: manufacturer, product, sample period (ns), unity note, pitch
        # fraction, SMPTE format, SMPTE offset, loop count, sampler data;
        # then one loop: id, type (0 = forward), start, end (inclusive),
        # fraction, play count (0 = infinite).
        smpl = struct.pack("<9I", 0, 0, int(round(1e9 / sr)), 60, 0, 0, 0, 1, 0)
        smpl += struct.pack("<6I", 0, 0, 0, n - 1, 0, 0)
        chunks.append(b"smpl" + struct.pack("<I", len(smpl)) + smpl)
    body = b"WAVE" + b"".join(chunks)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as fh:
        fh.write(b"RIFF" + struct.pack("<I", len(body)) + body)


def read_wav(path):
    """Returns (float array, sr, loop) where loop is (start, end) or None."""
    with open(path, "rb") as fh:
        data = fh.read()
    if data[:4] != b"RIFF" or data[8:12] != b"WAVE":
        raise ValueError(f"{path}: not a RIFF/WAVE file")
    pos, fmt, pcm, loop = 12, None, None, None
    while pos + 8 <= len(data):
        cid, size = data[pos:pos + 4], struct.unpack("<I", data[pos + 4:pos + 8])[0]
        body = data[pos + 8:pos + 8 + size]
        if cid == b"fmt ":
            fmt = struct.unpack("<HHIIHH", body[:16])
        elif cid == b"data":
            pcm = body
        elif cid == b"smpl" and len(body) >= 60:
            nloops = struct.unpack("<I", body[28:32])[0]
            if nloops:
                _, ltype, ls, le = struct.unpack("<4I", body[36:52])
                loop = (ls, le)
        pos += 8 + size + (size & 1)
    if fmt is None or pcm is None or fmt[0] != 1 or fmt[5] != 16:
        raise ValueError(f"{path}: expected 16-bit PCM")
    ch, sr = fmt[1], fmt[2]
    a = np.frombuffer(pcm, "<i2").astype(float) / 32768.0
    if ch > 1:
        a = a.reshape(-1, ch)
    return a, sr, loop


def remove_alternates(path):
    """A name exists once: writing <name>.wav removes a stale <name>.ogg in the
    same folder (and vice versa)."""
    base, ext = os.path.splitext(path)
    for other in (".wav", ".ogg"):
        if other != ext and os.path.exists(base + other):
            os.remove(base + other)


# --------------------------------------------------------------------------
# ffmpeg (Ogg Vorbis) helpers
# --------------------------------------------------------------------------
def ffmpeg():
    return shutil.which("ffmpeg")


def _channels(path):
    probe = shutil.which("ffprobe")
    if probe:
        out = subprocess.run([probe, "-v", "error", "-select_streams", "a:0", "-show_entries",
                              "stream=channels", "-of", "csv=p=0", path],
                             capture_output=True, text=True, check=True).stdout
        return int(out.strip().split(",")[0])
    info = subprocess.run([ffmpeg(), "-hide_banner", "-i", path],
                          capture_output=True, text=True).stderr
    m = re.search(r"Audio: [^\n]*?, \d+ Hz, (mono|stereo|(\d+) channels)", info)
    if not m:
        raise RuntimeError(f"cannot determine channel count of {path}")
    return {"mono": 1, "stereo": 2}.get(m.group(1)) or int(m.group(2))


def decode(path, sr=SR, mono=True):
    """Decode any audio file with ffmpeg to float64 at `sr`.  mono=True
    averages the channels (no ffmpeg downmix gain games)."""
    exe = ffmpeg()
    if not exe:
        raise RuntimeError("ffmpeg not found")
    ch = _channels(path)
    raw = subprocess.run([exe, "-v", "error", "-i", path, "-f", "f32le", "-ar", str(sr), "-"],
                         capture_output=True, check=True).stdout
    a = np.frombuffer(raw, "<f4").astype(float).reshape(-1, ch)
    if mono:
        return a.mean(axis=1)
    return a if ch > 1 else a[:, 0]


def encode_ogg(x, path, sr=SR, quality=6):
    exe = ffmpeg()
    if not exe:
        raise RuntimeError("ffmpeg not found")
    x = np.asarray(x, float)
    ch = 1 if x.ndim == 1 else x.shape[1]
    os.makedirs(os.path.dirname(path), exist_ok=True)
    cmd = [exe, "-v", "error", "-y", "-f", "f32le", "-ar", str(sr), "-ac", str(ch), "-i", "-",
           "-map_metadata", "-1", "-fflags", "+bitexact", "-flags:a", "+bitexact",
           "-c:a", "libvorbis", "-q:a", str(quality), path]
    subprocess.run(cmd, input=x.astype("<f4").tobytes(), check=True)


def load_any(path, mono=False):
    """Load a produced asset (.wav natively, .ogg via ffmpeg)."""
    if path.endswith(".wav"):
        a, sr, loop = read_wav(path)
        if mono and a.ndim > 1:
            a = a.mean(axis=1)
        return a, sr, loop
    return decode(path, mono=mono), SR, None


# --------------------------------------------------------------------------
# QC
# --------------------------------------------------------------------------
def seam_report(x, order=16):
    """How seamless is the wrap-around x[-1] -> x[0]?  Judged against the
    loop's own neighbourhood (0.25 s either side of the seam):
      step_ratio  |x[0] - x[-1]| / 99.9th percentile of |sample steps| nearby
      hf_ratio    'click' score: largest linear-prediction residual (order-16
                  LPC fitted on the neighbourhood) in the 3 samples after the
                  seam / 99.9th percentile of the residual nearby.  A
                  discontinuity is unpredictable (>> 1); smooth content ~<= 1.
      level_diff  |RMS(last 100 ms) - RMS(first 100 ms)| in dB (sparse loops
                  legitimately differ here)."""
    x = x if x.ndim == 2 else x[:, None]
    out = {"step_ratio": 0.0, "level_diff_db": 0.0, "hf_ratio": 0.0}
    h = int(0.25 * SR)
    for c in range(x.shape[1]):
        s = x[:, c]
        ctx = np.concatenate([s[-h:], s[:h]])          # seam between h-1 and h
        d = np.abs(np.diff(ctx))
        out["step_ratio"] = max(out["step_ratio"],
                                abs(s[0] - s[-1]) / (np.percentile(d, 99.9) + 1e-12))
        A = np.stack([ctx[order - k - 1:len(ctx) - k - 1] for k in range(order)], axis=1)
        tgt = ctx[order:]
        coef, *_ = np.linalg.lstsq(A, tgt, rcond=None)
        res = np.abs(tgt - A @ coef)
        i0 = h - order
        seam = res[i0:i0 + 3].max()
        out["hf_ratio"] = max(out["hf_ratio"], seam / (np.percentile(res, 99.9) + 1e-12))
        m = int(0.1 * SR)
        out["level_diff_db"] = max(out["level_diff_db"], abs(rms_db(s[-m:]) - rms_db(s[:m])))
    return out


def stats_row(name, x, sr=SR, loop=None):
    mono = x if x.ndim == 1 else x.mean(axis=1)
    row = {
        "name": name,
        "dur": x.shape[0] / sr,
        "ch": 1 if x.ndim == 1 else x.shape[1],
        "peak": peak_db(x),
        "rms": rms_db(x),
        "lk": lk_int(x) if loop else lk_max(x),
        "dc": float(np.mean(mono)),
        "finite": bool(np.all(np.isfinite(x))),
    }
    if loop:
        row.update(seam_report(x))
    return row


def print_table(rows, title=""):
    if title:
        print(f"\n== {title}")
    print(f"{'name':16s} {'dur s':>6s} {'ch':>2s} {'peak':>6s} {'rms':>6s} {'loud':>6s} {'dc':>8s}  notes")
    for r in rows:
        notes = []
        if "step_ratio" in r:
            notes.append(f"seam: step {r['step_ratio']:.2f}x p99.9, LPC click {r['hf_ratio']:.2f}x"
                         f" p99.9, level diff {r['level_diff_db']:.1f} dB")
        if r.get("src"):
            notes.append(r["src"])
        print(f"{r['name']:16s} {r['dur']:6.2f} {r['ch']:2d} {r['peak']:6.1f} {r['rms']:6.1f} "
              f"{r['lk']:6.1f} {r['dc']:+8.5f}  {' '.join(notes)}")
