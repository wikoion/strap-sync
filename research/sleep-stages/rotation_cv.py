"""Does wrist rotation (hrv.rotation()) help, and does it carry over to the MG? All LightGBM:
  heart       both stages on the ECG nights: what the app ships
  fused       heart, times a rotation-only model trained on the open Apple Watch nights
              (sleep-accel, BIDSleep): P ~ P_heart * (P_move / prior_move)^w
  fused wake  same, but rotation only shifts wake against sleep, not one sleep stage against another
  joint       both stages on the ECG nights plus the Apple Watch nights (their HR and rotation)
  joint+DR    joint plus the other DREAMT folds. Research only: DREAMT's DUA rules out shipping it.
  GRU         the GRU (gru.py) on the ECG nights, when gru_probs.py has left <out>-gru.npz; alone,
              averaged with heart ("ensemble"), and either fused with rotation
Scored on DREAMT's nights (E4 beats and rotation, a different wrist device; only joint+DR has seen
any of them), then each model stages the MG's 28->29 Oct night from history RR plus the raw
archive's gravity, against the Fitbit Air. Temperature is left out throughout. Each model's
probabilities are kept in <out>-<model>.npz, so a rerun resumes; delete them when inputs change.
SKIP_JOINT=1 in the environment leaves out joint and joint+DR (the slowest, and research only).
Usage: rotation_cv.py <out> <ECG source> <dreamt npz dir> <strap sync.sqlite> <dashboard health.db>
       <raw archive .bin> <Apple Watch npz dir>...  Needs lightgbm."""
import numpy as np, sys, os, sqlite3, warnings
warnings.filterwarnings("ignore")
sys.path.insert(0, os.path.dirname(__file__))
from model import kappa, transitions, fuse
from mlp import tempered_viterbi
from hrv import rr_series, features
from sources import load
from stack import fit, fit_two
import mg
out, ecg_src, dreamt_dir, whoop_db, hd_db, raw = sys.argv[1:7]; wrist_dirs = sys.argv[7:]
N0, N1 = 1793232665, 1793268846                          # band sleep flag (state 2): 00:11-10:14 UTC
W = (0.5, 1.0)                                           # fusion weights tried

COLS = features(np.empty(0), np.empty(0), np.empty(0, int), 200, 0, 200)[1]
ROT = [j for j, c in enumerate(COLS) if c.startswith("rot")]
HEART = [j for j, c in enumerate(COLS) if not c.startswith(("rot", "temp"))]
NO_TEMP = [j for j, c in enumerate(COLS) if not c.startswith("temp")]
def has(X): return np.isfinite(X[:, ROT[0]])
def mask(X, keep): return np.where(np.isin(np.arange(X.shape[1]), keep), X, np.nan)
def masked(data, keep): return [(mask(x, keep), y) for x, y in data]

ecg = [(x, y) for x, y, _ in load(ecg_src)]
dr = [(x, y) for x, y, _ in load(dreamt_dir)]
aw = [(x, y, s) for d in wrist_dirs for x, y, s in load(d)]
tags = sorted(set(s for *_, s in aw))
print(len(ecg), "ECG nights,", len(dr), "DREAMT nights,", len(aw), "Apple Watch nights", {t: sum(s == t for *_, s in aw) for t in tags}, flush=True)
aw = [(x, y) for x, y, _ in aw]
T = transitions([y for _, y in ecg])

# The MG night: history RR from the DB, gravity from the raw archive.
db = sqlite3.connect(f"file:{whoop_db}?mode=ro", uri=True)
r = np.array(db.execute("SELECT ts, ms FROM rr WHERE source = 2 AND ts >= ? AND ts < ? ORDER BY ts, idx", (N0 - 600, N1 + 600)).fetchall(), float)
beats = mg.beats(r[:, 0] - N0, r[:, 1] / 1000); beats = beats[beats >= 0]
n = (N1 - N0) // 30
Xm = features(*rr_series(beats), n, 0, n, mg.gravity(raw, N0, n * 30))[0]
print("MG night: rotation in %.0f%% of epochs; a >5 degree turn in %.1f%% of them" % (
    100 * np.isfinite(Xm[:, COLS.index("rot")]).mean(), 100 * np.nanmean(Xm[:, COLS.index("rot")] > 0)), flush=True)

