"""Scores a candidate model the way the app runs it: <model dir> as export_model.py writes it (both
LightGBM stages, the rotation model, model.json) plus its GRU (<net .pt>, run by gru_predict.py in its
own process), the mean of the two heart models fused with rotation, then the tempered Viterbi pass.
Each held-out source is scored per 30-s epoch over its sleep period (sources.py); with --mg, also the
owner's nights in a Strap Sync DB against the Fitbit in a Health Dashboard DB (agreement only).
--save <file.npz> keeps each night's predicted and true stages, to pool folds (pool.py).
Usage: evaluate.py <model dir> <net .pt> <source>... [--mg <sync.sqlite> <dashboard db>] [--save <file.npz>]. Needs lightgbm."""
import numpy as np, sys, os, json, sqlite3, subprocess, tempfile, warnings
warnings.filterwarnings("ignore")
sys.path.insert(0, os.path.dirname(__file__))
import lightgbm as lgb
from model import kappa, fuse
from mlp import tempered_viterbi
from hrv import rr_series, features
from sources import load
from stack import context
import mg
args = sys.argv[1:]
mg_dbs = args[args.index("--mg") + 1: args.index("--mg") + 3] if "--mg" in args else None
if mg_dbs: del args[args.index("--mg"): args.index("--mg") + 3]
save = args[args.index("--save") + 1] if "--save" in args else None
if save: del args[args.index("--save"): args.index("--save") + 2]
saved = {"p": [], "y": [], "src": []}
model_dir, net, srcs = args[0], args[1], args[2:]
c = json.load(open(f"{model_dir}/model.json")); T = np.array(c["transitions"])
b1, b2, bm = (lgb.Booster(model_file=f"{model_dir}/{k}.txt") for k in ("stage1", "stage2", "move"))
cols = features(np.empty(0), np.empty(0), np.empty(0, int), 200, 0, 200)[1]
rot = np.array([k.startswith("rot") for k in cols]); heart_cols = ~np.array([k.startswith(("rot", "temp")) for k in cols])

def gru(Xs):
    with tempfile.TemporaryDirectory() as tmp:
        arr = np.empty(len(Xs), object); arr[:] = Xs                 # np.array(Xs) of one night would be 3-D
        np.savez(f"{tmp}/x.npz", nights=arr)
        subprocess.run([sys.executable, "-I", os.path.join(os.path.dirname(os.path.abspath(__file__)), "gru_predict.py"), net, f"{tmp}/x.npz", f"{tmp}/p.npz"], check=True)
        return [np.asarray(p, float) for p in np.load(f"{tmp}/p.npz", allow_pickle=True)["p"]]

def stage(Xs):
    pg = gru(Xs); out = []
    for X, g in zip(Xs, pg):
        Xh = np.where(heart_cols, X, np.nan); p1 = b1.predict(Xh); p2 = b2.predict(context(p1, Xh))
        P = fuse((p2 + g) / 2, bm.predict(np.where(rot, X, np.nan)), np.array(c["move"]["prior"]), c["move"]["weight"], c["move"]["wake_only"],
                 np.isfinite(X[:, cols.index("rot")]))
        out.append(tempered_viterbi(P, T, c["temper"]))
    return out

def report(name, pp, yy):
    p, y = np.concatenate(pp), np.concatenate(yy)
    f1 = lambda k: 2 * np.sum((p == k) & (y == k)) / max(1, np.sum(p == k) + np.sum(y == k))
    print("%-18s %3d nights: accuracy %.3f kappa %.3f (per-night median %.3f); wake sens %.2f prec %.2f; F1 deep %.2f REM %.2f; minutes %s vs %s" % (
        name, len(pp), (p == y).mean(), kappa(p, y), np.median([kappa(a, b) for a, b in zip(pp, yy)]),
        np.mean(p[y == 0] == 0), np.mean(y[p == 0] == 0) if (p == 0).any() else np.nan, f1(2), f1(3),
        (np.bincount(p, minlength=4) / 2).astype(int), (np.bincount(y, minlength=4) / 2).astype(int)), flush=True)

