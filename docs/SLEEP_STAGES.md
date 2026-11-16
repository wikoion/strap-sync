# Sleep stages: research status

Status 2026-11-12: **an interim model is in the app and writes to Apple Health** (the
owner's call, before the gate below is met).
- **In Health:** each staged night goes as `awake` / `asleepCore` / `asleepDeep` / `asleepREM`, one
  sample per run (`whoopsync:stage:<start>`, version = the model's date and time as digits),
  replacing its `asleepUnspecified`.
- **On restaging:** the night is cleared from Health first (`Store.stageNight`), and its resting HR
  and breathing are written back with it.
- **Fallback:** nights without enough beats to stage keep plain `asleepUnspecified`.
- **The model** (version `2026-11-12.1332`: the weights of `2026-10-30.0435`, commit `6e0cd68`, under a
  new version so the app restages its nights):
  - **Heart:** the mean of the two-stage LightGBM and the bidirectional GRU, both trained on 1,027
    open ECG nights (HMC and all of CinC 2018). κ 0.520 on held-out sleep-lab nights (LightGBM
    alone 0.439, the GRU alone 0.522) and 0.609 on healthy nights at home (Wearanize+, never trained
    on). See [More training nights](#more-training-nights-30-oct).
  - **Movement:** a third LightGBM over wrist rotation alone, trained on 276 open Apple Watch
    nights (sleep-accel and BIDSleep). It's fused into the heart's probabilities before the Viterbi
    pass and only moves wake against sleep, at half weight. Epochs without gravity stay
    heart-only. See [Wrist rotation](#wrist-rotation-rotation_cvpy).
  - **DREAMT and Wearanize+ are left out, and stay for evaluation only:** DREAMT's DUA rules out
    sharing models trained on it, and Wearanize+'s terms limit both its versions to scientific
    research. `export_model.py` refuses either.
  - **Wearanize+ in training was tried and withdrawn.** From 30 Oct the owner's own builds ran
    `2026-10-30.0808`, with Wearanize+ in the LightGBM parts: κ 0.618 against this model's 0.609 on
    held-out Wearanize+ nights. On the owner's first two trial nights it agreed with the Fitbit 83.2% /
    88.7% of the time, against 85.9% / 88.1% for this one; see
    [Healthy sleepers at home](#healthy-sleepers-at-home-wearanize-30-oct).
- **Where it runs:** `SleepStager` in SyncCore (`SleepStages.swift`, `GBDT.swift`, model in
  `Resources/SleepModel/` from `export_model.py`) stages each finished night in `processNights`,
  from history RR and the per-second gravity vector (R18 bytes 45/49/53, stored as `motion.gx/gy/gz`
  from build `db718d4`). `Store.stages` keeps the result. The main screen shows it under "Sleep
  stages (experimental)" and the outbox takes it to Health.
- **Parity:** `SleepStagesTests` checks the Swift against Python on three hours of HMC SN003
  (`Fixtures/stages-hmc.json`) with three hours of a BIDSleep night's gravity (BS00-1). Features agree to
  1e-13, every model's probabilities (the GRU's against PyTorch in float64) and the fused ones to
  1e-9, and the stages exactly.
- **Speed:** SyncCore builds with `-O` even in Debug, so a night takes about 1.5 s instead of
  about 15. The models themselves take 0.3 s a night on the Mac, the GRU 0.1 s of it.

Scripts are in `research/sleep-stages/`.

**Where it stands:**
- **Against sleep-lab scoring:** a bidirectional GRU over HRV features reaches κ 0.48 (67%) on 382
  held-out sleep-clinic nights, with no movement signal. The two-stage LightGBM gets 0.43.
  - That's ahead of independent tests of Fitbits (0.41–0.42), but short of Google's own figure for
    its current algorithm (0.63).
  - It's also short of Verily's heart-only CNN on the same CinC nights (0.55 vs our 0.46; theirs
    trained on 10,000 nights).
- **On the MG's first night:** the two-stage LightGBM agrees with the Fitbit Air 82% of the time
  (κ 0.67), and the GRU 76% (κ 0.58).
  - Their difference is wake: the GRU scores 72 minutes, the Fitbit 1.
  - The GRU's wake falls where the strap shows large movements. Which of them is right needs an EEG
    reference.
- The first model managed 52% (κ 0.09). About 9 points of that gap was a wrong night window (see
  [Correction](#correction-the-mg-night-window)); the rest is HRV and context.
- **On wrist data (DREAMT, 23 nights so far):** κ 0.31. Those patients are much sicker, and wrist
  beats are noisier.

## What the strap gives

- **R18 byte 81, bits 4–5 = 2 is the band's own sleep flag, and it's accurate.**
  - On the first real night, its total sleep was within 2 minutes of the owner's Fitbit Air's.
  - The app now uses it to define the night (`Sleep.swift`), with stillness plus HR as the fallback.
- **No stages on the strap.**
  - Tested every unmapped R18 status byte (33, 36, 75–82, 104–112, and byte 81's other bit groups)
    against Fitbit's per-second stages for that night: `bytes.py` and `timeline.py`.
  - u16@75 / byte 76 correlated (byte 76 = 9 for 75% of REM seconds), but it changes only a few times
    a night in long runs (8 → 6 → 7 → 8 → 9 → A). That looks like optical/AFE settings drifting, not
    stages.
  - Stages are computed in WHOOP's cloud.
- **Beat intervals are good enough for HRV overnight.**
  - History RR covered 89% of the band-flag night: 29,461 intervals, 150 gaps, median gap 30 s
    (90th percentile 50 s), runs averaging 195 beats.
  - The first hour after the band flag starts covered about 50%; every hour after that 87–98%.
  - The earlier "60%" was the whole 18-h download including the day; it doesn't apply to sleep.

## Correction: the MG night window

`onset.py`, `whoop_night.py` and `stager.py` hardcoded a night window (N0, N1) that started 70 minutes
before the band flag's (`motion.state` = 2) and ended 80 minutes before it.
- So the first model's MG-vs-Fitbit score counted 70 minutes of evening wake as sleep, and cut off
  the last 80 minutes.
- Its time-since-onset features were also 70 minutes off, which explains part of its "right totals,
  wrong timing" result.
- All four scripts now use the band-flag times. The Fitbit lookup was always by absolute UTC, so
  the byte search in `bytes.py` and `timeline.py` is unaffected.

## What "beating Fitbit" means

Against polysomnography (PSG), four classes (wake / light / deep / REM), per 30-s epoch:

| System | κ | Accuracy | Source |
|---|---|---|---|
| Human scorers, AASM rules | ~0.76 | | inter-rater figure quoted by Radha 2021 |
| Google's updated Fitbit/Pixel algorithm (IBI + accelerometer) | 0.63 | 77% | Google 2026, in-house, 50 held-out PSG nights |
| The Fitbit algorithm before that update | 0.56 | 71% | same paper |
| Fitbit Sense / Apple Watch / Oura | 0.55 / 0.60 / 0.65 | | Robbins 2024, 35 adults (Oura promotes it) |
| Fitbit Sense / Fitbit Charge 5 / Apple Watch S8 | 0.42 / 0.41 / 0.53 | | Schyvens 2025, 62 adults, independent |
| WHOOP 4.0 | 0.37 | | Schyvens 2025 |

- The Fitbit Air has no published validation. It presumably runs Google's current algorithm.
- So the real target is **κ ≈ 0.6 on held-out PSG nights with MG-like inputs**. That beats every
  independent Fitbit number and roughly matches Google's own claim.
- Clinical datasets score lower than healthy ones for every method. Sridhar's model got κ 0.66 on
  SHHS but 0.55 on CinC 2018, a sleep clinic population.
- **Agreement with the Fitbit can't show we beat it.**
  - If both are about 70% right against PSG, they agree only about 50–65% of the time, depending
    on how much their errors overlap.
  - Scoring needs PSG-labelled data. For the owner's own nights it needs an EEG reference: a
    Muse S headband scored κ 0.76 against PSG in 56 adults (Lanthier 2025, SLEEP Advances).

## What the literature says works

- **HRV is the big step.** Oura (Altini & Kinnunen 2021) measured each signal's contribution with
  LightGBM over 440 nights:

  | Inputs | 4-stage accuracy |
  |---|---|
  | accelerometer | 57% |
  | + skin temperature | 60% |
  | + HR and HRV | 76% |
  | + circadian features | 79% |

  - It used 5-fold CV, possibly not split by person.
  - **Features:** HR, RMSSD, SDNN, pNN50, LF and HF power, LF and HF peak frequencies, total and
    normalised power, breathing rate. Windows were 1 and 5 min.
  - **Normalisation:** per night, using the 5–95 percentiles.
  - **Artefacts:** an interval is dropped if it's more than 16 bpm from its 7-beat median, and kept
    only with two good intervals either side.
  - **Circadian features:** cosine, exponential decay and linear time across the night.
- **Heart-only deep models:**
  - Sridhar 2020 (Verily): a CNN on instantaneous HR at 2 Hz, trained on 10,000 SHHS + MESA
    nights. κ 0.66 on held-out SHHS, 0.55 on CinC 2018.
  - Radha 2019 (Philips): an LSTM on HRV features, κ 0.61. Radha 2021: wrist PPG via transfer
    learning, κ 0.65.
  - SleepPPG-Net: raw finger PPG, κ 0.75. It needs raw PPG, which the MG's history doesn't have.
- **Physiology the features catch:**
  - deep: low HR, high HF power and RMSSD, steady breathing, low DFA α1;
  - REM: HR higher and irregular, LF/HF up, DFA α1 near 1, irregular breathing;
  - wake: movement and HR surges.

## Open-source models

None ships 4-stage weights for beat intervals, so we train our own and borrow the recipes.

| Project | Input | Classes | Weights | Licence | Use to us |
|---|---|---|---|---|---|
| [sleepecg](https://github.com/cbrnr/sleepecg) | R-peak times → HRV features, GRU | wake/sleep; wake/REM/NREM | yes (MESA) | BSD-3 | No deep class; 3-class κ 0.54 on SHHS. Its fast R-peak detector is used here for the ECG datasets. |
| [WatchSleepNet](https://github.com/WillKeWang/WatchSleepNet_public) (Duke, CHIL 2025) | IBI sequence, ResNet + TCN + LSTM + attention | wake/NREM/REM | no | MIT | Recipe: pretrain on ECG IBI (SHHS + MESA), fine-tune on wrist IBI (DREAMT). Also has SleepPPG-Net and InsightSleepNet code. |
| Sridhar 2020 | IHR | 4 | no code found | | Architecture described fully; could reimplement. |
| sleep_classifiers (Walch 2019) | HR + accelerometer | 3 | | | Already replicated in `model.py`. |
| YASA | EEG | 5 | yes | BSD-3 | Only for scoring an EEG headband reference. |

## Datasets

| Dataset | Nights | Signals | Labels | Access | Status |
|---|---|---|---|---|---|
| sleep-accel | 31 | Apple Watch HR (~0.2 Hz) + wrist accelerometer | PSG | open | used by the first model; its rotation (30 nights) trains the shipped movement model |
| Newcastle PSG + GENEActiv | 28 (clinic) | GENEActiv on both wrists, 85.7 Hz; no HR | PSG | open, CC BY 4.0, 0.96 GB (Zenodo) | converted with clock offsets fixed (24 used); a test set |
| **HMC** | 151 | ECG 256 Hz | PSG, AASM | open, CC BY 4.0, 15.7 GB | used: 140 pass the ECG check |
| **CinC 2018** | 994 | ECG 200 Hz | PSG, AASM | open, ODC-By, 135 GB | all records' beats extracted (973), from PhysioNet's AWS mirror (`physionet-open` S3, about 20 MB/s against physionet.org's 0.5) |
| BIDSleep (UMass Lowell, Sep 2026) | 253 (47 healthy, 3–7 nights each) | Apple Watch HR ~0.2 Hz + accelerometer ~50 Hz | Dreem 2 EEG, expert-corrected | open, ODC-By, 6.35 GB zip | in `~/datasets/bidsleep` (CRCs checked), all 253 converted; 246 train the shipped movement model |
| **DREAMT** | 100 | Empatica E4: BVP 64 Hz, IBI, accelerometer 32 Hz, skin temp 4 Hz | PSG | restricted: PhysioNet DUA (signed 29 Oct) | all 100 in `~/datasets/dreamt/data_64Hz` (checked against SHA256SUMS), 94 converted (the rest have no scoring or beats); about two thirds have beats covering at least half the night |
| Wearanize+ OA | 100 (healthy, at home) | PSG ECG; Empatica E4 accelerometer | PSG, hand-scored | Radboud Data Repository; scientific research only | evaluation only: 93 nights converted (87 with the E4); never in shipped weights |
| MESA | ~2,000 | ECG, finger PPG, wrist actigraphy | PSG | NSRR data request (free, days) | optional: the only big set with heart and wrist movement together |
| SHHS | ~8,000 | ECG | PSG | NSRR | optional |

## HRV model (`hrv.py`, `stack.py`, `gru.py`, `hrv_cv.py`, `hrv_stack.py`, `gru_cv.py`, `mg_night.py`)

**Beats:**
- **ECG datasets:** R-peaks from `sleepecg.detect_heartbeats` (`hmc_beats.py`, `cinc_beats.py`).
  Nights where under 70% of intervals pass the artefact check are dropped (HMC SN001 is one).
- **The MG:** beat times rebuilt from history RR. Each RR ends in its 1-s record, and records
  further apart than the RR plus 1.5 s mark a gap.
- **Thinning:** ECG beats are thinned with a two-state Markov mask to the MG's measured pattern
  (89% kept, runs averaging 195 beats).

**Features per 30-s epoch** (34 in all):
- **Gap handling:** successive differences only use adjacent beats, and spectra use Lomb-Scargle,
  so a gap leaves a hole and not a fake interval.
- **1-min window:** HR, ln RMSSD, ln SDNN, coverage.
- **5-min window:** HR, ln RMSSD, ln SDNN, pNN50, ln LF, ln HF, ln LF/HF, HFnu, the HF peak as
  breathing rate, the HF peak's share of HF power (breathing regularity), DFA α1, coverage.
- **Context:** ±5 and ±15-min means of HR, RMSSD, HF, LF/HF, DFA α1 and HFnu; HR minus its 15-min
  baseline; breathing-rate spread over about 10 min.
- **Normalisation:** per night, (x − median) / (p95 − p5), except coverage.
- **Time:** hours since onset, exp(−hours / 2), fraction of the night, cosine of the fraction.

**Classifier:**
- LightGBM: 300–400 trees, 31 leaves, at least 200 rows per leaf, class weights (1/prior)^0.5.
- Then the tempered Viterbi from `mlp.py`.
- **Second stage** (`stack.py`): another LightGBM over the first stage's probabilities at
  neighbouring epochs (up to ±20 min) and their rolling means. It's trained on inner-fold
  (out-of-fold) probabilities.
- **GRU** (`gru.py`), the alternative:
  - shape: a linear layer, then 2 bidirectional GRU layers of 64 units over the whole night;
  - inputs: the same features with NaN set to 0 and clipped to ±5, plus two no-beats flags;
  - training: class-weighted cross-entropy, early stopping on a tenth of the training nights.
  - About 12 minutes per fold on the CPU.
  - It reads the whole night, so the night's cycle structure is visible to it.
- **LightGBM and torch must not run in one process:** each brings its own OpenMP, and on macOS
  they deadlock with no error. `mg_night.py --gru` imports only torch; the default imports only
  LightGBM.

**Results** (sleep period only, 5-fold split by night, every HMC/CinC night is a different person):

| Evaluation | Accuracy | κ | Minutes wake / light / deep / REM |
|---|---|---|---|
| HMC 140 nights, HR only, full ECG | 0.503 | 0.216 | 6254 / 36413 / 10583 / 7916 (truth 8517 / 30380 / 12468 / 9802) |
| same, HR + HRV, full ECG | 0.596 | 0.372 | 6822 / 34580 / 11552 / 8212 |
| same, HR only, MG-thinned | 0.497 | 0.207 | |
| same, HR + HRV, MG-thinned | 0.594 | 0.367 | 6278 / 35008 / 11579 / 8302 |
| HMC 140 nights, both stages (`hrv_stack.py`), MG-thinned | 0.627 | 0.425 | 6329 / 33686 / 11299 / 9853 |
| HMC + CinC 382 nights, first stage only | 0.618 | 0.356 | 17531 / 104683 / 22626 / 22245 (truth 23861 / 93907 / 25515 / 23802) |
| **HMC + CinC 382 nights, both stages** | **0.649** | **0.431** | 21161 / 95120 / 24532 / 26272 |
| of which HMC (140) / CinC (242) | 0.642 / 0.653 | 0.453 / 0.415 | |
| MG night vs Fitbit, first model (`onset.py`) with the window fixed | 0.607 | 0.181 | 1 / 449 / 74 / 78 |
| MG night vs Fitbit, first HRV stage, trained on HMC | 0.774 | 0.550 | 22 / 418 / 45 / 116 |
| same, trained on HMC + CinC | 0.795 | 0.613 | 22 / 391 / 71 / 118 |
| **HMC + CinC 382 nights, GRU** (`gru_cv.py`, same folds) | **0.671** | **0.482** | 23271 / 87713 / 29315 / 26785 |
| of which HMC (140) / CinC (242) | 0.677 / 0.667 | 0.515 / 0.460 | |
| **MG night vs Fitbit, both stages, trained on HMC + CinC** | **0.816** | **0.669** | 23 / 353 / 80 / 146 |
| MG night vs Fitbit, GRU, trained on HMC + CinC | 0.758 | 0.579 | 72 / 350 / 100 / 80 |

**What the results show:**
- **HRV adds about 0.15 κ over HR alone.** The MG's gaps cost almost nothing (0.372 → 0.367).
- **The context stage adds another 0.05–0.08.** Going from 112 to about 305 training nights
  added about 0.03 on HMC.
- **The most useful features** were DFA α1 (±15 min), SDNN, time since onset, breathing-rate
  spread, HR against its baseline, and the breathing rate.
- **HMC is a sleep clinic population.** It has 14% wake inside the sleep period, and no movement
  signal reaches this model, so wake is its weakest class. On the MG, movement and the band flag
  cover that.
- **The GRU beats both LightGBM stages on held-out nights** (0.482 vs 0.431), on both datasets.
- **On the MG night,** the REM blocks and the deep blocks line up with Fitbit's, including the first
  deep block, which the HMC-only model missed.
  - **The MG's beat gaps are movements.** 78% of epochs with a 1-minute gap have movement above
    the night's 90th percentile, against 8% elsewhere (median peak 0.21 g against 0.01 g).
  - The GRU scores many of those as wake. The Fitbit scored only 1 minute of wake in 10 hours,
    and every device in Schyvens 2025 underestimated wake after sleep onset (by 12–48 minutes).
  - So the GRU's extra wake may be partly right.
  - This also means the random thinning used in training doesn't match the MG: real gaps go with
    movement.
  - One night is very little.
  - 82% agreement means both devices read the same autonomic signal. It doesn't mean either is
    right: Fitbit's errors and ours are probably correlated.

## Wrist rotation (`rotation_cv.py`)

**The measure** (`hrv.rotation()`): per 30-s epoch, the share of its six 5-s steps whose mean
gravity direction turns more than 5° (and more than 30°, a change of position), plus ±1/5/10-min
means, and minutes since and until the nearest turn. Angles don't depend on a device's units,
mounting or noise floor.

**It reads the same across devices:**

| Device | Epochs with a >5° turn, asleep / awake (median night) | Turn events per hour asleep | 5-s steps per event (mean) | Turn size p50 / p90 |
|---|---|---|---|---|
| Apple Watch (sleep-accel, 30 nights) | 3.5% / 49.9% | 3.9 | 2.07 | 16.5° / 58.6° |
| Empatica E4 (DREAMT) | 3.4% / 31.7% | 5.2 | 1.96 | 14.0° / 56.5° |
| MG, 28→29 Oct | 9.0% of the night | 9.3 | 2.59 | 19.2° / 85.7° |

The MG night simply had more turns: 65 movement bouts showed in the magnitudes.

**Models compared** (all LightGBM; temperature left out):
- **heart:** what shipped before, both stages on the ECG nights.
- **fused:** heart × a rotation-only model trained on the open Apple Watch nights, P ∝ P_heart ×
  (P_move / prior_move)^w (`model.fuse`). With **wake**, rotation only moves wake against sleep.
- **joint:** both stages on ECG + Apple Watch nights together (their HR and rotation).
- **joint+DR:** joint plus the other DREAMT folds, 5-fold. Research only.

**On DREAMT** (56 nights with beats over half the night; sleep period). Only joint+DR has seen any
DREAMT. Wake columns: epoch sensitivity / precision, recall of true wake bouts up to 5 min, share of
predicted bouts near true wake, predicted bouts per night.

| Model | Accuracy | κ | Wake sens / prec | Short bouts found | Bouts real | Bouts / night |
|---|---|---|---|---|---|---|
| heart | 0.577 | 0.259 | 0.43 / 0.36 | 0.27 | 0.78 | 4.9 |
| fused, w 0.5 | 0.607 | 0.312 | 0.52 / 0.50 | 0.37 | 0.83 | 7.1 |
| **fused wake, w 0.5 (shipped)** | **0.609** | **0.312** | **0.53 / 0.49** | **0.38** | **0.83** | **6.8** |
| fused, w 1 | 0.574 | 0.295 | 0.58 / 0.50 | 0.48 | 0.77 | 10.4 |
| fused wake, w 1 | 0.609 | 0.320 | 0.59 / 0.48 | 0.49 | 0.79 | 9.9 |
| joint | 0.614 | 0.307 | 0.44 / 0.53 | 0.26 | 0.89 | 4.2 |
| joint+DR (not shippable) | 0.713 | 0.378 | 0.52 / 0.56 | 0.37 | 0.92 | 6.1 |

**On the MG's 28→29 Oct night** (against the Fitbit Air, which scored 1 minute of wake):

| Model | Agreement | κ | Minutes wake / light / deep / REM | Wake bouts (all at a turn) |
|---|---|---|---|---|
| heart | 81.6% | 0.669 | 23 / 353 / 80 / 146 | 3 |
| **fused wake, w 0.5 (shipped)** | **77.9%** | **0.622** | **55 / 324 / 80 / 143** | **9** |
| fused wake, w 1 | 73.8% | 0.571 | 87 / 301 / 79 / 136 | 16 |
| joint | 82.0% | 0.675 | 21 / 352 / 82 / 147 | 6 |
| joint+DR | 66.5% | 0.382 | 90 / 390 / 7 / 116 | 11 |

**What it shows:**
- **Rotation carries over.** Trained on Apple Watch nights, it improves a different wrist device's
  wake on sleep-clinic patients. It finds more of the real wake (sensitivity 0.43 → 0.53) and calls
  wake wrongly less often (precision 0.36 → 0.49), so it isn't inventing wake there.
- **The joint model barely uses rotation.** Its rows with rotation have no HRV, so the trees learn
  rotation for HR-only nights and mostly ignore it when HRV is there. Fusing separately trained
  models avoids that.
- **Weight 0.5 rather than 1:** κ is level (0.312 vs 0.320). Weight 1 finds more short bouts on
  DREAMT (0.49 vs 0.38) at the same precision, but scores 87 minutes of wake on the MG night, against the
  Fitbit's 1. So the smaller weight is the cautious choice until the trial nights say otherwise.
- **DREAMT-trained movement is much better** (joint+DR κ 0.378), but it can't ship. BIDSleep's 253
  healthy home nights should narrow that gap for the open model.
- **The one MG night** can't say whether the extra wake is right. The trial nights are the test.

## The average of LightGBM and the GRU (`ensemble_cv.py`, `gru_probs.py`)

**On the 382 ECG sleep-lab nights** (heart only, the same 5 folds as before):

| Heart model | Accuracy | κ | of which HMC / CinC |
|---|---|---|---|
| LightGBM, both stages | 0.649 | 0.431 | 0.453 / 0.415 |
| GRU | 0.668 | 0.482 | 0.510 / 0.463 |
| GRU + Viterbi | 0.669 | 0.479 | |
| **mean of the two + Viterbi (shipped)** | **0.680** | **0.484** | **0.507 / 0.466** |
| mean of the two, no Viterbi | 0.676 | 0.487 | 0.512 / 0.469 |

**On DREAMT** (the same 56 nights as [Wrist rotation](#wrist-rotation-rotation_cvpy); only ECG and
Apple Watch nights trained on):

| Model | Accuracy | κ | Wake sens / prec | Short bouts found |
|---|---|---|---|---|
| LightGBM | 0.577 | 0.259 | 0.43 / 0.36 | 0.27 |
| LightGBM + rotation, w 0.5 | 0.609 | 0.312 | 0.53 / 0.49 | 0.38 |
| GRU | 0.583 | 0.306 | 0.45 / 0.42 | 0.27 |
| GRU + rotation, w 0.5 | 0.603 | 0.340 | 0.54 / 0.49 | 0.36 |
| mean | 0.602 | 0.311 | 0.44 / 0.41 | 0.27 |
| **mean + rotation, w 0.5 (shipped)** | **0.627** | **0.357** | **0.56 / 0.51** | **0.38** |
| mean + rotation, w 1 | 0.622 | 0.355 | 0.60 / 0.50 | 0.48 |

**On the MG's 28→29 Oct night** (against the Fitbit Air):

| Model | Agreement | κ | Minutes wake / light / deep / REM | Wake bouts |
|---|---|---|---|---|
| LightGBM + rotation | 77.9% | 0.622 | 55 / 324 / 80 / 143 | 9 |
| GRU | 78.8% | 0.620 | 17 / 349 / 98 / 137 | 5 |
| mean | 86.6% | 0.751 | 10 / 374 / 84 / 134 | 3 |
| **mean + rotation, w 0.5 (shipped)** | **82.1%** | **0.682** | **48 / 354 / 84 / 117** | **11, all at turns** |

**What it shows:**
- **The mean is the best heart model everywhere.** It's level with the GRU on the sleep-lab nights
  and ahead on DREAMT and the MG.
- **Rotation adds about the same on top of either:** +0.05 κ on DREAMT, with more wake found and
  wake called wrongly less often.
- **A net only knows the inputs it was trained with.** Trained on ECG nights, the GRU never saw
  rotation or temperature: those inputs were always 0 with their flags at 1, so their weights stayed
  random. Real values there are noise, so it's given the heart columns only (`gru.heart_only`).
  Earlier DREAMT figures for the ECG-only GRU (κ 0.28) were hurt by this; it scores 0.306 without
  it. LightGBM is immune: it never splits on a column that was always missing.

## Healthy sleepers at home: Wearanize+ (30 Oct)

Wearanize+ OA (Radboud Data Repository) has 100 nights of healthy, mostly young adults at
home with hand-scored PSG and a synchronised Empatica E4. `wearanize_night.py` takes the PSG ECG's
beats (thinned to the MG's coverage like the other ECG nights) and the E4's gravity. 93 nights pass the
beat check, 87 of them with the E4. It's the closest test to the owner's nights, and the first like-for-
like check on healthy sleepers.

**Evaluation only.** Its README says both versions "may only be used for scientific research purposes", so
no shipped weights are trained on it. The model trained with it below (`2026-10-30.0808`) ran in the
owner's own builds from 30 Oct and was withdrawn on 12 Nov, before the app was published; the app is back
on the weights without it (`2026-10-30.0435`, re-versioned `2026-11-12.1332`). Leaving it out costs κ 0.009
on these nights (0.609 against 0.618). On the owner's first two trial nights agreement with the Fitbit is
85.9% / 88.1% without it, against 83.2% / 88.7% with it.

**Candidates on Wearanize+ before it was used for training** (62 nights, the first converted):

| Candidate | κ | Wake minutes (truth 1,722) | MG agreement 28→29 / 29→30 |
|---|---|---|---|
| C0, shipped (`2026-10-30.0435`, now `2026-11-12.1332`) | 0.614 | 2,149 | 85.9% / 88.1% |
| C1: heart + DREAMT | 0.605 | 2,327 | 81.1% / 88.9% |
| C2: rotation + DREAMT | 0.612 | 2,226 | 85.9% / 88.1% |
| C3: rotation + Newcastle | 0.613 | 2,175 | 85.9% / 88.1% |
| C12: both DREAMT additions | 0.605 | 2,407 | 81.1% / 88.6% |

DREAMT pushes wake up on healthy nights (its patients have a lot), as noop found; Newcastle is neutral.

**Wearanize+ as training data** (5 folds by participant, all 93 nights held out once):

| Model | κ | Accuracy | Per-night median κ | Wake minutes (truth 2,235) |
|---|---|---|---|---|
| shipped | 0.609 | 0.757 | 0.626 | 3,230 |
| + Wearanize+ in both LightGBM heart stages and the rotation model (`2026-10-30.0808`, withdrawn: research use only) | 0.618 | 0.763 | 0.638 | 3,091 |

- Better in every fold (+0.001 to +0.014) and on 52 of 93 nights (worse on 22).
- **Retraining the GRU with Wearanize+ too doesn't help consistently:**
  - pooled κ 0.622, but better in only 3 of 5 folds (−0.008 to +0.020) and on 40 of 93 nights
    (worse on 40, median change 0);
  - 3,318 minutes of wake, against 3,091 and a truth of 2,235.
  So the GRU stays on the 1,027 HMC + CinC nights.
- On the MG nights: 83.2% / 88.7% agreement with the Fitbit (85.9% / 88.1% before). The 28→29 night
  gets more deep (111 minutes against the Fitbit's 82).

**Every model over-calls wake on these nights.** For the shipped model, by rotation weight:

| Weight | κ | Wake minutes (truth 2,235) | Wake sens / prec |
|---|---|---|---|
| 0 (heart only) | 0.602 | 2,017 | 0.45 / 0.50 |
| 0.25 | 0.608 | 2,587 | 0.59 / 0.51 |
| 0.5 (shipped) | 0.609 | 3,230 | 0.67 / 0.46 |

Rotation helps, and 0.25 would match the wake fraction better at the same κ. But on the MG the model
already scores almost no wake, and 0.25 would score less, so the weight waits for the trial nights.

**Against the published figures** (all different populations and labs): Oura 0.65 and Apple Watch 0.60
(Robbins 2024), Google's own Fitbit figure 0.63, Fitbit Sense 0.55 (Robbins), independent Fitbits
0.41–0.42 and WHOOP 4.0 0.37 (Schyvens 2025). This passes the κ ≥ 0.55 gate (step 7). The caveat:
the beats are thinned PSG ECG, not the MG's own optical beats.

## Against noop's stager (30 Oct)

ryanbr/noop's default stager, `SleepStagerV2` (commit `2a1de76`), is a hand-set recipe, not a trained
model: z-scored HR / HR variability / movement, a deep gate, a sleep-cycle prior, a jerk wake gate and a
sticky Viterbi. It was built byte-identical outside this repo, and its 52 tests pass. Its own harness
reproduces its published sleep-accel figure (κ 0.371). It was then given exactly our nights, windows and
cleaned, thinned beats. noop is PolyForm Noncommercial: it was run for evaluation only; none of its code
is in this repo.

| Test set | Epochs | Ours: accuracy / κ | noop: accuracy / κ | noop given more (best variant) |
|---|---|---|---|---|
| ECG sleep-lab, 1,027 nights (no movement) | 895,787 | **0.711 / 0.520** | 0.470 / 0.176 | 0.191 (dense 1 Hz HR) |
| DREAMT, 65 nights | 49,019 | **0.651 / 0.394** | 0.503 / 0.206 | 0.246 (the E4's own HR) |
| MG 28→29 Oct vs Fitbit | one night | **85.9% / 0.760** | 58.0% / 0.348 | 0.404 (raw-archive gravity) |
| MG 29→30 Oct vs Fitbit | one night | **88.1% / 0.793** | 70.9% / 0.546 | |
| sleep-accel, 31 nights | 26,773 | can't run (no beat intervals) | 0.611 / 0.371 | |

- **Ours is ahead on 1,007 of 1,027 sleep-lab nights** (median +0.33 κ) and 57 of 65 DREAMT nights.
  Within true sleep alone, ours is right 73% of the time on the sleep-lab nights, noop 55%.
- **Without movement noop scores no wake at all**; true wake goes to REM, which it over-calls 2.4×.
- **The comparison leans our way in places:** our model was trained on the same cohorts (out of fold),
  its DREAMT and MG fusion settings were chosen by looking at those nights, and both get the PSG sleep
  period as the window. Giving noop more than ours had (dense HR, the E4's HR) moves it by 0.04 κ at
  most.
- **The Fitbit's two exports of 28→29 disagree on 21% of epochs:** the dashboard's older
  `sleep_segments` export has 1 minute of wake, Health Sync's samples have 24. Agreement figures
  for that night use the samples (against the old export: 85.1%).

## The trial nights (MG + Fitbit Air)

Compared each morning from both apps' DBs: Strap Sync's `stages` and Health Dashboard's `samples`
(`type = 'sleep_stage'`, source `nl.appyhapps.healthsync`, stage in `method`). The dashboard's
`sleep_sessions` keeps one session a night and now prefers Strap Sync's, so the Fitbit's must come
from `samples`.

- **Over the first three trial nights** (model `2026-10-30.0435`, and `2026-10-30.0808` on the third),
  the model agreed with the Fitbit on 85.8% of epochs on average (κ 0.760). Python recomputes the phone's
  epochs exactly.
- **Health Sync copies Strap Sync's stages back into Health under its own name** (from 31 Oct).
  `evaluate.py` drops Health Sync samples that are exactly one of our runs; the rest is the Fitbit's
  (minute boundaries, against our half-minute ones).
- **Deep:** over those nights the Wearanize+ model scored more deep than the Fitbit, about 20 minutes a
  night on average. On Wearanize+ our deep minutes are within 6% of the truth.
- **Rotation:** on the second night, with fewer turns (a >5° turn in 6.4% of epochs, against 9.0% on the
  first), it added only the getting-up bout; heart-only agrees 87.7% (κ 0.786).
- **Where they differ:** deep (65% agreement where either says deep) more than REM (82%).

### Nights without the Fitbit

A few nights were checked against remembered wake-ups instead. They're too few and too rough to train on,
so they're kept as checks. Each had lost a part to night detection, not to the model; see PROGRESS.md, 5
and 9 Nov.

- **Onset:** the night now opens 15 minutes before the band's flag (`Sleep.bandLag`), and the model calls
  most of a still lead-in asleep. That suits the remembered onsets, and it's 6–12 minutes ahead of the
  Fitbit on the three trial nights above.
- **Getting up in the night:** the model scored the still minutes before the band's flag came back as
  awake, as remembered. So it isn't just calling stillness sleep.

## More training nights (30 Oct)

**Heart: all of CinC 2018.** Its beats came from PhysioNet's AWS mirror, and they give 1,027 ECG
nights (140 HMC + 887 CinC) against 382. Built with `ecg_cache.py` (in parallel) into
`feat-ecg-all.npz`. These are the same 5-fold CVs as before, over the bigger set; HMC's 140 nights
are scored in both, so they're the fair comparison.

| Heart model | 382 nights: all / HMC | 1,027 nights: all / HMC |
|---|---|---|
| LightGBM, both stages | 0.431 / 0.453 | 0.439 / 0.464 |
| GRU | 0.482 / 0.510 | 0.522 / 0.552 |
| **mean + Viterbi (shipped)** | **0.484 / 0.507** | **0.520 / 0.537** |

- The GRU gains the most (+0.04 on HMC). The mean is level with it on sleep-lab nights and stays
  ahead on DREAMT, so it's kept.

**Movement: BIDSleep.** 253 nights from 47 healthy adults at home, Dreem 2 EEG scored by an expert;
246 have gravity for over half the night.
- **The download:** it isn't on the AWS mirror, so it came from physionet.org in 16 parallel ranges.
- **The conversion:** two of its files end in a cut-off line, and numpy's parser stops quietly at a
  bad value, so `wrist_night.py` now checks each piece's row count.

Rotation alone, wake against sleep (AUC):

| Test set | Trained on sleep-accel | sleep-accel + BIDSleep |
|---|---|---|
| BIDSleep, held-out subjects (5 folds) | 0.784 | **0.824** |
| Newcastle (GENEActiv, clinic) | 0.871 | 0.863 |
| DREAMT (E4, clinic) | 0.813 | 0.813 |

**Together, on DREAMT** (65 nights) **and the MG night:**

| Model | DREAMT κ | Wake sens / prec | Bouts real | MG agreement | MG minutes wake / light / deep / REM | MG wake bouts |
|---|---|---|---|---|---|---|
| mean (1,027 nights), heart only | 0.355 | 0.43 / 0.47 | 0.87 | 86.4% | 9 / 364 / 81 / 148 | 3 |
| + sleep-accel rotation, w 0.5 | 0.404 | 0.56 / 0.57 | 0.87 | 82.5% | 42 / 340 / 80 / 140 | 10 |
| **+ sleep-accel + BIDSleep rotation, w 0.5 (shipped)** | **0.394** | **0.54 / 0.55** | **0.90** | **85.1%** | **22 / 355 / 81 / 144** | **6** |
| + sleep-accel + BIDSleep rotation, w 1 | 0.395 | 0.58 / 0.53 | 0.87 | 81.0% | 52 / 328 / 81 / 141 | 8 |

- **BIDSleep makes rotation better for healthy sleepers at home** and no worse for clinic
  patients. Its fused κ on DREAMT is 0.01 lower: within noise, and DREAMT's patients aren't
  the target.
- **It calls wake more conservatively:** fewer bouts, and 90% of them near real wake.
- **On the MG night** the shipped model scores six wake bouts: five in the night, and one getting up.

## DREAMT on all nights (29 Oct)

All 100 nights are downloaded and checked; 94 convert (the rest have no scoring or no beats); 65
have beats over half the night. Movement is now rotation. 5-fold by subject:

| Model | Trained on | Accuracy | κ |
|---|---|---|---|
| LightGBM, both stages | ECG nights | 0.585 | 0.278 |
| LightGBM, both stages | DREAMT, HRV only | 0.687 | 0.227 |
| LightGBM, both stages | DREAMT, HRV + rotation + temperature | 0.704 | 0.301 |
| LightGBM, both stages | ECG + DREAMT, everything | 0.711 | 0.384 |
| GRU | ECG nights (heart columns only) | 0.578 | 0.313 |
| **GRU** | **ECG + DREAMT, with rotation and temperature** | **0.722** | **0.438** |

- **Trained on its own nights,** the GRU with movement reaches κ 0.44 on this wrist device: the
  best figure so far on wrist data, against 0.40 on 38 nights before. It can't ship (DREAMT's DUA).
- **The open models score 0.31–0.36 here**: the gap is what wrist training data from the same
  device and population is worth.

## Newcastle PSG + GENEActiv (`wrist_night.py newcastle`)

28 sleep-clinic patients (Zenodo 1160410, CC BY 4.0), one PSG night each, a GENEActiv on each wrist
at 85.7 Hz, no heart rate.
- **The clocks disagree:** the sleep lab's and the accelerometers' were 0.5–20 min apart, the same
  on both wrists. Each night's offset is taken where turns separate wake from sleep best (sleep-accel,
  as a check, comes out at 0 for 23 of 26 nights). Four nights stay ambiguous after the shift and
  are left out: 24 participants, 47 wrists.
- **Rotation carries over again:** a >5° turn in 5.8% (left) / 6.8% (right) of asleep epochs and
  26% / 23% of awake ones. Asleep turns are higher than healthy sleepers' 3.5%: these are patients,
  some with restless legs.
- **Left and right wrists agree** on which epochs have a turn (correlation 0.73, median night), so
  the MG's wrist matters little.
- **As training data it doesn't help:** with sleep-accel + Newcastle, the mean + rotation model
  scores κ 0.349 on DREAMT against 0.357 with sleep-accel alone (0.328 before the clocks were fixed).
  On the MG night: 84.5% agreement, 34 minutes of wake in 8 bouts. Patients turning in their sleep
  weaken what a turn says. It's kept as a third-device test set.

## Next steps

1. **More training nights.** Carry on through CinC 2018 (`cinc_beats.py` with record ranges, run
   in chunks under 30 minutes; it keeps only the beats). Expect a few points of κ: Sridhar used
   10,000 nights.
2. **DREAMT** (`dreamt_night.py`, `dreamt_cv.py`). It's the only open set with wrist PPG IBI,
   accelerometer and skin temperature against PSG, the same signals as the MG.
   - **Format:** the IBI column holds each interval until the next beat. `dreamt_night.py` takes
     beats from changes in it, and puts back beats whose interval repeats the one before when the
     timing shows exactly that.
   - **Coverage** of the E4's own intervals ranges from 0% to 94% a night. Nights under 50% are
     left out.
   - **Pulse-waveform peaks are no better:** NeuroKit2's Elgendi detector on S002 kept 17%,
     against the E4's 31%.
   - **First results** (23 nights, LightGBM first stage, 5 folds):
     - ECG-trained only: κ 0.30;
     - trained on DREAMT, heart only: 0.21;
     - trained on DREAMT, plus movement and temperature: 0.26;
     - ECG + DREAMT: 0.31 (69%).
   - **GRU, 38 nights** (`dreamt_gru.py`):
     - ECG-trained only: κ 0.28;
     - ECG + DREAMT, with DREAMT's movement and temperature: **κ 0.40 (70.5%)**, with stage
       minutes close to the truth.
     - So movement helps a lot when training and test come from the same device.
   - **Deep sleep:** the patients have little of it (6% of the sleep period, against 12–14% in HMC
     and CinC). So the ECG model over-calls deep about 2.4 times.
   - **When all 100 nights are in:**
     - rerun with both stages and the GRU, with movement in the GRU;
     - put gaps where movement is, not at random;
     - try `data_100Hz` for a handful of nights: its PSG ECG on the same nights would separate the
       wrist's cost from the patients' effect.
   - **Movement and skin temperature from DREAMT don't transfer to the MG yet.** One LightGBM
     stage trained on the ECG nights plus 38 DREAMT nights was used to stage the MG night four
     ways (agreement with Fitbit; minutes wake / light / deep / REM):

     | MG night input | Agreement | κ | Minutes |
     |---|---|---|---|
     | heart only | 81% | 0.64 | 24 / 375 / 81 / 122 |
     | + temperature | 73% | 0.45 | 22 / 440 / 15 / 124 |
     | + movement (scaled levels) | 54% | 0.16 | 130 / 398 / 0 / 74 |
     | + both | 49% | 0.09 | 143 / 385 / 0 / 74 |

     - **Cause 1, a population confound:** only DREAMT nights have movement and temperature, so
       their presence identifies a sleep-clinic patient with broken sleep. Reweighting DREAMT to
       the ECG stage mix didn't help (heart only 81%, with movement 49%).
     - **Cause 2, the devices differ:** the MG's per-second movement during sleep spans
       0.005–0.010 g (5th–95th percentile), the E4's 0.003–0.04 g, with steps of 1/64 g.
     - **Events didn't fix it either.** Movement events relative to each night's own spread
       (`movement()` in `hrv.py`, kept for later) fire in 26% of the MG's epochs, against 1.2% of
       DREAMT's asleep epochs and 17% of its awake ones. With them the MG night came out as
       287 minutes of wake and no deep or REM.
     - **So the MG model stays heart-only for now.** Movement needs either a training set with
       the MG's own accelerometer, meaning EEG-reference nights wearing the MG, or a calibration
       mapping the MG's movement onto a training device's. Training data without the population
       confound would also help: MESA's community volunteers all wear an actigraph.
   - **The likely fix is wrist rotation.**
     - **Where it comes from:** R18 holds the MG's gravity vector as float32 x/y/z at bytes
       45/49/53 (|a| = 1.01 g, 5th–95th percentile 0.97–1.03). The app doesn't decode it yet.
     - **The measure:** the angle between successive 5-s gravity directions is in degrees,
       whatever the device's mounting, noise or units (`rotation_check.py`).
     - **It lines up across devices.** Share of epochs with a turn over 5°: DREAMT asleep 3.4%
       (median night), DREAMT awake 31.7%, the MG's first night 9.0%. By the old magnitude
       events the MG night looked more awake than awake patients.
     - **Done 29 Oct** (see [Wrist rotation](#wrist-rotation-rotation_cvpy)): rotation features
       replaced `movement()`. They were computed for DREAMT and sleep-accel, and a rotation-only
       model was fused into the heart model. Bytes 45/49/53 are decoded and stored, the features
       are ported, and it's installed (build `db718d4`).
     - **Still to do:**
       - BIDSleep (`wrist_night.py bidsleep`, straight from the zip): retrain the movement model on
         it plus sleep-accel, rerun `rotation_cv.py`, re-export;
       - revisit the weight with the trial nights.
3. **Ensemble: done 29 Oct** (see [The average](#the-average-of-lightgbm-and-the-gru-ensemble_cvpy)).
4. **MESA via NSRR:** 2,000 nights with ECG and wrist actigraphy together. It's the biggest
   step after DREAMT.
   - Its actigraphy is activity counts, not raw axes, so rotation won't apply. It needs its own
     calibration.
   - SHHS is the next request if volume matters.
   - Check NSRR's terms before shipping weights trained on either.
5. **The owner's trial,** from 29 Oct: nights wearing both the MG and the Fitbit, with a note
   of remembered awakenings.
   - The app keeps beats and per-second records for 14 days, and raw frames for 7.
   - Pull them with `xcrun devicectl ... copy from` for `Library/Application Support/WhoopSync/sync.sqlite`
     (plus `-wal`), and with `scripts/install-app.sh --pull-raw`.
   - Compare per night: agreement with the Fitbit, and whether the model's wake lines up with
     remembered awakenings and heart-rate surges.
   - On 28→29 Oct the Fitbit scored 1 minute of wake. The heart-only model scored 3 bouts, and only 1
     lined up with any of the 15 big heart-rate surges.
6. **A reference for the owner's nights:** a few nights with an EEG headband (Muse S, κ 0.76 vs
   PSG) would let us score the MG and the Fitbit against the same truth. Without one, the Fitbit
   is only a sanity check: aim for ≥ 70% agreement over several nights.
7. **Gate for trusting the stages** (they're written to Health already, by the owner's choice):
   - κ ≥ 0.55 on held-out PSG nights with MG-like inputs (DREAMT when we have it);
   - ≥ 70% agreement with the Fitbit across at least 5 of the owner's nights.
8. **Shipping:** done, in the app and in Health (see the status at the top). The gate in step 7 is
   now the bar for calling the stages trustworthy, not for writing them.
   - **Updating the model:** rerun `export_model.py` into `Packages/SyncCore/Sources/SyncCore/Resources/SleepModel`.
     A new `version` makes the app restage the nights it still has data for.

## How to rerun

The first model is plain numpy (system `python3`). The HRV scripts need a venv with numpy 2.5,
scipy 1.18, scikit-learn 1.9, lightgbm 4.7, sleepecg 0.6, edfio 0.4, wfdb 4.3 and torch 2.15
(neurokit2 only for the pulse-peak check). Python 3.14 works.

Datasets go outside the repo:
- **`~/datasets/dreamt/data_64Hz`:** the DREAMT CSVs, about 140 MB a night, checked against
  `~/datasets/dreamt/SHA256SUMS.txt`.
- **`~/datasets/sleep-accel`:** sleep-accel (2.2 GB, checked against its `SHA256SUMS.txt`; the
  `steps/` files aren't downloaded).
- **`~/datasets/bidsleep/bidsleep-1.0.1.zip`:** BIDSleep, read straight from the zip.
- **`~/datasets/sleep-stages`:** what's derived from the sleep-lab datasets:
  - `hmc-beats/` (140 usable nights) and `cinc-beats/` (279 nights);
  - `dreamt-npz/` (`dreamt_night.py` output, now with per-second gravity);
  - `sleep-accel-npz/` and `bidsleep-npz/` (`wrist_night.py` output);
  - `feat-ecg.npz`, the cached features for the 382 ECG nights, which most scripts take as their
    ECG source, with its fold probabilities (`feat-ecg-gru3-fold*.npz`, `feat-ecg-lgb2-fold*.npz`);
  - `feat-ecg-all.npz`, the same for all 1,027 ECG nights, with its fold probabilities;
  - `gru-ecg-all.pt`, the shipped GRU (all 1,027 nights, by `gru_probs.py`); `gru-ecg.pt` is
    the 382-night one;
  - `bidsleep-npz/`, `newcastle-npz/`.
- **Not kept:** the raw HMC EDFs (15.7 GB) and CinC signals. Re-fetch them from PhysioNet if beats
  need recomputing.
- **Your own nights, in `secrets/db/` (gitignored):** a copy of the phone's `sync.sqlite` and a Health
  Dashboard database with the Fitbit's stages (`health-dashboard.db`).

```
cd research/sleep-stages
# first model (sleep-accel)
python3 -I features.py <sleep-accel dir> <per-second out dir>
python3 -I variants2.py <per-second dir>
python3 -I onset.py <per-second dir> <strap sync.sqlite> <dashboard health.db>
# HRV model
venv/bin/python -I hmc_beats.py <hmc dir> <hmc beats dir>          # HMC: physionet.org/files/hmc-sleep-staging/1.1/
venv/bin/python -I cinc_beats.py <work dir> <cinc beats dir> 0 300   # downloads, keeps beats, deletes signals
venv/bin/python -I hrv_cv.py <beats dir>                             # HR only vs HR + HRV, full vs MG-thinned
venv/bin/python -I hrv_stack.py <beats dir>...                       # + second-stage context model
venv/bin/python -I gru_cv.py <feature cache> <beats dir>...            # GRU, same folds; caches features
venv/bin/python -I mg_night.py [--gru] [--raw <archive .bin>] <source>... <strap sync.sqlite> <dashboard health.db>
venv/bin/python -I dreamt_night.py ~/datasets/dreamt/data_64Hz <dreamt npz dir>   # finished downloads only
venv/bin/python -I wrist_night.py sleep-accel ~/datasets/sleep-accel <sleep-accel npz dir>
venv/bin/python -I wrist_night.py bidsleep ~/datasets/bidsleep/bidsleep-1.0.1.zip <bidsleep npz dir>
venv/bin/python -I dreamt_cv.py <feature cache .npz> <dreamt npz dir> [two]
venv/bin/python -I dreamt_gru.py <out prefix> <feature cache .npz> <dreamt npz dir>
venv/bin/python -I gru_probs.py <out prefix> <feature cache .npz> <dreamt npz dir> <strap sync.sqlite> <raw archive .bin>   # before rotation_cv.py, for its GRU rows
venv/bin/python -I ecg_cache.py <feature cache .npz> <hmc beats dir> <cinc beats dir>   # every core
venv/bin/python -I gru_cv.py <feature cache> && venv/bin/python -I ensemble_cv.py <feature cache>   # cache path without .npz
venv/bin/python -I wrist_night.py newcastle ~/datasets/newcastle/dataset_psgnewcastle2015_v1.0 <newcastle npz dir>
venv/bin/python -I rotation_cv.py <out prefix> <feature cache .npz> <dreamt npz dir> <strap sync.sqlite> <dashboard health.db> <raw archive .bin> <Apple Watch npz dir>...
venv/bin/python -I export_model.py <feature cache .npz> <hmc beats dir> Packages/SyncCore/Sources/SyncCore/Resources/SleepModel Packages/SyncCore/Tests/SyncCoreTests/Fixtures/stages-hmc.json ~/datasets/sleep-stages/gru-ecg-all.pt <Apple Watch npz dir>...
python3 -I rotation_check.py ~/datasets/dreamt/data_64Hz              # from the repo root
```

`rotation_cv.py` caches each model's probabilities next to its out prefix; give it a fixed set of
DREAMT nights (a directory of links), and delete the caches when that set changes.

`whoop_night.py`, `onset.py`, `stager.py`, `mg_night.py` and `rotation_cv.py` hardcode one MG night: the
band flag's start and end (`N0`, `N1`) and the Fitbit's session id. For another night, change them and use
a copy of the phone's DB from the morning after.
