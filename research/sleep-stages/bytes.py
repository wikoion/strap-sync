# Which R18 bytes track Fitbit's sleep stages? Per-second records joined to Fitbit's stage at that second.
import sqlite3, struct, sys, collections, math
raw, hd = sys.argv[1], sys.argv[2]
db = sqlite3.connect(hd)
segs = db.execute("SELECT stage, start_utc/1000, end_utc/1000 FROM sleep_segments WHERE session_id = 11076 AND stage IN ('core','deep','rem','awake')").fetchall()
def stage_at(t):
    for s, a, b in segs:
        if a <= t < b: return s
    return None
b = open(raw, "rb").read(); i = 0; rows = []
while i + 2 <= len(b):
    n = b[i] | b[i+1] << 8; f = b[i+2:i+2+n]; i += 2 + n
    if len(f) == 124 and f[8] == 47 and f[9] == 18:
        t = struct.unpack_from("<I", f, 15)[0]
        st = stage_at(t)
        if st: rows.append((t, st, f))
print("records in Fitbit's night:", len(rows))
stages = ["awake", "core", "deep", "rem"]
def report(name, val):
    by = collections.defaultdict(collections.Counter)
    for t, st, f in rows: by[st][val(f)] += 1
    # mutual information between value and stage
    total = len(rows); pv = collections.Counter(); ps = collections.Counter()
    for st in by:
        for v, c in by[st].items(): pv[v] += c; ps[st] += c
    mi = sum(c/total * math.log((c/total) / (pv[v]/total * ps[st]/total)) for st in by for v, c in by[st].items())
    top = pv.most_common(6)
    print(f"{name:14s} MI={mi:.3f}  values={len(pv):5d}  " + " | ".join(
        f"{v}: " + " ".join(f"{s[0]}{100*by[s][v]//max(1,ps[s])}" for s in stages) for v, _ in top[:4]))
for off in [33, 36, 38, 39, 63, 75, 76, 77, 78, 79, 80, 82, 104, 105, 106, 107, 108, 109, 110, 111, 112]:
    report(f"byte {off}", lambda f, o=off: f[o])
report("81 bits0-1", lambda f: f[81] & 3)
report("81 bits2-3", lambda f: (f[81] >> 2) & 3)
report("81 bits4-5", lambda f: (f[81] >> 4) & 3)
report("81 bits6-7", lambda f: (f[81] >> 6) & 3)
report("u16 75", lambda f: struct.unpack_from("<H", f, 75)[0])
report("u16 77", lambda f: struct.unpack_from("<H", f, 77)[0])
report("u16 79", lambda f: struct.unpack_from("<H", f, 79)[0])
