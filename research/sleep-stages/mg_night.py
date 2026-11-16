"""Train the model (both LightGBM stages, stack.py, or with --gru the GRU, gru.py) on the given
sources (sources.py: the ECG feature cache, ECG beats dirs, DREAMT and Apple Watch dirs), then stage the
MG's 28->29 Oct night from its history RR, wrist rotation and skin temperature, and compare with the
Fitbit Air's stages for it. Rotation and temperature are only used when some training nights have
rotation. Gravity comes from the DB's gx/gy/gz (app builds from 29 Oct) or from a raw archive
(--raw <file>, for DBs from before).
LightGBM and torch each bring their own OpenMP and deadlock in one process on macOS, so a run
imports only one of them.
Usage: mg_night.py [--gru] [--raw <archive .bin>] <source>... <strap sync.sqlite> <dashboard health.db>."""
import numpy as np, sys, os, sqlite3, warnings
warnings.filterwarnings("ignore")
sys.path.insert(0, os.path.dirname(__file__))
from model import kappa, transitions
from mlp import tempered_viterbi
from hrv import rr_series, features
from sources import load
import mg
args = sys.argv[1:]; use_gru = "--gru" in args; args = [a for a in args if a != "--gru"]
raw = args[args.index("--raw") + 1] if "--raw" in args else None
if raw: del args[args.index("--raw"): args.index("--raw") + 2]
*srcs, whoop_db, hd_db = args
if use_gru: from gru import prep, train, predict
else: from stack import fit_two
N0, N1 = 1793232665, 1793268846                          # band sleep flag (state 2): 00:11-10:14 UTC

tr = [(x, y) for src in srcs for x, y, _ in load(src)]
wrist = any(np.isfinite(x[:, 30]).any() for x, _ in tr)    # any training night with rotation
if use_gru: net = train([(prep(x), y) for x, y in tr])
else: two, c1 = fit_two(tr)
T = transitions([y for _, y in tr])
print("trained on", len(tr), "nights,", "with" if wrist else "without", "rotation and skin temperature")

db = sqlite3.connect(f"file:{whoop_db}?mode=ro", uri=True)
r = np.array(db.execute("SELECT ts, ms FROM rr WHERE source = 2 AND ts >= ? AND ts < ? ORDER BY ts, idx", (N0 - 600, N1 + 600)).fetchall(), float)
beats = mg.beats(r[:, 0] - N0, r[:, 1] / 1000); beats = beats[beats >= 0]
n = (N1 - N0) // 30
grav, skin = np.full((n * 30, 3), np.nan), np.full(n * 30, np.nan)
has_g = "gx" in [c[1] for c in db.execute("PRAGMA table_info(motion)")]
for t, sk, *g in db.execute(f"SELECT ts, skin{', gx, gy, gz' if has_g else ''} FROM motion WHERE ts >= ? AND ts < ?", (N0, N0 + n * 30)):
    skin[t - N0] = np.nan if sk is None else sk
    if g and None not in g: grav[t - N0] = g
if raw: grav = mg.gravity(raw, N0, n * 30)
Xm, _ = features(*rr_series(beats), n, 0, n, grav if wrist else None, skin if wrist else None)
paths = ({"GRU": predict(net, prep(Xm))} if use_gru else
         {"stage 1": tempered_viterbi(c1.predict_proba(Xm), T, 0.5), "stage 2": tempered_viterbi(two(Xm), T, 0.5)})

hd = sqlite3.connect(f"file:{hd_db}?mode=ro", uri=True)
segs = hd.execute("SELECT stage, start_utc/1000, end_utc/1000 FROM sleep_segments WHERE session_id = 11076 AND stage IN ('core','deep','rem','awake')").fetchall()
code = {"awake": 0, "core": 1, "deep": 2, "rem": 3}; fb = np.full(n, -1)
mid = N0 + np.arange(n) * 30 + 15
for s, a, b in segs: fb[(mid >= a) & (mid < b)] = code[s]
mk = fb >= 0; sym = "wLDR"
for k, path in paths.items():
    print("MG night vs Fitbit, %s: accuracy %.3f kappa %.3f; minutes %s vs Fitbit %s" % (k, (path[mk] == fb[mk]).mean(), kappa(path[mk], fb[mk]),
          (np.bincount(path, minlength=4) / 2).astype(int), (np.bincount(fb[mk], minlength=4) / 2).astype(int)))
    print("ours  ", "".join(sym[s] for s in path[::10]))
print("Fitbit", "".join(sym[s] if s >= 0 else "." for s in fb[::10]))
