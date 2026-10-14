#!/usr/bin/env python3
"""Curate Kenney CC0 sounds into Skyroot's audio set.

    python3 tools/audio/curate.py <kenney_dir>            # process + encode
    python3 tools/audio/curate.py <kenney_dir> --raw      # byte-for-byte copies

<kenney_dir> holds the extracted packs (only read, never executed):
    kenney_impact-sounds/Audio/*.ogg
    kenney_rpg-audio/Audio/*.ogg
    kenney_interface-sounds/Audio/*.ogg

Default mode (needs ffmpeg with libvorbis): each recipe decodes its source(s)
to 44.1 kHz mono, optionally layers/filters them, then gets the same finishing
as the synthesized SFX (DC block, silence trim, short fades, category loudness
normalisation with a -3 dBFS peak ceiling) and is written as mono Ogg Vorbis
(q6) to assets/audio/sfx/<name>.ogg.  The decoded result is re-checked so the
Vorbis overshoot never pushes a peak above -1 dBFS.

--raw copies the primary source file unchanged (stereo, original level, no
trim) for environments without ffmpeg.

Also (re)writes assets/audio/CREDITS.md and assets/audio/LICENSE-Kenney.txt.
"""
import argparse
import os
import shutil
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import numpy as np  # noqa: E402

import audiolib as al  # noqa: E402

PACKS = {
    "impact": ("kenney_impact-sounds", "Kenney Impact Sounds 1.0"),
    "rpg": ("kenney_rpg-audio", "Kenney RPG Audio"),
    "ui": ("kenney_interface-sounds", "Kenney Interface Sounds 1.0"),
}


def L(pack, fname, gain_db=0.0, offset_ms=0.0, speed=1.0):
    """A layer: source file, gain, time offset of its onset, varispeed."""
    return dict(pack=pack, file=fname, gain_db=gain_db, offset_ms=offset_ms, speed=speed)


def R(*layers, lp=None, hp=None, tilt_db=0.0, max_len=None, fade_out=0.025, note=""):
    """A recipe: layers, optional low/high-pass, a high-shelf tilt (dB above
    ~1.5 kHz), max length/fade for the trim, and a credits note."""
    return dict(layers=list(layers), lp=lp, hp=hp, tilt_db=tilt_db, max_len=max_len,
                fade_out=fade_out, note=note)


STEP = dict(max_len=0.40, fade_out=0.06)
RECIPES = {}
# Kenney's grass/concrete footstep variants are near-identical takes (waveform
# correlation 0.86-0.99), so each gets a deterministic varispeed (+-1 semitone)
# and a gentle tilt to make the five audibly different.
GRASS_VAR = [(1.00, 0.0), (0.95, 1.5), (1.05, -1.5), (0.92, -1.0), (1.07, 1.0)]
STONE_VAR = [(1.00, 0.0), (0.94, 1.5), (1.06, -1.0), (0.97, -2.0), (1.04, 2.0)]
for i in range(5):
    sp, tl = GRASS_VAR[i]
    RECIPES[f"step_grass_{i + 1}"] = R(L("impact", f"footstep_grass_00{i}.ogg", speed=sp),
                                       tilt_db=tl, **STEP)
    sp, tl = STONE_VAR[i]
    RECIPES[f"step_stone_{i + 1}"] = R(L("impact", f"footstep_concrete_00{i}.ogg", speed=sp),
                                       tilt_db=tl, **STEP)
# The impact pack's footstep_wood_* are near-pure ~100 Hz thumps over a hum
# floor; the RPG pack's footsteps are clearly boards (heel-toe, ~265 Hz floor
# resonance) and genuinely different takes, so they are used for wood.
for i, k in enumerate(["00", "02", "03", "07", "08"]):
    RECIPES[f"step_wood_{i + 1}"] = R(L("rpg", f"footstep{k}.ogg"), **STEP)
# Stone axe chop = solid wooden thunk (impactWood_medium) + the crunchy bite of
# rpg chop.ogg, varispeeded/regained/offset per variant so the four differ.
# (impactWood_medium_004 is a near-duplicate of _000, so it is not used.)
for i, (k, tsp, sp, g, off) in enumerate([("000", 1.0, 1.0, -2.0, 1.5),
                                          ("002", 1.0, 1.1, -3.0, 3.0),
                                          ("003", 0.95, 0.92, -4.0, 0.5),
                                          ("001", 1.1, 0.86, -1.0, 6.0)]):
    RECIPES[f"chop_{i + 1}"] = R(L("impact", f"impactWood_medium_{k}.ogg", speed=tsp),
                                 L("rpg", "chop.ogg", g, off, sp),
                                 note="layered: thunk + crunch")
