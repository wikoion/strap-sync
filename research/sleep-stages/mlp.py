import numpy as np
from model import softmax

def fit_mlp(X, y, w, hidden=24, iters=600, lr=0.05, l2=1e-3, seed=0):
    rng = np.random.default_rng(seed); n, d = X.shape
    W1 = rng.normal(0, 1 / np.sqrt(d), (d, hidden)); b1 = np.zeros(hidden)
    W2 = rng.normal(0, 1 / np.sqrt(hidden), (hidden, 4)); b2 = np.zeros(4)
    Y = np.eye(4)[y]; ws = w / w.sum()
    m1 = [np.zeros_like(a) for a in (W1, b1, W2, b2)]; m2 = [np.zeros_like(a) for a in (W1, b1, W2, b2)]
    for t in range(1, iters + 1):
        H = np.tanh(X @ W1 + b1); P = softmax(H @ W2 + b2)
        dZ = (P - Y) * ws[:, None]
        gW2 = H.T @ dZ + l2 * W2; gb2 = dZ.sum(0)
        dH = dZ @ W2.T * (1 - H ** 2)
        gW1 = X.T @ dH + l2 * W1; gb1 = dH.sum(0)
        for k, (p, g) in enumerate(zip((W1, b1, W2, b2), (gW1, gb1, gW2, gb2))):   # Adam
            m1[k] = 0.9 * m1[k] + 0.1 * g; m2[k] = 0.999 * m2[k] + 0.001 * g * g
            p -= lr * (m1[k] / (1 - 0.9 ** t)) / (np.sqrt(m2[k] / (1 - 0.999 ** t)) + 1e-8)
    return lambda Z: softmax(np.tanh(Z @ W1 + b1) @ W2 + b2)

def tempered_viterbi(P, T, alpha):
    lt = alpha * np.log(T); lp = np.log(P + 1e-9); n = len(P)
    D = lp[0].copy(); B = np.zeros((n, 4), int)
    for i in range(1, n):
        s = D[:, None] + lt; B[i] = s.argmax(0); D = s.max(0) + lp[i]
    path = np.zeros(n, int); path[-1] = D.argmax()
    for i in range(n - 1, 0, -1): path[i - 1] = B[i, path[i]]
    return path

