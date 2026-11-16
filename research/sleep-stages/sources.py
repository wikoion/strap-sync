"""Training nights from any prepared source, as (features, labels, tag) for the sleep period, the
tag being SN for HMC, tr for CinC, WZ for Wearanize+ (PSG ECG beats with the wrist's gravity), DR
for DREAMT, SA for sleep-accel, BS for BIDSleep and NC for Newcastle. A source
is the feature cache gru_cv.py writes (.npz holding 'nights'), a directory of ECG beats
(hmc_beats.py / cinc_beats.py, thinned to the MG's coverage), a directory of DREAMT nights
(dreamt_night.py; nights whose beats cover under half the sleep period are left out), or a directory
of Apple Watch nights (wrist_night.py: heart rate and rotation only; nights with gravity for under
half the sleep period are left out)."""
import numpy as np, glob, os
from hrv import epoch_features, rr_series, clean, features

def load(path):
    if path.endswith(".npz"):
        z = np.load(path, allow_pickle=True)
        return [(x, y, s) for (x, y), s in zip(z["nights"], z["source"])]
    out = []
    for i, p in enumerate(sorted(glob.glob(path + "/*.npz"))):
        d = np.load(p); y = d["y"]; s = np.where(y > 0)[0]
        if len(s) < 120: continue
        if "beats" in d:
            if len(rr_series(d["beats"])[0]) < 0.7 * len(d["beats"]): continue
            X, _ = epoch_features(d["beats"], len(y), s[0], s[-1] + 1, np.random.default_rng(i), grav=d["grav"] if "grav" in d else None)
            tag = str(d["src"]) if "src" in d else os.path.basename(p)[:2]
        elif "hr_t" not in d:
            sp = (d["t"] >= s[0] * 30) & (d["t"] < (s[-1] + 1) * 30)
            if d["rr"][sp].sum() < 0.5 * (s[-1] + 1 - s[0]) * 30: continue
            X, _ = features(*clean(d["t"], d["rr"], d["idx"]), len(y), s[0], s[-1] + 1, d["grav"] if "grav" in d else None, d["temp"]); tag = "DR"
        else:
            if np.isfinite(d["grav"][s[0] * 30: (s[-1] + 1) * 30, 0]).mean() < 0.5: continue
            X, _ = features(d["t"], d["rr"], d["idx"], len(y), s[0], s[-1] + 1, d["grav"], None, (d["hr_t"], d["hr_bpm"])); tag = str(d["src"])
        out.append((X, y[s[0]: s[-1] + 1], tag))
    return out
