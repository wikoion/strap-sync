"""The GRU (gru.py) trained on the ECG nights alone, its stage probabilities written where
rotation_cv.py looks for them (<out>-gru.npz: each DREAMT night's, in load() order, and the MG
28->29 Oct night's), so they can be fused with rotation and averaged with LightGBM in a process
without torch. The GRU only sees the heart columns: trained without rotation or temperature, it has
never learned what they mean. The trained net is kept in <out>-gru.pt, so a rerun resumes.
Usage: gru_probs.py <out> <ECG source> <dreamt npz dir> <strap sync.sqlite> <raw archive .bin>.
Needs torch (and not lightgbm: they deadlock in one process on macOS)."""
import numpy as np, sys, os, sqlite3, warnings
warnings.filterwarnings("ignore")
sys.path.insert(0, os.path.dirname(__file__))
import torch
from gru import prep, train, proba, Net, heart_only
from hrv import rr_series, features
from sources import load
import mg
out, ecg_src, dreamt_dir, whoop_db, raw = sys.argv[1:6]
N0, N1 = 1793232665, 1793268846

ecg = [(prep(x), y) for x, y, _ in load(ecg_src)]
if os.path.exists(out + "-gru.pt"):
    net = Net(ecg[0][0].shape[1]); net.load_state_dict(torch.load(out + "-gru.pt"))
else:
    net = train(ecg); torch.save(net.state_dict(), out + "-gru.pt")
dr = [prep(heart_only(x)) for x, _, _ in load(dreamt_dir)]
db = sqlite3.connect(f"file:{whoop_db}?mode=ro", uri=True)
r = np.array(db.execute("SELECT ts, ms FROM rr WHERE source = 2 AND ts >= ? AND ts < ? ORDER BY ts, idx", (N0 - 600, N1 + 600)).fetchall(), float)
beats = mg.beats(r[:, 0] - N0, r[:, 1] / 1000); beats = beats[beats >= 0]
n = (N1 - N0) // 30
Xm = features(*rr_series(beats), n, 0, n, mg.gravity(raw, N0, n * 30))[0]
np.savez(out + "-gru.npz", dr=np.array([proba(net, x) for x in dr], dtype=object), mg=proba(net, prep(heart_only(Xm))), prior=np.ones(4) / 4)
print("GRU probabilities for", len(dr), "DREAMT nights and the MG night")
