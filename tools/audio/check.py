#!/usr/bin/env python3
"""QC for assets/audio (run after synth.py / curate.py).

    python3 tools/audio/check.py [--root assets/audio]

Checks, for every name in the manifest (audiolib.SFX_NAMES / AMB_NAMES):
  * exactly one file sfx/<name>.(wav|ogg) or amb/<name>.(wav|ogg); no strays
  * WAVs are 16-bit PCM 44.1 kHz; SFX mono; loops carry a 'smpl' loop chunk
    spanning the whole file
  * no NaN/Inf, decoded sample peak <= -1 dBFS, |DC| < 0.002
  * durations: SFX 0.02-4 s, loops 12-24 s
  * loops wrap seamlessly (seam step and LPC 'click' score vs. the loop's own
    neighbourhood of the seam; see audiolib.seam_report)
  * CREDITS.md lists every file, LICENSE-Kenney.txt exists, total size < 45 MB
Prints a table (name, format, duration, channels, peak dBFS, RMS dBFS,
loudness, DC, notes) and exits non-zero if anything fails.  Ogg files are
decoded with ffmpeg (skipped with a warning if ffmpeg is missing).
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import numpy as np  # noqa: E402

import audiolib as al  # noqa: E402

MAX_TOTAL_MB = 45.0


def main(argv=None):
    ap = argparse.ArgumentParser(description="QC the Skyroot audio assets.")
    ap.add_argument("--root", default=al.AUDIO_DIR)
    a = ap.parse_args(argv)
    root = a.root
    fails, warns = [], []
    have_ffmpeg = bool(al.ffmpeg())
    if not have_ffmpeg:
        warns.append("ffmpeg not found: .ogg files are only checked for presence")

    expected = [("sfx", n) for n in al.SFX_NAMES] + [("amb", n) for n in al.AMB_NAMES]
    found = {}
    for sub in ("sfx", "amb"):
        d = os.path.join(root, sub)
        for fn in sorted(os.listdir(d)) if os.path.isdir(d) else []:
            if fn.startswith(".") or fn.endswith(".import"):
                continue
            base, ext = os.path.splitext(fn)
            if ext not in (".wav", ".ogg"):
                fails.append(f"{sub}/{fn}: unexpected file type")
                continue
            found.setdefault((sub, base), []).append(fn)
    for key, files in found.items():
        if key not in expected:
            fails.append(f"{key[0]}/{files[0]}: not in the manifest")
        if len(files) > 1:
            fails.append(f"{key[0]}/{key[1]}: several files {files}")

    rows = {"sfx": [], "amb": []}
    counts = {"wav": 0, "ogg": 0}
    for sub, name in expected:
        files = found.get((sub, name))
        if not files:
            fails.append(f"{sub}/{name}: MISSING")
            continue
        path = os.path.join(root, sub, files[0])
        ext = files[0].rsplit(".", 1)[1]
        counts[ext] += 1
        if ext == "ogg" and not have_ffmpeg:
            continue
        try:
            x, sr, loop = al.load_any(path)
        except (ValueError, RuntimeError) as e:
            fails.append(f"{sub}/{name}: {e}")
            continue
        if sr != al.SR:
            fails.append(f"{sub}/{name}: sample rate {sr}")
        is_loop = sub == "amb"
        if not np.all(np.isfinite(x)):
            fails.append(f"{sub}/{name}: non-finite samples")
            continue
        r = al.stats_row(name, x, loop=is_loop)
        r["src"] = ext
        dur = r["dur"]
        if r["peak"] > al.QC_PEAK_MAX_DB:
            fails.append(f"{sub}/{name}: peak {r['peak']:.2f} dBFS > {al.QC_PEAK_MAX_DB}")
        if abs(r["dc"]) > 0.002:
            fails.append(f"{sub}/{name}: DC offset {r['dc']:+.4f}")
        if sub == "sfx":
            if r["ch"] != 1:
                fails.append(f"sfx/{name}: {r['ch']} channels (SFX must be mono)")
            if not 0.02 <= dur <= 4.0:
                fails.append(f"sfx/{name}: duration {dur:.2f} s")
        else:
            if not 12.0 <= dur <= 24.0:
                fails.append(f"amb/{name}: loop length {dur:.2f} s")
            if ext == "wav" and loop != (0, x.shape[0] - 1):
                fails.append(f"amb/{name}: missing/odd smpl loop chunk {loop}")
            if r["step_ratio"] > 1.0 or r["hf_ratio"] > 2.0:
                fails.append(f"amb/{name}: seam not clean (step {r['step_ratio']:.2f}, "
                             f"click {r['hf_ratio']:.2f})")
        rows[sub].append(r)

    al.print_table(rows["sfx"], "SFX (peak/rms dBFS; loud = K-weighted max over 200 ms)")
    al.print_table(rows["amb"], "Ambience loops (loud = integrated K-weighted)")

    credits = os.path.join(root, "CREDITS.md")
    if not os.path.isfile(credits):
        fails.append("CREDITS.md missing")
    else:
        txt = open(credits, encoding="utf-8").read()
        for (sub, name), files in found.items():
            if f"{sub}/{files[0]}" not in txt:
                fails.append(f"CREDITS.md does not mention {sub}/{files[0]}")
    if not os.path.isfile(os.path.join(root, "LICENSE-Kenney.txt")):
        fails.append("LICENSE-Kenney.txt missing")

    total = sum(os.path.getsize(os.path.join(dp, f)) for dp, _, fs in os.walk(root) for f in fs)
    if total / 1e6 > MAX_TOTAL_MB:
        fails.append(f"total size {total / 1e6:.1f} MB > {MAX_TOTAL_MB} MB")
    sfx_pk = [r["peak"] for r in rows["sfx"]]
    print(f"\n{len(rows['sfx'])} SFX + {len(rows['amb'])} loops checked "
          f"({counts['wav']} wav, {counts['ogg']} ogg); total size {total / 1e6:.1f} MB")
    if sfx_pk:
        print(f"SFX peaks: max {max(sfx_pk):.1f} dBFS, median {np.median(sfx_pk):.1f} dBFS")
    for w in warns:
        print("WARN:", w)
    for f in fails:
        print("FAIL:", f)
    print("QC PASSED" if not fails else f"QC FAILED ({len(fails)} problems)")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
