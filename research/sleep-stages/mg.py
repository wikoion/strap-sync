"""The MG's history RR as beat times, as the app rebuilds them (beats()), and its gravity vector from
the raw archive (gravity()). beats(): each RR ends in its 1-s record; consecutive RRs whose records
are further apart than the RR itself (plus 1.5 s), or whose running beat time has drifted 2 s from
the record, start a new run at the record's time."""
import numpy as np

def beats(ts, rr):
    """ts: record times (s, relative), rr: intervals (s), in (ts, idx) order. Returns beat times."""
    b = np.empty(len(rr)); b[0] = ts[0]
    for k in range(1, len(rr)):
        b[k] = b[k - 1] + rr[k] if ts[k] - ts[k - 1] <= rr[k] + 1.5 and abs(b[k - 1] + rr[k] - ts[k]) < 2 else ts[k]
    return b

def gravity(raw_path, t0, n_sec):
    """Per-second gravity (x, y, z, g) from the app's raw strap archive (scripts/install-app.sh
    --pull-raw): R18 frames (124 bytes, type 47, record 18) hold it as float32 at bytes 45/49/53,
    with the record's time at byte 15. NaN for seconds without a record, or whose vector isn't
    finite with a length of 0.1-4 g (it's about 1 g; the app applies the same check)."""
    import struct
    g = np.full((n_sec, 3), np.nan); data = open(raw_path, "rb").read(); i = 0
    while i + 2 <= len(data):
        n = data[i] | data[i + 1] << 8; f = data[i + 2: i + 2 + n]; i += 2 + n
        if len(f) == 124 and f[8] == 47 and f[9] == 18:
            t = struct.unpack_from("<I", f, 15)[0] - t0
            v = np.array(struct.unpack_from("<3f", f, 45))
            if 0 <= t < n_sec and np.isfinite(v).all() and 0.1 <= np.linalg.norm(v) <= 4: g[t] = v
    return g
