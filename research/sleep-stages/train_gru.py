"""Trains the GRU (gru.py) on every night of the given sources (sources.py), heart columns only
(gru.heart_only), and saves it. Usage: train_gru.py <out .pt> <source>... Needs torch."""
import numpy as np, sys, os, warnings
warnings.filterwarnings("ignore")
sys.path.insert(0, os.path.dirname(__file__))
import torch
from gru import prep, train, heart_only
from sources import load
out, srcs = sys.argv[1], sys.argv[2:]
data = [(prep(heart_only(x)), y) for s in srcs for x, y, _ in load(s)]
print(len(data), "nights", flush=True)
torch.save(train(data).state_dict(), out)
