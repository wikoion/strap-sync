"""Per-30-s-epoch features from sleep-accel (Walch 2019, PhysioNet, ODC-By), built the way they can
also be built from a WHOOP MG's per-second records: movement, heart rate and time since sleep onset.
Writes one .npz per subject: X (epochs x features), y (0 wake, 1 light, 2 deep, 3 REM)."""
import numpy as np, sys, os, glob
D, OUT = sys.argv[1], sys.argv[2]
os.makedirs(OUT, exist_ok=True)
STAGE = {0: 0, 1: 1, 2: 1, 3: 2, 4: 2, 5: 3}

def read_motion(path, t0, t1):
    ts, mags = [], []
    with open(path) as f:
        for line in f:
            if line[0] == "-":
                continue  # the week before the lab night
            p = line.split()
            t = float(p[0])
            if t < t0 or t > t1:
                continue
            ts.append(t); mags.append((float(p[1])**2 + float(p[2])**2 + float(p[3])**2) ** 0.5)
    return np.array(ts), np.array(mags)

def per_second_motion(ts, mags, n_sec):
    # Gravity-removed magnitude, averaged per second: the closest match to the MG's R18 @41 value.
    out = np.full(n_sec, np.nan)
    sec = ts.astype(int)
    dyn = np.abs(mags - 1.0)
    for s in range(n_sec):
        pass
    sums = np.bincount(sec[(sec >= 0) & (sec < n_sec)], weights=dyn[(sec >= 0) & (sec < n_sec)], minlength=n_sec)
    cnts = np.bincount(sec[(sec >= 0) & (sec < n_sec)], minlength=n_sec)
    out[cnts > 0] = sums[cnts > 0] / cnts[cnts > 0]
    return out

for lab in sorted(glob.glob(f"{D}/labels/*_labeled_sleep.txt")):
    sid = os.path.basename(lab).split("_")[0]
    L = np.loadtxt(lab)
    L = L[L[:, 1] >= 0]
    n_ep = int(L[-1, 0] // 30) + 1
    n_sec = n_ep * 30
    y = np.full(n_ep, -1)
    for t, s in L: y[int(t // 30)] = STAGE[int(s)]
    hr = np.loadtxt(f"{D}/heart_rate/{sid}_heartrate.txt", delimiter=",")
    hr = hr[(hr[:, 0] >= -600) & (hr[:, 0] <= n_sec + 600)]
    hr1 = np.interp(np.arange(n_sec), hr[:, 0], hr[:, 1]) if len(hr) > 10 else np.full(n_sec, np.nan)
    mt, mm = read_motion(f"{D}/motion/{sid}_acceleration.txt", 0, n_sec)
    mot1 = per_second_motion(mt, mm, n_sec)
    np.savez(f"{OUT}/{sid}.npz", hr=hr1, motion=mot1, y=y)
    print(sid, n_ep, "epochs", "hr samples", len(hr), "motion samples", len(mt), flush=True)
