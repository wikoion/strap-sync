import sqlite3, sys, math, statistics, collections
wdb, hd = sqlite3.connect(sys.argv[1]), sqlite3.connect(sys.argv[2])
segs = hd.execute("SELECT stage, start_utc/1000, end_utc/1000 FROM sleep_segments WHERE session_id = 11076 AND stage IN ('core','deep','rem','awake')").fetchall()
def fit(t):
    for s, a, b in segs:
        if a <= t < b: return s
    return None
N0, N1 = 1793232665, 1793268846          # the band-flag night, 00:11–10:14
mins = {m: (hr, mot) for m, hr, mot in wdb.execute("SELECT minute, hr, motion FROM minutes WHERE minute >= ? AND minute < ?", (N0 - 600, N1 + 600))}
rr = collections.defaultdict(list)
for ts, idx, ms in wdb.execute("SELECT ts, idx, ms FROM rr WHERE source = 2 AND ts >= ? AND ts < ? ORDER BY ts, idx", (N0 - 600, N1 + 600)):
    rr[ts - ts % 60].append(ms)
def clean(xs):
    out = []
    for v in xs:
        if 300 <= v <= 2000 and (not out or abs(v - out[-1]) <= 0.2 * out[-1]): out.append(v)
    return out
night = list(range(N0, N1, 60))
F = {}
for m in night:
    win = clean([v for k in range(m - 120, m + 180, 60) for v in rr.get(k, [])])   # 5-min centred window
    rmssd = math.sqrt(statistics.mean([(a - b) ** 2 for a, b in zip(win[1:], win)])) if len(win) > 30 else None
    hrs = [mins[k][0] for k in range(m - 120, m + 180, 60) if k in mins and mins[k][0]]
    F[m] = dict(hr=mins.get(m, (None, None))[0], mot=mins.get(m, (None, None))[1], rmssd=rmssd,
                hrsd=statistics.pstdev(hrs) if len(hrs) >= 4 else None)
def z(key, f=lambda x: x):
    vals = [f(F[m][key]) for m in night if F[m][key]]
    mu, sd = statistics.mean(vals), statistics.pstdev(vals) or 1
    return {m: (f(F[m][key]) - mu) / sd if F[m][key] else 0 for m in night}
zhr, zhrv, zsd = z("hr"), z("rmssd", math.log), z("hrsd")
# Longer-scale HR: 15-min centred mean minus 60-min mean (REM bouts raise HR for tens of minutes)
def smooth(d, half):
    return {m: statistics.mean([d[k] for k in range(m - half*60, m + half*60 + 1, 60) if k in d]) for m in night}
zhr15, zhrv15, zsd15 = smooth(zhr, 7), smooth(zhrv, 7), smooth(zsd, 7)
def classify(td, tr, wd, wr):
    out = {}
    for i, m in enumerate(night):
        frac = i / len(night)
        deep = -zhr15[m] + zhrv15[m] - zsd15[m] * wd
        rem = zhr15[m] + zsd15[m] - zhrv15[m] * wr
        if F[m]["mot"] and F[m]["mot"] > 0.05: out[m] = "awake"
        elif deep > td and frac < 0.85: out[m] = "deep"
        elif rem > tr and i > 60: out[m] = "rem"
        else: out[m] = "core"
    return out
def score(pred):
    pairs = [(pred[m], fit(m)) for m in night if fit(m)]
    acc = sum(a == b for a, b in pairs) / len(pairs)
    mins_ = collections.Counter(a for a, _ in pairs)
    return acc, dict(mins_)
best = []
for td in (0.6, 0.8, 1.0, 1.2, 1.5):
    for tr in (0.4, 0.6, 0.8, 1.0, 1.2):
        for wd in (0, 0.5, 1):
            for wr in (0, 0.5, 1):
                acc, m = score(classify(td, tr, wd, wr))
                best.append((acc, td, tr, wd, wr, m))
best.sort(reverse=True)
for b in best[:6]: print(round(b[0], 3), b[1:5], b[5])
print("Fitbit:", dict(collections.Counter(fit(m) for m in night if fit(m))))
# naive baseline: everything core
print("all-core accuracy:", round(sum(fit(m) == "core" for m in night if fit(m)) / sum(1 for m in night if fit(m)), 3))
