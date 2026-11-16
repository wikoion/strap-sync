"""Wrist accelerometer nights against sleep staging -> one .npz per night for sources.py: grav (mean
x, y, z per second, g), hr_t / hr_bpm (an Apple Watch's heart-rate samples, about one every 5 s, or
none; no beat intervals, so t, rr and idx are empty), y per 30-s epoch (0 wake, 1 light, 2 deep,
3 REM, -1 unscored) and src (SA, BS or NC). They train the rotation model, which never sees heart
data, so the healthy sleepers' movement doesn't get tied to a patient's heart the way DREAMT's did.
  sleep-accel  Walch 2019 (PhysioNet, ODC-By): 31 lab nights, PSG. Time 0 is the PSG start.
  bidsleep     BIDSleep (PhysioNet, ODC-By): 47 adults at home, 3-7 nights each, Dreem 2 EEG
               scored by an expert. Time 0 is recStart.
  newcastle    Newcastle PSG + accelerometer (Zenodo, CC BY 4.0): 28 sleep-clinic patients, a GENEActiv
               on each wrist, no heart rate. src NC.
Usage: wrist_night.py sleep-accel|bidsleep|newcastle <dataset dir> <out dir>."""
import numpy as np, glob, os, sys
sys.path.insert(0, os.path.dirname(__file__))
import hrv
kind, D, OUT = sys.argv[1:4]
os.makedirs(OUT, exist_ok=True)

def per_second(ts, xyz, n_sec):
    sec = np.floor(ts).astype(int); ok = (sec >= 0) & (sec < n_sec)
    cnt = np.bincount(sec[ok], minlength=n_sec)
    with np.errstate(all="ignore"):
        return np.vstack([np.bincount(sec[ok], xyz[ok, k], n_sec) for k in range(3)]).T / cnt[:, None]

def save(name, src, grav, hr, y):
    hr = hr[(hr[:, 0] >= -600) & (hr[:, 0] < len(y) * 30 + 600)]
    e = np.empty(0)
    np.savez(f"{OUT}/{name}.npz", t=e, rr=e, idx=e.astype(int), grav=grav, hr_t=hr[:, 0], hr_bpm=hr[:, 1], y=y, src=src)
    print(name, len(y), "epochs,", len(hr), "HR samples, gravity in %.0f%% of seconds" % (100 * np.isfinite(grav[:, 0]).mean()), flush=True)

