"""Writes the GRU (gru.py) the app ships, trained on the open ECG nights, for SyncCore: <model dir>/gru.json
with its weights (PyTorch's layout; gate order r, z, n), the flag columns and the columns it's
trained without. The net is kept in <net .pt>; one already there is used as is (gru_probs.py
writes the same). With <features .npy> and <out .npy>, also writes its stage probabilities for those
feature rows, computed in float64 as the Swift port does. export_model.py runs this in its own
process: torch and LightGBM deadlock in one process on macOS.
Usage: export_gru.py <ECG source> <net .pt> <model dir> [<features .npy> <out .npy>]. Needs torch."""
import numpy as np, json, sys, os, warnings
warnings.filterwarnings("ignore")
sys.path.insert(0, os.path.dirname(__file__))
import torch
from gru import prep, train, Net, heart_only, FLAGS
from sources import load
src, net_path, model_dir = sys.argv[1:4]

if os.path.exists(net_path):
    net = Net(46 + len(FLAGS)); net.load_state_dict(torch.load(net_path))
else:
    net = train([(prep(x), y) for x, y, _ in load(src)]); torch.save(net.state_dict(), net_path)
net = net.double().eval()
sd = {k: v.numpy().tolist() for k, v in net.state_dict().items()}
cell = lambda l, s: {"w_ih": sd[f"gru.weight_ih_l{l}{s}"], "w_hh": sd[f"gru.weight_hh_l{l}{s}"],
                     "b_ih": sd[f"gru.bias_ih_l{l}{s}"], "b_hh": sd[f"gru.bias_hh_l{l}{s}"]}
masked = [j for j in range(46) if np.isnan(heart_only(np.zeros((1, 46)))[0, j])]
json.dump({"input": {"weight": sd["inp.0.weight"], "bias": sd["inp.0.bias"]},
           "layers": [{"forward": cell(l, ""), "reverse": cell(l, "_reverse")} for l in range(2)],
           "output": {"weight": sd["out.weight"], "bias": sd["out.bias"]}, "flags": FLAGS, "masked": masked},
          open(f"{model_dir}/gru.json", "w"), separators=(",", ":"))
print("gru.json:", os.path.getsize(f"{model_dir}/gru.json"), "bytes")
if len(sys.argv) > 5:
    with torch.no_grad():
        P = torch.softmax(net(torch.from_numpy(prep(heart_only(np.load(sys.argv[4])), np.float64))[None])[0], -1)
    np.save(sys.argv[5], P.numpy())
