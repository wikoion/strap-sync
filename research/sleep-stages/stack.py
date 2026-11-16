"""The two LightGBM stages: per-epoch features, then a second pass over the first stage's stage
probabilities at neighbouring epochs (up to +-20 min) and their rolling means. The second stage
trains on inner-fold (out-of-fold) probabilities so it learns from honest inputs."""
import numpy as np
import lightgbm as lgb
from model import window_mean

def fit(data):
    X = np.vstack([x for x, _ in data]); y = np.concatenate([y for _, y in data]); m = y >= 0
    prior = np.bincount(y[m], minlength=4) / m.sum()
    clf = lgb.LGBMClassifier(n_estimators=300, learning_rate=0.06, num_leaves=31, min_child_samples=200,
                             subsample=0.8, subsample_freq=1, colsample_bytree=0.8, verbose=-1)
    return clf.fit(X[m], y[m], sample_weight=(1 / prior[y[m]]) ** 0.5)

def context(P, X):
    n = len(P); f = [X, P]
    for o in (1, 2, 5, 10, 20, 40):
        f += [np.vstack([P[:1]] * o + [P[:-o]]) if o < n else np.repeat(P[:1], n, 0),
              np.vstack([P[o:]] + [P[-1:]] * o) if o < n else np.repeat(P[-1:], n, 0)]
    for h in (2, 5, 10, 20, 40):
        f.append(np.vstack([window_mean(P[:, k], h) for k in range(4)]).T)
    return np.hstack(f)

def oof(data, folds=3):
    out = [None] * len(data)
    for f in range(folds):
        clf = fit([data[i] for i in range(len(data)) if i % folds != f])
        for i in range(f, len(data), folds): out[i] = clf.predict_proba(data[i][0])
    return out

def fit_two(data):
    """Returns predict(X) -> stage probabilities from both stages."""
    c1 = fit(data); c2 = fit([(context(P, x), y) for P, (x, y) in zip(oof(data), data)])
    return lambda X: c2.predict_proba(context(c1.predict_proba(X), X)), c1
