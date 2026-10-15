#!/usr/bin/env python3
"""Procedural sound synthesis for Skyroot (numpy only, no scipy).

Regenerates every synthesized one-shot (assets/audio/sfx/<name>.wav, mono)
and every ambience loop (assets/audio/amb/<name>.wav) as 16-bit PCM 44.1 kHz.

Deterministic: every sound gets its own RNG seeded from its name
(audiolib.seed_for), so regenerating one sound never changes another and
two runs produce identical files.

    python3 tools/audio/synth.py                 # regenerate everything
    python3 tools/audio/synth.py knap fire_      # only names starting with these
    python3 tools/audio/synth.py --list          # list what this script makes

Techniques: modal synthesis (sums of exponentially decaying sinusoids) for
stone/wood/ceramic impacts, Poisson impulse trains through resonator banks
for crackle/fibre/grain textures, stick-slip pulse trains for creaks and
friction, Minnaert-style rising-pitch sine "bubbles" for water, and STFT
time-varying spectral shaping of noise for wind, whooshes, breath and beds.

Loops are rendered with an extra tail whose slow control curves are periodic
in the loop length; the tail is equal-power crossfaded into the head, so the
wrap point is as smooth as any other point (check.py verifies this).
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import numpy as np  # noqa: E402

import audiolib as al  # noqa: E402
from audiolib import SR, biquad, bp, filt, hp, lp  # noqa: E402


# =============================================================================
# Primitives
# =============================================================================
def N(sec):
    return int(round(sec * SR))


def tv(n):
    return np.arange(n) / SR


def nz(x):
    """Normalise to unit peak (safe for silence)."""
    m = np.max(np.abs(x))
    return x / m if m > 0 else x


def tnorm(x, q=99.5):
    """Normalise a sparse texture by its typical loud peaks (percentile of the
    active samples), not by its single largest outlier."""
    a = np.abs(x)
    if a.max() == 0:
        return x
    act = a[a > 1e-3 * a.max()]
    return x / np.percentile(act, q)


def rmsn(x):
    """Normalise to unit RMS."""
    r = np.sqrt(np.mean(x ** 2))
    return x / r if r > 0 else x


def mix(*xs):
    """Sum 1-D arrays of different lengths (zero-padded to the longest)."""
    n = max(len(x) for x in xs)
    out = np.zeros(n)
    for x in xs:
        out[:len(x)] += x
    return out


def place(buf, x, at, gain=1.0):
    """Mix x into buf starting at time `at` seconds.  If x would end with an
    audible step, its last 5 ms are faded so no atom can click."""
    m0 = np.max(np.abs(x)) if len(x) else 0.0
    if m0 > 0 and np.max(np.abs(x[-1])) > 1e-3 * m0:
        k = min(len(x) // 4, N(0.005))
        w = 0.5 + 0.5 * np.cos(np.linspace(0, np.pi, k))
        x = x.copy()
        x[-k:] *= w if x.ndim == 1 else w[:, None]
    i = int(round(at * SR))
    if i >= buf.shape[0] or gain == 0:
        return buf
    if i < 0:
        x = x[-i:]
        i = 0
    m = min(x.shape[0], buf.shape[0] - i)
    buf[i:i + m] += gain * x[:m]
    return buf


def expdec(n, tau):
    return np.exp(-np.arange(n) / (tau * SR))


def ar(n, att, tau):
    """Raised-cosine attack then exponential decay."""
    t = tv(n)
    a = np.clip(t / att, 0, 1) if att > 0 else np.ones(n)
    return (0.5 - 0.5 * np.cos(np.pi * a)) * np.exp(-np.maximum(t - att, 0) / tau)


def pw(n, pts):
    """Piecewise-linear envelope from [(t, v), ...]."""
    ts, vs = zip(*pts)
    return np.interp(tv(n), ts, vs)


def white(rng, n):
    return rng.standard_normal(n)


def colored(rng, n, exponent, fmin=15.0):
    """Noise with power spectrum ~ 1/f^exponent (pink = 1, brown = 2)."""
    X = rng.standard_normal(n // 2 + 1) + 1j * rng.standard_normal(n // 2 + 1)
    f = np.fft.rfftfreq(n, 1 / SR)
    X *= np.maximum(f, fmin) ** (-exponent / 2.0)
    X[0] = 0
    return rmsn(np.fft.irfft(X, n))


def modes(n, freqs, taus, amps, phases=None):
    """Sum of exponentially decaying sinusoids (modal synthesis)."""
    t = tv(n)
    y = np.zeros(n)
    for i, (f, tau, a) in enumerate(zip(freqs, taus, amps)):
        if f >= 0.45 * SR:
            continue
        ph = 0.0 if phases is None else phases[i]
        y += a * np.exp(-t / tau) * np.sin(2 * np.pi * f * t + ph)
    return y


def chirp(n, f_of_t, env):
    """Sine with time-varying frequency array and envelope."""
    return np.sin(2 * np.pi * np.cumsum(f_of_t) / SR) * env


def impulses(n, times, amps):
    x = np.zeros(n)
    idx = np.round(np.asarray(times) * SR).astype(int)
    ok = (idx >= 0) & (idx < n)
    np.add.at(x, idx[ok], np.asarray(amps, float)[ok])
    return x


def poisson(rng, rate_fn, t0, t1, rmax):
    """Event times of an inhomogeneous Poisson process (thinning)."""
    if t1 <= t0 or rmax <= 0:
        return np.zeros(0)
    k = int((t1 - t0) * rmax * 1.3 + 20)
    times = t0 + np.cumsum(rng.exponential(1.0 / rmax, k))
    while times[-1] < t1:
        times = np.concatenate([times, times[-1] + np.cumsum(rng.exponential(1.0 / rmax, k))])
    times = times[times < t1]
    rate = rate_fn(times) if callable(rate_fn) else np.full(len(times), float(rate_fn))
    return times[rng.random(len(times)) < np.clip(rate / rmax, 0, 1)]


def resonate(x, bands):
    """Parallel bank of band-pass resonators: [(fc, q, gain), ...]."""
    return sum(g * filt(x, biquad("bp", fc, q)) for fc, q, g in bands)


def fftconv(x, h):
    n = len(x) + len(h) - 1
    nfft = 1 << int(np.ceil(np.log2(n)))
    return np.fft.irfft(np.fft.rfft(x, nfft) * np.fft.rfft(h, nfft), nfft)[:n]


def reverb(rng, x, t60=0.8, mix=0.15, lpf=5000.0, pre=0.01):
    """Small diffuse reverb (decaying-noise impulse response).  Returns a
    longer array (dry + wet tail)."""
    m = N(t60 * 1.1)
    ir = white(rng, m) * np.exp(-6.91 * tv(m) / t60)
    ir = lp(ir, lpf)
    ir[:N(pre)] = 0
    ir /= np.sqrt(np.sum(ir ** 2))
    wet = fftconv(x, ir)
    dry = np.concatenate([x, np.zeros(len(wet) - len(x))])
    return dry + mix * wet * (np.std(x) / (np.std(wet[:len(x)]) + 1e-12))


def sat(x, drive):
    x = nz(x)
    return np.tanh(drive * x) / np.tanh(drive)


def pan(x, p):
    """Equal-power pan, p in [-1, 1] -> (n, 2)."""
    a = (p + 1) * np.pi / 4
    return np.stack([x * np.cos(a), x * np.sin(a)], axis=1)


def curve(rng, period, fmax, slope=0.7, rate=200.0):
    """Smooth random control curve (zero mean, unit std) periodic in `period`
    seconds, with content up to fmax Hz.  Returns a callable of time."""
    m = max(8, int(period * rate))
    k = max(1, int(fmax * period))
    spec = np.zeros(m // 2 + 1, complex)
    kk = np.arange(1, min(k, m // 2) + 1)
    spec[kk] = (rng.standard_normal(len(kk)) + 1j * rng.standard_normal(len(kk))) * kk ** (-slope)
    v = np.fft.irfft(spec, m)
    v = (v - v.mean()) / (v.std() + 1e-12)
    grid = np.arange(m) * period / m
    return lambda t: np.interp(np.asarray(t, float), grid, v, period=period)


def squash(c, lo, hi):
    """Map a ~N(0,1) curve value into [lo, hi] smoothly."""
    return lo + (hi - lo) * 0.5 * (1 + np.tanh(c / 1.3))


# spectral magnitude shapes for STFT shaping (f in Hz, broadcastable)
def m_bp(f, fc, q):
    r = np.maximum(f, 1.0) / fc
    return 1.0 / np.sqrt(1.0 + (q * (r - 1.0 / r)) ** 2)


def m_lp(f, fc, order=2):
    return 1.0 / np.sqrt(1.0 + (np.maximum(f, 0.0) / fc) ** (2 * order))


def m_hp(f, fc, order=2):
    return 1.0 / np.sqrt(1.0 + (fc / np.maximum(f, 1e-3)) ** (2 * order))


def stft_filter(x, gain_fn, win=2048):
    """Time-varying filtering: STFT -> multiply by gain_fn(t, f) -> overlap-add.
    t: frame-centre times (s) as a column, f: bin freqs (Hz) as a row."""
    hop = win // 4
    n = len(x)
    w = 0.5 - 0.5 * np.cos(2 * np.pi * np.arange(win) / win)
    xp = np.concatenate([np.zeros(win), x, np.zeros(win + hop)])
    nfr = 1 + (len(xp) - win) // hop
    idx = np.arange(win)[None, :] + hop * np.arange(nfr)[:, None]
    X = np.fft.rfft(xp[idx] * w, axis=1)
    tc = (hop * np.arange(nfr) + win / 2 - win) / SR
    f = np.fft.rfftfreq(win, 1 / SR)
    G = gain_fn(tc[:, None], f[None, :])
    Y = np.fft.irfft(X * G, n=win, axis=1) * w
    out = np.zeros(len(xp))
    norm = np.zeros(len(xp))
    w2 = w * w
    for i in range(nfr):
        out[i * hop:i * hop + win] += Y[i]
        norm[i * hop:i * hop + win] += w2
    return out[win:win + n] / np.maximum(norm[win:win + n], 1e-9)


def shaped_noise(rng, n, gain_fn, win=2048):
    return stft_filter(white(rng, n), gain_fn, win)


def granular(rng, n, density, rate_max, bands, pareto=2.5, t0=0.0):
    """Granular texture: Poisson micro-impulses whose rate follows `density`
    (array over n samples, 0..1) through a resonator bank [(fc, q), ...]."""
    tt = tv(n)
    times = poisson(rng, lambda t: rate_max * np.interp(t, tt, density), t0, n / SR, rate_max)
    amps = np.minimum(rng.pareto(pareto, len(times)) + 0.3, 3.0) * np.sqrt(np.interp(times, tt, density))
    amps *= rng.choice([-1.0, 1.0], len(times))
    imp = impulses(n, times, amps)
    return sum(filt(imp, biquad("bp", fc, q)) * rng.uniform(0.7, 1.3) for fc, q in bands)


def crackle(rng, n, rate_fn, t0, t1, rmax, bands, amp_fn=None, pareto=2.2):
    """Fibre/crackle texture: inhomogeneous Poisson impulses -> resonators."""
    times = poisson(rng, rate_fn, t0, t1, rmax)
    amps = np.minimum(rng.pareto(pareto, len(times)) + 0.2, 6.0)
    if amp_fn is not None:
        amps *= amp_fn(times)
    imp = impulses(n, times, amps * rng.choice([-1.0, 1.0], len(times)))
    return sum(filt(imp, biquad("bp", fc, q)) for fc, q in bands)


def bubble(f0, xi=0.12, amp=1.0, length=4.5):
    """Minnaert-style bubble: decaying sine whose pitch rises (van den Doel)."""
    d = 0.043 * f0 + 0.0014 * f0 ** 1.5
    n = max(64, int(length / d * SR))
    t = tv(n)
    f = f0 * (1.0 + xi * d * t)
    y = np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-d * t)
    y *= np.clip(t / 0.0004, 0, 1)
    return amp * y


def bubbles(rng, n, times, fmin, fmax, amp=1.0, xi=(0.05, 0.22), amp_fn=None):
    out = np.zeros(n)
    for t0 in times:
        f0 = np.exp(rng.uniform(np.log(fmin), np.log(fmax)))
        a = amp * rng.uniform(0.35, 1.0) * (fmin / f0) ** 0.25
        if amp_fn is not None:
            a *= amp_fn(t0)
        place(out, bubble(f0, rng.uniform(*xi)), t0, a)
    return out


def stick_slip(rng, n, rate, amp, jitter=0.07, skip=0.0, lpf=6000.0):
    """Stick-slip friction pulse train: `rate` (Hz) and `amp` are per-sample
    arrays; each period is jittered and some slips are skipped.  Returns the
    impulse train low-passed at `lpf` (pulse sharpness), ready for resonators."""
    times, amps = [], []
    t = 0.0
    T = n / SR
    while t < T:
        i = min(int(t * SR), n - 1)
        r = rate[i]
        if r <= 1.0 or amp[i] <= 1e-4:
            t += 0.004
            continue
        t += max(0.0004, (1.0 / r) * (1.0 + jitter * rng.standard_normal()))
        if t >= T or rng.random() < skip:
            continue
        times.append(t)
        amps.append(amp[min(int(t * SR), n - 1)] * rng.uniform(0.55, 1.0))
    imp = impulses(n, np.array(times), np.array(amps))
    return filt(imp, biquad("lp", lpf, 0.6))


# =============================================================================
# Reusable sound "atoms"
# =============================================================================
def thud(rng, n, f0, tau=0.025, drop=0.3, noise_lp=350.0, noise_tau=0.015, noise_amt=0.7):
    """Low impact: sine with downward pitch settle + low-passed noise burst."""
    t = tv(n)
    f = f0 * (1 + drop * np.exp(-t / 0.01))
    s = chirp(n, f, np.exp(-t / tau))
    nb = lp(white(rng, n) * expdec(n, noise_tau), noise_lp)
    return nz(s) + noise_amt * nz(nb)


def click(rng, n, tau=0.0005, hpf=1000.0, lpf=None):
    c = hp(white(rng, n) * expdec(n, tau), hpf)
    return nz(lp(c, lpf) if lpf else c)


def stone_hit(rng, f0, bright=1.0, dur=0.35):
    """Stone landing on earth: dull thud, a short 'clok' and a little grit."""
    n = N(dur)
    th = thud(rng, n, f0, tau=0.03, drop=0.35, noise_lp=450, noise_tau=0.012)
    cl = click(rng, n, 0.0006, 500, 3000 + 2500 * bright)
    md = modes(n, np.array([880, 1370, 2050]) * rng.uniform(0.88, 1.15, 3),
               [0.012, 0.008, 0.005], [1.0, 0.6, 0.35])
    gt = rng.uniform(0.002, 0.07, 25)
    grit = filt(impulses(n, gt, rng.uniform(0.2, 1.0, 25) * np.exp(-gt / 0.03)
                         * rng.choice([-1, 1], 25)), biquad("bp", 3000, 0.7))
    return th + 0.45 * bright * cl + 0.25 * bright * nz(md) + 0.12 * nz(grit)


def wood_knock(rng, f0, dur=0.3, bright=1.0, tau=0.04):
    """Modal wooden knock (log/plank/beam)."""
    n = N(dur)
    ratios = np.array([1.0, 2.31, 3.89, 5.6]) * rng.uniform(0.96, 1.04, 4)
    taus = tau / np.array([1.0, 1.6, 2.4, 3.4])
    amps = np.array([1.0, 0.55, 0.35, 0.2]) * rng.uniform(0.7, 1.2, 4)
    md = nz(modes(n, f0 * ratios, taus, amps))
    cl = click(rng, n, 0.0005, 900, 3000 + 3500 * bright)
    body = nz(lp(white(rng, n) * expdec(n, 0.01), 700))
    return md + 0.45 * bright * cl + 0.5 * body


def ceramic(rng, n, f1, tau1, bright=0.8, k=6):
    ratios = np.array([1.0, 1.62, 2.53, 3.41, 4.6, 5.9])[:k] * rng.uniform(0.97, 1.03, k)
    amps = np.array([1.0, 0.7, 0.5, 0.35, 0.22, 0.14])[:k] * rng.uniform(0.7, 1.2, k)
    amps *= bright ** np.arange(k)
    return modes(n, f1 * ratios, tau1 / ratios ** 0.6, amps, rng.uniform(0, 0.4, k))


def leaf_rustle(rng, n, density, rate_max=3500, bright=1.0):
    """Leaves: dense crisp granular ticks plus a soft airy underlay."""
    g = granular(rng, n, density, rate_max,
                 [(1900 * bright, 0.9), (3300 * bright, 1.1), (5200 * bright, 1.3)], pareto=4.0)
    under = bp(white(rng, n), 3000 * bright, 0.6) * density
    return lp(rmsn(g) + 0.35 * rmsn(under), 9000)


def soil_grains(rng, n, density, rate_max=1500, bands=((900, 0.9), (1900, 1.1), (3600, 1.3))):
    return granular(rng, n, density, rate_max, bands, pareto=2.4)


def bell_note(f, dur, decay=1.0, bright=1.0, amp=1.0):
    """Warm additive chime: mostly harmonic partials, upper ones decay faster,
    a slightly detuned twin of the fundamental for a gentle shimmer."""
    n = N(dur)
    t = tv(n)
    parts = [(1.0, 1.0, 1.0), (2.0, 0.30, 0.55), (3.01, 0.09, 0.33), (4.13, 0.045, 0.2),
             (5.42, 0.02, 0.13)]
    y = np.zeros(n)
    for r, a, td in parts:
        if f * r < 0.45 * SR:
            y += a * (bright ** (r - 1)) * np.exp(-t / (decay * td)) * np.sin(2 * np.pi * f * r * t)
    y += 0.22 * np.exp(-t / (decay * 1.15)) * np.sin(2 * np.pi * f * 1.0021 * t + 1.3)
    rel = np.clip((dur - t) / (0.25 * dur), 0, 1)
    return amp * y * (1 - np.exp(-t / 0.0022)) * (0.5 - 0.5 * np.cos(np.pi * rel))


def formant_noise(rng, n, gain_t, formants, win=1024, lpf=4000.0):
    """Noise through moving formants: formants = [(fc_fn(t), q, g), ...]."""
    def g(tt, ff):
        s = sum(gg * m_bp(ff, fc(tt), q) for fc, q, gg in formants)
        return gain_t(tt) * s * m_lp(ff, lpf, 2)
    return shaped_noise(rng, n, g, win)


def tail_fade(x, start, end):
    """Fade x to silence between `start` and `end` seconds and cut there."""
    t = tv(len(x))
    w = np.clip((end - t) / (end - start), 0, 1)
    return (x * (0.5 - 0.5 * np.cos(np.pi * w)))[:N(end)]


def env_fn(pts):
    ts, vs = zip(*pts)
    return lambda t: np.interp(t, ts, vs)


# =============================================================================
# Registry
# =============================================================================
REGISTRY = []


def sfx(stem, count=None):
    def deco(fn):
        if count is None:
            REGISTRY.append((stem, "sfx", fn, 0))
        else:
            for i in range(count):
                REGISTRY.append((f"{stem}_{i + 1}", "sfx", fn, i))
        return fn
    return deco


def amb(name, seconds, xfade, stereo=False):
    def deco(fn):
        REGISTRY.append((name, "amb", fn, dict(seconds=seconds, xfade=xfade, stereo=stereo)))
        return fn
    return deco


# =============================================================================
# Footsteps
# =============================================================================
@sfx("step_dirt", 4)
def step_dirt(rng, v):
    """Soft earthy step: heel thud + soil crunch, then a softer toe roll."""
    n = N(0.45)
    x = np.zeros(n)
    toe = [0.075, 0.09, 0.065, 0.1][v]
    f0 = [118, 128, 110, 135][v]
    crunch_amt = [0.75, 0.6, 0.9, 0.7][v]

    def contact(g, f, amt, dur=0.3):
        m = N(dur)
        tt = tv(m)
        th = thud(rng, m, f, tau=0.018, drop=0.3, noise_lp=550, noise_tau=0.014, noise_amt=1.2)
        dens = np.exp(-tt / 0.03) * (1 - np.exp(-tt / 0.002))
        cr = soil_grains(rng, m, dens, 3200, ((800, 0.9), (1700, 1.1), (3200, 1.3)))
        scuff = bp(white(rng, m), 1100, 0.7) * ar(m, 0.003, 0.03)
        return g * (nz(th) + amt * nz(cr) + 0.25 * nz(scuff))

    place(x, contact(1.0, f0, crunch_amt), 0.0)
    place(x, contact(0.5, f0 * 1.15, crunch_amt * 1.2, 0.25), toe)
    return lp(x, 6500)


@sfx("step_water", 3)
def step_water(rng, v):
    """Foot into shallow water: slosh, spray, bubbles and a few drips."""
    n = N(0.6)
    tau = [0.055, 0.045, 0.065][v]
    slosh = formant_noise(
        rng, n, lambda tt: np.clip(tt / 0.01, 0, 1) * np.exp(-np.maximum(tt - 0.01, 0) / tau),
        [(lambda tt: 700 + 400 * np.exp(-tt / 0.05), 1.2, 1.0),
         (lambda tt: 1900 + 0 * tt, 1.5, 0.45)], win=512, lpf=5000)
    spray = lp(hp(white(rng, n), 1800), 9000) * ar(n, 0.004, 0.025 + 0.008 * v)
    th = thud(rng, n, 90, tau=0.02, noise_lp=300)
    bt = 0.004 + rng.exponential(0.04, [12, 9, 15][v])
    bub = bubbles(rng, n, bt[bt < 0.25], 650, 3200, xi=(0.06, 0.22))
    drips = bubbles(rng, n, rng.uniform(0.14, 0.42, [4, 3, 6][v]), 1800, 4500, xi=(0.08, 0.25))
    return (0.9 * nz(slosh) + 0.35 * nz(spray) + 0.4 * nz(th) + 0.45 * nz(bub)
            + 0.2 * nz(drips))


# =============================================================================
# Stone
# =============================================================================
@sfx("knap", 5)
def knap(rng, v):
    """Flint knapping: a crisp contact click, the hammerstone's short 'clack'
    body, a bright inharmonic ring of the core (2.5-11 kHz) and, on some
    strikes, a tiny tinkle of the detached flake."""
    n = N(0.5)
    P = [dict(f1=3150, tau=0.050, fb=1250, ft=330, flakes=0),
         dict(f1=3750, tau=0.042, fb=1480, ft=290, flakes=1),
         dict(f1=2700, tau=0.064, fb=1050, ft=360, flakes=0),
         dict(f1=4200, tau=0.036, fb=1650, ft=310, flakes=2),
         dict(f1=3400, tau=0.056, fb=1180, ft=270, flakes=1)][v]
    t = tv(n)
    f1 = P["f1"] * rng.uniform(0.985, 1.015)
    ratios = np.array([1.0, 1.36, 1.91, 2.47, 2.98]) * rng.uniform(0.97, 1.03, 5)
    amps = np.array([1.0, 0.8, 0.55, 0.4, 0.25]) * rng.uniform(0.6, 1.15, 5)
    taus = P["tau"] / ratios ** 0.75
    ring = nz(modes(n, f1 * ratios, taus, amps))
    # fast initial decay on top of the ring: crisp, stone-like rather than metallic
    ring *= 0.55 + 0.45 * np.exp(-t / 0.008)
    fb = P["fb"] * rng.uniform(0.97, 1.03)
    body = nz(modes(n, [fb, fb * 1.53, fb * 2.21], [0.016, 0.011, 0.007], [1.0, 0.55, 0.3]))
    thock = nz(modes(n, [P["ft"]], [0.008], [1.0]))
    cl = click(rng, n, 0.00045, 2500)
    sz = nz(bp(white(rng, n), 6800, 1.2)) * expdec(n, 0.010)
    x = 0.85 * ring + 1.0 * body + 0.5 * thock + 0.6 * cl + 0.18 * sz
    for k in range(P["flakes"]):
        t0 = rng.uniform(0.045, 0.09) + 0.055 * k
        m = N(0.04)
        fl = nz(modes(m, rng.uniform(5200, 8800, 3), [0.006, 0.0045, 0.0035], [1, .7, .5]))
        fl += 0.6 * click(rng, m, 0.0003, 3000)
        place(x, nz(fl), t0, rng.uniform(0.10, 0.18))
    return lp(x, 13000)


@sfx("stone_break")
def stone_break(rng, v):
    """A stone splitting: sharp crack, low body modes, micro-fractures, then
    the pieces dropping apart."""
    n = N(1.0)
    x = np.zeros(n)
    m = N(0.5)
    crack = nz(hp(white(rng, m) * expdec(m, 0.0016), 700))
    body = nz(modes(m, np.array([640, 1010, 1530, 2240, 3150]) * rng.uniform(0.97, 1.03, 5),
                    [0.05, 0.036, 0.026, 0.018, 0.012], [1.0, 0.8, 0.6, 0.45, 0.28]))
    thump = nz(modes(m, [150, 230], [0.04, 0.02], [1.0, 0.5]))
    place(x, crack + 0.7 * body + 0.6 * thump, 0.0)
    mt = 0.003 + np.cumsum(rng.exponential(0.004, 30))
    mt = mt[mt < 0.09]
    ma = (rng.pareto(2.5, len(mt)) + 0.3) * np.exp(-mt / 0.04) * rng.choice([-1, 1], len(mt))
    micro = filt(impulses(n, mt, ma), [biquad("bp", 3200, 0.8), biquad("hp", 1200)])
    x += 0.5 * nz(micro)
    for t0, g, f0 in [(0.20, 0.45, 180), (0.33, 0.3, 230), (0.41, 0.15, 260)]:
        place(x, stone_hit(rng, f0, 0.6), t0, g)
    return x


@sfx("stone_drop", 3)
def stone_drop(rng, v):
    """Stone thudding onto earth, with a small bounce on some variants."""
    n = N(0.6)
    x = np.zeros(n)
    f0 = [110, 135, 92][v]
    place(x, stone_hit(rng, f0, [1.0, 1.2, 0.8][v]), 0.0)
    if v == 0:
        place(x, stone_hit(rng, f0 * 1.15, 0.8, 0.25), 0.105, 0.28)
    if v == 2:
        place(x, stone_hit(rng, f0 * 1.2, 0.8, 0.25), 0.085, 0.35)
        place(x, stone_hit(rng, f0 * 1.3, 0.7, 0.2), 0.15, 0.12)
    return x


# =============================================================================
# Wood
# =============================================================================
@sfx("wood_split")
def wood_split(rng, v):
    """Axe/wedge thunk, tearing fibres, the split crack, halves falling."""
    n = N(1.1)
    x = np.zeros(n)
    place(x, wood_knock(rng, 175, 0.4, 1.0, 0.035), 0.0)
    cr = crackle(rng, n, lambda tt: 150 + 2500 * np.clip((tt - 0.01) / 0.12, 0, 1) ** 2,
                 0.01, 0.135, 2700, [(900, 1.2), (2100, 1.5), (4200, 1.5)])
    x += 0.45 * tnorm(cr)
    m = N(0.3)
    crack = (nz(hp(white(rng, m) * expdec(m, 0.0012), 500))
             + 0.8 * nz(modes(m, [680, 1120, 1830, 2700], [0.022, 0.016, 0.011, 0.008],
                              [1, .8, .6, .4])))
    place(x, nz(crack), 0.135, 0.95)
    place(x, wood_knock(rng, 210, 0.35, 0.8, 0.045), 0.43, 0.6)
    place(x, wood_knock(rng, 250, 0.3, 0.7, 0.04), 0.56, 0.45)
    place(x, wood_knock(rng, 270, 0.25, 0.6, 0.03), 0.64, 0.18)
    return x


@sfx("branch_snap")
def branch_snap(rng, v):
    """Green branch: fibres creak and crackle faster and faster, a sharp
    snap, stringy after-tearing, and the leaves rustle."""
    n = N(0.8)
    t = tv(n)
    ts = 0.24
    x = np.zeros(n)
    cr = crackle(rng, n, lambda tt: 20 + 900 * np.clip(tt / ts, 0, 1) ** 3, 0.0, ts, 950,
                 [(1800, 1.5), (3300, 2), (5200, 2)], amp_fn=lambda tt: 0.3 + 0.7 * (tt / ts) ** 2)
    x += 0.35 * nz(cr)
    m = N(0.3)
    snap = (0.7 * nz(hp(white(rng, m) * expdec(m, 0.0015), 700))
            + 1.0 * nz(modes(m, [1150, 1850, 2950, 4300], [0.02, 0.015, 0.011, 0.008],
                             [1, .8, .6, .4]))
            + 0.5 * nz(modes(m, [320, 610], [0.014, 0.01], [1, 0.6])))
    place(x, nz(snap), ts)
    cr2 = crackle(rng, n, lambda tt: 700 * np.exp(-(tt - ts - 0.005) / 0.05), ts + 0.005,
                  ts + 0.25, 700, [(1500, 1.5), (3000, 2)])
    x += 0.3 * nz(cr2)
    for dt, g in [(0.03, 0.35), (0.075, 0.2)]:
        mm = N(0.1)
        s2 = nz(hp(white(rng, mm) * expdec(mm, 0.0006), 1200)) + 0.5 * nz(
            modes(mm, rng.uniform(1300, 3500, 2), [0.008, 0.006], [1, .7]))
        place(x, nz(s2), ts + dt, g)
    dens = np.interp(t, [ts - 0.05, ts + 0.02, ts + 0.45], [0, 1, 0]) * (t > ts - 0.05)
    x += 0.07 * nz(leaf_rustle(rng, n, dens, 1500))
    return x


def creak_core(rng, dur, rate_pts, env_pts, res, jitter=0.07, skip=0.03, rate_var=0.1,
               fric_fc=1200.0):
    n = N(dur)
    t = tv(n)
    rate = env_fn(rate_pts)(t) * (1 + rate_var * curve(rng, dur, 6)(t))
    env = np.clip(env_fn(env_pts)(t) * (1 + 0.25 * curve(rng, dur, 10)(t)), 0, None)
    body = resonate(stick_slip(rng, n, rate, env, jitter=jitter, skip=skip, lpf=2500), res)
    fr = bp(white(rng, n), fric_fc, 0.9) * env
    return nz(body) + 0.05 * nz(fr)


@sfx("tree_creak")
def tree_creak(rng, v):
    """Long groaning creak: slow stick-slip pulses through trunk resonances."""
    x = creak_core(rng, 3.4, [(0, 22), (0.5, 34), (0.9, 62), (1.2, 45), (1.6, 30), (2.0, 38),
                              (2.25, 75), (2.45, 50), (3.0, 30), (3.4, 20)],
                   [(0, 0), (0.3, 0.35), (0.9, 1.0), (1.25, 0.55), (1.6, 0.3), (2.0, 0.6),
                    (2.3, 1.0), (2.6, 0.7), (3.0, 0.35), (3.4, 0)],
                   [(185, 6, 0.9), (430, 10, 1.0), (790, 12, 0.8), (1360, 10, 0.45), (2350, 8, 0.2)],
                   jitter=0.09, skip=0.04, rate_var=0.12, fric_fc=900)
    return reverb(rng, x, t60=0.7, mix=0.12, lpf=3500)


@sfx("tree_fall")
def tree_fall(rng, v):
    """Foliage whoosh building as the tree accelerates, a heavy trunk thud,
    branches crashing, then the canopy settling."""
    dur, ti = 4.0, 2.05
    n = N(dur)
    t = tv(n)
    x = np.zeros(n)
    cr = crackle(rng, n, lambda tt: 250 * np.exp(-tt / 0.3), 0.0, 0.6, 250,
                 [(1100, 1.2), (2400, 1.5)])
    x += 0.12 * nz(cr)

    def g(tt, ff):
        uu = np.clip(tt / ti, 0, 1)
        a = np.where(tt < ti, uu ** 2.2, np.exp(-(tt - ti) / 0.08))
        fc = 380 + 1500 * uu ** 1.5
        return a * (m_bp(ff, fc, 0.8) + 0.4 * m_hp(ff, 2500, 1) * m_lp(ff, 7000, 2))
    whoosh = shaped_noise(rng, n, g, win=2048)
    u = np.clip(t / ti, 0, 1)
    dens = np.where(t < ti, u ** 2, np.exp(-(t - ti) / 0.35))
    leaves = leaf_rustle(rng, n, dens, rate_max=4000, bright=0.85)
    x += 0.5 * nz(whoosh) + 0.35 * nz(leaves)
    m = N(1.6)
    tt = tv(m)
    boom = chirp(m, 34 + 38 * np.exp(-tt / 0.06), np.exp(-tt / 0.32))
    body = lp(white(rng, m) * expdec(m, 0.12), 260)
    impact = sat(nz(boom) + 0.8 * nz(body), 1.6)
    crunch = crackle(rng, m, lambda s: 1800 * np.exp(-s / 0.15), 0.0, 0.8, 1800,
                     [(700, 1.0), (1600, 1.2), (3200, 1.5)])
    impact = impact + 0.35 * nz(crunch)
    for k in range(6):
        place(impact, wood_knock(rng, rng.uniform(140, 420), 0.3, 0.7, 0.04),
              rng.uniform(0.0, 0.45), rng.uniform(0.15, 0.4))
    leafcrash = bp(white(rng, m), 3200, 0.7) * ar(m, 0.01, 0.3)
    impact = impact + 0.25 * nz(leafcrash)
    place(x, impact, ti)
    place(x, thud(rng, N(0.8), 46, tau=0.15, drop=0.4, noise_lp=250, noise_tau=0.08),
          ti + 0.27, 0.35)
    for k in range(7):
        t0 = rng.uniform(ti + 0.5, dur - 0.4)
        place(x, wood_knock(rng, rng.uniform(250, 600), 0.2, 0.5, 0.025), t0,
              0.12 * np.exp(-(t0 - ti) / 0.8))
    return x


# =============================================================================
# Plants
# =============================================================================
@sfx("cut_grass", 3)
def cut_grass(rng, v):
    """Swish of the blade through grass + fibrous snipping + a little rustle."""
    n = N(0.45)
    t = tv(n)
    sw_dur = [0.13, 0.10, 0.16][v]
    f_lo, f_hi = [(1800, 5500), (2200, 6500), (1500, 4800)][v]

    def g(tt, ff):
        u = np.clip(tt / sw_dur, 0, 1)
        fc = f_lo * (f_hi / f_lo) ** u
        a = np.sin(np.pi * u) ** 1.5 * (tt < sw_dur)
        return a * m_bp(ff, fc, 1.3) * m_lp(ff, 9000, 2)
    sw = shaped_noise(rng, n, g, win=512)
    tc = sw_dur * 0.55
    snips = crackle(rng, n, lambda tt: 3500 * np.exp(-((tt - tc) / 0.012) ** 2), tc - 0.03,
                    tc + 0.05, 3500, [(3000, 1.2), (5500, 1.5), (8000, 1.5)])
    dens = np.clip(1 - (t - tc) / 0.25, 0, 1) * (t > tc)
    rus = leaf_rustle(rng, n, dens * 0.5, rate_max=900)
    return 0.8 * nz(sw) + 0.55 * nz(snips) + 0.2 * nz(rus)


@sfx("rustle", 3)
def rustle(rng, v):
    """Leaf rustle (granular)."""
    dur = [0.75, 0.9, 0.5][v]
    n = N(dur)
    t = tv(n)
    if v == 0:
        dens = np.interp(t, [0, 0.15, 0.45, 0.75], [0, 1, 0.5, 0])
    elif v == 1:
        dens = np.interp(t, [0, 0.12, 0.3, 0.42, 0.55, 0.9], [0, 0.8, 0.3, 0.2, 1.0, 0])
    else:
        dens = np.interp(t, [0, 0.03, 0.1, 0.14, 0.2, 0.25, 0.33, 0.5],
                         [0, 1, 0.3, 0.9, 0.25, 0.7, 0.15, 0])
    dens *= np.clip(1 + 0.3 * curve(rng, dur, 20)(t), 0, None)
    return leaf_rustle(rng, n, dens, rate_max=[3500, 3000, 4500][v], bright=[1.0, 0.9, 1.1][v])


@sfx("harvest_pop")
def harvest_pop(rng, v):
    """Crop pulled from the soil: roots tense and tear, a soft 'thwup', soil
    sprinkles back down."""
    n = N(0.7)
    t = tv(n)
    tp = 0.17
    dens = np.clip(t / tp, 0, 1) ** 1.5 * (t < tp)
    x = 0.45 * nz(soil_grains(rng, n, dens, 900, ((700, 1.0), (1500, 1.2))))
    x += 0.25 * nz(crackle(rng, n, lambda tt: 60 + 300 * (tt / tp) ** 2, 0.04, tp, 360,
                           [(2200, 2), (3800, 2)]))
    m = N(0.15)
    tt = tv(m)
    thwup = chirp(m, 200 * np.exp(-tt / 0.03) + 90, ar(m, 0.004, 0.03))
    air = bp(white(rng, m), 700, 0.8) * expdec(m, 0.012)
    pop = nz(thwup) + 0.4 * nz(air) + 0.35 * click(rng, m, 0.0006, 2000)
    place(x, nz(pop), tp, 1.0)
    d2 = np.exp(-(t - tp - 0.02) / 0.12) * (t > tp + 0.02)
    x += 0.25 * nz(soil_grains(rng, n, d2, 400, ((1500, 1.0), (3500, 1.2))))
    for t0 in (tp + 0.08, tp + 0.16):
        place(x, thud(rng, N(0.1), rng.uniform(160, 240), tau=0.01, noise_lp=500,
                      noise_tau=0.008), t0, 0.15)
    return x


# =============================================================================
# Earth
# =============================================================================
@sfx("dig_soil", 3)
def dig_soil(rng, v):
    """Scoop of loose soil: gritty scrape in, then clumps and grains falling."""
    n = N(0.8)
    t = tv(n)
    a_dur = [0.13, 0.10, 0.16][v]
    scr_env = np.interp(t, [0, 0.015, a_dur, a_dur + 0.06], [0, 1, 0.6, 0])
    scrape = formant_noise(rng, n, lambda tt: np.interp(tt, t, scr_env),
                           [(lambda tt: 1500 + 0 * tt, 0.8, 1.0),
                            (lambda tt: 3200 + 0 * tt, 1.2, 0.4)], win=512, lpf=6000)
    crunch = soil_grains(rng, n, scr_env, 3000)
    x = 0.55 * nz(scrape) + 0.7 * nz(crunch)
    place(x, 0.5 * nz(thud(rng, N(0.2), 130, tau=0.025, noise_lp=400)), 0.01)
    f0, f1 = [(0.26, 0.6), (0.22, 0.55), (0.3, 0.7)][v]
    fall = np.interp(t, [f0, f0 + 0.05, f1 - 0.1, f1], [0, 1, 0.5, 0])
    x += 0.45 * nz(soil_grains(rng, n, fall, 1500, ((800, 0.9), (1700, 1.1), (3200, 1.3))))
    for k in range([7, 5, 10][v]):
        place(x, thud(rng, N(0.08), rng.uniform(150, 280), tau=0.008, noise_lp=600,
                      noise_tau=0.006), rng.uniform(f0, f1 - 0.05), rng.uniform(0.12, 0.3))
    return lp(x, 7000)


@sfx("dig_clay", 2)
def dig_clay(rng, v):
    """Heavy wet dig: squelching push, sucking pull-out, a suction pop."""
    n = N(0.9)
    t = tv(n)
    push_d = [0.28, 0.24][v]
    push = formant_noise(
        rng, n, lambda tt: np.sin(np.pi * np.clip(tt / push_d, 0, 1)) ** 0.8 * (tt < push_d),
        [(lambda tt: 520 - 200 * np.clip(tt / push_d, 0, 1), 3, 1.0),
         (lambda tt: 2.6 * (520 - 200 * np.clip(tt / push_d, 0, 1)), 4, 0.35)],
        win=1024, lpf=2500)
    p0 = [0.36, 0.33][v]
    pull = formant_noise(
        rng, n, lambda tt: np.sin(np.pi * np.clip((tt - p0) / 0.14, 0, 1)) ** 1.2,
        [(lambda tt: 300 + 550 * np.clip((tt - p0) / 0.14, 0, 1), 3.5, 1.0),
         (lambda tt: 2.4 * (300 + 550 * np.clip((tt - p0) / 0.14, 0, 1)), 4, 0.3)],
        win=1024, lpf=3000)
    rough = np.clip(1 + 0.6 * curve(rng, 0.9, 60, slope=0.1)(t), 0, None)
    x = (0.9 * nz(push) + 0.8 * nz(pull)) * rough
    place(x, 0.5 * nz(thud(rng, N(0.25), 85, tau=0.03, noise_lp=300)), 0.02)
    pop = mix(nz(bubble([210, 180][v], 0.12, length=3.0)),
              0.3 * click(rng, N(0.12), 0.0008, 400, 2000))
    place(x, nz(pop), p0 + 0.13, 0.32)
    x += 0.12 * nz(crackle(rng, n, lambda tt: 120 * np.exp(-((tt - 0.5) / 0.15) ** 2), 0.3, 0.75,
                           120, [(1800, 2), (3000, 2)]))
    return lp(x, 5000)


@sfx("place_soil", 2)
def place_soil(rng, v):
    """Soft packed thud of earth being pressed down (v2: pat-pat)."""
    n = N(0.5)
    x = np.zeros(n)

    def pat(g, f0):
        m = N(0.3)
        tt = tv(m)
        th = lp(white(rng, m) * expdec(m, 0.03), 320)
        s = chirp(m, f0 * (1 + 0.2 * np.exp(-tt / 0.01)), expdec(m, 0.028))
        pn = bp(white(rng, m) * expdec(m, 0.01), 750, 0.9)
        cr = soil_grains(rng, m, np.exp(-tt / 0.06) * (tt > 0.008), 700,
                         ((1000, 1.0), (2400, 1.2)))
        return g * (nz(th) + 0.7 * nz(s) + 0.35 * nz(pn) + 0.18 * nz(cr))
    if v == 0:
        place(x, pat(1.0, 80), 0.0)
    else:
        place(x, pat(0.6, 95), 0.0)
        place(x, pat(1.0, 85), 0.13)
    return x


@sfx("compost_turn")
def compost_turn(rng, v):
    """Wet leafy compost lifted, turned and flopped back down."""
    dur = 1.15
    n = N(dur)
    t = tv(n)
    mot = np.interp(t, [0, 0.12, 0.38, 0.5, 0.62, 0.9, 1.15], [0, 0.8, 1.0, 0.3, 0.9, 0.3, 0])
    leaves = leaf_rustle(rng, n, mot, rate_max=2500, bright=0.7)
    wet = formant_noise(rng, n, lambda tt: np.interp(tt, t, mot) ** 1.3,
                        [(lambda tt: 420 + 250 * np.sin(2 * np.pi * 1.3 * tt), 2.5, 1.0),
                         (lambda tt: 1100 + 0 * tt, 3, 0.4)], win=1024, lpf=2500)
    x = nz(0.6 * rmsn(leaves) + 0.7 * rmsn(wet))
    place(x, 0.7 * nz(thud(rng, N(0.3), 95, tau=0.03, noise_lp=400, noise_tau=0.02)), 0.56)
    place(x, 0.4 * nz(thud(rng, N(0.3), 110, tau=0.025, noise_lp=500)), 0.66)
    x += 0.15 * nz(soil_grains(rng, n, np.exp(-np.maximum(t - 0.58, 0) / 0.15) * (t > 0.58), 900))
    return x


# =============================================================================
# Clay & pottery
# =============================================================================
@sfx("clay_squish", 4)
def clay_squish(rng, v):
    """Wet clay pressed/kneaded: a short squelch whose formant glides as the
    clay deforms, a soft fizz of tiny wet micro-bubbles while it is pressed,
    and a little tacky unsticking at the release.  Soft, no sloppy gurgles."""
    P = [dict(d=0.30, att=0.06, F=(280, 560), tack=60, pip=False),
         dict(d=0.36, att=0.09, F=(460, 300), tack=80, pip=True),
         dict(d=0.26, att=0.045, F=(240, 480), tack=50, pip=False),
         dict(d=0.40, att=0.11, F=(330, 650), tack=90, pip=True)][v]
    d, att = P["d"], P["att"]
    n = N(d + 0.15)
    t = tv(n)

    def gain(tt):
        return np.where(tt < att, np.sin(0.5 * np.pi * np.clip(tt / att, 0, 1)),
                        np.exp(-(tt - att) / (0.3 * (d - att)))) * (tt >= 0)

    def F1(tt):
        return P["F"][0] + (P["F"][1] - P["F"][0]) * np.sin(0.5 * np.pi * np.clip(tt / d, 0, 1))
    sq = formant_noise(rng, n, gain, [(F1, 5, 1.0), (lambda tt: 2.3 * F1(tt), 6, 0.45),
                                      (lambda tt: 120 + 0 * tt, 1.0, 0.2)], win=1024, lpf=2500)
    wet = np.clip(1 + 0.3 * curve(rng, d + 0.15, 90, slope=0.0)(t), 0, None)
    x = nz(sq * wet)
    fizz_t = poisson(rng, lambda tt: 450 * gain(tt), 0.0, d, 450)
    fizz = bubbles(rng, n, fizz_t, 1600, 4200, amp=1.0, xi=(0.05, 0.15))
    x += 0.12 * tnorm(fizz)
    tack = crackle(rng, n, lambda tt: P["tack"] * (tt > att) * np.exp(-(tt - att) / 0.12),
                   att, d, P["tack"], [(2200, 2), (3400, 2)])
    x += 0.1 * tnorm(tack)
    if P["pip"]:
        place(x, bubble(rng.uniform(650, 900), 0.1), att + 0.05, 0.15)
    return lp(x, 4500)


@sfx("clay_slap")
def clay_slap(rng, v):
    """Lump of wet clay slapped onto a surface: 'thwap' with a wet splat."""
    n = N(0.5)
    t = tv(n)
    imp = lp(white(rng, n) * expdec(n, 0.0025), 4500)
    body = lp(white(rng, n) * expdec(n, 0.035), 480)
    tone = chirp(n, 125 * (1 + 0.3 * np.exp(-t / 0.01)), expdec(n, 0.03))
    form = bp(white(rng, n) * ar(n, 0.002, 0.03), 320, 2)
    splat = bp(white(rng, n) * ar(n, 0.003, 0.025), 1400, 0.8)
    tack = crackle(rng, n, lambda tt: 70 * np.exp(-(tt - 0.03) / 0.08), 0.03, 0.25, 70,
                   [(2200, 2), (3400, 2)])
    x = (0.8 * nz(imp) + 0.9 * nz(body) + 0.6 * nz(tone) + 0.5 * nz(form) + 0.35 * nz(splat)
         + 0.1 * nz(tack))
    return lp(x, 6000)


@sfx("clay_press", 4)
def clay_press(rng, v):
    """A fingertip of clay pressed into place: a tiny, muted, slightly wet
    'tuk' - short and soft enough to repeat while you work a layer."""
    dur = 0.16
    n = N(dur)
    t = tv(n)
    f0 = [150, 175, 135, 190][v] * rng.uniform(0.95, 1.05)
    thump = lp(white(rng, n) * expdec(n, 0.012), 700)
    tone = chirp(n, f0 * (1 + 0.25 * np.exp(-t / 0.008)), expdec(n, 0.018))
    wet = bp(white(rng, n) * ar(n, 0.004, 0.02), 900 + 120 * v, 1.2)
    x = 0.8 * nz(thump) + 0.6 * nz(tone) + 0.18 * nz(wet)
    x *= np.minimum(1.0, (dur - t) / 0.05)
    return lp(x, 2200) * 0.5


@sfx("clay_pinch", 3)
def clay_pinch(rng, v):
    """A pinch of clay picked off: a soft tacky pull, quieter than adding."""
    dur = 0.14
    n = N(dur)
    t = tv(n)
    tack = bp(white(rng, n) * ar(n, 0.006, 0.018), [1100, 1300, 950][v], 1.5)
    pull = lp(white(rng, n) * ar(n, 0.01, 0.03), 600)
    x = 0.5 * nz(tack) + 0.6 * nz(pull)
    x *= np.minimum(1.0, (dur - t) / 0.04)
    return lp(x, 2600) * 0.4


@sfx("clay_smooth")
def clay_smooth(rng, v):
    """Wet palm gliding over clay: soft friction swell with fine stick-slip."""
    dur = 0.55
    n = N(dur)
    t = tv(n)
    env = np.sin(np.pi * np.clip(t / 0.5, 0, 1)) ** 1.4
    fl = curve(rng, dur, 45, slope=0.1)

    def g(tt, ff):
        e = np.interp(tt, t, env) * (1 + 0.3 * fl(tt))
        fc = 850 + 150 * np.sin(np.pi * np.clip(tt / 0.5, 0, 1))
        return np.maximum(e, 0) * (m_bp(ff, fc, 0.7) + 0.25 * m_bp(ff, 2400, 1.5)) * m_lp(ff, 3500)
    x = shaped_noise(rng, n, g, win=512)
    tack = crackle(rng, n, lambda tt: 40 * np.interp(tt, t, env), 0.0, dur, 40, [(2600, 2)])
    return nz(x) + 0.05 * nz(tack)


@sfx("pottery_place")
def pottery_place(rng, v):
    """Fired pot set down: gentle ceramic clunk + surface thud, settling tick."""
    n = N(0.55)
    x = np.zeros(n)

    def contact(g, bright):
        m = N(0.45)
        tt = tv(m)
        c = nz(ceramic(rng, m, 640, 0.035, 0.65)) * (1 - np.exp(-tt / 0.0005))
        s = thud(rng, m, 150, tau=0.014, noise_lp=700, noise_tau=0.008)
        k = click(rng, m, 0.0005, 400, 3500)
        return g * (0.8 * c + 0.7 * nz(s) + 0.25 * bright * k)
    place(x, contact(1.0, 1.0), 0.0)
    place(x, contact(0.35, 0.6), 0.024)
    return lp(x, 7000)


@sfx("pottery_crack")
def pottery_crack(rng, v):
    """Ceramic cracking: bright clink, fracture crackle, fragments tinkling."""
    n = N(0.8)
    x = np.zeros(n)
    m = N(0.5)
    place(x, nz(ceramic(rng, m, 1850, 0.035, 0.85)) + 0.6 * click(rng, m, 0.0004, 2000), 0.0, 0.9)
    fr = crackle(rng, n, lambda tt: 3000 * np.exp(-(tt - 0.018) / 0.02), 0.018, 0.09, 3000,
                 [(2500, 1.0), (4200, 1.2), (6500, 1.5)])
    x += 0.45 * tnorm(fr)
    m = N(0.2)
    place(x, nz(hp(white(rng, m) * expdec(m, 0.0012), 1200)), 0.022, 0.7)
    for k in range(5):
        m = N(0.1)
        frag = nz(ceramic(rng, m, rng.uniform(3800, 6500), 0.012, 0.7, k=4))
        place(x, frag, rng.uniform(0.07, 0.45), rng.uniform(0.08, 0.25))
    place(x, 0.25 * nz(thud(rng, N(0.2), 220, tau=0.012, noise_lp=900)), 0.12)
    return x


@sfx("pottery_tap")
def pottery_tap(rng, v):
    """Fingertip tap on a fired pot: dull ceramic 'tok'."""
    n = N(0.45)
    t = tv(n)
    md = nz(ceramic(rng, n, 980, 0.045, 0.6, k=5)) * (1 - np.exp(-t / 0.0008))
    flesh = lp(white(rng, n) * expdec(n, 0.006), 450)
    return lp(md + 0.6 * nz(flesh), 6000)


# =============================================================================
# Water
# =============================================================================
@sfx("water_splash")
def water_splash(rng, v):
    """Something dropped/stepped into water: impact, decaying slosh, spray,
    a bubble cloud, the cavity's low 'plunk' and a few drips falling back."""
    n = N(1.0)
    impact = lp(white(rng, n) * ar(n, 0.002, 0.02), 5000)
    slosh = formant_noise(rng, n, lambda tt: np.clip(tt / 0.01, 0, 1)
                          * np.exp(-np.maximum(tt - 0.01, 0) / 0.09),
                          [(lambda tt: 600 + 500 * np.exp(-tt / 0.06), 1.0, 1.0),
                           (lambda tt: 1800 + 0 * tt, 1.3, 0.5)], win=512, lpf=6000)
    spray = lp(hp(white(rng, n), 2000), 10000) * ar(n, 0.008, 0.07)
    bt = 0.005 + rng.exponential(0.07, 40)
    bub = bubbles(rng, n, bt[bt < 0.5], 500, 3000, xi=(0.06, 0.22))
    drips = bubbles(rng, n, rng.uniform(0.18, 0.7, 9), 1500, 4200, xi=(0.08, 0.25))
    th = thud(rng, n, 85, tau=0.03, noise_lp=300)
    x = (0.7 * nz(impact) + 0.9 * nz(slosh) + 0.4 * nz(spray) + 0.45 * nz(bub)
         + 0.2 * nz(drips) + 0.35 * nz(th))
    place(x, 0.45 * nz(bubble(240, 0.15)), 0.03)
    return x


