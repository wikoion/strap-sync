"""The GRU (gru.py) on DREAMT nights, 5-fold subject-wise: trained on the ECG PSG nights alone, and
on the ECG nights plus the other DREAMT folds (with wrist rotation and skin temperature, which the
ECG nights lack and the GRU is told so). Sleep period only. Each fold is kept in <out>-foldN.npz so a
rerun resumes; delete them when the DREAMT nights change.
Usage: dreamt_gru.py <out> <ECG source> <dreamt npz dir>. Needs torch."""
import numpy as np, sys, os, warnings
warnings.filterwarnings("ignore")
sys.path.insert(0, os.path.dirname(__file__))
from model import kappa
from gru import prep, train, predict, heart_only
from sources import load
out, ecg_src, dreamt_dir = sys.argv[1:4]
ecg = [(prep(x), y) for x, y, _ in load(ecg_src)]
dr_raw = [(x, y) for x, y, _ in load(dreamt_dir)]
dr = [(prep(x), y) for x, y in dr_raw]
print(len(dr), "DREAMT nights,", len(ecg), "ECG nights", flush=True)

order = np.random.default_rng(0).permutation(len(dr))
f_ecg = out + "-ecg.npz"
if not os.path.exists(f_ecg):
    net = train(ecg); np.savez(f_ecg, p=np.array([predict(net, prep(heart_only(x))) for x, _ in dr_raw], dtype=object))
res = {"GRU, ECG only": list(np.load(f_ecg, allow_pickle=True)["p"]), "GRU, ECG + DREAMT": [None] * len(dr)}
for f in range(5):
    done = f"{out}-fold{f}.npz"
    if not os.path.exists(done):
        test = set(order[f::5]); net = train(ecg + [dr[i] for i in order if i not in test])
        np.savez(done, p=np.array([predict(net, dr[i][0]) for i in order[f::5]], dtype=object))
    for i, p in zip(order[f::5], np.load(done, allow_pickle=True)["p"]): res["GRU, ECG + DREAMT"][i] = p
    print("fold", f, "done", flush=True)
for k, ps in res.items():
    pp = [p[y >= 0] for p, (_, y) in zip(ps, dr)]; yy = [y[y >= 0] for _, y in dr]
    p, y = np.concatenate(pp), np.concatenate(yy)
    print("%-18s accuracy %.3f kappa %.3f (per-night median %.3f); minutes %s vs truth %s" % (k, (p == y).mean(), kappa(p, y),
          np.median([kappa(a, b) for a, b in zip(pp, yy)]), (np.bincount(p, minlength=4) / 2).astype(int), (np.bincount(y, minlength=4) / 2).astype(int)))
