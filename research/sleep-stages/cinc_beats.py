"""R-peaks and stages from the PhysioNet/CinC Challenge 2018 training set (994 MGH nights, open,
ECG at 200 Hz, AASM stages as change points in the .arousal files). Downloads each record into
<work dir>, keeps only the .npz (beats, y as in hmc_beats.py) in <out dir>, and deletes the 134 MB
signal file. Several can run at once on different record ranges, each with its own work dir.
Usage: cinc_beats.py <work dir> <out dir> <first> <count>. Needs wfdb and sleepecg."""
import numpy as np, sys, os, subprocess, wfdb, sleepecg
WORK, OUT, first, count = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
# PhysioNet's AWS mirror of its open data: about 20 MB/s here, against well under 1 MB/s from physionet.org.
URL = "https://physionet-open.s3.amazonaws.com/challenge-2018/1.0.0/training/"
STAGE = {"W": 0, "N1": 1, "N2": 1, "N3": 2, "R": 3}
os.makedirs(WORK, exist_ok=True); os.makedirs(OUT, exist_ok=True)
names = [r.strip("/") for r in subprocess.run(["curl", "-sSL", URL + "RECORDS"], capture_output=True, text=True).stdout.split()]

for r in names[first: first + count]:
    if os.path.exists(f"{OUT}/{r}.npz"): continue
    for ext in ("hea", "arousal", "mat"):
        subprocess.run(["curl", "-sSL", "--retry", "4", "-o", f"{WORK}/{r}.{ext}", f"{URL}{r}/{r}.{ext}"], check=True)
    try:
        rec = wfdb.rdrecord(f"{WORK}/{r}", channel_names=["ECG"]); fs = rec.fs
        ann = wfdb.rdann(f"{WORK}/{r}", "arousal")
        peaks = sleepecg.detect_heartbeats(rec.p_signal[:, 0], fs)
        ch = [(s / fs, STAGE[a]) for s, a in zip(ann.sample, ann.aux_note) if a in STAGE]
        t0 = ch[0][0]; n = int((rec.sig_len / fs - t0) // 30)
        y = np.full(n, -1)
        for (t, s), nxt in zip(ch, [c[0] for c in ch[1:]] + [t0 + n * 30]):
            y[int(round((t - t0) / 30)): int(round((nxt - t0) / 30))] = s
        beats = peaks / fs - t0
        np.savez(f"{OUT}/{r}.npz", beats=beats[(beats >= 0) & (beats < n * 30)], y=y)
        print(r, n, "epochs", len(peaks), "beats", flush=True)
    except Exception as e:
        print(r, "failed:", e, flush=True)
    finally:
        for ext in ("hea", "arousal", "mat"):
            if os.path.exists(f"{WORK}/{r}.{ext}"): os.remove(f"{WORK}/{r}.{ext}")
