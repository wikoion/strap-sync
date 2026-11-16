"""Stage probabilities from a saved GRU for a list of nights: <in .npz> holds "nights" (an object
array of feature matrices); <out .npz> gets "p" (one probability matrix per night).
Usage: gru_predict.py <net .pt> <in .npz> <out .npz>. Needs torch (and not lightgbm)."""
import numpy as np, sys, os, warnings
warnings.filterwarnings("ignore")
sys.path.insert(0, os.path.dirname(__file__))
import torch
from gru import prep, proba, Net, heart_only, FLAGS
net_path, src, out = sys.argv[1:4]
net = Net(46 + len(FLAGS)); net.load_state_dict(torch.load(net_path))
X = np.load(src, allow_pickle=True)["nights"]
P = np.empty(len(X), object); P[:] = [proba(net, prep(heart_only(np.asarray(x, float)))) for x in X]
np.savez(out, p=P)
