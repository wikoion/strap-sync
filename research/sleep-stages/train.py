import numpy as np, glob, sys, os
sys.path.insert(0, os.path.dirname(__file__))
from model import *
nights = []
for p in sorted(glob.glob(sys.argv[1] + "/*.npz")):
    d = np.load(p); X = epoch_features(d["hr"], d["motion"]); y = d["y"][: len(X)]
    nights.append((os.path.basename(p), X, y))
print(len(nights), "nights,", sum(len(y) for _, _, y in nights), "epochs")
allp, ally = [], []
per = []
for i, (sid, Xt, yt) in enumerate(nights):
    tr = [n for j, n in enumerate(nights) if j != i]
    X = np.vstack([x for _, x, y in tr]); y = np.concatenate([y for _, x, y in tr])
    m = y >= 0; X, y = X[m], y[m]
    mu, sd = X.mean(0), X.std(0) + 1e-6
    prior = np.bincount(y, minlength=4) / len(y)
    w = (1 / prior)[y] ** 0.5                       # partly balance the classes
    W = fit_softmax((X - mu) / sd, y, w)
    T = transitions([yy for _, _, yy in tr])
    P = predict_proba(W, (Xt - mu) / sd)
    path = viterbi(P, T, prior)
    mt = yt >= 0
    allp.append(path[mt]); ally.append(yt[mt])
    per.append(((path[mt] == yt[mt]).mean(), kappa(path[mt], yt[mt])))
p, y = np.concatenate(allp), np.concatenate(ally)
print("LOSO accuracy %.3f, kappa %.3f" % ((p == y).mean(), kappa(p, y)))
print("per-night median accuracy %.3f, median kappa %.3f" % tuple(np.median(np.array(per), 0)))
print("baseline all-light accuracy %.3f" % (y == 1).mean())
cm = np.zeros((4, 4), int)
for a, b in zip(y, p): cm[a, b] += 1
print("confusion (rows truth wake/light/deep/rem, cols predicted):\n", cm)
print("minutes predicted vs truth:", (np.bincount(p, minlength=4) / 2).astype(int), (np.bincount(y, minlength=4) / 2).astype(int))
