"""Pools evaluate.py --save files (e.g. the folds of a cross-validation) and scores them together.
Usage: pool.py <name> <file.npz>... [-- <name> <file.npz>...]"""
import numpy as np, sys, os
sys.path.insert(0, os.path.dirname(__file__))
from model import kappa
groups, cur = [], None
for a in sys.argv[1:]:
    if a == "--": cur = None; continue
    if cur is None: cur = (a, []); groups.append(cur)
    else: cur[1].append(a)
for name, files in groups:
    pp = [p for f in files for p in np.load(f, allow_pickle=True)["p"]]; yy = [y for f in files for y in np.load(f, allow_pickle=True)["y"]]
    p, y = np.concatenate(pp).astype(int), np.concatenate(yy).astype(int)
    f1 = lambda k: 2 * np.sum((p == k) & (y == k)) / max(1, np.sum(p == k) + np.sum(y == k))
    print("%-24s %3d nights: accuracy %.3f kappa %.3f (per-night median %.3f); wake sens %.2f prec %.2f; F1 deep %.2f REM %.2f; minutes %s vs %s" % (
        name, len(pp), (p == y).mean(), kappa(p, y), np.median([kappa(a, b) for a, b in zip(pp, yy)]), np.mean(p[y == 0] == 0),
        np.mean(y[p == 0] == 0), f1(2), f1(3), (np.bincount(p, minlength=4) / 2).astype(int), (np.bincount(y, minlength=4) / 2).astype(int)))
