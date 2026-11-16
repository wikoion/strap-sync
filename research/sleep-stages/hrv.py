"""HRV features per 30-s epoch from beat intervals, built to survive the gaps a WHOOP MG's history
leaves (the 28->29 Oct night: 89% of the time covered, 150 gaps, median 30 s, runs averaging 195
beats). Successive differences only use beats that are adjacent, and spectra use Lomb-Scargle, so
missing beats leave holes rather than fake intervals. Movement and skin temperature columns are
always present, and NaN for sources without them (the ECG PSG datasets). Movement is wrist rotation
(rotation()), which carries over between devices. Needs scipy."""
import numpy as np
from scipy.signal import lombscargle
from scipy.ndimage import median_filter
from model import window_mean

FREQS = np.arange(0.04, 0.401, 0.005)              # Hz: LF 0.04-0.15, HF 0.15-0.4
LF, HF = FREQS < 0.15, FREQS >= 0.15

def rr_series(beats):
    """Beat times (s) -> (t, rr, idx) after clean()."""
    return clean(beats[1:], np.diff(beats), np.arange(len(beats) - 1))

def clean(t, rr, idx):
    """Intervals ending at t, with idx their position in the full beat series (idx[i + 1] ==
    idx[i] + 1 means adjacent). An interval is kept when it's 0.33-1.5 s, within 20% of its 7-beat
    median, and has two normal intervals either side (Oura's rule)."""
    med = median_filter(rr, 7, mode="nearest")
    ok = (rr > 0.33) & (rr < 1.5) & (np.abs(rr - med) < 0.2 * med)
    keep = ok.copy()
    for s in (1, 2):
        keep[s:] &= ok[:-s]; keep[:-s] &= ok[s:]
    return t[keep], rr[keep], idx[keep]

def thin(n, rng, keep=0.89, run=195):
    """Mask over n intervals that keeps about `keep` of them in runs averaging `run` intervals: the
    MG's overnight history coverage."""
    p_lose = 1 / run; p_find = p_lose * keep / (1 - keep)
    m = np.empty(n, bool); s = True
    u = rng.random(n)
    for i in range(n):
        s = (u[i] >= p_lose) if s else (u[i] < p_find)
        m[i] = s
    return m

def dfa_a1(r):
    y = np.cumsum(r - r.mean()); F = []; scales = (4, 6, 8, 11, 16)
    for n in scales:
        m = len(y) // n
        seg = y[: m * n].reshape(m, n); x = np.arange(n) - (n - 1) / 2
        slope = seg @ x / (x @ x); res = seg - seg.mean(1, keepdims=True) - slope[:, None] * x
        F.append(np.sqrt((res ** 2).mean()))
    return np.polyfit(np.log(scales), np.log(F), 1)[0]

def windows(t, rr, idx, centres, half, spectral):
    lo = np.searchsorted(t, centres - half); hi = np.searchsorted(t, centres + half)
    out = np.full((len(centres), 12 if spectral else 4), np.nan)
    for e, (a, b) in enumerate(zip(lo, hi)):
        r = rr[a:b]
        if len(r) < (40 if spectral else 12): continue
        adj = np.diff(idx[a:b]) == 1; d = np.diff(r)[adj]
        hr = 60 / r.mean(); cover = len(r) / (2 * half * hr / 60)
        rmssd = np.sqrt((d ** 2).mean()) if len(d) > 5 else np.nan
        row = [hr, np.log(rmssd + 1e-4), np.log(r.std() + 1e-4), cover]
        if spectral:
            P = lombscargle(t[a:b], r - r.mean(), 2 * np.pi * FREQS)
            lf, hf = P[LF].sum(), P[HF].sum(); k = np.argmax(np.where(HF, P, -1))
            sd1 = d.std() / np.sqrt(2) if len(d) > 5 else np.nan
            sd2 = np.sqrt(max(2 * r.var() - sd1 ** 2, 1e-12)) if len(d) > 5 else np.nan
            row += [np.log(lf + 1e-9), np.log(hf + 1e-9), np.log((lf + 1e-9) / (hf + 1e-9)), hf / (lf + hf + 1e-12),
                    FREQS[k] * 60, P[k] / (hf + 1e-12), dfa_a1(r) if len(r) >= 64 else np.nan,
                    (np.abs(d) > 0.05).mean() if len(d) > 5 else np.nan]
        out[e] = row
    return out