def cached(name, make):
    """make() -> (list of DREAMT probability arrays, MG probabilities[, the model's training prior])."""
    f = f"{out}-{name}.npz"
    if not os.path.exists(f):
        pd, pm, *prior = make(); np.savez(f, dr=np.array(pd, dtype=object), mg=pm, prior=prior[0] if prior else np.ones(4) / 4)
    z = np.load(f, allow_pickle=True); assert len(z["dr"]) == len(dr), f"{f} is for other DREAMT nights: delete it"
    return list(z["dr"]), z["mg"], z["prior"]

def make_heart():
    h, _ = fit_two(ecg)
    return [h(mask(x, HEART)) for x, _ in dr], h(mask(Xm, HEART))
def make_move():
    m = fit(masked(aw, ROT)); prior = np.mean(np.vstack([m.predict_proba(x) for x, _ in masked(aw, ROT)]), 0)
    return [m.predict_proba(mask(x, ROT)) for x, _ in dr], m.predict_proba(mask(Xm, ROT)), prior
def make_joint():
    j, _ = fit_two(ecg + masked(aw, NO_TEMP))
    return [j(mask(x, NO_TEMP)) for x, _ in dr], j(mask(Xm, NO_TEMP))
def make_joint_dr():
    order = np.random.default_rng(0).permutation(len(dr)); pd = [None] * len(dr)
    for f in range(5):
        done = f"{out}-joint_dr-fold{f}.npz"
        if not os.path.exists(done):
            test = set(order[f::5]); j, _ = fit_two(ecg + masked(aw, NO_TEMP) + masked([dr[i] for i in order if i not in test], NO_TEMP))
            np.savez(done, p=np.array([j(mask(dr[i][0], NO_TEMP)) for i in order[f::5]], dtype=object))
        for i, p in zip(order[f::5], np.load(done, allow_pickle=True)["p"]): pd[i] = p
        print("joint+DR fold", f, "done", flush=True)
    j, _ = fit_two(ecg + masked(aw, NO_TEMP) + masked(dr, NO_TEMP))
    return pd, j(mask(Xm, NO_TEMP))

heart = cached("heart", make_heart)[:2]; print("heart done", flush=True)
models = {"heart": heart}
if aw:
    *move, prior = cached("move", make_move)
    for w in W:
        for wake_only in (False, True):
            models["fused%s w%.1f" % (" wake" if wake_only else "", w)] = (
                [fuse(a, b, prior, w, wake_only, has(x)) for a, b, (x, _) in zip(heart[0], move[0], dr)], fuse(heart[1], move[1], prior, w, wake_only, has(Xm)))
    if not os.environ.get("SKIP_JOINT"): models["joint"] = cached("joint", make_joint)[:2]; print("joint done", flush=True)
if not os.environ.get("SKIP_JOINT"): models["joint+DR"] = cached("joint_dr", make_joint_dr)[:2]
if os.path.exists(f"{out}-gru.npz"):
    gru = cached("gru", None)[:2]
    ens = ([(a + b) / 2 for a, b in zip(heart[0], gru[0])], (heart[1] + gru[1]) / 2)
    for name, m in (("GRU", gru), ("ensemble", ens)):
        models[name] = m
        if aw:
            for w in W:
                models["%s wake w%.1f" % (name, w)] = ([fuse(a, b, prior, w, True, has(x)) for a, b, (x, _) in zip(m[0], move[0], dr)],
                                                       fuse(m[1], move[1], prior, w, True, has(Xm)))

def bouts(s):
    """Runs of wake (s == 0) as (start, end) epoch pairs."""
    d = np.diff(np.r_[0, (s == 0).astype(int), 0]); return list(zip(np.where(d == 1)[0], np.where(d == -1)[0]))

