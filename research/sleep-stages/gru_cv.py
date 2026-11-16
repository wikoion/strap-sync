"""The GRU (gru.py) against the LightGBM stages, on the same nights and the same 5 folds as
hrv_stack.py. Features are cached in <cache>.npz, and each fold's stage probabilities in
<cache>-gru3-foldN.npz (ensemble_cv.py reads them). Usage: gru_cv.py <cache> <beats dir>...
Needs torch."""
import numpy as np, glob, sys, os, warnings
warnings.filterwarnings("ignore")
sys.path.insert(0, os.path.dirname(__file__))
from model import kappa
from hrv import epoch_features, rr_series
from gru import prep, train, proba
cache, dirs = sys.argv[1], sys.argv[2:]

if os.path.exists(cache + ".npz"):
    z = np.load(cache + ".npz", allow_pickle=True); nights, source = list(z["nights"]), z["source"]
else:
    nights, source = [], []
    for i, p in enumerate(sorted(q for d in dirs for q in glob.glob(d + "/*.npz"))):
        d = np.load(p); y = d["y"]; s = np.where(y > 0)[0]
        if len(s) < 120 or len(rr_series(d["beats"])[0]) < 0.7 * len(d["beats"]): continue
        X, _ = epoch_features(d["beats"], len(y), s[0], s[-1] + 1, np.random.default_rng(i))
        nights.append((X, y[s[0]: s[-1] + 1])); source.append(os.path.basename(p)[:2])
    source = np.array(source)
    np.savez(cache, nights=np.array(nights, dtype=object), source=source)
print(len(nights), "nights", flush=True)

data = [(prep(x), y) for x, y in nights]
order = np.random.default_rng(0).permutation(len(data)); pp, yy, src = [], [], []
for f in range(5):
    done = f"{cache}-gru3-fold{f}.npz"                        # each fold is kept, so a rerun resumes
    if not os.path.exists(done):
        test = set(order[f::5]); net = train([data[i] for i in order if i not in test])
        np.savez(done, p=np.array([proba(net, data[i][0]) for i in order[f::5]], dtype=object))
    for i, P in zip(order[f::5], np.load(done, allow_pickle=True)["p"]):
        y = data[i][1]; m = y >= 0; p = P.argmax(1)
        pp.append(p[m]); yy.append(y[m]); src.append(source[i])
    print("fold", f, "done", flush=True)
for name in sorted(set(src)) + ["all"]:
    sel = [j for j, s in enumerate(src) if name in (s, "all")]
    p, y = np.concatenate([pp[j] for j in sel]), np.concatenate([yy[j] for j in sel])
    print("GRU %-4s %3d nights: accuracy %.3f kappa %.3f (per-night median %.3f); minutes %s vs truth %s" % (name, len(sel), (p == y).mean(),
          kappa(p, y), np.median([kappa(pp[j], yy[j]) for j in sel]), (np.bincount(p, minlength=4) / 2).astype(int), (np.bincount(y, minlength=4) / 2).astype(int)))
