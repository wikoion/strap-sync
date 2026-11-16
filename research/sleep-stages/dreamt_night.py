"""DREAMT (PhysioNet, restricted: 100 sleep-clinic nights, Empatica E4 on the wrist against PSG) ->
one .npz per night in the shape features() takes: t, rr, idx (the E4's own beat intervals, as the MG
reports its own), mot (gravity-removed magnitude, g), grav (mean x, y, z, g) and temp per second, y
per 30-s epoch (0 wake, 1 light, 2 deep, 3 REM, -1
unscored). Time 0 is the first scored epoch (the end of the 'P' preparation period). Nights written before
grav was added are redone.
Usage: dreamt_night.py <data_64Hz dir> <out dir>."""
import numpy as np, csv, glob, os, sys, time
D, OUT = sys.argv[1], sys.argv[2]
os.makedirs(OUT, exist_ok=True)
STAGE = {"W": 0, "N1": 1, "N2": 1, "N3": 2, "R": 3}
TOL = 1.5 / 64                                      # the E4 times beats to 1/64 s

def intervals(ev_t, ev_v):
    """The IBI column holds each interval until the next beat, so a beat whose interval equals the
    one before it doesn't show. Put back up to three such repeats where the timing says exactly
    that happened; any other mismatch is a gap (idx jumps by 2)."""
    t, rr, idx = [ev_t[0]], [ev_v[0]], [0]
    for k in range(1, len(ev_t)):
        gap = ev_t[k] - t[-1]; extra = gap - ev_v[k]; i = idx[-1] + 1
        if abs(extra) > TOL:
            m = round(extra / rr[-1])
            if 1 <= m <= 3 and abs(extra - m * rr[-1]) <= TOL * (m + 1):
                for _ in range(m):
                    t.append(t[-1] + rr[-1]); rr.append(rr[-1]); idx.append(i); i += 1
            else:
                i += 1
        t.append(ev_t[k]); rr.append(ev_v[k]); idx.append(i)
    return np.array(t), np.array(rr), np.array(idx)

for path in sorted(glob.glob(f"{D}/S[0-9][0-9][0-9]_whole_df.csv")):
    sid = os.path.basename(path)[:4]
    if os.path.exists(f"{OUT}/{sid}.npz") and "grav" in np.load(f"{OUT}/{sid}.npz"): continue
    if time.time() - os.path.getmtime(path) < 30 * 86400: continue    # wget -N only stamps the server's (2024) date once a file is done
    ts, acc, temp, stage, ev_t, ev_v = [], [], [], [], [], []
    last = None
    with open(path) as f:
        r = csv.reader(f); h = next(r); c = {k: h.index(k) for k in ("TIMESTAMP", "ACC_X", "ACC_Y", "ACC_Z", "TEMP", "IBI", "Sleep_Stage")}
        for row in r:
            if len(row) < len(h): break                  # still downloading
            t = float(row[c["TIMESTAMP"]]); ts.append(t)
            x, y, z = (float(row[c[k]] or "nan") for k in ("ACC_X", "ACC_Y", "ACC_Z"))
            acc.append((x, y, z)); temp.append(float(row[c["TEMP"]] or "nan"))
            stage.append(STAGE.get(row[c["Sleep_Stage"]], -1 if row[c["Sleep_Stage"]] != "P" else -2))
            v = row[c["IBI"]]
            if v and v != last: ev_t.append(t); ev_v.append(float(v))
            last = v
    ts, acc, temp, stage = np.array(ts), np.array(acc) / 64, np.array(temp), np.array(stage)
    mag = np.sqrt((acc ** 2).sum(1))
    scored = np.where(stage != -2)[0]
    if len(scored) == 0 or len(ev_t) < 1000: print(sid, "skipped: no scoring or IBI"); continue
    t0 = ts[scored[0]]; n = int((ts[-1] - t0) // 30)
    sec = np.floor(ts - t0).astype(int); ok = (sec >= 0) & (sec < n * 30)
    cnt = np.bincount(sec[ok], minlength=n * 30)
    with np.errstate(all="ignore"):
        mot = np.bincount(sec[ok], np.abs(mag[ok] - 1), n * 30) / cnt
        grav = np.vstack([np.bincount(sec[ok], acc[ok, k], n * 30) for k in range(3)]).T / cnt[:, None]
        tmp = np.bincount(sec[ok], np.nan_to_num(temp[ok]), n * 30) / np.bincount(sec[ok], np.isfinite(temp[ok]), n * 30)
    ep = sec[ok] // 30; y = np.full(n, -1)
    for e in range(n):
        s = stage[ok][ep == e]; s = s[s >= 0]
        if len(s) > 0.9 * 1920:
            v = np.bincount(s, minlength=4); y[e] = v.argmax() if v.max() >= 0.9 * len(s) else -1
    t, rr, idx = intervals(np.array(ev_t) - t0, np.array(ev_v))
    keep = (t >= -300) & (t < n * 30 + 300)
    np.savez(f"{OUT}/{sid}.npz", t=t[keep], rr=rr[keep], idx=idx[keep], mot=mot, grav=grav, temp=tmp, y=y)
    print(sid, n, "epochs", keep.sum(), "intervals", "coverage %.2f" % (rr[keep][(t[keep] >= 0) & (t[keep] < n * 30)].sum() / (n * 30)), flush=True)
