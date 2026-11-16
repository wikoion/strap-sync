"""First stage alone versus both stages (stack.py): 5-fold subject-wise CV over every ECG PSG night
given, beats thinned to the MG's coverage, sleep period only, scored per dataset (SN = HMC,
tr = CinC 2018). Usage: hrv_stack.py <beats dir>..."""
import numpy as np, glob, sys, os, warnings
warnings.filterwarnings("ignore")
sys.path.insert(0, os.path.dirname(__file__))
from model import kappa, transitions
from mlp import tempered_viterbi
from hrv import epoch_features, rr_series
from stack import fit_two

nights, source = [], []
for i, p in enumerate(sorted(q for d in sys.argv[1:] for q in glob.glob(d + "/*.npz"))):
    d = np.load(p); y = d["y"]; s = np.where(y > 0)[0]
    if len(s) < 120 or len(rr_series(d["beats"])[0]) < 0.7 * len(d["beats"]): continue
    X, names = epoch_features(d["beats"], len(y), s[0], s[-1] + 1, np.random.default_rng(i))
    nights.append((X, y[s[0]: s[-1] + 1])); source.append(os.path.basename(p)[:2])
source = np.array(source)
print(len(nights), "nights", dict(zip(*np.unique(source, return_counts=True))), flush=True)

order = np.random.default_rng(0).permutation(len(nights)); res = {k: ([], [], []) for k in ("stage 1", "stage 2")}
for f in range(5):
    test = order[f::5]; tr = [nights[i] for i in order if i not in set(test)]
    two, c1 = fit_two(tr); T = transitions([y for _, y in tr])
    for i in test:
        Xt, yt = nights[i]; mt = yt >= 0
        for k, P in (("stage 1", c1.predict_proba(Xt)), ("stage 2", two(Xt))):
            path = tempered_viterbi(P, T, 0.5)
            res[k][0].append(path[mt]); res[k][1].append(yt[mt]); res[k][2].append(source[i])
    print("fold", f, "done", flush=True)
for k, (pp, yy, src) in res.items():
    for name in sorted(set(src)) + ["all"]:
        sel = [j for j, s in enumerate(src) if name in (s, "all")]
        p, y = np.concatenate([pp[j] for j in sel]), np.concatenate([yy[j] for j in sel])
        pk = [kappa(pp[j], yy[j]) for j in sel]
        print("%-8s %-4s %3d nights: accuracy %.3f kappa %.3f (per-night median %.3f); minutes %s vs truth %s" % (k, name, len(sel),
              (p == y).mean(), kappa(p, y), np.median(pk), (np.bincount(p, minlength=4) / 2).astype(int), (np.bincount(y, minlength=4) / 2).astype(int)))
