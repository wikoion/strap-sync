"""What the wrist adds, scored on DREAMT nights (dreamt_night.py) with 5-fold subject-wise CV:
  ECG only     trained on the ECG PSG nights alone (as the MG is today), HRV features
  DREAMT HRV   trained on the other DREAMT folds, HRV features only
  DREAMT all   same, plus wrist rotation (hrv.rotation) and skin temperature
  ECG + DREAMT trained on the ECG nights plus the other DREAMT folds, every feature
Sleep period only; nights where the E4's intervals cover under half the sleep period are left out
(the MG covers 89%). Usage: dreamt_cv.py <ECG feature cache .npz from gru_cv.py> <dreamt npz dir> [two]
("two" uses both LightGBM stages; the default is the first stage only)."""
import numpy as np, glob, sys, os, warnings
warnings.filterwarnings("ignore")
sys.path.insert(0, os.path.dirname(__file__))
from model import kappa, transitions
from mlp import tempered_viterbi
from hrv import clean, features
from stack import fit, fit_two
ecg = [tuple(n) for n in np.load(sys.argv[1], allow_pickle=True)["nights"]]
two = len(sys.argv) > 3 and sys.argv[3] == "two"

nights, names = [], []
for p in sorted(glob.glob(sys.argv[2] + "/*.npz")):
    d = np.load(p); y = d["y"]; s = np.where(y > 0)[0]
    if len(s) < 120: continue
    sp = (d["t"] >= s[0] * 30) & (d["t"] < (s[-1] + 1) * 30)
    if d["rr"][sp].sum() < 0.5 * (s[-1] + 1 - s[0]) * 30: continue    # beats cover under half the night
    t, rr, idx = clean(d["t"], d["rr"], d["idx"])
    X, cols = features(t, rr, idx, len(y), s[0], s[-1] + 1, d["grav"], d["temp"])
    nights.append((X, y[s[0]: s[-1] + 1])); names.append(os.path.basename(p)[:4])
hrv = [j for j, c in enumerate(cols) if not c.startswith(("rot", "temp"))]
cov = [np.nanmean(x[:, cols.index("cover5")]) for x, _ in nights]
print(len(nights), "DREAMT nights, median 5-min beat coverage %.2f;" % np.median(cov), len(ecg), "ECG nights", flush=True)

def model(data):
    if two: return fit_two(data)[0]
    clf = fit(data); return clf.predict_proba

def mask(data, keep):
    return [(np.where(np.isin(np.arange(x.shape[1]), keep), x, np.nan), y) for x, y in data]

T = transitions([y for _, y in ecg]); order = np.random.default_rng(0).permutation(len(nights))
res = {k: ([], []) for k in ("ECG only", "DREAMT HRV", "DREAMT all", "ECG + DREAMT")}
f_ecg = model(mask(ecg, hrv))
for f in range(5):
    test = set(order[f::5]); tr = [nights[i] for i in order if i not in test]
    fs = {"ECG only": f_ecg, "DREAMT HRV": model(mask(tr, hrv)), "DREAMT all": model(tr), "ECG + DREAMT": model(ecg + tr)}
    for i in order[f::5]:
        X, y = nights[i]; m = y >= 0
        for k, g in fs.items():
            Xi = mask([(X, y)], hrv)[0][0] if k in ("ECG only", "DREAMT HRV") else X
            p = tempered_viterbi(g(Xi), T, 0.5); res[k][0].append(p[m]); res[k][1].append(y[m])
    print("fold", f, "done", flush=True)
for k, (pp, yy) in res.items():
    p, y = np.concatenate(pp), np.concatenate(yy)
    print("%-13s accuracy %.3f kappa %.3f (per-night median %.3f); minutes %s vs truth %s" % (k, (p == y).mean(), kappa(p, y),
          np.median([kappa(a, b) for a, b in zip(pp, yy)]), (np.bincount(p, minlength=4) / 2).astype(int), (np.bincount(y, minlength=4) / 2).astype(int)))
