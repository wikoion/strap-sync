import sqlite3, struct, sys, collections, datetime
raw, hd = sys.argv[1], sys.argv[2]
db = sqlite3.connect(hd)
segs = db.execute("SELECT stage, start_utc/1000, end_utc/1000 FROM sleep_segments WHERE session_id = 11076 AND stage IN ('core','deep','rem','awake')").fetchall()
def stage_at(t):
    for s, a, b in segs:
        if a <= t < b: return s
    return "-"
b = open(raw, "rb").read(); i = 0; recs = {}
while i + 2 <= len(b):
    n = b[i] | b[i+1] << 8; f = b[i+2:i+2+n]; i += 2 + n
    if len(f) == 124 and f[8] == 47 and f[9] == 18:
        recs[struct.unpack_from("<I", f, 15)[0]] = f
ts = sorted(t for t in recs if 1793231580 - 1800 <= t <= 1793268600)
# 5-minute rows: Fitbit stage (mode), byte76 low nibble (mode), byte75 high nibble (mode), byte 36 (mode)
rows = collections.defaultdict(list)
for t in ts: rows[t - t % 300].append(t)
code = {"core": "c", "deep": "D", "rem": "R", "awake": "w", "-": "."}
line_f, line_a, line_b, line_c = [], [], [], []
for k in sorted(rows):
    tt = rows[k]
    fs = collections.Counter(stage_at(t) for t in tt).most_common(1)[0][0]
    a = collections.Counter(recs[t][76] & 0x0F for t in tt).most_common(1)[0][0]
    bb = collections.Counter(recs[t][75] >> 4 for t in tt).most_common(1)[0][0]
    c = collections.Counter(recs[t][36] for t in tt).most_common(1)[0][0]
    line_f.append(code[fs]); line_a.append("%X" % a); line_b.append("%X" % bb); line_c.append("%X" % (c & 0xF))
start = datetime.datetime.fromtimestamp(min(rows), datetime.UTC).strftime("%H:%M")
print("5-minute columns from", start)
for name, l in (("Fitbit    ", line_f), ("b76 lo    ", line_a), ("b75 hi    ", line_b), ("b36 lo    ", line_c)):
    s = "".join(l)
    print(name, s[:64]); print("          ", s[64:])
# exact agreement per value of byte 76
conf = collections.defaultdict(collections.Counter)
for t in ts: conf[recs[t][76] & 0x0F][stage_at(t)] += 1
for v in sorted(conf): print("b76", v, dict(conf[v]))
