"""A small bidirectional GRU over a night's sequence of epoch features (hrv.py): 2 layers of 64
units each way, class weights (1/prior)^0.5, early stopping on a tenth of the training nights."""
import numpy as np
import torch, torch.nn as nn
from model import kappa
torch.manual_seed(0); torch.set_num_threads(8)

FLAGS = [0, 4, 30, 38]          # hr1, hr5, rot, temp in hrv.features()' column order

def heart_only(X):
    """Rotation and temperature columns (30-41) set to NaN, for a net trained on nights without
    them: their weights never learned anything, so real values there are noise."""
    X = X.copy(); X[:, 30:42] = np.nan; return X

def prep(X, dtype=np.float32):
    """NaN to 0, clipped to +-5, plus flags for no beats in the 1-min / 5-min window and for no
    rotation / no skin temperature (the ECG datasets have neither)."""
    assert X.shape[1] == 46
    miss = np.isnan(X[:, FLAGS]).astype(float)
    return np.hstack([np.clip(np.nan_to_num(X), -5, 5), miss]).astype(dtype)

class Net(nn.Module):
    def __init__(self, d, h=64):
        super().__init__()
        self.inp = nn.Sequential(nn.Linear(d, h), nn.ReLU(), nn.Dropout(0.2))
        self.gru = nn.GRU(h, h, num_layers=2, batch_first=True, bidirectional=True, dropout=0.2)
        self.out = nn.Linear(2 * h, 4)
    def forward(self, x): return self.out(self.gru(self.inp(x))[0])

def batches(data, size, rng):
    order = rng.permutation(len(data))
    for k in range(0, len(order), size):
        part = [data[i] for i in order[k: k + size]]; L = max(len(y) for _, y in part)
        X = np.zeros((len(part), L, part[0][0].shape[1]), np.float32); Y = np.full((len(part), L), -1)
        for j, (x, y) in enumerate(part): X[j, : len(y)] = x; Y[j, : len(y)] = y
        yield torch.from_numpy(X), torch.from_numpy(Y)

def train(data, epochs=40):
    rng = np.random.default_rng(0); val = data[::10]; tr = [d for i, d in enumerate(data) if i % 10]
    y = np.concatenate([y for _, y in tr]); prior = np.bincount(y[y >= 0], minlength=4) / (y >= 0).sum()
    net = Net(tr[0][0].shape[1]); opt = torch.optim.Adam(net.parameters(), 1e-3, weight_decay=1e-4)
    loss_f = nn.CrossEntropyLoss(weight=torch.tensor((1 / prior) ** 0.5, dtype=torch.float32), ignore_index=-1)
    best, state = -1, None
    for ep in range(epochs):
        net.train()
        for X, Y in batches(tr, 16, rng):
            opt.zero_grad(); loss_f(net(X).reshape(-1, 4), Y.reshape(-1)).backward()
            nn.utils.clip_grad_norm_(net.parameters(), 1.0); opt.step()
        k = kappa(*map(np.concatenate, zip(*[(p[y >= 0], y[y >= 0]) for p, y in ((predict(net, x), y) for x, y in val)])))
        if k > best: best, state = k, {n: v.clone() for n, v in net.state_dict().items()}
    net.load_state_dict(state); return net

def predict(net, x):
    net.eval()
    with torch.no_grad(): return net(torch.from_numpy(x)[None])[0].argmax(-1).numpy()

def proba(net, x):
    """Stage probabilities per epoch (softmax of the outputs)."""
    net.eval()
    with torch.no_grad(): return torch.softmax(net(torch.from_numpy(x)[None])[0], -1).numpy().astype(float)