for i, k in enumerate(["000", "001", "004"]):
    RECIPES[f"wood_drop_{i + 1}"] = R(L("impact", f"impactPlank_medium_{k}.ogg"))
for i, k in enumerate(["000", "003", "004"]):
    RECIPES[f"hammer_wood_{i + 1}"] = R(L("impact", f"impactWood_light_{k}.ogg"))
RECIPES.update({
    "pickup": R(L("rpg", "handleSmallLeather.ogg")),
    "drop_item": R(L("rpg", "dropLeather.ogg")),
    "ui_click": R(L("ui", "click_001.ogg")),
    "ui_hover": R(L("ui", "tick_002.ogg"), lp=8000),
    "ui_open": R(L("ui", "open_002.ogg"), lp=7000),
    "ui_close": R(L("ui", "close_002.ogg"), lp=7000),
    "ui_error": R(L("ui", "error_004.ogg"), lp=6000),
    "page_flip_1": R(L("rpg", "bookFlip1.ogg")),
    "page_flip_2": R(L("rpg", "bookFlip2.ogg")),
    "page_flip_3": R(L("rpg", "bookFlip3.ogg")),
    "book_open": R(L("rpg", "bookOpen.ogg")),
    "book_close": R(L("rpg", "bookClose.ogg")),
})


def src_path(kdir, layer):
    return os.path.join(kdir, PACKS[layer["pack"]][0], "Audio", layer["file"])


def varispeed(x, speed):
    if speed == 1.0:
        return x
    pos = np.arange(0, len(x) - 1, speed)
    return np.interp(pos, np.arange(len(x)), x)


def onset_trim(x, rel_db=-25.0):
    """Cut a layer's quiet lead-in so layers line up on their attacks."""
    e, h = al.env_db(x, 0.001)
    i = int(np.argmax(e > e.max() + rel_db))
    return x[max(0, i * h - int(0.001 * al.SR)):]


def build(kdir, rec):
    parts = []
    for ly in rec["layers"]:
        x = al.decode(src_path(kdir, ly))
        if len(rec["layers"]) > 1:
            x = onset_trim(x)
        x = varispeed(x, ly["speed"]) * 10 ** (ly["gain_db"] / 20)
        parts.append((int(ly["offset_ms"] * al.SR / 1000), x))
    n = max(o + len(x) for o, x in parts)
    y = np.zeros(n)
    for o, x in parts:
        y[o:o + len(x)] += x
    if rec["tilt_db"]:
        y = al.filt(y, al.biquad("hs", 1500, 0.7, rec["tilt_db"]))
    if rec["hp"]:
        y = al.hp(y, rec["hp"])
    if rec["lp"]:
        y = al.lp(y, rec["lp"])
    return np.concatenate([y, np.zeros(int(0.02 * al.SR))])


def write_credits(out_root, raw=False):
    how = ("copied unchanged by `tools/audio/curate.py --raw`" if raw else
           "trimmed, mixed to mono, loudness-normalised and re-encoded (Ogg Vorbis q6) by "
           "`tools/audio/curate.py`; extra processing is noted per file")
    lines = ["# Skyroot audio credits", "",
             "All audio in this folder is CC0 1.0 (public domain dedication).",
             "Curated files come from Kenney's CC0 packs (www.kenney.nl; see "
             f"LICENSE-Kenney.txt) and were {how}. "
             "Everything else was generated from scratch by `tools/audio/synth.py` "
             "(numpy procedural synthesis) and is likewise released under CC0.", "",
             "Regenerate with:", "",
             "    python3 tools/audio/synth.py",
             "    python3 tools/audio/curate.py /path/to/kenney   # needs ffmpeg", "",
             "| file | source | licence |", "|---|---|---|"]
    for name in al.SFX_NAMES:
        if name in RECIPES:
            rec = RECIPES[name]
            layers = rec["layers"][:1] if raw else rec["layers"]
            src = " + ".join(f"{PACKS[ly['pack']][1]}: `{ly['file']}`" for ly in layers)
            extra = []
            if raw:
                pass
            elif rec["note"]:
                extra.append(rec["note"])
            elif len(rec["layers"]) > 1:
                extra.append("layered")
            if not raw and any(ly["speed"] != 1.0 for ly in rec["layers"]):
                extra.append("varispeed")
            if not raw and (rec["tilt_db"] or rec["lp"] or rec["hp"]):
                extra.append("EQ")
            if extra:
                src += f" ({', '.join(extra)})"
            lines.append(f"| sfx/{name}.ogg | {src} | CC0 1.0 |")
        else:
            lines.append(f"| sfx/{name}.wav | synthesized by tools/audio/synth.py | CC0 1.0 |")
    for name in al.AMB_NAMES:
        lines.append(f"| amb/{name}.wav | synthesized by tools/audio/synth.py (seamless loop) "
                     f"| CC0 1.0 |")
    lines += ["", "Loops carry a RIFF `smpl` loop chunk (start 0, end = last sample), so "
              "Godot's WAV importer loops them with its default *Loop Mode: Detect From WAV*.", ""]
    with open(os.path.join(out_root, "CREDITS.md"), "w") as fh:
        fh.write("\n".join(lines))