if kind == "sleep-accel":
    STAGE = {0: 0, 1: 1, 2: 1, 3: 2, 4: 2, 5: 3}
    for lab in sorted(glob.glob(f"{D}/labels/*_labeled_sleep.txt")):
        sid = os.path.basename(lab).split("_")[0]
        if os.path.exists(f"{OUT}/SA{sid}.npz"): continue
        L = np.loadtxt(lab); L = L[L[:, 1] >= 0]
        y = np.full(int(L[-1, 0] // 30) + 1, -1)
        for t, s in L: y[int(t // 30)] = STAGE[int(s)]
        raw = open(f"{D}/motion/{sid}_acceleration.txt", "rb").read()
        k = 0                                       # skip the week before the lab night (negative times)
        while k < len(raw) and raw[k:k + 1] == b"-": k = raw.index(b"\n", k) + 1
        m = np.array(raw[k:].split(), float).reshape(-1, 4)
        hr = np.loadtxt(f"{D}/heart_rate/{sid}_heartrate.txt", delimiter=",")
        save(f"SA{sid}", "SA", per_second(m[:, 0], m[:, 1:], len(y) * 30), hr, y)
elif kind == "bidsleep":
    # Read straight from PhysioNet's zip (5.9 GB; 27.9 GB unpacked). Per night: motion.csv
    # (Timestamp,x,y,z in g, ~50 Hz), hr.csv (time,bpm, no header), labels.mat (recStart in US
    # Eastern time; expert_label per 30 s: 0 W, 1 N1, 2 N2, 3 N3, 4 REM, 5 unknown).
    import zipfile, io, re, datetime, zoneinfo, scipy.io
    STAGE = np.array([0, 1, 1, 2, 3, -1])
    z = zipfile.ZipFile(D); nights = {}
    for name in z.namelist():
        m = re.search(r"Bidslab(\d+)/(\d+)/(motion\.csv|hr\.csv|labels\.mat)$", name)
        if m: nights.setdefault((m[1], int(m[2])), {})[m[3]] = name
    def rows(text, cols):
        """Complete lines of numbers. numpy's parser stops quietly at the first bad value, so a piece
        that doesn't come out at `cols` numbers a line is parsed line by line, keeping whole rows
        (some files end in a cut-off line)."""
        a = np.fromstring(text.replace(b"\n", b","), sep=",")
        if len(a) == text.count(b"\n") * cols: return a.reshape(-1, cols)
        good = []
        for ln in text.split(b"\n"):
            try:
                v = [float(x) for x in ln.split(b",")]
                if len(v) == cols: good.append(v)
            except ValueError: pass
        return np.array(good, float).reshape(-1, cols)
    def numbers(member, cols, header):
        """A CSV of numbers, in 32 MB pieces."""
        out, rest = [], b""
        with z.open(member) as f:
            if header: f.readline()
            while chunk := f.read(1 << 25):
                chunk = rest + chunk; k = chunk.rfind(b"\n") + 1; rest = chunk[k:]
                out.append(rows(chunk[:k], cols))
        if rest.strip(): out.append(rows(rest + b"\n", cols))
        return np.concatenate(out)
    for (subj, night), f in sorted(nights.items()):
        name = f"BS{subj}-{night}"
        if os.path.exists(f"{OUT}/{name}.npz"): continue
        if len(f) < 3: print(name, "skipped: missing", {"motion.csv", "hr.csv", "labels.mat"} - set(f)); continue
        lab = scipy.io.loadmat(io.BytesIO(z.read(f["labels.mat"])))
        t0 = datetime.datetime.fromisoformat(str(lab["recStart"][0])).replace(tzinfo=zoneinfo.ZoneInfo("America/New_York")).timestamp()
        y = STAGE[np.minimum(lab["expert_label"].ravel().astype(int), 5)]
        m = numbers(f["motion.csv"], 4, True); hr = numbers(f["hr.csv"], 2, False)
        hr[:, 0] -= t0
        save(name, "BS", per_second(m[:, 0] - t0, m[:, 1:], len(y) * 30), hr, y)
elif kind == "newcastle":
    # Newcastle PSG + accelerometer (Zenodo 1160410, CC BY 4.0): 28 sleep-clinic patients, a GENEActiv on
    # each wrist (85.7 Hz) and RemLogic 30-s scoring with clock times. No heart rate. One .npz per
    # wrist (NCxx-left, NCxx-right); time 0 is the first scored epoch.
    import datetime, re
    STAGE = {"W": 0, "N1": 1, "N2": 1, "N3": 2, "R": 3}

    def geneactiv(path):
        """GENEActiv .bin (text): a header with per-axis calibration, then pages of 10 lines whose last
        is 300 samples of 12 hex digits: x, y, z as 12-bit two's complement, then light and button.
        Returns sample times (local clock, POSIX-style seconds) and x, y, z in g."""
        lines = open(path, "rb").read().decode("latin-1").splitlines()
        h = {}
        for ln in lines[:80]:
            k, _, v = ln.partition(":"); h.setdefault(k.strip(), v.strip())
        gain = np.array([float(h[f"{a} gain"]) for a in "xyz"]); off = np.array([float(h[f"{a} offset"]) for a in "xyz"])
        fs = float(h["Measurement Frequency"].split()[0])
        starts = [i for i, ln in enumerate(lines) if ln == "Recorded Data" and i + 9 < len(lines) and len(lines[i + 9]) == 3600]
        times = [datetime.datetime.strptime(lines[i + 3][len("Page Time:"):], "%Y-%m-%d %H:%M:%S:%f").replace(tzinfo=datetime.timezone.utc).timestamp()
                 for i in starts]
        raw = np.frombuffer(bytes.fromhex("".join(lines[i + 9] for i in starts)), np.uint8).reshape(len(starts), 300, 6).astype(np.int64)
        v = (raw[..., 0] << 40) | (raw[..., 1] << 32) | (raw[..., 2] << 24) | (raw[..., 3] << 16) | (raw[..., 4] << 8) | raw[..., 5]
        a = np.stack([(v >> s) & 0xFFF for s in (36, 24, 12)], -1); a = np.where(a >= 2048, a - 4096, a)
        g = (a * 100 - off) / gain
        t = np.array(times)[:, None] + np.arange(300) / fs
        return t.ravel(), g.reshape(-1, 3)

    for psg in sorted(glob.glob(f"{D}/psg/mecsleep*_psg.txt")):
        pid = re.search(r"mecsleep(\d+)_psg", psg)[1]
        rows = [ln.split("\t") for ln in open(psg, encoding="latin-1").read().splitlines()]
        date = next(r[1] for r in rows if r[0] == "Recording Date:")
        k = next(i for i, r in enumerate(rows) if r[0] == "Sleep Stage"); tc = rows[k].index("Time [hh:mm:ss]")
        body = [r for r in rows[k + 1:] if len(r) > tc and re.fullmatch(r"\d\d:\d\d:\d\d", r[tc])]
        day = datetime.datetime.strptime(date, "%d/%m/%Y").replace(tzinfo=datetime.timezone.utc).timestamp()
        ts, last = [], None
        for r in body:                                   # clock times; a step backwards is midnight
            hh, mm, ss = map(int, r[tc].split(":")); t = day + hh * 3600 + mm * 60 + ss
            if last is not None and t < last - 43200: day += 86400; t += 86400
            ts.append(t); last = t
        if os.path.exists(f"{OUT}/NC{pid}-left.npz"): continue
        n = int(round((ts[-1] - ts[0]) / 30)) + 1; y = np.full(n, -1)
        for tt, r in zip(ts, body): y[int(round((tt - ts[0]) / 30))] = STAGE.get(r[0], -1)
        wrists = []
        for f in sorted(glob.glob(f"{D}/acc/MECSLEEP{pid}_*wrist_*.bin")):
            t, g = geneactiv(f)
            # The scoring's date can be the evening's or the morning's: take the one the device covers.
            day_shift = min((0, -86400, 86400), key=lambda s: -np.mean((ts[0] + s >= t[0]) & (ts[0] + s <= t[-1])))
            wrists.append(("left" if "_left wrist_" in f else "right", t, g, ts[0] + day_shift))
        # The sleep lab's clock and the accelerometers' weren't synchronised: offsets of 0.5-20 min,
        # the same on both wrists. Take the offset (within +-20 min) at which turns separate wake from
        # sleep best, over both wrists. This uses the labels, so it slightly flatters this set's own
        # fit; sleep-accel, as a check, comes out at 0 for 23 of 26 nights.
        def separation(grav):
            r = np.nan_to_num(hrv.rotation(grav, n)["rot"]) > 0; k = np.arange(n); out = []
            for L in range(-40, 41):
                rr = np.roll(r, L); m = (y >= 0) & (k >= 40) & (k < n - 40); w, sl = m & (y == 0), m & (y > 0)
                out.append(rr[w].mean() - rr[sl].mean() if w.sum() > 10 and sl.sum() > 10 else np.nan)
            return np.array(out)
        L = int(np.nanargmax(np.nanmean([separation(per_second(t - t0, g, n * 30)) for _, t, g, t0 in wrists], 0))) - 40
        grav = {side: per_second(t - (t0 - 30 * L), g, n * 30) for side, t, g, t0 in wrists}
        # Ambiguous offsets (a second peak, e.g. with periodic leg movements) don't come back to 0 on
        # every wrist after the shift: leave those nights out.
        left_over = [int(np.nanargmax(separation(v))) - 40 for v in grav.values()]
        if max(map(abs, left_over)) > 2:
            print(f"NC{pid}: skipped, clock offset ambiguous ({L / 2:+g} min, then {[x / 2 for x in left_over]})"); continue
        print(f"NC{pid}: scoring {L / 2:+g} min against the accelerometers")
        for side, v in grav.items(): save(f"NC{pid}-{side}", "NC", v, np.empty((0, 2)), y)
