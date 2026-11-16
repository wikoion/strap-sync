"""Wrist rotation, the movement measure that should transfer between devices: the angle between
successive 5-s gravity directions, in degrees. The MG's gravity vector is R18 float32 x/y/z at bytes
45/49/53 (|a| = 1.01 g, 5th-95th 0.97-1.03; byte 41 is the gravity-removed magnitude). The E4's comes
from per-second means of its raw axes. Prints the share of epochs with a turn over 5 degrees for the
28->29 Oct MG night (from the raw archive) and for the first ten DREAMT nights (asleep and awake).
Run from the repo root: rotation_check.py <DREAMT data_64Hz dir>."""
import struct, csv, glob, sys, numpy as np
def rot5(sec_xyz):
    """per-second gravity vectors (n x 3, NaN allowed) -> per-5-s angle change in degrees."""
    n = len(sec_xyz) // 5 * 5; g = np.nanmean(sec_xyz[:n].reshape(-1, 5, 3), 1)
    u = g / np.linalg.norm(g, axis=1, keepdims=True)
    c = np.clip((u[1:] * u[:-1]).sum(1), -1, 1); return np.r_[np.nan, np.degrees(np.arccos(c))]
def epoch_frac(r5, thr=5):   # fraction of 5-s steps per 30-s epoch rotating more than thr degrees
    n = len(r5) // 6 * 6; return np.nanmean((r5[:n] > thr).reshape(-1, 6), 1)
# MG night from the raw archive
N0, N1 = 1793232665, 1793268846
xyz = np.full((N1 - N0, 3), np.nan)
data = open('secrets/raw/2026-10-29T10.bin', 'rb').read(); i = 0
while i + 2 <= len(data):
    n = data[i] | data[i + 1] << 8; f = data[i + 2: i + 2 + n]; i += 2 + n
    if len(f) == 124 and f[8] == 47 and f[9] == 18:
        t = struct.unpack_from('<I', f, 15)[0]
        if N0 <= t < N1: xyz[t - N0] = struct.unpack_from('<3f', f, 45)
mg = epoch_frac(rot5(xyz))
print('MG night: %.0f%% of seconds have axes; epochs with a >5 deg turn: %.1f%%; per-5s turn median %.2f deg' %
      (100 * np.isfinite(xyz[:, 0]).mean(), 100 * np.mean(mg > 0), np.nanmedian(rot5(xyz))))
# DREAMT: per-second mean of the raw axes, first 10 complete nights
asleep, awake, med = [], [], []
for p in sorted(glob.glob(sys.argv[1] + '/S*_whole_df.csv'))[:10]:
    ts, ax, st = [], [], []
    with open(p) as fh:
        r = csv.reader(fh); h = next(r)
        for row in r:
            if len(row) < len(h): break
            ts.append(float(row[0])); ax.append((float(row[2] or 'nan'), float(row[3] or 'nan'), float(row[4] or 'nan'))); st.append(row[9])
    ts = np.array(ts); ax = np.array(ax) / 64; st = np.array(st)
    t0 = ts[np.argmax(st != 'P')]; sec = np.floor(ts - t0).astype(int); ok = sec >= 0; ns = sec[ok].max() + 1
    S = np.full((ns, 3), np.nan)
    for k in range(3): S[:, k] = np.bincount(sec[ok], ax[ok, k], ns) / np.maximum(np.bincount(sec[ok], minlength=ns), 1)
    fr = epoch_frac(rot5(S)); lab = st[ok][::1920][: len(fr)]
    m = min(len(fr), len(lab)); fr, lab = fr[:m], lab[:m]
    sl = np.isin(lab, ['N1', 'N2', 'N3', 'R']); aw = lab == 'W'
    asleep.append(100 * np.mean(fr[sl] > 0)); awake.append(100 * np.mean(fr[aw] > 0)); med.append(np.nanmedian(rot5(S)))
print('DREAMT (10 nights): epochs with a >5 deg turn, asleep %.1f%% (median night), awake %.1f%%; per-5s turn median %.2f deg' %
      (np.median(asleep), np.median(awake), np.median(med)))