@sfx("water_fill")
def water_fill(rng, v):
    """Vessel scooped into water and filling: dip, then glugs whose pitch
    rises with the vessel's air-cavity resonance."""
    dur = 1.25
    n = N(dur)
    t = tv(n)
    env = np.interp(t, [0, 0.08, 0.2, 0.95, 1.2], [0, 0.3, 1.0, 0.9, 0])

    def fc(tt):
        return 380 * (1000 / 380) ** np.clip((tt - 0.1) / 1.0, 0, 1)
    res = formant_noise(rng, n, lambda tt: np.interp(tt, t, env),
                        [(fc, 6, 1.0), (lambda tt: 2.7 * fc(tt), 5, 0.3)], win=1024, lpf=5000)
    glug = np.zeros(n)
    for t0 in poisson(rng, 26, 0.08, 1.1, 26):
        place(glug, bubble(fc(t0) * rng.uniform(0.8, 1.25), rng.uniform(0.06, 0.2)), t0,
              rng.uniform(0.4, 1.0) * np.interp(t0, t, env))
    small = bubbles(rng, n, poisson(rng, 40, 0.05, 1.1, 40), 900, 3000, amp=0.4)
    x = nz(0.6 * rmsn(res) + 1.0 * rmsn(glug) + 0.35 * rmsn(small))
    dip = lp(white(rng, n) * ar(n, 0.004, 0.03), 3000)
    return x + 0.7 * nz(dip)


