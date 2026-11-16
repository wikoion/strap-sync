import numpy as np, glob, sys, os, sqlite3, warnings, collections
warnings.filterwarnings("ignore")
sys.path.insert(0, os.path.dirname(__file__))
from model import *
from mlp import fit_mlp, tempered_viterbi
train_dir, whoop_db, hd_db = sys.argv[1:4]
nights = []
for p in sorted(glob.glob(train_dir + "/*.npz")):
    d = np.load(p); X = epoch_features(d["hr"], d["motion"]); nights.append((X, d["y"][: len(X)]))
X = np.vstack([x for x, y in nights]); y = np.concatenate([y for x, y in nights]); m = y >= 0; X, y = X[m], y[m]
mu, sd = X.mean(0), X.std(0) + 1e-6
prior = np.bincount(y, minlength=4) / len(y); w = (1 / prior)[y] ** 0.5
f = fit_mlp((X - mu) / sd, y, w); T = transitions([yy for _, yy in nights])
# The WHOOP night (band flag 00:11-10:14), per second from the strap's own records.
N0, N1 = 1793232665, 1793268846
db = sqlite3.connect(whoop_db)
hr = np.full(N1 - N0, np.nan); mot = np.full(N1 - N0, np.nan)
for ts, bpm, motion in db.execute("SELECT ts, bpm, motion FROM motion WHERE ts >= ? AND ts < ?", (N0, N1)):
    if bpm > 0: hr[ts - N0] = bpm
    if motion is not None: mot[ts - N0] = motion
print("per-second coverage: hr %.1f%%, motion %.1f%%" % (100 * np.mean(~np.isnan(hr)), 100 * np.mean(~np.isnan(mot))))
Xw = epoch_features(hr, mot)
P = f((Xw - mu) / sd); path = tempered_viterbi(P, T, 0.5)
# Fitbit, per 30 s epoch
hd = sqlite3.connect(hd_db)
segs = hd.execute("SELECT stage, start_utc/1000, end_utc/1000 FROM sleep_segments WHERE session_id = 11076 AND stage IN ('core','deep','rem','awake')").fetchall()
code = {"awake": 0, "core": 1, "deep": 2, "rem": 3}
fb = np.full(len(path), -1)
for s, a, b in segs:
    for e in range(len(path)):
        t = N0 + e * 30 + 15
        if a <= t < b: fb[e] = code[s]
mk = fb >= 0
print("vs Fitbit: accuracy %.3f kappa %.3f" % ((path[mk] == fb[mk]).mean(), kappa(path[mk], fb[mk])))
print("minutes  ours  wake/light/deep/rem:", (np.bincount(path, minlength=4) / 2).astype(int))
print("minutes Fitbit wake/light/deep/rem:", (np.bincount(fb[mk], minlength=4) / 2).astype(int))
sym = "wLDR"
print("ours  ", "".join(sym[s] for s in path[::10]))
print("Fitbit", "".join(sym[s] if s >= 0 else "." for s in fb[::10]))
# Optional 4th argument: where to save the normalisation and transitions.
if len(sys.argv) > 4: np.savez(sys.argv[4], mu=mu, sd=sd, T=T)
