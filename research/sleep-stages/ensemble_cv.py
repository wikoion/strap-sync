"""The GRU, both LightGBM stages and their average, on the ECG sleep-lab nights with the same 5
folds as hrv_stack.py and gru_cv.py (heart only: these nights have no movement). LightGBM's fold
probabilities are kept in <cache>-lgb2-foldN.npz; the GRU's come from gru_cv.py's
<cache>-gru3-foldN.npz, so run that first (it needs torch, this needs lightgbm).
Usage: ensemble_cv.py <cache>."""
import numpy as np, sys, os, warnings
warnings.filterwarnings("ignore")
sys.path.insert(0, os.path.dirname(__file__))
from model import kappa, transitions
from mlp import tempered_viterbi
from stack import fit_two
cache = sys.argv[1]
z = np.load(cache + ".npz", allow_pickle=True); nights, source = list(z["nights"]), z["source"]
order = np.random.default_rng(0).permutation(len(nights))
res = {k: ([], [], []) for k in ("LightGBM", "GRU", "GRU + Viterbi", "ensemble", "ensemble, no Viterbi")}
for f in range(5):
    test = order[f::5]; tr = [nights[i] for i in order if i not in set(test)]
    done = f"{cache}-lgb2-fold{f}.npz"
    if not os.path.exists(done):
        two, _ = fit_two(tr); np.savez(done, p=np.array([two(nights[i][0]) for i in test], dtype=object))
    T = transitions([y for _, y in tr])
    for i, pl, pg in zip(test, np.load(done, allow_pickle=True)["p"], np.load(f"{cache}-gru3-fold{f}.npz", allow_pickle=True)["p"]):
        y = nights[i][1]; m = y >= 0
        for k, path in (("LightGBM", tempered_viterbi(pl, T, 0.5)), ("GRU", pg.argmax(1)), ("GRU + Viterbi", tempered_viterbi(pg, T, 0.5)),
                        ("ensemble", tempered_viterbi((pl + pg) / 2, T, 0.5)), ("ensemble, no Viterbi", ((pl + pg) / 2).argmax(1))):
            res[k][0].append(path[m]); res[k][1].append(y[m]); res[k][2].append(source[i])
    print("fold", f, "done", flush=True)
for k, (pp, yy, src) in res.items():
    for name in sorted(set(src)) + ["all"]:
        sel = [j for j, s in enumerate(src) if name in (s, "all")]
        p, y = np.concatenate([pp[j] for j in sel]), np.concatenate([yy[j] for j in sel])
        print("%-21s %-4s %3d nights: accuracy %.3f kappa %.3f (per-night median %.3f); minutes %s vs truth %s" % (k, name, len(sel),
              (p == y).mean(), kappa(p, y), np.median([kappa(pp[j], yy[j]) for j in sel]),
              (np.bincount(p, minlength=4) / 2).astype(int), (np.bincount(y, minlength=4) / 2).astype(int)))