@sfx("drink", 2)
def drink(rng, v):
    """Gulp: a little liquid, the throat 'glk' and a low gulp (v2: two)."""
    n = N([0.5, 0.75][v])
    x = np.zeros(n)

    def gulp(g, f0):
        m = N(0.3)
        tt = tv(m)
        glk = bp(white(rng, m) * expdec(m, 0.004), 1300, 2)
        low = chirp(m, f0 * (1 + 0.5 * np.exp(-tt / 0.015)), ar(m, 0.005, 0.02))
        form = bp(white(rng, m) * ar(m, 0.004, 0.03), 520, 3)
        return g * (0.6 * nz(glk) + 0.7 * nz(low) + 0.6 * nz(form))
    place(x, bubbles(rng, N(0.15), rng.uniform(0, 0.06, 3), 450, 900, amp=0.18), 0.0)
    place(x, gulp(1.0, 150), 0.1)
    if v == 1:
        place(x, gulp(0.85, 165), 0.42)
    return lp(x, 5000)


@sfx("sizzle")
def sizzle(rng, v):
    """Water on embers: sputtering steam hiss with small pops."""
    dur = 1.5
    n = N(dur)
    t = tv(n)
    env = ar(n, 0.03, 0.5) * np.clip((dur - t) / 0.3, 0, 1)
    sp = curve(rng, dur, 30, slope=0.2)

    def g(tt, ff):
        e = np.interp(tt, t, env) * np.clip(1 + 0.6 * sp(tt), 0.1, None)
        return e * m_hp(ff, 2200, 2) * m_lp(ff, 9500, 2) * (1 + 0.6 * m_bp(ff, 5200, 1.2))
    hiss = shaped_noise(rng, n, g, win=512)
    pops = crackle(rng, n, lambda tt: 70 * np.exp(-tt / 0.4), 0.0, dur, 70, [(2800, 1.5), (5200, 2)])
    small = bubbles(rng, n, poisson(rng, lambda tt: 25 * np.exp(-tt / 0.3), 0, 0.9, 25),
                    1800, 4500, amp=0.5)
    return nz(hiss) + 0.3 * nz(pops) + 0.2 * nz(small)