NAMES1 = ["hr1", "rmssd1", "sdnn1", "cover1"]
NAMES5 = ["hr5", "rmssd5", "sdnn5", "cover5", "lf5", "hf5", "lfhf5", "hfnu5", "resp5", "resp_peak5", "dfa5", "pnn50_5"]

def epoch_features(beats, n, a, b, rng=None, keep=0.89, grav=None):
    """Beat times (s from epoch 0), n epochs, sleep period [a, b) in epochs, optional per-second
    gravity. Thins beats to the MG's coverage when rng is given. Returns (features for epochs a..b-1,
    column names)."""
    t, rr, idx = rr_series(beats)
    if rng is not None:
        m = thin(len(beats), rng, keep)[idx]; t, rr, idx = t[m], rr[m], idx[m]
    return features(t, rr, idx, n, a, b, grav)

def per_epoch(x, n, f):
    x = np.full(n * 30, np.nan) if x is None else np.r_[x, np.full(max(0, n * 30 - len(x)), np.nan)][: n * 30]
    with np.errstate(all="ignore"):
        return f(x.reshape(n, 30), 1)

def movement(mot, n):
    """Not used since rotation(): it didn't carry over to the MG (SLEEP_STAGES.md). Movement as
    events, not levels: wrist accelerometers differ too much in noise floor and processing (the MG's sleep movement spans 0.005-0.010 g, the E4's 0.003-0.04 g) for scaled
    levels to transfer. A second is an event when it's more than 8 interquartile ranges above the
    night's median (16 for a big one); features are event fractions, local event rates, and minutes
    since and until the nearest event, all comparable across devices. NaN without movement."""
    names = ["mot", "mot_m1", "mot_m5", "mot_m10", "mot_big", "mot_big_m5", "mot_since", "mot_until"]
    if mot is None or not np.isfinite(mot).any(): return {k: np.full(n, np.nan) for k in names}
    x = np.r_[mot, np.full(max(0, n * 30 - len(mot)), np.nan)][: n * 30]
    q25, med, q75 = np.nanpercentile(x, [25, 50, 75]); iqr = max(q75 - q25, 1e-4)
    ev = np.where(np.isfinite(x), x > med + 8 * iqr, np.nan); big = np.where(np.isfinite(x), x > med + 16 * iqr, np.nan)
    with np.errstate(all="ignore"):
        f = np.nanmean(ev.reshape(n, 30), 1); fb = np.nanmean(big.reshape(n, 30), 1)
    hit = np.nan_to_num(f) > 0; e = np.arange(n)
    last = np.maximum.accumulate(np.where(hit, e, -10 ** 6)); nxt = np.minimum.accumulate(np.where(hit, e, 10 ** 6)[::-1])[::-1]
    return dict(zip(names, [f, window_mean(f, 2), window_mean(f, 10), window_mean(f, 20), fb, window_mean(fb, 10),
                            np.minimum((e - last) / 2, 60.0), np.minimum((nxt - e) / 2, 60.0)]))

def turns(grav):
    """Per-second gravity vectors (n x 3, any units, NaN allowed) -> the angle in degrees between
    successive 5-s mean directions, one value per 5-s step (NaN where either step has no data).
    Angles don't depend on a device's units, mounting, noise floor or processing."""
    n = len(grav) // 5 * 5
    with np.errstate(all="ignore"):
        g = np.nanmean(grav[:n].reshape(-1, 5, 3), 1); u = g / np.linalg.norm(g, axis=1, keepdims=True)
    c = np.clip((u[1:] * u[:-1]).sum(1), -1, 1)
    return np.r_[np.nan, np.degrees(np.arccos(c))]

ROT_NAMES = ["rot", "rot_m1", "rot_m5", "rot_m10", "rot_big", "rot_big_m5", "rot_since", "rot_until"]

