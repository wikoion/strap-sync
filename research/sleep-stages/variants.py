import numpy as np, glob, sys, os, warnings
warnings.filterwarnings("ignore")
sys.path.insert(0, os.path.dirname(__file__))
from model import *
nights = []
for p in sorted(glob.glob(sys.argv[1] + "/*.npz")):
    d = np.load(p); X = epoch_features(d["hr"], d["motion"]); nights.append((X, d["y"][: len(X)]))
def run(balance, mode):
    allp, ally = [], []
    for i, (Xt, yt) in enumerate(nights):
        tr = [n for j, n in enumerate(nights) if j != i]
        X = np.vstack([x for x, y in tr]); y = np.concatenate([y for x, y in tr]); m = y >= 0; X, y = X[m], y[m]
        mu, sd = X.mean(0), X.std(0) + 1e-6
        prior = np.bincount(y, minlength=4) / len(y)
        w = (1 / prior)[y] ** balance
        W = fit_softmax((X - mu) / sd, y, w)
        P = predict_proba(W, (Xt - mu) / sd)
        T = transitions([yy for _, yy in tr])
        if mode == "argmax": path = P.argmax(1)
        elif mode == "hmm":  # posterior / training prior = likelihood
            eff = prior ** (1 - balance); eff /= eff.sum()
            path = viterbi(P, T, eff)
        mt = yt >= 0; allp.append(path[mt]); ally.append(yt[mt])
    p, y = np.concatenate(allp), np.concatenate(ally)
    return (p == y).mean(), kappa(p, y), (np.bincount(p, minlength=4) / 2).astype(int)
for balance in (0.0, 0.5):
    for mode in ("argmax", "hmm"):
        acc, k, mins = run(balance, mode)
        print(f"balance {balance} {mode:6s}: accuracy {acc:.3f} kappa {k:.3f} minutes {mins}")