# =============================================================================
# Fire
# =============================================================================
@sfx("fire_ignite")
def fire_ignite(rng, v):
    """Tinder catching: soft 'fwoomp' that opens up, then first crackles."""
    dur = 1.5
    n = N(dur)
    t = tv(n)

    def g(tt, ff):
        u = np.clip(tt / 0.32, 0, 1)
        a = np.where(tt < 0.32, u ** 1.5, 0.25 + 0.75 * np.exp(-(tt - 0.32) / 0.18))
        a = a * np.clip((dur - tt) / 0.5, 0, 1)
        return a * (m_lp(ff, 220 + 1900 * u, 2) * m_hp(ff, 50, 2) + 0.15 * u * m_bp(ff, 3000, 1.0))
    whoosh = shaped_noise(rng, n, g, win=1024)
    pre = lp(white(rng, n) * ar(n, 0.01, 0.05), 300)
    low = lp(colored(rng, n, 2.0), 140) * pw(n, [(0, 0), (0.3, 1), (0.6, 0.5), (1.5, 0.2)])
    cr = crackle(rng, n, lambda tt: 14 * np.clip((tt - 0.25) / 0.4, 0, 1), 0.25, dur, 14,
                 [(2000, 1.3), (3600, 1.6), (900, 1.2)])
    x = nz(whoosh) + 0.3 * nz(pre) + 0.4 * nz(low) + 0.3 * tnorm(cr)
    return x * np.clip((dur - t) / 0.4, 0, 1)


