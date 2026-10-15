"""Synthesizes the animal sounds (goat bleats, junglefowl clucks and squawks,
crab clicks) into assets/audio/sfx.  Additive voices shaped by a few vowel
formants, kept short and soft.  Needs numpy.

    python3 tools/audio/gen_animal_sfx.py
"""
import os
import wave

import numpy as np

SR = 44100
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
OUT = os.path.join(ROOT, "assets", "audio", "sfx")


def formant_env(freqs, formants):
    """Spectral envelope: a sum of resonance peaks [(centre Hz, width Hz, gain)]."""
    env = np.zeros_like(freqs)
    for c, w, g in formants:
        env += g / (1.0 + ((freqs - c) / w) ** 2)
    return env


def voice(f0, amp, formants, harmonics=14, noise=0.0, seed=0):
    """f0, amp: per-sample arrays.  A buzzy voice through formant peaks."""
    n = len(f0)
    out = np.zeros(n)
    phase = np.cumsum(2.0 * np.pi * f0 / SR)
    for k in range(1, harmonics + 1):
        fk = f0 * k
        a = formant_env(fk, formants) / k ** 0.6
        a[fk > SR * 0.45] = 0.0
        out += a * np.sin(phase * k)
    if noise > 0.0:
        rng = np.random.default_rng(seed)
        nz = rng.standard_normal(n)
        # breathy noise, roughly band-passed by smoothing and differencing
        nz = np.convolve(nz, np.ones(6) / 6.0, mode="same")
        nz = np.diff(np.concatenate([[0.0], nz]))
        out += nz * noise * 4.0
    return out * amp


def adsr(n, a, r, curve=1.0):
    t = np.arange(n) / SR
    dur = n / SR
    env = np.minimum(1.0, t / max(a, 1e-4))
    env = np.minimum(env, np.clip((dur - t) / max(r, 1e-4), 0.0, 1.0))
    return env ** curve


def save(name, x, peak=0.45):
    x = x / max(1e-9, np.max(np.abs(x))) * peak
    # a few ms of fade at both ends: no clicks
    f = int(0.004 * SR)
    x[:f] *= np.linspace(0, 1, f)
    x[-f:] *= np.linspace(1, 0, f)
    data = (x * 32767).astype(np.int16)
    path = os.path.join(OUT, name + ".wav")
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(data.tobytes())
    print("wrote", path)


EH = [(620, 140, 1.0), (1850, 220, 0.55), (2650, 300, 0.25)]
AA = [(800, 160, 1.0), (1250, 200, 0.6), (2600, 300, 0.2)]
UH = [(450, 120, 1.0), (1000, 180, 0.45), (2400, 300, 0.12)]


def bleat(dur, f_start, f_mid, f_end, trill, seed, hurt=False):
    n = int(dur * SR)
    t = np.arange(n) / SR
    u = t / dur
    f0 = np.interp(u, [0.0, 0.15, 0.75, 1.0], [f_start, f_mid, f_mid * 0.97, f_end])
    f0 *= 1.0 + 0.035 * np.sin(2 * np.pi * trill * t)
    trem = 1.0 - 0.45 * (0.5 + 0.5 * np.sin(2 * np.pi * trill * t + 0.4))
    amp = adsr(n, 0.03 if hurt else 0.05, 0.16) * trem
    x = voice(f0, amp, EH if not hurt else AA, harmonics=12, noise=0.05 if not hurt else 0.12, seed=seed)
    return x


def cluck(seed, n_clucks=2, gap=0.15, base=360):
    rng = np.random.default_rng(seed)
    total = int((n_clucks * gap + 0.12) * SR)
    out = np.zeros(total)
    for i in range(n_clucks):
        d = 0.06 + rng.uniform(-0.01, 0.015)
        n = int(d * SR)
        t = np.arange(n) / SR
        f0 = np.linspace(base * rng.uniform(0.95, 1.1), base * 0.78, n)
        amp = np.exp(-t / 0.025) * np.minimum(1.0, t / 0.004)
        x = voice(f0, amp, UH, harmonics=10, noise=0.08, seed=seed + i)
        at = int((i * gap + rng.uniform(0, 0.02)) * SR)
        out[at:at + n] += x[: total - at]
    return out


def squawk(seed):
    n = int(0.32 * SR)
    t = np.arange(n) / SR
    u = t / 0.32
    f0 = np.interp(u, [0, 0.2, 1.0], [780, 920, 640])
    f0 *= 1.0 + 0.06 * np.sin(2 * np.pi * 31 * t)
    amp = adsr(n, 0.01, 0.12)
    return voice(f0, amp, AA + [(3200, 400, 0.2)], harmonics=9, noise=0.25, seed=seed)


def clicks(seed, n_clicks):
    rng = np.random.default_rng(seed)
    total = int((0.05 * n_clicks + 0.06) * SR)
    out = np.zeros(total)
    at = 0
    for i in range(n_clicks):
        n = int(0.006 * SR)
        nz = rng.standard_normal(n)
        nz = np.diff(np.concatenate([[0.0], nz]))   # bright
        x = nz * np.exp(-np.arange(n) / SR / 0.0012)
        out[at:at + n] += x * rng.uniform(0.6, 1.0)
        at += int(rng.uniform(0.03, 0.06) * SR)
    return out


def main():
    os.makedirs(OUT, exist_ok=True)
    save("goat_bleat_1", bleat(0.75, 430, 480, 400, 13.0, 1), 0.4)
    save("goat_bleat_2", bleat(0.6, 500, 540, 460, 14.5, 2), 0.4)
    save("goat_hurt", bleat(0.38, 640, 700, 520, 18.0, 3, hurt=True), 0.45)
    save("fowl_cluck_1", cluck(4, 2, 0.15, 360), 0.4)
    save("fowl_cluck_2", cluck(5, 3, 0.12, 400), 0.4)
    save("fowl_squawk", squawk(6), 0.42)
    save("crab_click_1", clicks(7, 3), 0.3)
    save("crab_click_2", clicks(8, 4), 0.3)


if __name__ == "__main__":
    main()
