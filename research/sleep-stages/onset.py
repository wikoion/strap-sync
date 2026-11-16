"""Train on the sleep period only (first to last non-wake epoch), as the app sees a night from the band
flag's onset to its end, and score leave-one-subject-out plus the MG night against Fitbit."""
import numpy as np, glob, sys, os, sqlite3, warnings
warnings.filterwarnings("ignore")
sys.path.insert(0, os.path.dirname(__file__))
from model import *
from mlp import fit_mlp, tempered_viterbi
train_dir, whoop_db, hd_db = sys.argv[1:4]
nights = []
for p in sorted(glob.glob(train_dir + "/*.npz")):
    d = np.load(p); y = d["y"]
    asleep = np.where((y > 0))[0]
    a, b = asleep[0], asleep[-1] + 1                      # sleep period, in epochs
    hr, mot = d["hr"][a * 30: b * 30], d["motion"][a * 30: b * 30]
    X = epoch_features(hr, mot); nights.append((X, y[a: a + len(X)]))
def train(tr):
    X = np.vstack([x for x, y in tr]); y = np.concatenate([y for x, y in tr]); m = y >= 0; X, y = X[m], y[m]
    mu, sd = X.mean(0), X.std(0) + 1e-6
    prior = np.bincount(y, minlength=4) / len(y); w = (1 / prior)[y] ** 0.5
    return fit_mlp((X - mu) / sd, y, w), mu, sd, transitions([yy for _, yy in tr])
pp, yy = [], []
for i, (Xt, yt) in enumerate(nights):
    f, mu, sd, T = train([n for j, n in enumerate(nights) if j != i])
    path = tempered_viterbi(f((Xt - mu) / sd), T, 0.5); mt = yt >= 0
    pp.append(path[mt]); yy.append(yt[mt])
p, y = np.concatenate(pp), np.concatenate(yy)
print("LOSO, sleep period only: accuracy %.3f kappa %.3f; minutes %s vs truth %s" % ((p == y).mean(), kappa(p, y),
      (np.bincount(p, minlength=4) / 2).astype(int), (np.bincount(y, minlength=4) / 2).astype(int)))
f, mu, sd, T = train(nights)
N0, N1 = 1793232665, 1793268846
db = sqlite3.connect(whoop_db)
hr = np.full(N1 - N0, np.nan); mot = np.full(N1 - N0, np.nan)
for ts, bpm, motion in db.execute("SELECT ts, bpm, motion FROM motion WHERE ts >= ? AND ts < ?", (N0, N1)):
    if bpm > 0: hr[ts - N0] = bpm
    if motion is not None: mot[ts - N0] = motion
path = tempered_viterbi(f((epoch_features(hr, mot) - mu) / sd), T, 0.5)
hd = sqlite3.connect(hd_db)
segs = hd.execute("SELECT stage, start_utc/1000, end_utc/1000 FROM sleep_segments WHERE session_id = 11076 AND stage IN ('core','deep','rem','awake')").fetchall()
code = {"awake": 0, "core": 1, "deep": 2, "rem": 3}; fb = np.full(len(path), -1)
for s, a, b in segs:
    for e in range(len(path)):
        if a <= N0 + e * 30 + 15 < b: fb[e] = code[s]
mk = fb >= 0
print("MG night vs Fitbit: accuracy %.3f kappa %.3f; minutes %s vs Fitbit %s" % ((path[mk] == fb[mk]).mean(), kappa(path[mk], fb[mk]),
      (np.bincount(path, minlength=4) / 2).astype(int), (np.bincount(fb[mk], minlength=4) / 2).astype(int)))
sym = "wLDR"
print("ours  ", "".join(sym[s] for s in path[::10])); print("Fitbit", "".join(sym[s] if s >= 0 else "." for s in fb[::10]))