@sfx("ember_blow")
def ember_blow(rng, v):
    """Gentle breath on an ember; the ember answers with a faint glow-rush."""
    dur = 1.3
    n = N(dur)
    fl = curve(rng, dur, 18, slope=0.3)
    envf = env_fn([(0, 0), (0.15, 0.85), (0.35, 1.0), (0.75, 0.9), (1.05, 0.0)])
    breath = formant_noise(rng, n, lambda tt: envf(tt) * (1 + 0.12 * fl(tt)),
                           [(lambda tt: 1150 + 0 * tt, 1.0, 1.0),
                            (lambda tt: 2600 + 0 * tt, 1.5, 0.55),
                            (lambda tt: 600 + 0 * tt, 1.5, 0.35)], win=1024, lpf=6000)
    glow = lp(colored(rng, n, 2.0), 250) * pw(n, [(0, 0), (0.3, 0.2), (0.8, 0.5), (1.2, 0.1),
                                                   (1.3, 0)])
    cr = crackle(rng, n, 6.0, 0.35, 1.2, 6, [(2400, 1.5)])
    return nz(breath) + 0.1 * nz(glow) + 0.1 * tnorm(cr)


@sfx("fire_out")
def fire_out(rng, v):
    """Fire doused: steam hiss with sputters, a smoky puff, fading out."""
    dur = 2.1
    n = N(dur)
    t = tv(n)
    env = ar(n, 0.02, 0.6) * np.clip((dur - t) / 0.6, 0, 1)
    sp = curve(rng, dur, 22, slope=0.2)

    def g(tt, ff):
        e = np.interp(tt, t, env) * np.clip(1 + 0.5 * sp(tt) * np.exp(-tt / 0.6), 0.1, None)
        return e * (m_hp(ff, 1800, 2) * m_lp(ff, 9000, 2)
                    + 0.35 * m_lp(ff, 500, 2) * np.exp(-tt / 0.25))
    hiss = shaped_noise(rng, n, g, win=1024)
    pops = crackle(rng, n, lambda tt: 50 * np.exp(-tt / 0.35), 0, 1.2, 50, [(2600, 1.5), (4800, 2)])
    puff = lp(white(rng, n) * ar(n, 0.01, 0.12), 400)
    return nz(hiss) + 0.3 * nz(pops) + 0.35 * nz(puff)


