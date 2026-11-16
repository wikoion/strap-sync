"""How much HRV adds: 5-fold subject-wise cross-validation on ECG PSG nights (from hmc_beats.py),
sleep period only, LightGBM on HR-only versus HR + HRV features, with full ECG beats and with beats
thinned to the MG's overnight coverage (89%, ~30 s gaps). Run with the scratch venv (needs scipy and lightgbm)."""
import numpy as np, glob, sys, os, warnings
warnings.filterwarnings("ignore")
sys.path.insert(0, os.path.dirname(__file__))
import lightgbm as lgb
from model import kappa, transitions
from mlp import tempered_viterbi
from hrv import epoch_features, rr_series, HR_ONLY

nights = {False: [], True: []}
for i, p in enumerate(sorted(glob.glob(sys.argv[1] + "/*.npz"))):
    d = np.load(p); y = d["y"]; s = np.where(y > 0)[0]
    if len(s) < 120 or len(rr_series(d["beats"])[0]) < 0.7 * len(d["beats"]): continue   # short night or bad ECG
    a, b = s[0], s[-1] + 1
    for thinned in (False, True):
        X, names = epoch_features(d["beats"], len(y), a, b, np.random.default_rng(i) if thinned else None)
        nights[thinned].append((X, y[a:b]))
print(len(nights[False]), "nights,", sum(len(y) for _, y in nights[False]) // 120, "hours of sleep period", flush=True)

def run(data, cols, label, folds=5):
    rng = np.random.default_rng(0); order = rng.permutation(len(data)); pp, yy, pk = [], [], []
    imp = np.zeros(len(cols))
    for f in range(folds):
        test = set(order[f::folds]); tr = [data[i] for i in range(len(data)) if i not in test]
        X = np.vstack([x[:, cols] for x, _ in tr]); y = np.concatenate([y for _, y in tr]); m = y >= 0
        prior = np.bincount(y[m], minlength=4) / m.sum()
        clf = lgb.LGBMClassifier(n_estimators=400, learning_rate=0.05, num_leaves=31, min_child_samples=200,
                                 subsample=0.8, subsample_freq=1, colsample_bytree=0.8, verbose=-1)
        clf.fit(X[m], y[m], sample_weight=(1 / prior[y[m]]) ** 0.5)
        imp += clf.booster_.feature_importance("gain")
        T = transitions([y for _, y in tr])
        for i in test:
            Xt, yt = data[i]; path = tempered_viterbi(clf.predict_proba(Xt[:, cols]), T, 0.5); mt = yt >= 0
            pp.append(path[mt]); yy.append(yt[mt]); pk.append(kappa(path[mt], yt[mt]))
    p, y = np.concatenate(pp), np.concatenate(yy)
    print("%-28s accuracy %.3f kappa %.3f (per-night median %.3f); minutes %s vs truth %s" % (label, (p == y).mean(), kappa(p, y),
          np.median(pk), (np.bincount(p, minlength=4) / 2).astype(int), (np.bincount(y, minlength=4) / 2).astype(int)), flush=True)
    return imp

hr_cols = [names.index(k) for k in HR_ONLY]; all_cols = list(range(len(names)))
for thinned in (False, True):
    tag = "MG-thinned" if thinned else "full ECG"
    run(nights[thinned], hr_cols, f"HR only, {tag}")
    imp = run(nights[thinned], all_cols, f"HR + HRV, {tag}")
top = np.argsort(-imp)[:15]
print("top features (MG-thinned):", ", ".join(f"{names[j]} {imp[j] / imp.sum():.2f}" for j in top))
