# Datasets

Every dataset this repo uses, its licence, what to cite, and how it's used. None of the data is in the repo
except the two test-fixture excerpts below; the research scripts read the datasets from outside it
(`~/datasets`). The PhysioNet datasets also ask for the standard PhysioNet citation: Goldberger AL et al.,
"PhysioBank, PhysioToolkit, and PhysioNet", Circulation 101(23):e215–e220 (2000),
[doi:10.1161/01.CIR.101.23.e215](https://doi.org/10.1161/01.CIR.101.23.e215).

How each is used:
- **Shipped weights:** trains the sleep model the app ships (`Packages/SyncCore/Sources/SyncCore/Resources/SleepModel`,
  whose `model.json` names them in `trained_on`).
- **Test fixture:** an excerpt is in `Packages/SyncCore/Tests/SyncCoreTests/Fixtures`.
- **Evaluation only:** scores models on the Mac; never in shipped weights.

## Sleep stages

| Dataset | Licence | Use |
|---|---|---|
| PhysioNet/CinC Challenge 2018 | ODC-By 1.0 | Shipped weights: 887 nights of ECG beats for the heart model (LightGBM and GRU) |
| HMC sleep staging database | CC BY 4.0 | Shipped weights: 140 nights of ECG beats for the heart model. Test fixture: 3 h of SN003 |
| sleep-accel (Walch 2019) | ODC-By 1.0 | Shipped weights: 30 Apple Watch nights for the wrist-rotation model |
| BIDSleep | ODC-By 1.0 | Shipped weights: 246 Apple Watch nights for the wrist-rotation model. Test fixture: 3 h of BS00-1's gravity |
| Newcastle PSG + GENEActiv | CC BY 4.0 | Evaluation only: a third-device test set for the rotation model (as training data it didn't help) |
| Wearanize+ OA | Research only (see below) | Evaluation only: healthy nights at home |
| DREAMT | PhysioNet Restricted Health Data License 1.5.0 | Evaluation only. Never in weights; the data is never shared |
| MESA, SHHS (NSRR) | NSRR data use agreement | Not used: access to MESA was requested, and no data has been used |

**Fixture excerpts.** `Fixtures/stages-hmc.json` holds three hours of HMC SN003 (ECG beats as MG-style RR
records, from sleep onset) and three hours of BIDSleep BS00-1's per-second gravity, with what the Python
computes from them. They're redistributed under those datasets' licences (CC BY 4.0 and ODC-By 1.0), with
the attribution in the fixture's `source` field and here.

**Wearanize+ OA.** The download carries a CC BY 4.0 licence file, but its README says both versions "may
only be used for scientific research purposes". So it's treated as research only: the model trained with it
(`2026-10-30.0808`) was withdrawn, and `research/sleep-stages/export_model.py` refuses its nights (and
DREAMT's).

Citations and sources:
- **CinC 2018:** Ghassemi MM et al., "You Snooze, You Win: the PhysioNet/Computing in Cardiology Challenge
  2018", Computing in Cardiology 45 (2018), [doi:10.22489/CinC.2018.049](https://doi.org/10.22489/CinC.2018.049).
  [physionet.org/content/challenge-2018/1.0.0](https://physionet.org/content/challenge-2018/1.0.0/).
- **HMC:** Alvarez-Estevez D, Rijsman RM, "Inter-database validation of a deep learning approach for
  automatic sleep scoring", PLoS ONE 16(8):e0256111 (2021),
  [doi:10.1371/journal.pone.0256111](https://doi.org/10.1371/journal.pone.0256111).
  [physionet.org/content/hmc-sleep-staging/1.1](https://physionet.org/content/hmc-sleep-staging/1.1/).
- **sleep-accel:** Walch O, Huang Y, Forger D, Goldstein C, "Sleep stage prediction with raw acceleration and
  photoplethysmography heart rate data derived from a consumer wearable device", SLEEP 42(12):zsz180 (2019),
  [doi:10.1093/sleep/zsz180](https://doi.org/10.1093/sleep/zsz180).
  [physionet.org/content/sleep-accel/1.0.0](https://physionet.org/content/sleep-accel/1.0.0/).
- **BIDSleep:** Song T-A et al., "A Multi-Night Instantaneous Heart Rate and Accelerometry Dataset with
  EEG Sleep Stage Labels" (UMass Lowell), PhysioNet, version 1.0.1,
  [doi:10.13026/rees-1092](https://doi.org/10.13026/rees-1092).
- **Newcastle:** van Hees VT et al., "A novel, open access method to assess sleep duration using a
  wrist-worn accelerometer", PLoS ONE 10(11):e0142533 (2015),
  [doi:10.1371/journal.pone.0142533](https://doi.org/10.1371/journal.pone.0142533). Data: Zenodo 1160410,
  [doi:10.5281/zenodo.1160410](https://doi.org/10.5281/zenodo.1160410).
- **Wearanize+ OA:** Radboud Data Repository, [doi:10.34973/j6jf-9e62](https://doi.org/10.34973/j6jf-9e62).
- **DREAMT:** Wang WK, Yang J, Shetty A, Dunn J, "DREAMT: Dataset for Real-time sleep stage EstimAtion
  using Multisensor wearable Technology", PhysioNet (restricted access), version 2.2.0,
  [doi:10.13026/3f7y-2d80](https://doi.org/10.13026/3f7y-2d80).
- **MESA, SHHS:** National Sleep Research Resource, [sleepdata.org](https://sleepdata.org/).

## Our own data

The owner's own recordings (the MG's nights and the Fitbit's) aren't in the repo; the docs give only
aggregate figures from them, such as agreement and κ against the Fitbit. The only strap data here is a
handful of frames in `Whoop5Tests.swift`, a few seconds from the owner's MG kept as protocol test vectors,
under the repo's licence.