def rotation(grav, n, small=5.0, big=30.0):
    """Wrist rotation per 30-s epoch from per-second gravity: the share of its six 5-s steps that turn
    more than `small` degrees (and more than `big`, a change of position), local means of that over
    +-1, 5 and 10 minutes, and minutes since and until the nearest epoch with a turn (capped at 60).
    In DREAMT a >5 degree turn falls in 3.4% of asleep epochs and 32% of awake ones (median night).
    NaN without gravity."""
    if grav is None or not np.isfinite(grav).any(): return {k: np.full(n, np.nan) for k in ROT_NAMES}
    g = np.full((n * 30, 3), np.nan); m = min(len(grav), n * 30); g[:m] = grav[:m]
    r = turns(g).reshape(n, 6); ok = np.isfinite(r)
    with np.errstate(all="ignore"):
        f = np.where(ok.any(1), (r > small).sum(1) / ok.sum(1), np.nan)
        fb = np.where(ok.any(1), (r > big).sum(1) / ok.sum(1), np.nan)
    hit = np.nan_to_num(f) > 0; e = np.arange(n)
    last = np.maximum.accumulate(np.where(hit, e, -10 ** 6)); nxt = np.minimum.accumulate(np.where(hit, e, 10 ** 6)[::-1])[::-1]
    return dict(zip(ROT_NAMES, [f, window_mean(f, 2), window_mean(f, 10), window_mean(f, 20), fb, window_mean(fb, 10),
                                np.minimum((e - last) / 2, 60.0), np.minimum((nxt - e) / 2, 60.0)]))

def hr_windows(ht, bpm, centres, half, min_n):
    """Mean of sparse heart-rate samples (an Apple Watch's ~0.2 Hz) in each window, for sources
    without beat intervals."""
    lo = np.searchsorted(ht, centres - half); hi = np.searchsorted(ht, centres + half)
    cs = np.r_[0, np.cumsum(bpm)]; k = hi - lo
    return np.where(k >= min_n, (cs[hi] - cs[lo]) / np.maximum(k, 1), np.nan)

def features(t, rr, idx, n, a, b, grav=None, temp=None, hr=None):
    """Cleaned intervals (from clean()), plus optional per-second gravity (x, y, z; rotation()) and
    skin temperature (deg C) from epoch 0. Sources without beat intervals can give heart-rate samples
    hr = (times, bpm) instead; they fill the HR columns and the rest stay NaN."""
    c = np.arange(n) * 30 + 15.0
    W1 = windows(t, rr, idx, c, 30, False); W5 = windows(t, rr, idx, c, 150, True)
    if hr is not None and len(t) == 0:
        W1[:, 0] = hr_windows(*hr, c, 30, 3); W5[:, 0] = hr_windows(*hr, c, 150, 10)
    cols = dict(zip(NAMES1, W1.T)) | dict(zip(NAMES5, W5.T))
    for k in ("hr5", "rmssd5", "hf5", "lfhf5", "dfa5", "hfnu5"):
        cols[k + "_m5"] = window_mean(cols[k], 10); cols[k + "_m15"] = window_mean(cols[k], 30)
    cols["hr_vs_base"] = cols["hr1"] - window_mean(cols["hr1"], 30)
    cols["resp_sd"] = np.array([np.nanstd(cols["resp5"][max(0, i - 10): i + 11]) if np.isfinite(cols["resp5"][max(0, i - 10): i + 11]).sum() > 3 else np.nan
                                for i in range(n)])          # breathing steadiness over ~10 min
    for k, v in rotation(grav, n).items(): cols[k] = v
    te = per_epoch(temp, n, np.nanmean)
    cols["temp"] = te; cols["temp_m5"] = window_mean(te, 10); cols["temp_m15"] = window_mean(te, 30)
    cols["temp_vs_base"] = te - window_mean(te, 20)
    X = np.vstack([cols[k][a:b] for k in cols]).T; names = list(cols)
    keep_raw = [i for i, k in enumerate(names) if k.startswith(("cover", "rot"))]
    for j in range(X.shape[1]):
        if j in keep_raw: continue
        v = X[:, j][np.isfinite(X[:, j])]
        if len(v) < 20: X[:, j] = np.nan; continue
        lo, med, hi = np.percentile(v, [5, 50, 95])
        X[:, j] = (X[:, j] - med) / (hi - lo + 1e-9)   # per-night robust scaling (Oura)
    h = np.arange(b - a) / 120; frac = h / max(h[-1], 1e-9)
    X = np.hstack([X, np.vstack([h, np.exp(-h / 2), frac, np.cos(2 * np.pi * frac)]).T])
    return X, names + ["hours", "decay", "frac", "cos"]

HR_ONLY = ["hr1", "hr5", "hr5_m5", "hr5_m15", "hr_vs_base", "hours", "decay", "frac", "cos"]
