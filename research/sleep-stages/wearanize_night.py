"""Wearanize+ OA PlugNPlay (Radboud Data Repository, doi:10.34973/j6jf-9e62; scientific research use only,
so evaluation only, never in shipped weights): healthy, mostly young adults sleeping at home, one night
each, PSG scored by hand (scorer 1, AASM, 30 s) with a
synchronised Empatica E4 on the wrist for most. One .npz per night in the shape sources.py takes for
ECG beats: beats (R-peaks from the PSG ECG, s), y (0 wake, 1 light, 2 deep, 3 REM, -1 other), src WZ,
and grav (the E4's per-second mean x, y, z, g) when the night has the E4. Every device in a PlugNPlay
file starts at the same moment, so time 0 is the start of the file.
Usage: wearanize_night.py <PlugNPlay Parquet dir> <out dir>. Needs pyarrow and sleepecg."""
import numpy as np, glob, os, sys
import pyarrow.parquet as pq, sleepecg
D, OUT = sys.argv[1], sys.argv[2]
os.makedirs(OUT, exist_ok=True)
STAGE = {0: 0, 1: 1, 2: 1, 3: 2, 4: 3}
ECG = ("ECG 2", "ECG1", "ECG2")                     # SOMNOscreen, then Mentalab

for p in sorted(glob.glob(f"{D}/*.parquet")):
    name = os.path.basename(p).split(".")[0]
    if os.path.exists(f"{OUT}/{name}.npz"): continue
    rows = pq.read_table(p, columns=["Device", "SamplingRate", "SignalData", "SleepScores"]).to_pylist()
    psg = next((r for r in rows if r["SleepScores"] and r["SleepScores"].get("ManualScores1")), None)
    if psg is None: print(name, "skipped: no manual scores"); continue
    ch = next((c for c in ECG if psg["SignalData"].get(c) is not None), None)
    if ch is None: print(name, "skipped: no ECG"); continue
    fs = psg["SamplingRate"][ch]; ecg = np.asarray(psg["SignalData"][ch], float)
    try: beats = sleepecg.detect_heartbeats(ecg, fs) / fs
    except ValueError as e: print(name, "skipped:", e); continue        # e.g. a flat (empty) ECG channel
    y = np.array([STAGE.get(int(v), -1) if v is not None else -1 for v in psg["SleepScores"]["ManualScores1"]])
    out = dict(beats=beats, y=y, src="WZ")
    e4 = next((r for r in rows if r["Device"].startswith("Empatica")), None)
    if e4 is not None and e4["SignalData"].get("ACCX") is not None:
        f4 = e4["SamplingRate"]["ACCX"]; a = np.vstack([np.asarray(e4["SignalData"][k], float) for k in ("ACCX", "ACCY", "ACCZ")]).T / 64
        sec = (np.arange(len(a)) / f4).astype(int); n = len(y) * 30; ok = sec < n
        cnt = np.bincount(sec[ok], minlength=n)
        with np.errstate(all="ignore"):
            out["grav"] = np.vstack([np.bincount(sec[ok], a[ok, k], n) for k in range(3)]).T / cnt[:, None]
    np.savez(f"{OUT}/{name}.npz", **out)
    print(name, len(y), "epochs,", len(beats), "beats from", ch, "at %g Hz;" % fs, "E4 gravity" if "grav" in out else "no E4", flush=True)
