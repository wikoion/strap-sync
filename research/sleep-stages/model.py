"""Sleep stages from per-second heart rate and movement: epoch features normalised within the night,
multinomial logistic regression, then Viterbi smoothing with learned stage transitions."""
import numpy as np

STAGES = ["wake", "light", "deep", "rem"]

def window_mean(x, half):
    k = np.ones(2 * half + 1)
    num = np.convolve(np.nan_to_num(x), k, "same")
    den = np.convolve((~np.isnan(x)).astype(float), k, "same")
    return np.where(den > 0, num / np.maximum(den, 1), np.nan)

def robust_z(x):
    v = x[~np.isnan(x)]
    if len(v) < 10: return np.zeros_like(x)
    med = np.median(v); iqr = np.subtract(*np.percentile(v, [75, 25])) or 1.0
    return np.nan_to_num((x - med) / iqr)

def epoch_features(hr, motion):
    """hr, motion: per-second arrays for the night (NaN where missing). Returns (epochs x features)."""
    n = len(hr) // 30
    hr, motion = hr[: n * 30].reshape(n, 30), motion[: n * 30].reshape(n, 30)
    with np.errstate(all="ignore"):
        hr_e = np.nanmean(hr, 1)
        hr_sd = np.nanstd(hr, 1)
        mot_e = np.log(np.nanmean(motion, 1) + 1e-3)
        mot_max = np.log(np.nanmax(motion, 1) + 1e-3)
    f = []
    for x in (mot_e, mot_max):
        z = robust_z(x)
        f += [z, window_mean(z, 2), window_mean(z, 10), window_mean(z, 20)]
    zhr = robust_z(hr_e)
    f += [zhr, window_mean(zhr, 2), window_mean(zhr, 10), window_mean(zhr, 30),
          zhr - window_mean(zhr, 30),                        # HR against its local baseline
          robust_z(window_mean(hr_sd, 5)),                   # short-term HR variability
          robust_z(np.array([np.nanstd(hr_e[max(0, i - 10): i + 11]) for i in range(n)]))]  # ~10 min HR spread
    frac = np.arange(n) / max(n - 1, 1)
    f += [frac, frac ** 2, np.cos(2 * np.pi * frac)]
    X = np.nan_to_num(np.vstack(f).T)
    return X

def fit_softmax(X, y, w, l2=1e-2, iters=400, lr=0.5):
    n, d = X.shape; k = 4
    W = np.zeros((d + 1, k)); Xb = np.hstack([X, np.ones((n, 1))])
    Y = np.eye(k)[y]
    for _ in range(iters):
        P = softmax(Xb @ W)
        G = Xb.T @ ((P - Y) * w[:, None]) / w.sum() + l2 * np.vstack([W[:-1], np.zeros((1, k))])
        W -= lr * G
    return W

def softmax(Z):
    Z = Z - Z.max(1, keepdims=True); E = np.exp(Z); return E / E.sum(1, keepdims=True)

def predict_proba(W, X):
    return softmax(np.hstack([X, np.ones((len(X), 1))]) @ W)

def transitions(seqs, eps=1.0):
    T = np.full((4, 4), eps)
    for s in seqs:
        s = s[s >= 0]
        for a, b in zip(s[:-1], s[1:]): T[a, b] += 1
    return T / T.sum(1, keepdims=True)

def viterbi(P, T, prior):
    n = len(P); lp = np.log(P + 1e-9); lt = np.log(T)
    # Divide out the class prior so emissions act as likelihoods.
    lp = lp - np.log(prior + 1e-9)
    D = np.zeros((n, 4)); B = np.zeros((n, 4), int)
    D[0] = lp[0] + np.log(prior)
    for i in range(1, n):
        s = D[i - 1][:, None] + lt
        B[i] = s.argmax(0); D[i] = s.max(0) + lp[i]
    path = np.zeros(n, int); path[-1] = D[-1].argmax()
    for i in range(n - 1, 0, -1): path[i - 1] = B[i, path[i]]
    return path

def kappa(a, b):
    a, b = np.asarray(a), np.asarray(b); po = (a == b).mean()
    pe = sum((a == k).mean() * (b == k).mean() for k in range(4))
    return (po - pe) / (1 - pe)

def fuse(Ph, Pm, prior, w, wake_only, has):
    """Combines the heart model's stage probabilities Ph with a movement model's Pm, whose ratio to
    its training prior acts as a likelihood: P ~ Ph * (Pm / prior)^w, only in epochs where `has` (the
    epoch has rotation). With wake_only, movement only moves wake against sleep and leaves the sleep
    stages' balance to the heart."""
    if wake_only:
        lw = np.log(Pm[:, 0] / prior[0] + 1e-9) - np.log((1 - Pm[:, 0]) / (1 - prior[0]) + 1e-9)
        L = np.c_[lw, np.zeros((len(lw), 3))]
    else: L = np.log(Pm / prior + 1e-9)
    P = np.exp(np.log(Ph + 1e-9) + w * np.where(has[:, None], L, 0)); return P / P.sum(1, keepdims=True)