# =============================================================================
# Rope
# =============================================================================
@sfx("rope_twist", 3)
def rope_twist(rng, v):
    """Plant fibres twisting: dry irregular creak + fibrous crackle."""
    dur = [0.6, 0.7, 0.5][v]
    n = N(dur)
    t = tv(n)
    rp = [[(0, 60), (dur, 140)], [(0, 180), (dur * 0.5, 110), (dur, 160)], [(0, 90), (dur, 220)]][v]
    rate = env_fn(rp)(t) * (1 + 0.15 * curve(rng, dur, 12)(t))
    env = np.clip(np.sin(np.pi * np.clip(t / dur, 0, 1)) ** 1.2
                  * (1 + 0.35 * curve(rng, dur, 15)(t)), 0, None)
    pul = stick_slip(rng, n, rate, env, jitter=0.15, skip=0.1, lpf=4000)
    fc = [1500, 1900, 1250][v]
    creak = resonate(pul, [(fc, 8, 1.0), (fc * 1.9, 8, 0.5), (fc * 0.45, 6, 0.4)])
    fib = granular(rng, n, env, 600, [(3500, 1.2), (6000, 1.5)])
    rus = bp(white(rng, n), 4000, 0.8) * env
    return nz(creak) + 0.35 * nz(fib) + 0.12 * nz(rus)


@sfx("bow_drill", 3)
def bow_drill(rng, v):
    """One push or pull of a bow drill: a soft wooden rub that swells and fades
    with the bow's speed - short, low and dry, so it can repeat for a few
    seconds without grating."""
    dur = rng.uniform(0.32, 0.4)
    n = N(dur)
    t = tv(n)
    speed = np.sin(np.pi * t / dur) ** 1.2
    pul = stick_slip(rng, n, 55 + 90 * speed, speed ** 1.4, jitter=0.15, skip=0.08, lpf=2600)
    rub = resonate(pul, [(310, 3, 0.9), (640, 4, 0.7), (1250, 3, 0.25)])

    def g(tt, ff):
        vv = np.interp(tt, t, speed)
        return vv ** 2.0 * m_bp(ff, 500 + 500 * vv, 0.8) * m_lp(ff, 2500, 2)
    hush = shaped_noise(rng, n, g, win=512)
    x = rmsn(rub) + 0.35 * rmsn(hush)
    x = lp(x, 3000)
    x *= np.minimum(1.0, t / 0.03) * np.minimum(1.0, (dur - t) / 0.06)
    return nz(x) * 0.55


@sfx("rope_tighten")
def rope_tighten(rng, v):
    """Rope hauled taut: a sliding zip, a rising creak, a taut thrum."""
    dur = 0.8
    n = N(dur)
    t = tv(n)
    zenv = np.interp(t, [0, 0.03, 0.14, 0.2], [0, 1, 0.8, 0])
    zz = formant_noise(rng, n, lambda tt: np.interp(tt, t, zenv),
                       [(lambda tt: 1200 + 2500 * np.clip(tt / 0.18, 0, 1), 1.5, 1.0)],
                       win=512, lpf=7000)
    rate = np.interp(t, [0.1, 0.45], [70, 260])
    cenv = np.interp(t, [0.1, 0.16, 0.4, 0.47], [0, 1, 0.9, 0])
    creak = resonate(stick_slip(rng, n, rate, cenv, jitter=0.06, skip=0.03, lpf=3000),
                     [(950, 8, 1.0), (1900, 9, 0.5), (420, 6, 0.5)])
    x = 0.5 * nz(zz) + 0.7 * nz(creak)
    m = N(0.3)
    tt = tv(m)
    tw = modes(m, [128, 256, 385], [0.07, 0.045, 0.03], [1, 0.45, 0.25]) * (1 - np.exp(-tt / 0.002))
    th = thud(rng, m, 170, tau=0.02, noise_lp=800, noise_tau=0.008)
    place(x, 0.6 * nz(tw) + 0.5 * nz(th), 0.46)
    return x


# =============================================================================
# Food
# =============================================================================
@sfx("eat", 3)
def eat(rng, v):
    """Soft eating: v1 crunchy bite + chew, v2 juicy soft bites, v3 grainy chew."""
    n = N(0.8)
    x = np.zeros(n)

    def crunch(g, dens, dur, lpf):
        m = N(dur + 0.12)
        tt = tv(m)
        d = np.exp(-tt / (dur * 0.5)) * (1 - np.exp(-tt / 0.003))
        cr = crackle(rng, m, lambda s: dens * np.interp(s, tt, d), 0, dur, dens,
                     [(1400, 1.0), (2600, 1.2), (4200, 1.4)])
        jaw = thud(rng, m, 160, tau=0.015, noise_lp=600, noise_tau=0.01)
        return g * lp(nz(cr) + 0.5 * nz(jaw), lpf)

    def chew(g, f1):
        m = N(0.18)
        sq = formant_noise(rng, m, lambda s: np.sin(np.pi * np.clip(s / 0.16, 0, 1)) ** 2,
                           [(lambda s: f1 + 0 * s, 3, 1.0), (lambda s: 2.6 * f1 + 0 * s, 3, 0.35)],
                           win=512, lpf=3000)
        return g * nz(sq)
    if v == 0:
        place(x, crunch(1.0, 1800, 0.09, 6500), 0.0)
        place(x, crunch(0.5, 900, 0.06, 5000), 0.25)
        place(x, chew(0.35, 600), 0.45)
    elif v == 1:
        place(x, chew(0.9, 520), 0.0)
        place(x, bubbles(rng, N(0.1), rng.uniform(0.0, 0.05, 3), 700, 1500, amp=0.25), 0.03)
        place(x, chew(0.6, 600), 0.22)
        place(x, chew(0.45, 560), 0.42)
    else:
        place(x, crunch(0.9, 1200, 0.06, 5500), 0.0)
        place(x, crunch(0.6, 1000, 0.05, 5000), 0.2)
        place(x, crunch(0.45, 800, 0.05, 4500), 0.38)
    return x


@sfx("berry_pick")
def berry_pick(rng, v):
    """Leaves part, a tiny stem snap and a soft pop as the berry comes free."""
    n = N(0.35)
    t = tv(n)
    x = 0.25 * nz(leaf_rustle(rng, n, np.interp(t, [0, 0.03, 0.12, 0.25], [0, 1, 0.3, 0]), 1200))
    m = N(0.05)
    place(x, nz(resonate(click(rng, m, 0.0003, 2000), [(3200, 3, 1.0), (5200, 3, 0.6)])), 0.05, 0.6)
    m = N(0.12)
    tt = tv(m)
    place(x, nz(chirp(m, 300 * (1 + 0.5 * np.exp(-tt / 0.008)), ar(m, 0.002, 0.018))), 0.055, 0.8)
    return x


# =============================================================================
# Items / UI
# =============================================================================
@sfx("discovery")
def discovery(rng, v):
    """Warm, gentle rising pentatonic chime (E5 G5 A5 -> C6 over a soft C5)."""
    n = N(4.0)
    x = np.zeros(n)
    for t0, f, a, d in [(0.00, 659.26, 0.70, 0.7), (0.14, 783.99, 0.72, 0.7),
                        (0.28, 880.00, 0.78, 0.8), (0.46, 1046.50, 1.0, 1.1)]:
        place(x, bell_note(f, 3.5, decay=d, bright=0.9), t0, a)
        place(x, 0.05 * click(rng, N(0.02), 0.0004, 3000, 9000), t0)
    place(x, bell_note(523.25, 3.5, decay=1.0, bright=0.6), 0.46, 0.3)
    return tail_fade(reverb(rng, x, t60=1.4, mix=0.25, lpf=6000), 2.5, 3.4)


@sfx("hint")
def hint(rng, v):
    """A single soft chime."""
    n = N(2.0)
    x = np.zeros(n)
    place(x, bell_note(783.99, 2.0, decay=0.4, bright=0.8), 0.0)
    place(x, 0.04 * click(rng, N(0.02), 0.0004, 3000, 9000), 0.0)
    return tail_fade(reverb(rng, x, t60=0.7, mix=0.18, lpf=6000), 0.9, 1.4)


@sfx("build_complete")
def build_complete(rng, v):
    """Satisfying wooden thunk, then a soft two-note chime (G5 + C6)."""
    n = N(4.0)
    x = np.zeros(n)
    place(x, wood_knock(rng, 165, 0.5, 0.8, 0.06), 0.0)
    place(x, wood_knock(rng, 200, 0.3, 0.6, 0.04), 0.012, 0.25)
    chime = (bell_note(783.99, 3.0, decay=0.6, bright=0.8, amp=0.32)
             + bell_note(1046.5, 3.0, decay=0.7, bright=0.7, amp=0.3))
    place(x, chime, 0.09)
    return tail_fade(reverb(rng, x, t60=1.0, mix=0.15, lpf=5000), 1.6, 2.3)


# =============================================================================
# Structure
# =============================================================================
@sfx("creak_warn", 3)
def creak_warn(rng, v):
    """Structural strain creak: beams and lashings groaning under load."""
    if v == 0:
        args = (0.95, [(0, 70), (0.5, 120), (0.95, 150)],
                [(0, 0), (0.15, 0.8), (0.6, 1.0), (0.95, 0)])
    elif v == 1:
        args = (1.25, [(0, 170), (0.4, 120), (0.8, 140), (1.25, 85)],
                [(0, 0), (0.1, 0.9), (0.5, 0.6), (0.85, 1.0), (1.25, 0)])
    else:
        args = (1.05, [(0, 95), (0.35, 110), (0.45, 100), (1.05, 125)],
                [(0, 0), (0.06, 1.0), (0.32, 0.7), (0.38, 0.0), (0.5, 0.0), (0.58, 0.9),
                 (0.9, 0.8), (1.05, 0)])
    x = creak_core(rng, *args, res=[(320, 8, 0.7), (710, 12, 1.0), (1440, 12, 0.7), (2600, 8, 0.3)],
                   jitter=0.06, skip=0.03, rate_var=0.08, fric_fc=1500)
    return reverb(rng, x, t60=0.4, mix=0.08, lpf=4000)


@sfx("collapse")
def collapse(rng, v):
    """Wooden structure giving way: strain, cracks, tumbling timbers, a heavy
    landing, rattling debris and dust."""
    dur = 3.8
    n = N(dur)
    t = tv(n)
    x = np.zeros(n)
    rate = np.interp(t, [0, 0.35], [80, 190])
    cenv = np.interp(t, [0, 0.05, 0.3, 0.38], [0, 0.7, 1.0, 0])
    creak = resonate(stick_slip(rng, n, rate, cenv, 0.06, 0.03, lpf=2500),
                     [(330, 8, 0.7), (720, 12, 1.0), (1450, 12, 0.6)])
    x += 0.35 * nz(creak)
    for t0, g in [(0.33, 1.0), (0.48, 0.7), (0.62, 0.5)]:
        m = N(0.3)
        crk = nz(hp(white(rng, m) * expdec(m, 0.0012), 600)) + 0.6 * nz(
            modes(m, rng.uniform(600, 2400, 3), [0.02, 0.014, 0.01], [1, .7, .5]))
        place(x, nz(crk), t0, g)
    kt = poisson(rng, lambda tt: 11 * np.exp(-((tt - 1.25) / 0.55) ** 2)
                 + 2 * np.exp(-((tt - 2.2) / 0.5) ** 2), 0.6, 3.2, 12)
    for t0 in kt:
        f0 = np.exp(rng.uniform(np.log(130), np.log(480)))
        place(x, wood_knock(rng, f0, 0.35, rng.uniform(0.5, 1.0), rng.uniform(0.03, 0.07)), t0,
              rng.uniform(0.25, 0.8) * (1.0 if t0 < 2.0 else 0.6))
    m = N(1.8)
    tt = tv(m)
    boom = chirp(m, 40 + 35 * np.exp(-tt / 0.05), np.exp(-tt / 0.25))
    body = lp(white(rng, m) * expdec(m, 0.09), 300)
    place(x, sat(nz(boom) + 0.7 * nz(body), 1.5), 1.15, 1.1)
    rat = crackle(rng, n, lambda s: 300 * np.exp(-((s - 1.4) / 0.6) ** 2), 0.6, 3.3, 300,
                  [(900, 1.2), (1800, 1.5), (3200, 1.5)])
    x += 0.25 * nz(rat)
    x += 0.08 * nz(bp(white(rng, n), 1500, 0.6) * np.interp(t, [0.5, 1.2, 2.5, 3.5], [0, 1, 0.3, 0]))
    return x