def write_licence(kdir, out_root):
    parts = ["Licence texts of the Kenney packs used in assets/audio (all CC0 1.0).",
             "Copied verbatim from each pack's License.txt (line endings normalised).", ""]
    for key in ("impact", "rpg", "ui"):
        folder, title = PACKS[key]
        with open(os.path.join(kdir, folder, "License.txt"), "rb") as fh:
            txt = fh.read().decode("utf-8", errors="replace")
        # the originals mix CRLF with stray CR (CR CR LF): normalise as displayed
        txt = txt.replace("\r\r\n", "\n").replace("\r\n", "\n").replace("\r", "\n").strip("\n")
        parts += ["=" * 72, f"{title}  ({folder}/License.txt)", "=" * 72, txt, ""]
    with open(os.path.join(out_root, "LICENSE-Kenney.txt"), "w") as fh:
        fh.write("\n".join(parts) + "\n")


def main(argv=None):
    ap = argparse.ArgumentParser(description="Curate Kenney CC0 sounds for Skyroot.")
    ap.add_argument("kenney_dir", help="folder containing the extracted kenney_* packs")
    ap.add_argument("--raw", action="store_true", help="copy primary sources unchanged")
    ap.add_argument("--out", default=al.AUDIO_DIR, help="output root (default assets/audio)")
    a = ap.parse_args(argv)
    kdir = os.path.abspath(a.kenney_dir)
    for name, rec in RECIPES.items():
        assert name in al.SFX_NAMES, f"{name} is not in the manifest"
        for ly in rec["layers"]:
            if not os.path.isfile(src_path(kdir, ly)):
                raise SystemExit(f"missing source: {src_path(kdir, ly)}")
    raw = a.raw
    if not raw and not al.ffmpeg():
        print("WARNING: ffmpeg not found -> falling back to --raw copies", file=sys.stderr)
        raw = True
    rows = []
    stems = {}
    for name in al.SFX_NAMES:
        if name in RECIPES:
            stems.setdefault(al.stem_of(name), []).append(name)
    for stem, names in stems.items():
        dsts = [os.path.join(a.out, "sfx", nm + ".ogg") for nm in names]
        os.makedirs(os.path.dirname(dsts[0]), exist_ok=True)
        if raw:
            for nm, dst in zip(names, dsts):
                shutil.copyfile(src_path(kdir, RECIPES[nm]["layers"][0]), dst)
                al.remove_alternates(dst)
            continue
        xs = [al.prepare_sfx(build(kdir, RECIPES[nm]), nm, max_len=RECIPES[nm]["max_len"],
                             fade_out=RECIPES[nm]["fade_out"]) for nm in names]
        ys, _, lim = al.normalise_set(xs, names)
        for nm, dst, y, used in zip(names, dsts, ys, lim):
            for _ in range(4):  # guard against Vorbis overshoot
                al.encode_ogg(y, dst)
                dec = al.decode(dst)
                over = al.peak_db(dec) - (al.QC_PEAK_MAX_DB - 0.3)
                if over <= 0:
                    break
                y = y * 10 ** (-(over + 0.1) / 20)
            al.remove_alternates(dst)
            row = al.stats_row(nm, dec)
            row["src"] = " + ".join(ly["file"] for ly in RECIPES[nm]["layers"])
            if used > 0.05:
                row["src"] += f"  (limited {used:.1f} dB)"
            rows.append(row)
    if rows:
        al.print_table(rows, "curated Kenney SFX (decoded Ogg; peak/rms dBFS, loud = K-weighted max 200 ms)")
    write_credits(a.out, raw)
    write_licence(kdir, a.out)
    print(f"\n{len(RECIPES)} Kenney-derived files -> {os.path.relpath(a.out, al.REPO)}/sfx "
          f"({'raw copies' if raw else 'mono Ogg Vorbis q6'}); wrote CREDITS.md, LICENSE-Kenney.txt")
    return 0


if __name__ == "__main__":
    sys.exit(main())
