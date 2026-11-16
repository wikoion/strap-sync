"""Builds the ECG feature cache that gru_cv.py would (the same nights, thinning seeds and order), using
every core. Usage: ecg_cache.py <cache .npz> <beats dir>..."""
import numpy as np, glob, sys, os, warnings
from multiprocessing import Pool
sys.path.insert(0, os.path.dirname(__file__))
from hrv import epoch_features, rr_series

def night(args):
    i, p = args
    warnings.filterwarnings("ignore")
    d = np.load(p); y = d["y"]; s = np.where(y > 0)[0]
    if len(s) < 120 or len(rr_series(d["beats"])[0]) < 0.7 * len(d["beats"]): return None
    X, _ = epoch_features(d["beats"], len(y), s[0], s[-1] + 1, np.random.default_rng(i))
    return X, y[s[0]: s[-1] + 1], os.path.basename(p)[:2]

if __name__ == "__main__":
    cache, dirs = sys.argv[1], sys.argv[2:]
    paths = sorted(q for d in dirs for q in glob.glob(d + "/*.npz"))
    with Pool() as pool: out = [r for r in pool.map(night, list(enumerate(paths)), chunksize=4) if r is not None]
    np.savez(cache, nights=np.array([(x, y) for x, y, _ in out], dtype=object), source=np.array([s for *_, s in out]))
    print(len(out), "nights of", len(paths), dict(zip(*np.unique([s for *_, s in out], return_counts=True))))
