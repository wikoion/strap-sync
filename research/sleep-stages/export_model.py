"""Trains the stager the app ships and writes it for SyncCore:
  heart     the mean of two models on the open ECG nights, HMC (CC BY 4.0) and CinC 2018 (ODC-By),
            beats thinned to the MG's coverage: both LightGBM stages (stack.py) and the GRU (gru.py,
            written by export_gru.py in its own process)
  movement  one LightGBM over the wrist-rotation columns alone (hrv.rotation()), on open Apple Watch
            nights: sleep-accel and BIDSleep (ODC-By). Fused into the heart's probabilities
            (model.fuse: wake against sleep only, weight MOVE_WEIGHT) before the Viterbi pass.
DREAMT and Wearanize+ never go in: DREAMT's DUA rules out shipping models trained on it, and Wearanize+'s
terms allow scientific research only. Both stay for evaluation.
  <model dir>/stage1.txt, stage2.txt, move.txt   LightGBM text models
  <model dir>/gru.json     the GRU's weights
  <model dir>/model.json   transitions, Viterbi temper, fusion prior and weight, feature count, provenance
plus a parity fixture for the Swift tests: three hours of HMC SN003 as MG-style RR records (three
gaps), three hours of an open Apple Watch night's gravity as per-second records (a 1-min and a 5-min
gap: epochs inside them have no rotation and stay heart-only), and what
this code computes from them (features, each model's probabilities, the fused ones, stages).
The version is the date and time (YYYY-MM-DD.HHMM), so its digits keep growing for Health.
Usage: export_model.py <heart source>[,<heart source>...] <hmc beats dir> <model dir> <fixture .json | -> <GRU net .pt>
       <wrist npz dir>...  Heart sources may be any sources.py source (their rotation and temperature
       are dropped); wrist dirs give the rotation model its nights. "-" skips the fixture.
Needs lightgbm (and torch for export_gru.py)."""
import numpy as np, json, sys, os, glob, warnings, datetime, subprocess, tempfile
warnings.filterwarnings("ignore")
sys.path.insert(0, os.path.dirname(__file__))
from model import transitions, fuse
from mlp import tempered_viterbi
from hrv import rr_series, features, FREQS
from sources import load
from stack import fit, oof, context
import mg
src, hmc_dir, model_dir, fixture, net = sys.argv[1:6]; wrist_dirs = sys.argv[6:]
ALPHA, MOVE_WEIGHT, WAKE_ONLY = 0.5, 0.5, True
NAMES = {"SN": "HMC sleep staging database (PhysioNet, CC BY 4.0)", "tr": "PhysioNet/CinC Challenge 2018 (ODC-By 1.0)",
         "WZ": "Wearanize+ OA (Radboud Data Repository, research use only)", "DR": "DREAMT (PhysioNet Restricted Health Data License 1.5.0)",
         "SA": "sleep-accel (PhysioNet, ODC-By 1.0)", "BS": "BIDSleep (PhysioNet, ODC-By 1.0)", "NC": "Newcastle PSG + accelerometer (Zenodo, CC BY 4.0)"}

cols = features(np.empty(0), np.empty(0), np.empty(0, int), 200, 0, 200)[1]
rot = np.array([c.startswith("rot") for c in cols]); heart_cols = ~np.array([c.startswith(("rot", "temp")) for c in cols])
heart = [(x, y, s) for h in src.split(",") for x, y, s in load(h)]
aw = [(x, y, s) for d in wrist_dirs for x, y, s in load(d)]
aw = [(x, y, s) for x, y, s in aw if np.isfinite(x[:, cols.index("rot")]).mean() > 0.5]   # e.g. Wearanize+ nights without the E4
assert aw and all(s in NAMES for *_, s in aw), "movement needs wrist nights (wrist_night.py)"
# Evaluation only, never in shipped weights: Wearanize+ (research use only) and DREAMT (its DUA).
RESEARCH_ONLY = {"WZ", "DR"}
assert not RESEARCH_ONLY & {s for *_, s in heart + aw}, "Wearanize+ and DREAMT are for evaluation only: leave them out"
def provenance(rows):
    tags = [s for *_, s in rows]
    return f"{len(rows)} nights: " + "; ".join(f"{NAMES.get(t, t)} ({tags.count(t)})" for t in dict.fromkeys(tags))
trained_on = (f"heart LightGBM: {provenance(heart)}, ECG beats thinned to the MG's coverage; heart GRU: {os.path.basename(net)}; "
              f"movement: {provenance(aw)}")
nights = [(np.where(heart_cols, x, np.nan), y) for x, y, _ in heart]
aw = [(np.where(rot, x, np.nan), y) for x, y, _ in aw]
c1 = fit(nights); P = oof(nights)
c2 = fit([(context(p, x), y) for p, (x, y) in zip(P, nights)])
cm = fit(aw); prior = np.mean(np.vstack([cm.predict_proba(x) for x, _ in aw]), 0)
T = transitions([y for _, y in nights])
os.makedirs(model_dir, exist_ok=True)
for name, c in (("stage1", c1), ("stage2", c2), ("move", cm)):
    open(f"{model_dir}/{name}.txt", "w").write(c.booster_.model_to_string())