print("model", c["version"], "| heart", c["trained_on"][:160])
for s in srcs:
    nights = load(s); paths = stage([x for x, _, _ in nights])
    m = [y >= 0 for _, y, _ in nights]
    report(os.path.basename(s.rstrip("/")), [p[k] for p, k in zip(paths, m)], [y[k] for (_, y, _), k in zip(nights, m)])
    saved["p"] += [p[k] for p, k in zip(paths, m)]; saved["y"] += [y[k] for (_, y, _), k in zip(nights, m)]; saved["src"] += [s] * len(nights)
    withg = [i for i, (x, _, _) in enumerate(nights) if np.isfinite(x[:, cols.index("rot")]).mean() > 0.5]
    if 0 < len(withg) < len(nights):
        report("  with wrist", [paths[i][m[i]] for i in withg], [nights[i][1][m[i]] for i in withg])

if mg_dbs:
    db = sqlite3.connect(f"file:{mg_dbs[0]}?mode=ro", uri=True); hd = sqlite3.connect(f"file:{mg_dbs[1]}?mode=ro", uri=True)
    code = {"awake": 0, "core": 1, "deep": 2, "rem": 3}
    for start, end in db.execute("SELECT start, end FROM stages ORDER BY start").fetchall():
        n = (end - start) // 30
        r = np.array(db.execute("SELECT ts, ms FROM rr WHERE source = 2 AND ts >= ? AND ts < ? ORDER BY ts, idx", (start - 600, end + 600)).fetchall(), float)
        b = mg.beats(r[:, 0] - start, r[:, 1] / 1000); b = b[b >= 0]
        grav = np.full((n * 30, 3), np.nan)
        for t, *g in db.execute("SELECT ts, gx, gy, gz FROM motion WHERE ts >= ? AND ts < ? AND gx IS NOT NULL", (start, end)): grav[t - start] = g
        path = stage([features(*rr_series(b), n, 0, n, grav)[0]])[0]
        fb = np.full(n, -1); mid = (start + np.arange(n) * 30 + 15) * 1000
        # Health Sync also copies Strap Sync's own stages back into Health under its name (seen from
        # 31 Oct): drop its samples that are exactly one of our runs, which leaves the Fitbit's.
        ours = db.execute("SELECT epochs FROM stages WHERE start = ?", (start,)).fetchone()
        runs = set()
        if ours:
            e = np.array([int(ch) for ch in ours[0]]); k = np.r_[0, np.where(np.diff(e))[0] + 1, len(e)]
            runs = {(1000 * (start + 30 * a), 1000 * (start + 30 * b), int(e[a])) for a, b in zip(k[:-1], k[1:])}
        copied = 0
        for st, a, e in hd.execute("SELECT method, start_utc, end_utc FROM samples WHERE type = 'sleep_stage' AND source_bundle = 'nl.appyhapps.healthsync' "
                                   "AND method != 'in_bed' AND start_utc < ? AND end_utc > ?", (end * 1000, start * 1000)):
            if (a, e, code[st]) in runs: copied += 1; continue
            fb[(mid >= a) & (mid < e)] = code[st]
        if copied: print("  (left out %d Health Sync samples that are copies of Strap Sync's own stages)" % copied)
        k = fb >= 0
        print("MG night from %s: agreement with the Fitbit %.1f%%, kappa %.3f; minutes %s (Fitbit %s); gravity in %.0f%% of seconds" % (
            np.datetime64(int(start), "s"), 100 * (path[k] == fb[k]).mean() if k.any() else np.nan, kappa(path[k], fb[k]) if k.any() else np.nan,
            (np.bincount(path, minlength=4) / 2).astype(int), (np.bincount(fb[k], minlength=4) / 2).astype(int), 100 * np.isfinite(grav[:, 0]).mean()))
if save:
    obj = lambda a: (lambda o: (o.__setitem__(slice(None), a), o)[1])(np.empty(len(a), object))
    np.savez(save, p=obj(saved["p"]), y=obj(saved["y"]), src=np.array(saved["src"]))