def wake_scores(pp, yy):
    """Epoch wake sensitivity and precision; recall of true wake bouts up to 5 minutes (hit when a
    predicted wake epoch is within one epoch); share of predicted wake bouts near any true wake."""
    p, y = np.concatenate(pp), np.concatenate(yy); hit_t = tot_t = hit_p = tot_p = 0
    for a, b in zip(pp, yy):
        for s, e in bouts(b):
            if e - s <= 10: tot_t += 1; hit_t += (a[max(0, s - 1): e + 1] == 0).any()
        for s, e in bouts(a): tot_p += 1; hit_p += (b[max(0, s - 1): e + 1] == 0).any()
    return (np.mean(p[y == 0] == 0), np.mean(y[p == 0] == 0) if (p == 0).any() else np.nan, hit_t / max(tot_t, 1), hit_p / max(tot_p, 1), tot_p / len(pp))

hd = sqlite3.connect(f"file:{hd_db}?mode=ro", uri=True)
segs = hd.execute("SELECT stage, start_utc/1000, end_utc/1000 FROM sleep_segments WHERE session_id = 11076 AND stage IN ('core','deep','rem','awake')").fetchall()
code = {"awake": 0, "core": 1, "deep": 2, "rem": 3}; fb = np.full(n, -1); mid = N0 + np.arange(n) * 30 + 15
for s, a, b in segs: fb[(mid >= a) & (mid < b)] = code[s]
mk = fb >= 0; sym = "wLDR"
rot = np.nan_to_num(Xm[:, COLS.index("rot")]); big = np.nan_to_num(Xm[:, COLS.index("rot_big")])

print("\nDREAMT, %d nights (sleep period). wake: epoch sensitivity / precision, recall of true bouts <= 5 min, "
      "share of predicted bouts near true wake, predicted bouts per night" % len(dr))
yy = [y[y >= 0] for _, y in dr]
for k, (pd, _) in models.items():
    pp = [tempered_viterbi(P, T, 0.5)[y >= 0] for P, (_, y) in zip(pd, dr)]
    p, y = np.concatenate(pp), np.concatenate(yy)
    print("  %-15s accuracy %.3f kappa %.3f (per-night median %.3f); minutes %s vs truth %s; wake %.2f / %.2f, %.2f, %.2f, %.1f" % (
        k, (p == y).mean(), kappa(p, y), np.median([kappa(a, b) for a, b in zip(pp, yy)]),
        (np.bincount(p, minlength=4) / 2).astype(int), (np.bincount(y, minlength=4) / 2).astype(int), *wake_scores(pp, yy)))

print("\nMG night vs Fitbit (Fitbit minutes %s). Wake bouts: UTC start, minutes, turns in them (share of 5-s steps > 5 degrees)"
      % (np.bincount(fb[mk], minlength=4) / 2).astype(int))
for k, (_, pm) in models.items():
    path = tempered_viterbi(pm, T, 0.5); b = bouts(path)
    moved = sum(rot[max(0, s - 1): e + 1].max() > 0 for s, e in b)
    print("  %-15s accuracy %.3f kappa %.3f; minutes %s; %d wake bouts, %d at a turn" % (k, (path[mk] == fb[mk]).mean(), kappa(path[mk], fb[mk]),
          (np.bincount(path, minlength=4) / 2).astype(int), len(b), moved))
    print("     ", " ".join("%s %g%s" % (np.datetime64(int(N0 + 30 * s), "s").astype(str)[11:16], (e - s) / 2, "*" if rot[max(0, s - 1): e + 1].max() > 0 else "")
                         for s, e in b))
    print("     ", "".join(sym[s] for s in path[::10]))
print("  Fitbit         ", "".join(sym[s] if s >= 0 else "." for s in fb[::10]))
print("  turns >30 deg  ", "".join("|" if big[i: i + 10].max() > 0 else ("'" if rot[i: i + 10].max() > 0 else " ") for i in range(0, n, 10)))