json.dump({"version": datetime.datetime.now().strftime("%Y-%m-%d.%H%M"), "features": nights[0][0].shape[1], "epoch_seconds": 30,
           "freqs": FREQS.tolist(),                       # np.arange's own values: the LF/HF edge depends on them
           "transitions": T.round(8).tolist(), "temper": ALPHA, "stages": ["wake", "light", "deep", "rem"],
           "heart": "mean of stage2 and gru", "move": {"prior": prior.tolist(), "weight": MOVE_WEIGHT, "wake_only": WAKE_ONLY},
           "trained_on": trained_on},
          open(f"{model_dir}/model.json", "w"), indent=1)

def gru(X):
    """export_gru.py in its own process: writes gru.json, and returns the GRU's probabilities for X."""
    if X is None:
        subprocess.run([sys.executable, "-I", os.path.join(os.path.dirname(os.path.abspath(__file__)), "export_gru.py"), src, net, model_dir], check=True)
        return None
    with tempfile.TemporaryDirectory() as tmp:
        np.save(f"{tmp}/x.npy", X)
        subprocess.run([sys.executable, "-I", os.path.join(os.path.dirname(os.path.abspath(__file__)), "export_gru.py"),
                        src, net, model_dir, f"{tmp}/x.npy", f"{tmp}/p.npy"], check=True)
        return np.load(f"{tmp}/p.npy")

if fixture == "-":
    gru(None); print("model:", {f: os.path.getsize(f"{model_dir}/{f}") for f in os.listdir(model_dir)}); sys.exit(0)

# Fixture. RR: SN003's beats from its first sleep epoch, three hours, as 1-s records with three gaps.
d = np.load(f"{hmc_dir}/SN003.npz"); y = d["y"]; t0 = np.where(y > 0)[0][0] * 30
b = d["beats"]; b = b[(b >= t0) & (b < t0 + 3 * 3600)] - t0
for g in (1800.0, 4000.0, 7000.0):                        # 30-s holes, like the MG's
    b = b[(b < g) | (b >= g + 30)]
rr = np.diff(b); ts = np.floor(b[1:]).astype(int); ms = np.round(rr * 1000).astype(int)
idx = np.zeros(len(ts), int)
for k in range(1, len(ts)): idx[k] = idx[k - 1] + 1 if ts[k] == ts[k - 1] else 0
keep = ms < 3000                                          # the MG never reports the long gap intervals
ts, idx, ms = ts[keep], idx[keep], ms[keep]
n = 3 * 3600 // 30
# Gravity: the first open Apple Watch night with gravity for all of its first three hours asleep,
# rounded to 1e-6 g, with a 1-min and a 5-min hole.
for p in sorted(q for dd in wrist_dirs for q in glob.glob(dd + "/*.npz")):
    w = np.load(p); s0 = np.where(w["y"] > 0)[0][0] * 30; G = np.round(w["grav"][s0: s0 + n * 30], 6)
    if len(G) == n * 30 and np.isfinite(G).all(): break
gsec = np.arange(n * 30); gk = ~(((gsec >= 2000) & (gsec < 2060)) | ((gsec >= 6000) & (gsec < 6300)))
grav = np.full((n * 30, 3), np.nan); grav[gk] = G[gk]
X, cols = features(*rr_series(mg.beats(ts.astype(float), ms / 1000)), n, 0, n, grav)
p1 = c1.predict_proba(X); p2 = c2.predict_proba(context(p1, X)); pm = cm.predict_proba(np.where(rot, X, np.nan))
pg = gru(X); ph = (p2 + pg) / 2
pf = fuse(ph, pm, prior, MOVE_WEIGHT, WAKE_ONLY, np.isfinite(X[:, cols.index("rot")])); path = tempered_viterbi(pf, T, ALPHA)
print("model:", {f: os.path.getsize(f"{model_dir}/{f}") for f in os.listdir(model_dir)})
nan = lambda a: [[None if not np.isfinite(v) else float(v) for v in row] for row in a]
json.dump({"source": "HMC sleep staging database SN003 (PhysioNet, CC BY 4.0), 3 h from sleep onset; gravity from "
                     f"{os.path.basename(p)[:-4]}, 3 h from sleep onset ({'BIDSleep' if os.path.basename(p).startswith('BS') else 'sleep-accel'}, PhysioNet, ODC-By)",
           "epochs": n, "records": np.c_[ts, idx, ms].tolist(), "gravity": [[int(t), *map(float, G[t])] for t in gsec[gk]],
           "columns": cols, "features": nan(X), "stage1": nan(p1), "stage2": nan(p2), "gru": nan(pg), "move": nan(pm), "fused": nan(pf),
           "stages": path.tolist()},
          open(fixture, "w"), separators=(",", ":"))
print("fixture:", os.path.getsize(fixture), "bytes;", len(ts), "records,", gk.sum(), "gravity seconds from", os.path.basename(p),
      "; stages", np.bincount(path, minlength=4), "(heart alone %s)" % np.bincount(tempered_viterbi(ph, T, ALPHA), minlength=4))