# =============================================================================
# Player
# =============================================================================
@sfx("hurt")
def hurt(rng, v):
    """Soft body thud with a breathy, whispered 'huh' (no voice, no gore)."""
    n = N(0.6)
    x = np.zeros(n)
    m = N(0.3)
    th = thud(rng, m, 95, tau=0.035, drop=0.4, noise_lp=500, noise_tau=0.02)
    cloth = bp(white(rng, m), 2200, 0.8) * ar(m, 0.002, 0.03)
    place(x, nz(th) + 0.15 * nz(cloth), 0.0)
    breath = formant_noise(rng, n, env_fn([(0, 0), (0.03, 0), (0.05, 1.0), (0.12, 0.7), (0.38, 0)]),
                           [(lambda tt: 650 + 0 * tt, 5, 1.0), (lambda tt: 1150 + 0 * tt, 7, 0.6),
                            (lambda tt: 2500 + 0 * tt, 8, 0.3)], win=1024, lpf=4500)
    return x + 0.55 * nz(breath)


@sfx("fall_whoosh")
def fall_whoosh(rng, v):
    """~3 s of rushing air while falling: builds, buffets, whistles higher."""
    dur = 3.1
    n = N(dur)
    flut = curve(rng, dur, 12, slope=0.3)
    gust = curve(rng, dur, 2.0)

    def g(tt, ff):
        u = np.clip(tt / 2.7, 0, 1)
        a = (0.12 + 0.88 * u ** 1.6) * (1 + 0.25 * u * flut(tt)) * (1 + 0.1 * gust(tt))
        a = a * np.clip((dur - tt) / 0.35, 0, 1) * np.clip(tt / 0.25, 0, 1)
        body = m_bp(ff, 280 + 650 * u, 0.6)
        whistle = 0.35 * u * m_bp(ff, 600 + 600 * u, 10)
        air = 0.3 * m_hp(ff, 2000, 1) * m_lp(ff, 3000 + 5000 * u, 2)
        rumble = 0.6 * m_lp(ff, 110, 2) * m_hp(ff, 30, 2)
        return np.maximum(a, 0) * (body + whistle + air + rumble)
    return shaped_noise(rng, n, g, win=2048)


@sfx("heartbeat")
def heartbeat(rng, v):
    """Low double thump ('lub-dub').  Gently saturated so it still reads on
    small speakers."""
    n = N(0.85)
    x = np.zeros(n)

    def beat(f0, tau, amp):
        m = N(0.35)
        tt = tv(m)
        s = chirp(m, f0 * (1 + 0.6 * np.exp(-tt / 0.02)), ar(m, 0.008, tau))
        nb = lp(white(rng, m) * ar(m, 0.004, tau * 0.6), 180)
        return amp * sat(nz(s) + 0.3 * nz(nb), 1.8)
    place(x, beat(52, 0.06, 1.0), 0.0)
    place(x, beat(60, 0.045, 0.75), 0.28)
    return lp(x, 900)


# =============================================================================
# Ambience loops.  Each generator gets (rng, n, f) and returns n + f samples:
# every slow control curve is periodic in n, so the extra f samples continue
# the head's motion and can be crossfaded into it (see make_loop).
# =============================================================================
def soft_limit(x, thr, head):
    """Soft knee above thr: outliers approach thr + head instead of growing."""
    a = np.abs(x)
    over = np.maximum(a - thr, 0)
    return np.sign(x) * np.where(a > thr, thr + over / (1 + over / head), a)


def wind_bed(rng, n, f, strong):
    total = n + f
    T = n / SR
    gust = curve(rng, T, 0.45 if strong else 0.3, slope=0.9)
    sub = curve(rng, T, 2.5, slope=0.5)
    flut = curve(rng, T, 9.0, slope=0.2)
    drift = curve(rng, T, 0.25)
    chans = []
    for ch, off in enumerate((0.0, 0.45)):
        def g(tt, ff, ch=ch, off=off):
            s = 0.75 * gust(tt - off) + 0.3 * sub(tt - 0.5 * off)
            s = squash(s, 0.2, 1.0) if strong else squash(s, 0.15, 0.8)
            amp = (0.25 + s) ** (1.6 if strong else 1.3)
            if strong:
                amp = amp * np.clip(1 + 0.25 * s ** 2 * flut(tt + 3.1 * ch), 0.2, None)
            body = (m_bp(ff, 280 + (550 if strong else 400) * s, 0.7)
                    * m_lp(ff, 900 + (2000 if strong else 1500) * s, 2))
            air = (0.18 if strong else 0.10) * m_hp(ff, 1500, 1) * m_lp(ff, 1800 + 3500 * s, 2)
            fw = (560 if ch == 0 else 610) + 420 * s + 40 * drift(tt)
            if strong:
                whistle = 1.8 * s ** 2 * m_bp(ff, fw, 16) + 1.0 * s ** 2.5 * m_bp(ff, 1.62 * fw, 22)
                low = 1.6 * (0.4 + s) * m_lp(ff, 120, 2) * m_hp(ff, 28, 2)
            else:
                whistle = 0.9 * s ** 2 * m_bp(ff, fw, 16)
                low = 0.3 * m_lp(ff, 150, 2)
            return amp * (body + air + whistle + low) * m_hp(ff, 45, 2) * m_lp(ff, 9000, 2)
        chans.append(shaped_noise(rng, total, g, win=4096))
    left, right = chans
    return np.stack([left + 0.18 * right, right + 0.18 * left], axis=1)  # L/R corr ~0.35


@amb("wind_soft", 24.0, 3.0, stereo=True)
def wind_soft(rng, n, f):
    """Airy high-altitude breeze: broad soft rush, slow gusts, faint howl."""
    return wind_bed(rng, n, f, strong=False)


@amb("wind_strong", 20.0, 3.0, stereo=True)
def wind_strong(rng, n, f):
    """Stronger gusting with buffeting, a low rumble and a hollow whistle."""
    return wind_bed(rng, n, f, strong=True)


@amb("rain_light", 16.0, 1.5, stereo=True)
def rain_light(rng, n, f):
    """Soft steady rain: dense fine patter, some heavier drops on leaves, a
    low wash, and sparse distinct droplet 'plips'."""
    total = n + f
    T = n / SR
    tt = tv(total)
    inten = curve(rng, T, 0.12)
    chans = []
    for ch in range(2):
        mod = 1 + 0.12 * inten(tt + 0.9 * ch)
        tp = poisson(rng, 1600, 0, total / SR, 1600)
        imp = impulses(total, tp, np.minimum(rng.lognormal(0, 0.5, len(tp)), 4.0)
                       * rng.choice([-1, 1], len(tp)))
        patter = filt(imp, [biquad("bp", 3200, 0.55), biquad("lp", 8500, 0.7)])
        tm = poisson(rng, 22, 0, total / SR, 22)
        imp2 = impulses(total, tm, np.minimum(rng.lognormal(0, 0.5, len(tm)), 3.0)
                        * rng.choice([-1, 1], len(tm)))
        med = resonate(imp2, [(1400, 2.0, 0.8), (2600, 2.5, 0.6), (650, 1.5, 0.4)])
        wash = lp(hp(colored(rng, total, 1.0), 150), 1100)
        bed = (rmsn(patter) + 0.6 * rmsn(wash)) * mod + 1.2 * tnorm(med)
        plips = np.zeros(total)
        for t0 in poisson(rng, 2.2, 0, total / SR, 2.2):
            g = 0.6 * click(rng, N(0.01), 0.0003, 2000, 8000)
            b = nz(bubble(rng.uniform(1700, 3800), rng.uniform(0.08, 0.25)))
            place(plips, nz(mix(g, b)), t0, rng.uniform(0.4, 1.0))
        chans.append(soft_limit(bed + 2.8 * plips, 14.0, 4.0))
    return np.stack(chans, axis=1)


@amb("crickets_night", 20.0, 1.5, stereo=True)
def crickets_night(rng, n, f):
    """A few crickets at different spots, chirping in bouts with pauses, over
    a barely-there night air bed.  Sparse and quiet."""
    total = n + f
    T = n / SR
    out = np.zeros((total, 2))
    # the nearest cricket keeps going most of the time (thr low); the others
    # come and go in bouts, so it is never silent but rarely busy
    bugs = [dict(fc=4650, pan=-0.55, rate=2.2, pulses=(3, 5), lvl=1.0, far=0.0, thr=-1.1),
            dict(fc=4300, pan=0.6, rate=1.7, pulses=(2, 4), lvl=0.7, far=0.25, thr=0.1),
            dict(fc=5050, pan=0.15, rate=2.6, pulses=(3, 4), lvl=0.4, far=0.6, thr=0.2),
            dict(fc=3950, pan=-0.25, rate=1.4, pulses=(4, 6), lvl=0.3, far=0.8, thr=0.0)]
    for b in bugs:
        act = curve(rng, T, 0.15)
        thr = b["thr"]
        mono = np.zeros(total)
        t0 = rng.uniform(0, 1.0 / b["rate"])
        while t0 < total / SR:
            if act(t0) > thr:
                k = int(rng.integers(b["pulses"][0], b["pulses"][1] + 1))
                fc = b["fc"] * rng.uniform(0.985, 1.015)
                for p in range(k):
                    m = N(0.016)
                    tt = tv(m)
                    e = np.sin(np.pi * tt / tt[-1]) ** 2
                    ph = 2 * np.pi * fc * (tt - 0.01 * tt ** 2 / tt[-1])
                    place(mono, (np.sin(ph) + 0.12 * np.sin(2 * ph)) * e, t0 + p * 0.034,
                          1.0 - 0.15 * p / k)
            t0 += rng.uniform(0.85, 1.2) / b["rate"]
        if b["far"] > 0:
            mono = lp(mono, 9000 - 4000 * b["far"])
            mono = reverb(rng, mono, t60=0.6, mix=0.3 * b["far"], lpf=5000)[:total]
        out += pan(mono * b["lvl"], b["pan"])
    bed = np.stack([lp(hp(colored(rng, total, 1.0), 60), 700) for _ in range(2)], axis=1)
    return out + 0.012 * bed


@amb("pond_lap", 18.0, 1.5)
def pond_lap(rng, n, f):
    """Very gentle wavelets lapping at the edge with the odd hollow 'blup'
    and a few small bubbles rising."""
    total = n + f
    T = total / SR
    x = np.zeros(total)
    t0 = rng.uniform(0.2, 0.8)
    while t0 < T:
        dur = rng.uniform(0.5, 0.8)
        att = rng.uniform(0.05, 0.11)
        f1 = rng.uniform(450, 700)
        m = N(dur)
        sl = formant_noise(
            rng, m, lambda tt, att=att, dur=dur: np.interp(tt, [0, att, dur], [0, 1, 0]) ** 1.5,
            [(lambda tt, f1=f1: f1 * (1 + 0.4 * np.exp(-tt / 0.1)), 1.0, 1.0),
             (lambda tt: 1700 + 0 * tt, 1.2, 0.35)], win=1024, lpf=2600)
        lap = nz(sl)
        if rng.random() < 0.7:
            place(lap, bubble(rng.uniform(170, 320), rng.uniform(0.06, 0.18)), att * 0.8,
                  rng.uniform(0.3, 0.6))
        lap += bubbles(rng, m, att + rng.exponential(0.08, int(rng.integers(1, 4))), 350, 1100,
                       amp=0.35)
        place(x, lap, t0, rng.uniform(0.45, 1.0))
        t0 += rng.uniform(1.2, 2.6)
    x += bubbles(rng, total, poisson(rng, 0.9, 0, T, 0.9), 600, 2200, amp=0.22)
    bed = bp(white(rng, total), 600, 0.5) * (1 + 0.4 * curve(rng, n / SR, 0.3)(tv(total)))
    return x + 0.025 * rmsn(bed)


