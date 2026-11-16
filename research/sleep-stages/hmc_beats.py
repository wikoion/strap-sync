"""R-peaks and stages from the HMC sleep staging database (PhysioNet, 151 nights, ECG at 256 Hz, AASM
stages per 30 s). Writes one .npz per night: beats (seconds from the first epoch), y (0 wake, 1 light,
2 deep, 3 REM, -1 unscored). Run with the scratch venv (needs edfio and sleepecg)."""
import numpy as np, sys, os, glob, edfio, sleepecg
D, OUT = sys.argv[1], sys.argv[2]
os.makedirs(OUT, exist_ok=True)
STAGE = {"W": 0, "N1": 1, "N2": 1, "N3": 2, "R": 3}

for edf in sorted(glob.glob(f"{D}/recordings/SN[0-9][0-9][0-9].edf")):
    sid = os.path.basename(edf)[:-4]
    if os.path.exists(f"{OUT}/{sid}.npz"): continue
    scoring = f"{D}/recordings/{sid}_sleepscoring.txt"
    if not os.path.exists(scoring): continue
    ecg = next(s for s in edfio.read_edf(edf).signals if s.label == "ECG")
    fs = ecg.sampling_frequency
    peaks = sleepecg.detect_heartbeats(ecg.data, fs)
    ep = []
    for line in open(scoring).read().splitlines()[1:]:
        p = [x.strip() for x in line.split(",")]
        if p[4].startswith("Sleep stage ") and p[3] == "30":
            ep.append((float(p[2]), STAGE.get(p[4][12:], -1)))
    t0 = ep[0][0]; n = int((ep[-1][0] - t0) // 30) + 1
    y = np.full(n, -1)
    for t, s in ep: y[int((t - t0) // 30)] = s
    beats = peaks / fs - t0
    np.savez(f"{OUT}/{sid}.npz", beats=beats[(beats >= 0) & (beats < n * 30)], y=y)
    print(sid, n, "epochs", len(peaks), "beats", flush=True)
