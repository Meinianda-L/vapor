"""Measure horizontal motion between captured VaporBoost output frames.

For a pattern moving DX app-pixels per frame, upscaled by S, consecutive real
frames should shift by DX*S output pixels and a generated frame should sit
halfway (DX*S/2) after the previous real frame.
usage: analyze.py <capture dir> <frame a> <frame b>
"""
import glob
import os
import sys


def load(path):
    name = os.path.basename(path)
    w, h = map(int, name.rsplit("_", 1)[1].split(".")[0].split("x"))
    return open(path, "rb").read(), w, h


def band(data, w, h, rows=12):
    # Green channel of a band of rows around the vertical centre (BGRA layout).
    y0 = h // 2 - rows // 2
    return [[data[((y0 + r) * w + x) * 4 + 1] for x in range(w)] for r in range(rows)]


def shift(a, b, w, max_shift=48):
    """Return the shift s (pixels) minimising mean |b[x] - a[x - s]|, plus its error."""
    best = None
    lo, hi = max_shift, w - max_shift
    for s in range(-max_shift, max_shift + 1):
        err = 0
        for ra, rb in zip(a, b):
            err += sum(abs(rb[x] - ra[x - s]) for x in range(lo, hi, 2))
        err /= len(a) * ((hi - lo) // 2)
        if best is None or err < best[1]:
            best = (s, err)
    return best


d, fa, fb = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
real_a = glob.glob(f"{d}/f{fa:03d}_real_*.bgra")[0]
real_b = glob.glob(f"{d}/f{fb:03d}_real_*.bgra")[0]
gen_b = glob.glob(f"{d}/f{fb:03d}_gen_*.bgra")
ra, w, h = load(real_a)
rb, _, _ = load(real_b)
A, B = band(ra, w, h), band(rb, w, h)
print(f"output size {w}x{h}")
s, e = shift(A, B, w)
print(f"real f{fa} -> real f{fb}: shift {s:+d} px (mean abs err {e:.2f})")
if gen_b:
    g, _, _ = load(gen_b[0])
    G = band(g, w, h)
    s1, e1 = shift(A, G, w)
    s2, e2 = shift(G, B, w)
    print(f"real f{fa} -> gen  f{fb}: shift {s1:+d} px (err {e1:.2f})")
    print(f"gen  f{fb} -> real f{fb}: shift {s2:+d} px (err {e2:.2f})")