def fire_bed(rng, n, f, large):
    total = n + f
    T = n / SR
    t = tv(total)
    fl1 = curve(rng, T, 2.5 if large else 1.8, slope=0.5)
    fl2 = curve(rng, T, 0.4)

    def g(tt, ff):
        a = squash(0.6 * fl1(tt) + 0.5 * fl2(tt), 0.35, 1.0)
        roar = m_lp(ff, 900 if large else 520, 2) * m_hp(ff, 35, 2)
        lick = (0.35 if large else 0.2) * a * m_bp(ff, 1100 + 400 * a, 0.7)
        return a * roar + lick
    bed = rmsn(shaped_noise(rng, total, g, win=2048))
    if large:
        bed = bed + 0.6 * rmsn(lp(colored(rng, total, 2.0), 110)) * (0.8 + 0.2 * squash(fl2(t), 0, 1))
    rate = 26.0 if large else 10.0
    ct = poisson(rng, lambda s: rate * squash(fl1(s), 0.5, 1.2), 0, total / SR, rate * 1.2)
    times, amps = [], []
    for c in ct:
        base = rng.lognormal(0, 0.8)
        for j in range(1 + rng.poisson(1.5)):
            times.append(c + rng.uniform(0, 0.012))
            amps.append(base * rng.uniform(0.3, 1.0) * rng.choice([-1, 1]))
    imp = impulses(total, np.array(times), np.array(amps))
    crack = lp(resonate(imp, [(1900, 1.3, 1.0), (3600, 1.6, 0.8), (6200, 1.8, 0.5),
                              (900, 1.2, 0.3)]), 10000)
    prate = 0.6 if large else 0.25
    pops = np.zeros(total)
    for p in poisson(rng, prate, 0, total / SR, prate):
        m = N(0.12)
        pop = (0.8 * click(rng, m, 0.0004, 600, 7000)
               + 0.6 * nz(modes(m, [rng.uniform(140, 320)], [0.012], [1]))
               + 0.2 * nz(hp(white(rng, m), 3500) * ar(m, 0.01, 0.04)))
        place(pops, nz(pop), p, rng.uniform(0.5, 1.0))
    hiss = np.zeros(total)
    for h in poisson(rng, 0.07, 0, total / SR, 0.07):
        d = rng.uniform(0.3, 0.9)
        m = N(d)
        place(hiss, bp(white(rng, m), rng.uniform(3800, 6000), 2.0) * np.sin(np.pi * tv(m) / d) ** 2,
              h, rng.uniform(0.5, 1.0))
    x = (bed + (2.6 if large else 2.4) * tnorm(crack) + (7.0 if large else 6.0) * nz(pops)
         + 1.2 * nz(hiss))
    return soft_limit(x, 10.0, 4.0)


@amb("fire_small", 16.0, 1.5)
def fire_small(rng, n, f):
    """Campfire: soft low roar breathing with the flames + cosy crackles."""
    return fire_bed(rng, n, f, large=False)


@amb("fire_large", 16.0, 1.5)
def fire_large(rng, n, f):
    """Big fire: fuller roar and rumble, flame licks, denser crackles/pops."""
    return fire_bed(rng, n, f, large=True)


@amb("mound_smolder", 18.0, 1.5)
def mound_smolder(rng, n, f):
    """Sealed charcoal mound: muffled low rumble, rare soft crackles, the odd
    slow hiss of escaping steam/smoke."""
    total = n + f
    T = n / SR
    t = tv(total)
    rumble = rmsn(lp(colored(rng, total, 2.0), 160)) * (1 + 0.35 * curve(rng, T, 0.15)(t))
    roar = rmsn(lp(colored(rng, total, 1.0), 420)) * (1 + 0.3 * curve(rng, T, 1.2)(t))
    ct = poisson(rng, 1.6, 0, total / SR, 1.6)
    imp = impulses(total, ct, rng.lognormal(0, 0.7, len(ct)) * rng.choice([-1, 1], len(ct)))
    crack = al.lp4(resonate(imp, [(900, 1.2, 1.0), (1700, 1.5, 0.6)]), 1500)
    hiss = np.zeros(total)
    for h in poisson(rng, 0.18, 0, total / SR, 0.18):
        d = rng.uniform(0.6, 1.6)
        m = N(d)
        place(hiss, bp(white(rng, m), rng.uniform(2500, 4500), 1.2) * np.sin(np.pi * tv(m) / d) ** 2,
              h, rng.uniform(0.4, 1.0))
    return soft_limit(rumble + 0.45 * roar + 2.5 * tnorm(crack) + 0.6 * nz(hiss), 8.0, 3.0)


@amb("drill_spin", 12.0, 0.8)
def drill_spin(rng, n, f):
    """Wooden fire drill: 30 alternating strokes per loop.  Each stroke's
    speed (zero at the reversals) drives a stick-slip rasp through the
    spindle/hearth resonances plus a brightening friction hiss."""
    total = n + f
    T = n / SR
    K = 30
    per = T / K
    jit = rng.normal(0, 0.012, K)
    ks = np.arange(-1, int(np.ceil(total / SR / per)) + 3)
    bnd = ks * per + jit[ks % K]          # periodic: bnd[k + K] = bnd[k] + T
    t = tv(total)
    ki = np.searchsorted(bnd, t, side="right") - 1
    u = (t - bnd[ki]) / (bnd[ki + 1] - bnd[ki])
    v = np.sin(np.pi * np.clip(u, 0, 1)) ** 0.8
    stroke_gain = rng.uniform(0.8, 1.0, K)     # hand pressure varies stroke to stroke
    alt = np.where(ks[ki] % 2 == 0, 1.0, 0.86) * stroke_gain[ks[ki] % K]
    pul = stick_slip(rng, total, 45 + 170 * v, v ** 1.3 * alt, jitter=0.12, skip=0.05)
    rasp = resonate(pul, [(520, 3, 0.8), (1150, 4, 1.0), (2300, 3, 0.6), (3900, 2, 0.3)])

    def g(tt, ff):
        vv = np.interp(tt, t, v)
        return vv ** 1.5 * m_bp(ff, 700 + 1600 * vv, 0.7) * m_lp(ff, 6000, 2)
    fric = shaped_noise(rng, total, g, win=512)
    low = lp(white(rng, total), 220) * v ** 1.2
    return rmsn(rasp) + 0.6 * rmsn(fric) + 0.3 * rmsn(low)


@amb("water_pour", 12.0, 1.0)
def water_pour(rng, n, f):
    """Bubbly pouring stream: splashy band noise + many small bubbles + the
    occasional deeper gurgle."""
    total = n + f
    T = n / SR
    slow = curve(rng, T, 0.8)
    flut = curve(rng, T, 14, slope=0.2)

    def g(tt, ff):
        a = (1 + 0.18 * slow(tt)) * (1 + 0.12 * flut(tt))
        return a * (m_bp(ff, 1250, 0.6) + 0.45 * m_bp(ff, 3200, 0.9)
                    + 0.25 * m_lp(ff, 300, 2)) * m_lp(ff, 9000, 2)
    stream = shaped_noise(rng, total, g, win=1024)
    bub = bubbles(rng, total, poisson(rng, 95, 0, total / SR, 95), 420, 2600, xi=(0.05, 0.22))
    gur = bubbles(rng, total, poisson(rng, 6, 0, total / SR, 6), 140, 380, xi=(0.08, 0.25))
    spl = granular(rng, total, np.ones(total), 900, [(4500, 1.2), (7000, 1.5)])
    return rmsn(stream) + 0.9 * rmsn(bub) + 0.5 * rmsn(gur) + 0.25 * rmsn(spl)


# =============================================================================
# Driver
# =============================================================================
def make_loop(fn, rng, seconds, xfade, stereo):
    """Render n + f samples, then equal-power crossfade the tail [n, n+f)
    into the head [0, f).  out[n-1] -> out[0] is then y[n-1] -> y[n], i.e.
    a sample step the generator produced itself."""
    n, f = N(seconds), N(xfade)
    y = np.asarray(fn(rng, n, f), float)[: n + f]
    if stereo and y.ndim == 1:
        y = np.stack([y, y], axis=1)
    y = al.dc_block(y)
    th = np.linspace(0.0, np.pi / 2, f)
    wi, wo = np.sin(th), np.cos(th)
    if y.ndim == 2:
        wi, wo = wi[:, None], wo[:, None]
    out = y[:n].copy()
    out[:f] = y[:f] * wi + y[n:n + f] * wo
    return out - out.mean(axis=0)


def render_loop(name, fn, arg):
    rng = al.rng_for(name)
    y = make_loop(fn, rng, arg["seconds"], arg["xfade"], arg["stereo"])
    return al.normalise_loop(y, al.AMB_TARGET[name])


def render_stem(entries):
    """Render all variants of one stem, then loudness-normalise them jointly."""
    xs = []
    for name, _, fn, v in entries:
        x = np.asarray(fn(al.rng_for(name), v), float)
        x = np.concatenate([np.zeros(N(0.004)), x, np.zeros(N(0.02))])
        xs.append(al.prepare_sfx(x, name))
    ys, _, lim = al.normalise_set(xs, [e[0] for e in entries])
    return ys, lim


def main(argv=None):
    ap = argparse.ArgumentParser(description="Regenerate Skyroot's synthesized audio.")
    ap.add_argument("only", nargs="*", help="only names starting with these prefixes")
    ap.add_argument("--list", action="store_true", help="list the sounds this script makes")
    ap.add_argument("--out", default=al.AUDIO_DIR, help="output root (default assets/audio)")
    a = ap.parse_args(argv)
    known = set(al.SFX_NAMES) | set(al.AMB_NAMES)
    for name, _, _, _ in REGISTRY:
        assert name in known, f"{name} is not in the audio manifest"
    if a.list:
        for name, kind, _, _ in REGISTRY:
            print(f"{kind}  {name}")
        return 0
    rows = {"sfx": [], "amb": []}
    stems = {}
    for entry in REGISTRY:
        key = al.stem_of(entry[0]) if entry[1] == "sfx" else entry[0]
        stems.setdefault(key, []).append(entry)
    for key, entries in stems.items():
        if a.only and not any(e[0].startswith(p) for e in entries for p in a.only):
            continue
        kind = entries[0][1]
        if kind == "sfx":
            ys, lim = render_stem(entries)
            outs = [(e[0], y, f"limited {l:.1f} dB" if l > 0.05 else "")
                    for e, y, l in zip(entries, ys, lim)]
        else:
            name, _, fn, arg = entries[0]
            outs = [(name, render_loop(name, fn, arg), "")]
        for name, y, note in outs:
            if not np.all(np.isfinite(y)):
                raise SystemExit(f"{name}: produced non-finite samples")
            path = os.path.join(a.out, "sfx" if kind == "sfx" else "amb", name + ".wav")
            al.write_wav(path, y, loop=(kind == "amb"), seed=al.seed_for(name))
            al.remove_alternates(path)
            row = al.stats_row(name, y, loop=(kind == "amb"))
            row["src"] = note
            rows[kind].append(row)
    if rows["sfx"]:
        al.print_table(rows["sfx"], "synthesized SFX (peak/rms dBFS, loud = K-weighted max 200 ms)")
    if rows["amb"]:
        al.print_table(rows["amb"], "synthesized loops (loud = integrated K-weighted)")
    n = len(rows["sfx"]) + len(rows["amb"])
    print(f"\nwrote {n} files under {os.path.relpath(a.out, al.REPO)}/")
    return 0


if __name__ == "__main__":
    sys.exit(main())
