# Progress

Running log of what's built, what's been seen working on the real strap, and what's next.
Newest first. Design and reasoning: [`SPEC.md`](SPEC.md).

## 2026-11-16: a night slept on after it was written no longer reaches Health short

- **Seen on the phone:** when the phone was unlocked in the morning, Apple Health got 3 h 33 of sleep of a
  night of 9 h 14. The whole night replaced it eight minutes later.
- **Why:** awake in the small hours, the night was written as over by the twelve-minutes-in-bed rule. The
  phone was locked, so its samples waited in the outbox. Sleep went on half an hour later, but a night under
  way is only written once it's over, so the short version was still what the outbox held when the phone was
  unlocked, and it went to Health. The whole night followed once the app was sure the day had started.
  Replayed, the 14 nights stored have the rule make the same early call on 7 of them.
- **Now** (SPEC §5, "A night that goes on after it was written"):
  - While protected data is available, a pass writes a night that was written and has gone on since as far
    as it has got (`Sleep.soFar`, whole minutes only, so each version is longer than the last), stages and
    all, before the outbox is written. `Sleep.due` chooses what a pass writes.
  - Unlocking the phone with a night under way also asks the strap for a download, if the last was over a
    minute ago.
  - The Sleep row says how far such a night is written: "Asleep since 23:10 · written up to 07:42".
  - Unchanged: when a night is over, and a night not yet written waits until it is.
- **Not covered:** an unlock that lands while a download or a write to Health is running. Nights aren't
  worked out then, so the short version can be in Health for the seconds until the pass after it.
- **Tests:** SyncCore's tests pass (142, 6 of them new, 3 skipped). `NightDryRunTests` (skipped unless
  `STRAPSYNC_DRYRUN_DB` is set) replays a copy of the phone's database, writing nothing:
  - With the lock times of that day's log, the pass that unlocking starts writes the night five minutes
    short of whole (9 h 09), and the two downloads after it bring it to 9 h 14, before the app is sure you're up.
  - All 14 stored nights end up the same whether the phone was locked throughout, unlocked throughout or
    either at random, with downloads at three offsets.
  - In the Simulator, on a copy of the database from before the whole night was written, the app wrote the
    night as far as the copy's minutes went, with its stages and its clear.
  - Built for the Simulator with Xcode 26.3. **Not yet seen on the phone.**

## 2026-11-14: samples keep the time zone they were recorded in

- **Why:** each sample was stamped with the phone's zone when it was written. Right for live data, but every
  rewrite of older data (restaged nights, `nightsRedo6`, `metadataRedo1`, version bumps) stamped it with the
  zone of the day it was rewritten. After a change of zone, nights slept in the old one carried the new one,
  so a reader put their wake times in the evening and filed them as naps.
- **Now** (SPEC §4, "Dedup"; SHARING.md, "Time zone"):
  - The app keeps a zone history (`ZoneHistory`, the `zones` table): the phone's zone at launch, at each
    history download and when iOS says it changed, a row only when it differs.
  - A sample's zone is the one in effect at its start. The outbox stores it with the row (`zone`) and keeps
    it through rewrites, and Health is given that, not the zone now. Where it isn't known, no zone.
  - Before the history, zones are reconstructed once from the app's daily logs (`ZoneLog`): a log's lines
    keep the zone their process started in, and each file's modification time gives the offset of its last
    process, so a change is placed at the first process in the new zone. Days no log covers stay unknown.
    The result is logged once, as instants and offsets.
  - **`zoneRedo1`** rewrites, once, the app's own samples in Health from the last 16 days that have the wrong
    zone, in place: their outbox rows get the right zone and one sync version above Health's. What Health has
    decides, not the outbox, which can hold rows Health no longer has, still marked written (a restaged night's
    clear deleted them). Samples with no outbox row are left as they are, and outbox rows Health doesn't have
    are never touched. No restaging: it goes through the outbox's batches like any write, and waits for
    `metadataRedo1` and `nightsRedo6` to finish.
- **The owner's own record:** the phone's own zone can be wrong for days, and the logs with it, so an optional
  `Documents/time-zones.json` (format in DEVELOPMENT.md) states the zones for a past stretch. Where it reaches,
  it replaces the logs; the app's own record wins from its first entry. A file with anything wrong in it is
  ignored, whole, and the log says why. The history in effect is logged once, with each stretch's source, and
  the redo waits for the file to be read.
- **Lost nights, in the same pass:** a night Health lost to the clear-after-save race (entry below) whose rows
  the outbox still has, written, is written again: only a whole night whose sleep rows all have its newest
  version, with nothing of the app's sleep, resting heart rate or breathing in Health within two hours of it.
  Stale rows of an earlier version beside a current night stay out.
  - **Why `nightsRedo6` didn't restage such a night:** its staging loop skips a night without a word when
    `Sleep.nights` over the 14 days' minutes doesn't find it (it compares the night's median heart rate with
    every other worn minute in the window), when it has fewer than 1,000 history beats, or when the stager
    returns no stages, and the redo counts as done once a pass stages fewer than two. Nothing there is plainly a
    bug, so the stager is unchanged. The dry run prints which check each lost night fails.
- **Reading back what it wrote:** in the iOS 18.6 Simulator, an app allowed only to write sleep read its own
  sample back, sync identifier, version and zone included, from a later launch too, with no read request. So
  Strap Sync still asks only to write.
- **Checks:**
  - `scripts/zone-check.sh` runs the redo end to end with HealthKit in a new Simulator (`ZoneCheck.swift`),
    through the app's writer. Passed: 79 samples before, 89 after: the same ones plus the 10 of the lost night,
    back in the zone a time-zones.json gave it;
    40 rewritten one version up in the history's zone; 22 outbox rows not in Health left out (6 stages a clear
    had deleted, 1 heart rate, and a night staged twice whose two versions are both gone); 1 sample with no
    outbox row left as it was. It fails, as it should, with the redo made to rewrite the outbox's rows instead
    (the deleted stages come back), and with the lost-night rule's version check dropped (the twice-staged
    night comes back).
  - The dry run (`ZoneDryRunTests`) prints the reconstructed history, what the redo would rewrite and the nights
    it would write again (with why the stager left each), from copies of the logs, the database and Wellmaxx's
    database (standing in for Health), and writes nothing. Skipped unless
    `STRAPSYNC_DRYRUN_DIR` is set.
- **Tests:** SyncCore's tests pass (133, 15 of them new; the dry run skipped). Built for the Simulator with
  Xcode 16.4 and 26.3. **Not yet seen on the phone.**

## 2026-11-14: nights staged during a write to Health are no longer lost

- **Seen on the phone:** the first launch of a build with a new sleep model restaged the stored nights
  while a long one-time write to Health was under way. Two nights staged during it had no sleep samples
  in Health afterwards.
- **Why:** a flush read the pending clears once, ran them, then saved batches. Staging runs between a
  flush's awaits, so the nights staged during the save added their clears and new samples, the loop saved
  the samples, and the next flush's clears deleted them from Health by time range. Already marked
  written, they were never saved again.
- **Now** (`HealthFlush` in SyncCore; SPEC §5, "Rewriting a night"):
  - Staging adds a night's clear and its new samples in one transaction (`Store.stageNight`), and drops
    the night's earlier rows from the outbox.
  - A night less than two hours from one being written again lost the samples its clear reached. They're
    now marked unwritten in the same transaction, and written again after the clear.
  - Every pending clear runs before each batch. The samples a pending clear covers wait for it, and the
    rest are written, so one clear that can't run no longer holds up everything else.
  - Nights aren't staged while a batch is being saved, but as soon as the flush is done. So a clear never
    deletes a sample saved after it was added.
- **`nightsRedo6`** stages and writes again, stages and all, every night still in the stored beats
  (14 days), two a pass, once protected data is available. Minutes are kept 8 days, so the older ones are
  rebuilt from the motion records and kept until the redo is done (`restageFrom`).
- **Tests:** SyncCore's tests pass (118, 9 of them new), among them 300 random interleavings of
  staging, flushing and failed writes. Built for the Simulator with Xcode 16.4 and 26.3.
  **Not yet seen on the phone.**

## 2026-11-13: skin temperature, RMSSD and ECGs in Apple Health, as metadata

- **Why:** an app from another developer team can't read the shared keychain group, which needs the same
  team, and Health has no type for skin temperature, RMSSD or a WHOOP ECG. But Health keeps custom
  metadata on samples, and any app allowed to read them gets it.
- **Now** ([`SHARING.md`](SHARING.md#through-apple-health) has the keys):
  - Heart-rate samples carry their 10-minute skin-temperature interval (`StrapSyncSkinTemperature`,
    `…Start`, `…Seconds`), with the keychain item's intervals and rule (`SkinTemperature`).
  - HRV samples carry their window's RMSSD (`StrapSyncRMSSD`), the keychain `hrv` item's value.
  - The heart-rate sample of the minute an ECG started in carries the recording (`StrapSyncECG`, base64 of
    its 16-bit samples, with its start, sample rate and heart rate).
  - The MG's heart rate stays 0 during an ECG, so that minute often has no sample. Then the recording gets
    a heart-rate sample of its own, `whoopsync:ecg:<start>`, from its start to its end at its own heart
    rate, and keeps it. One with no heart rate yet waits for it.
- **Rewrites:** the outbox now keeps the version a sample's data was planned with (`basis`) apart from the
  sync version Health is given (`version`), plus the metadata (`meta`). The same data with other metadata
  goes out again one version up (`Outbox.merge`), so a sample whose interval is still filling in is
  replaced in Health. More data still goes out at its own version, as before.
- **`metadataRedo1`** plans the stored samples once more, so recent history carries the metadata: 8 days of
  skin temperature (the minutes kept), 14 of RMSSD and ECGs. Only samples that gain metadata are rewritten.
  It runs on finished hours, and not mid-download.
- **Checked in the iOS 18.6 Simulator (Xcode 16.4):**
  - Metadata strings from 11 KB to 4 MB on a heart-rate sample saved and read back intact, also after a
    reboot.
  - Numbers come back as doubles, dates as dates.
  - A sync version equal to the stored one replaced the sample too; a lower one was silently ignored.
  - **End to end:** a second app with another bundle ID, allowed only to read heart rate and HRV, read
    the demo's samples (`-demo YES`): skin temperature on 1,229 of 1,235 heart-rate samples (at most 10
    to an interval), RMSSD on all 20 HRV samples, and one ECG, whose waveform decoded to its 4,034 samples.
    That build came before ECGs got samples of their own, so the demo's other ECG, with no heart-rate
    sample in its minute, wasn't carried.
- **Tests:** SyncCore's tests pass (109, 20 of them new). Built for the Simulator with Xcode 16.4 and 26.3.
  **Not yet seen on the phone.**

## 2026-11-13: a build can bundle its own sleep model and add its own sources

- **Sleep model:** `SleepStager.load(from:)` reads a model from any folder laid out like SyncCore's
  `Resources/SleepModel`. The app uses a `PersonalSleepModel` folder in its bundle if it has one, else
  SyncCore's, and logs the version it loaded ("Sleep stages: model …").
- **Own sources:** with the `PERSONAL` compilation condition, `AppModel` and `ContentView` call
  `PersonalHooks`, which that build's own sources provide. Without it, none of that is compiled.
  [`DEVELOPMENT.md`](DEVELOPMENT.md#a-builds-own-sources-and-sleep-model) lists the hooks.
- **Apple Health:** the app asks only to write, so its Info.plist has only the update usage string.
- **Tests:** SyncCore's tests pass. **Not yet seen on the phone.**

## 2026-11-12: the sleep model without Wearanize+

- **Why:** Wearanize+ OA's README says both its versions "may only be used for scientific research
  purposes", so the shipped weights can't be trained on it. Like DREAMT, it stays for evaluation only.
- **Now** the model is `2026-11-12.1332`: the weights of `2026-10-30.0435` (commit `6e0cd68`), trained only on
  HMC, CinC 2018, sleep-accel and BIDSleep. The new version makes the app restage the nights it still has.
  - **On held-out Wearanize+ nights:** κ 0.609, against 0.618 for `2026-10-30.0808`, the model with it.
  - **On the owner's first two trial nights,** agreement with the Fitbit: 85.9% / 88.1%, against 83.2% / 88.7%.
  - `export_model.py` refuses Wearanize+ and DREAMT nights. Licences: [`DATASETS.md`](../DATASETS.md).
- **Tests:** the parity fixture is back to the one that matches these weights; SyncCore's tests pass.
- **Not yet built or seen on the phone.**

## 2026-11-10: samples say which time zone they're from

- **Why:** our samples had no zone, so after a change of time zone Wellmaxx used the zone it read at
  launch, the one the phone had left. By that clock a night could end hours late, past its main-sleep
  window, and be filed as a nap. Fixed in Wellmaxx too (main 4209dd6).
- **Also seen:** flushes fail while the phone is locked ("Protected health data is inaccessible"), and with
  a night to clear first, a flush writes nothing until it's unlocked.
- **Now** every sample carries `HKMetadataKeyTimeZone`, the phone's zone when it's written.
- **`nightsRedo5`** writes the latest night again once, stages and all, if it ended in the last 36 hours:
  likely slept in the zone the phone has now. Older nights keep what they have.
- **TestFlight 20261110.1613** (main 5893671), with Wellmaxx 20261110.1614. **Not yet seen on the phone.**

## 2026-11-09: an hour and a half lying awake no longer ends the night

- **Report:** the end of a night with several wake-ups was missing from Health.
- **Why:** the band's flag had a gap of 82 minutes, past `maxWake` (60), so the 93 minutes flagged after it
  were a block of their own. That was under `minSession`, so they were dropped.
  - In the gap: about 15 minutes up at a waking heart rate, then lying in bed at a sleeping heart rate (the
    same median as asleep).
- **Now:** with the band's flag, blocks up to `maxQuietWake` (120) minutes apart also join when the gap looks
  like lying in bed (`Sleep.joinQuiet`):
  - the strap is worn for at least half the gap;
  - the gap's median heart rate is within `quietHR` (10 bpm) of the sleeping median of the blocks either side.
  - Relative to the night, not fixed: the sleeping median can move by more than `quietHR` from night to
    night.
  - Up and about at a waking heart rate, a later doze is still its own block (`testADozeAfterGettingUpIsNotTheNight`).
- **`nightsRedo4`** steps `nightsDoneUntil` back two days once and drops those nights' stored stages. A
  rewritten night is cleared in Health, stages and all, and staging skips a night it already covers, so an
  unchanged night would otherwise come back as plain "asleep".
- **Replayed on the phone's minutes (eight nights), every 5 minutes, against the old code:** only two nights
  change.
  - **The reported night** is written once up the first time, then again with its last 93 minutes.
  - **Another** starts 72 minutes earlier: a 7-minute flag 65 minutes before the rest now joins.
- **Staged on the Mac** (model `2026-10-30.0808`): the rewritten night has 2 h 12 more sleep than Health had,
  and the model scores most of the 82-minute gap awake.
  - An earlier 45-minute gap in the band's flag, with movement, is mostly light sleep to the model.
- **TestFlight 20261109.1019** (main d49a5dc). **Seen on the phone:** the night was rewritten whole.

## 2026-11-08: SDNN from steady windows, detrended

- **Report:** Health Dashboard gave a high Recovery beside a "vitals out of range" warning. SDNN read above
  usual where heart rate and RMSSD said otherwise, and Recovery weighted SDNN most.
- **Why:** heart rate stepped down inside the chosen windows, by about 10 bpm in one. SDNN counts a step
  as variability: that window's SDNN was about twice its RMSSD.
  - Picking the window with the lowest mean heart rate makes this likelier: as a raised heart rate settles,
    the window where it drops has the hour's lowest mean.
- **Health Dashboard's side:** it now takes RMSSD for Recovery and SDNN for longer-term fitness.
- **Now:**
  - **SDNN is detrended first:** smoothness priors, λ = 500, as Kubios does (`Detrend.swift`). Slow
    changes, and most of a step, no longer count.
  - **Steady windows first:** a window is steady when its minutes' mean heart rates stay within 5 bpm.
    The hour's HRV comes from the steady window with the lowest mean heart rate, or from the lowest
    overall when none is steady. RMSSD comes from the same window.
  - **Versions start at 1,000,000** (`Aggregator.hrvAlgorithm`), so Health's SDNN samples are replaced.
  - **`hrvRedo1` recomputes every stored hour once** (beats are kept two weeks): the `hrv` table, the
    share and Health.
- **Over eight nights of stored beats (82 night hours):**
  - Nightly SDNN (geometric mean of the hours) is 5–13% lower.
  - Only 2 hours changed window, and RMSSD is unchanged but on one night, by under 1%.
  - 13% of windows aren't steady, and 1 hour has no steady window.
  - A 10 bpm drop put into the last fifth of each chosen window raises the old SDNN ×2.49 (median). Its 1-minute
    range is ≥ 5.3 bpm, so the window isn't chosen; detrending alone would leave ×1.39.
- **Tests:** detrend matches scipy's sparse solve to 1e-6. A steady window's SDNN is unchanged. A step's
  window is passed over for a steady one, the fallback works when none is steady, and the new versions
  beat the old.
- **TestFlight 20261108.1322** (main 06520ef). Not yet seen on the phone, and the night that showed it
  wasn't on the Mac to replay.

## 2026-11-06: keeping the strap's optical bursts (R26)

- **Found:** the MG stores 40-second bursts of 25 Hz PPG every 20 minutes (R26), which the app didn't keep and
  the strap deletes once acknowledged. Asleep, heart rate from the waveform is within 0.6 bpm of R18's.
- **R26 is decoded and kept.**
  - `Whoop5Message.optical(R26Record)`: the base plus 24 deltas, motion, status, acceptance.
  - `HistoryChunk.optical` is saved to a new `ppg` table in the chunk's transaction, before the
    acknowledgement. The deltas are a 48-byte BLOB, so SQLiteDB gained `.blob`.
  - `ppg` is never pruned: about 0.3 MB a day.
- **Other layouts are banked whole:** `banked`, 30 days, ready for R20 multi-channel optical, if the strap
  ever sends it.
- **Backfill:** on first open, the app reads its 7-day raw frame archive once and banks the R26 seconds in
  it (`ppgBackfill1`, logged as "Optical bursts: banked N optical seconds…").
- **Tests:** R26 decode against our captured frame (signed base −52,064), other layouts kept whole, the
  archive reader. A Mac round-trip check of the BLOB binding.
- **Not yet seen on the phone.**

## 2026-11-05: waking in the night no longer loses part of it

- **Report:** on two nights, part of the sleep either side of a wake-up was missing from Health.
- **Why:** on each, the band's sleep flag had a gap: 26 minutes on one night and 18 on the other.
  - Rest minutes more than 10 minutes apart made separate blocks, and blocks under `minSession` (3 h)
    were dropped.
  - So 1 h 44 and 2 h 03 of flagged sleep never reached Health, and the stage model never saw them.
- **Also:** the band flags sleep 14–17 minutes after the last movement and doesn't backdate it. That held
  for 10 of 11 onsets over eight nights; once it was 5 minutes. It flags waking within 1–2
  minutes.
- **Now** (with the band's flag; stillness-only nights are unchanged):
  - **Blocks join** across up to `maxWake` = 60 minutes awake, and the gap is an awakening. Back
    asleep within an hour of a night already written, the night grows and is written again
    (`nightLastStart`).
  - **A night opens `bandLag` = 15 minutes before its first flag,** awake in the fallback samples, so
    the stage model judges the onset. "Asleep since" still shows the flag.
  - **Staging redoes any night its stored stages don't cover** (`stagesCover`), not only one that grew
    at the end. Newest first.
  - **`nightsRedo3`** steps `nightsDoneUntil` back two days once, so both nights are written again.
- **Replayed on the phone's minutes (eight nights), every 5 minutes:**
  - Each night is written once, minutes after waking.
  - The night with the later wake-up is written soon after it, then again once the rest of the night is in.
  - No night ends mid-night.
  - One night keeps its start: a 7-minute flag 65 minutes before the rest is past `maxWake`.
- **Staged on the Mac from the pulled DB** (model `2026-10-30.0808`): on both nights the model scores the
  wake-up awake and stages the part Health hadn't had.
- **Against the Fitbit, onset is now 6–12 minutes earlier** on the three nights with both:
  - The model calls most of a still lead-in asleep.
  - Minute heart rate in the lead-in matches the first flagged minutes every time, so only an EEG night
    can settle it. `bandLag = 0` puts the old onset back.
- **Not yet seen on the phone.**

## 2026-11-01: the night arrives as soon as you're up

- **Report:** 25 minutes after getting up, the night still wasn't in Apple Health, after two "Download
  now" presses. "Write to Apple Health now" did nothing either.
- **Why:** a night was written only once 30 minutes of data followed its end. Downloads ran every 15
  minutes and only while live heart rate kept the app awake. It was written when the app was opened, 45
  minutes after the band's wake; on the two nights before, it took 31 and 38 minutes.
  The Write button only re-ran the same check on data already downloaded.
- **Now:**
  - **Up and about:** five minutes after the night with three of them moving (mean motion ≥ 0.05 g)
    ends it. Lying awake in bed ends it after `Sleep.settle` = 12 minutes (`maxBridge` + 2: past
    that, rest starts a new block, so the end can't move).
  - **Back asleep within `maxBridge`** (getting up briefly, which looked like the morning): the night grows,
    and is written and staged again. Kept as `nightLastStart`; stages are redone when a night outgrows
    its stored ones.
  - **Downloads every 5 minutes while a night is under way,** and at once when the app is opened (at
    most once a minute).
  - **Write to Apple Health now** downloads first, then works out the night and writes.
  - The strap section shows "Asleep since HH:MM", then "Woke HH:MM · written once you're up".
- **Replayed on the phone's stored minutes (four nights),** stepping every 5 minutes: each night is
  written once, with no mid-night false ending, 7-16 minutes after the band's wake. The last one is
  written 40 minutes sooner than it was.
- **Seen in the same log:** the strap's data stopped about half an hour after the night ended, so
  nothing could download until the app was opened.

## 2026-10-29 (evening): RMSSD as well as SDNN, shared with Health Dashboard

- **Why:** Health Dashboard compares a new device with the previous one's baseline while the new
  one calibrates. The Fitbit's HRV is RMSSD, and Strap Sync wrote only SDNN, which can't be
  compared with it. On the first MG night, SDNN ran 0.97–1.31× RMSSD from window to window.
- **What:** `Aggregator.hourlyWindows` gives each hour's window as SDNN and RMSSD. RMSSD uses only
  neighbouring clean beats (`successiveDifferences`). SDNN still goes to Health, unchanged.
  - Both are kept in a new `hrv` table (14 days) and shared as the `hrv` keychain item
    (SHARING.md).
  - A one-time backfill computes the stored week's hours from beats.
- **Not yet confirmed on the phone:** check the Log for "HRV: computed SDNN and RMSSD for N stored
  hours".

## 2026-10-30: more training nights

### Built

- **Model `2026-10-30.0435`** (commit `6e0cd68`). It isn't on the phone yet: RoamRun was waiting
  for the device.
  - **Heart:** the mean of LightGBM and the GRU, now trained on 1,027 sleep-lab nights: all of
    CinC 2018 as well as HMC. On held-out nights κ goes from 0.484 to 0.520. On HMC's 140 nights,
    scored in both runs, it goes from 0.507 to 0.537, and the GRU alone from 0.510 to 0.552.
  - **Rotation:** now also trained on BIDSleep (246 nights of healthy adults at home). Rotation
    alone separates wake from sleep better on held-out BIDSleep subjects (AUC 0.784 → 0.824), and
    the same on the clinic sets.
  - **On 28→29 Oct:** 85% agreement with the Fitbit, 22 minutes of wake in 6 bouts, all at turns.
- **Data:**
  - CinC came from PhysioNet's AWS mirror at about 20 MB/s; physionet.org itself gives about
    0.5 MB/s.
  - BIDSleep is downloaded, CRC-checked and converted.
  - Newcastle (GENEActiv on both wrists) is converted with each night's clock offset fixed. It's a
    test set: as training data it didn't help.
- **Step 3: DREAMT on all nights** (65 usable). Trained on ECG + DREAMT, the GRU with movement
  reaches κ 0.44 on the E4. That's research only.

### Next

1. **Reinstall** (phone unlocked, RoamRun up); the nights the app still has restage under the new
   version.
2. **Each trial morning:** pull both DBs, then compare the MG night with the Fitbit and the
   owner's notes. 29→30 Oct is the first night with gravity.
3. **MESA / SHHS** when NSRR approves; check their terms before shipping anything trained on them.

## 2026-10-29 (late): the GRU in the app

### Built

- **The heart model is now the mean of LightGBM and the GRU** (model `2026-10-29.1520`, build
  `3353a7c`, installed). Rotation is fused on top as before.
  - **On 382 held-out sleep-lab nights:** κ 0.484. LightGBM alone scores 0.431 and the GRU 0.482.
    Independent tests of Fitbits score 0.41–0.42, and Google's own figure is 0.63.
  - **On 56 DREAMT wrist nights:** κ 0.357, up from 0.312 for LightGBM with rotation.
  - **On 28→29 Oct:** 82% agreement with the Fitbit, and 48 minutes of wake in 11 bouts, all at
    wrist turns.
  - **On the phone:** `GRU.swift` matches PyTorch to 1e-9 and adds about 0.1 s a night. 67 SyncCore
    tests pass.
- **The GRU only sees heart columns:** inputs it was never trained with were noise.
- **Model versions** are now date and time (`YYYY-MM-DD.HHMM`).

### Confirmed on the phone

- Build `db718d4` restaged 28→29 Oct at 21:53 (phone time): same stages, "0% of seconds with
  gravity", as expected for a night stored before gravity was decoded.

### In progress

- **DREAMT:** all 100 nights downloaded and checked; 94 converted. Next is `dreamt_cv.py` and
  `dreamt_gru.py` on all of them.
- **BIDSleep:** downloading in 16 parallel ranges at about 0.5 MB/s, so about 3.5 hours. One
  connection got 0.1 MB/s.

## 2026-10-29 (evening): wrist rotation for wake

### Built

- **Confirmed on the phone:** build `86e9c24` wrote the stages to Health: "Sleep stages (model
  2026-10-29): …", then "removed 13 earlier samples", then "saved 51 samples".
- **The strap's gravity vector** (R18 float32 x/y/z at bytes 45/49/53) is decoded
  (`R18Record.gravity`) and stored per second (`motion.gx/gy/gz`).
- **Wrist rotation for wake** (model `2026-10-29.14`, build `db718d4`):
  - **The measure:** the angle between successive 5-s gravity directions. It reads the same on the
    MG, an Apple Watch and an Empatica E4.
  - **The model:** a rotation-only LightGBM trained on the open Apple Watch nights (sleep-accel).
    It's fused into the heart model before the Viterbi pass and only moves wake against sleep, at
    half weight. Epochs without gravity stay heart-only, so nights stored before this build stage
    as before.
  - **On 56 DREAMT nights** (PSG truth, a different wrist device): κ 0.26 → 0.31. Wake sensitivity
    went 0.43 → 0.53 and precision 0.36 → 0.49, so it finds more real wake and invents less.
  - **On the 28→29 Oct night:** 55 minutes of wake in 9 bouts, all at turns. It agrees with the
    Fitbit 78% of the time (82% heart-only); the Fitbit scored 1 minute of wake.
- **Parity with Python:** Swift features agree to 7.5e-14, and every model's probabilities and
  the stages exactly, on a fixture that now has gravity. 66 SyncCore tests pass.
- **Data:**
  - DREAMT nights are re-converted with per-second gravity: 84 of them, 56 with beats over half
    the night.
  - sleep-accel is copied to `~/datasets/sleep-accel`.
  - `wrist_night.py` converts sleep-accel, and BIDSleep straight from its zip.
- **Installed;** the app needs reopening after the reinstall.

### Not yet confirmed on the phone

- That records saved from now carry gravity, and that the restaged 28→29 night logs "0% of seconds
  with gravity" (it was stored before decoding) with the same stages as before.

### In progress

- **DREAMT:** 89 of 100 nights downloaded and checked against SHA256SUMS.
- **BIDSleep** (6.35 GB zip) starts downloading once DREAMT finishes, to `~/datasets/bidsleep`.

### Next

1. **When BIDSleep is in:** convert it, retrain the movement model on BIDSleep plus sleep-accel,
   rerun `rotation_cv.py`, re-export and reinstall.
2. **When DREAMT completes:** rerun `dreamt_cv.py` and `dreamt_gru.py` on all nights. Their
   movement columns are now rotation.
3. **Each trial morning:** pull both DBs and compare the MG night with the Fitbit and the
   owner's notes. Awakening times, even rough ones, would let the wake bouts be checked.
4. **The fusion weight** (0.5 now; 1 finds more short wake on DREAMT): revisit after a few trial
   nights.

## 2026-10-29 (later): sleep stages in the app and in Apple Health

### Built

- **Stages on the phone.** `SleepStager` (SyncCore) stages each finished night from history RR:
  HRV features, two LightGBM stages, then a tempered Viterbi pass.
  - **In the app:** the main screen shows the latest night under "Sleep stages (experimental)".
  - **In Health:** the same stages replace the night's plain "asleep" with Awake / Core / Deep /
    REM. The night is cleared first; resting HR and breathing go back with it.
- **The model:** heart only, trained on 382 open ECG sleep-lab nights (HMC and CinC 2018).
  - **Against sleep-lab scoring:** κ 0.43 on held-out nights. A bidirectional GRU gets 0.48 but
    isn't shipped yet. Fitbits score 0.41–0.42 in independent tests and 0.63 in Google's own.
  - **On the 28→29 Oct MG night:** 81–82% agreement with the Fitbit Air.
- **Parity with Python:** checked on a fixture. Features agree to 1e-13 and stages exactly.
  SyncCore builds with `-O` even in Debug, so a night stages in about 1.5 s.
- **Retention:** beats and per-second records are now kept for 14 days, not 3, for the trial.
- **Commits on `main`:** `c9f3c11` (research), `e6f69f6` (stages in the app), `86e9c24` (stages
  to Health). None pushed.

### Not yet confirmed on the phone

- **The Health write from build `86e9c24`.** It was installed, but the app hadn't been opened
  since. Check the Log for "Apple Health: removed N earlier samples" followed by "saved N
  samples", and the Health app's Sleep view for Strap Sync stages.

### Found

- **The old research scripts used the wrong night window,** 70 minutes ahead of the band flag's.
  With it fixed, the first model's agreement with Fitbit went from 52% to 61%; HRV took it to 82%.
- **Overnight RR coverage on the MG is 89%,** not 60%. Its gaps coincide with movement.
- **The MG's gravity vector** is in R18 at bytes 45/49/53 (float32 x/y/z, about 1 g). That makes
  device-independent wrist-rotation features possible, which is the planned fix for movement.
  See `SLEEP_STAGES.md`, step 2.
- **Movement and skin temperature from DREAMT don't transfer to the MG** as magnitudes: there's a
  population confound and the devices differ. The model stays heart-only until rotation is tried.
- **On the 28→29 Oct night,** with 65 movement bouts, the Fitbit scored 1 minute of wake, and the
  model caught 1 of the 15 big heart-rate surges.

### In progress

- **DREAMT download:** 80 of 100 nights, 8 at a time. Files land in `~/datasets/dreamt/data_64Hz`,
  and a file is complete when its mtime is the server's 2024 date.
- **The trial:** the owner wears both the MG and the Fitbit from 29 Oct and notes remembered
  awakenings.

### Next

1. **Wrist-rotation movement features** for DREAMT, sleep-accel and BIDSleep (BIDSleep: download
   from PhysioNet, open, 5.9 GB zip). Retrain, test on the MG night, then decode bytes 45/49/53
   in the app.
2. **When DREAMT completes:** rerun `dreamt_cv.py` and `dreamt_gru.py` on all nights.
3. **Each trial morning:** pull the MG DB and Health Dashboard DB and compare per night. Use the
   Fitbit and the owner's notes, not the Fitbit alone.
4. **Model upgrades:** possibly the GRU (better on sleep-lab nights) or an ensemble. Re-export
   with `export_model.py`; a new version restages and rewrites the nights the app still has.
5. **MESA when approved.**

## 2026-10-29: first full night, ECG working, sleep fixed, stages researched

### Working on the owner's MG

- **Pairing:** the strap was never set up with the WHOOP app. It needed pairing mode: charge it,
  then tap until the lights flash blue.
- **Background history:** downloads every 15 minutes, about 900 records each.
- **Morning catch-up:** 65,632 records (18 h) in 7 minutes, now shown as "Downloading: N records, up
  to HH:MM".
- **First night (28→29 Oct):**
  - Total sleep within 2 minutes of the Fitbit Air's.
  - Resting HR and hourly breathing rate written. One hour's breathing rate was an outlier; filtering
    hours far from the night's median would catch it, but isn't done.
  - SpO2 from 25 runs.
- **ECG:** complete recordings, about 40 s at about 98 Hz.
  - Heart rate comes from the strap, else the trace if it's within 15% of the wrist HR, else the
    wrist HR (`heartRateSource`).
  - The how-to screen, countdown and done state are in.
- **Sharing with Health Dashboard** via the keychain group (`SHARING.md`). The dashboard side is
  SPEC §17.27 in that repo (schema v9): skin temperature becomes wrist temp, and ECGs appear under
  Today → Health Monitor.

### Fixed today

- **Nights judged mid-download:** the first night was written from half a download, hours short.
  Nights now need settled data after their end and aren't judged during a download.
- **Sleep from stillness:** the band's own flag now defines the night.
- **Re-written nights:** they now clear the app's earlier sleep, resting-HR and breathing samples
  from Health first. One-off redo flags `nightsRedo1` and `nightsRedo2` recomputed that night, and
  Health now holds the corrected version.

### Open

- **The app was dead for 18 hours on 28–29 Oct.** There was no crash or jetsam report, so it may have
  been swiped away.
  - Launch reason, termination, memory warnings and Bluetooth state are now logged.
  - A "stopped syncing" local notice fires 3 h after the last completed download.
  - Confirm the next gap's cause from the log.
- **Sleep stages:** an interim heart-only model now runs in the app. It shows each night's stages
  on the main screen and writes them to Health as Awake / Core / Deep / REM, in place of plain
  "asleep". See [`SLEEP_STAGES.md`](SLEEP_STAGES.md).
  - Beats and per-second records are now kept for 14 days, not 3, so nights can be copied off for
    research.
  - An HRV model trained on 382 open ECG sleep-lab nights agrees with the Fitbit on 82% of the
    first night (κ 0.67). The first model managed 52%.
  - Against sleep-lab scoring it reaches κ 0.43, level with independent Fitbit tests (0.41–0.42)
    but short of Google's own 0.63.
  - The old scripts' night window was 70 minutes early; it's fixed.
  - Next: more training nights, and DREAMT (the owner must sign PhysioNet's DUA).
- **SpO2 calibration** still needs a logging reference oximeter.
- **Signing:** the free signing profile expires 29 Oct. Reinstall both apps
  (`scripts/install-app.sh`; the dashboard via `roamrun install iPhone <app>` after building `iosApp`
  in the Wellmaxx repo).

## 2026-10-28 (later): ECG, and sharing with Health Dashboard

### ECG (built, not yet tried on the strap)

- **Commands,** from ryanbr/noop `docs/PROTOCOL_ECG.md` and #891, hardware-confirmed on other MGs:
  - Start: select wrist (123 `01 01` right / `01 02` left), live filtered output on (139 `01 01`),
    generation start (124 `01 02`, not `01 01`, which is stop).
  - Stop: 124 `01 01`, then 139 `01 00`.
  - A recording cut off by a disconnect is stopped on the next connection, never restarted.
- **Data:** filtered R17 records (packet type 43, layout 17, 240 bytes, up to 100 i16 samples)
  plus the status block: progress, quality, contact, a heart-rate value, and an HRV-related value
  with unknown units.
- **When it finishes:** once the strap reports progress 100 and the HRV value arrives (or 20 s after
  progress 100). Gives up if no waveform arrives within 20 s; caps the whole recording at 120 s.
- **Stored** for 90 days, and shown as a list and a scrollable trace.
- **Unknowns:**
  - Amplitude is uncalibrated.
  - The sample rate isn't a published constant, so it's estimated from arrival times.
  - There's no rhythm classification. Byte 23 is kept raw.
- History downloads wait while an ECG runs.

### Sharing (built)

- The format is in [`SHARING.md`](SHARING.md), which is the contract with Health Dashboard: a
  keychain group, `<TEAM_ID>.com.richarddraycott.healthshare`.
  - Free teams can't sign App Groups (tested: Xcode refuses), but keychain groups under the team
    prefix work.
- Strap Sync is the only writer, and keeps 7 days:
  - `skin-temperature`: 10-minute means over worn minutes. Rewritten when it changes, checked every
    10 minutes.
  - `ecg.<start>`: one item per recording.
- Per-minute summaries now stay 8 days, so a whole week can be shared.
- The Health Dashboard reader is being built in that repo.

## 2026-10-28: built, paired, writing to Health

**Hardware:** a WHOOP MG, never set up with the WHOOP app.
iPhone 16 Pro. Installs go over RoamRun (`scripts/install-app.sh`); free-team builds last 7 days.

### Seen working on the strap

- **Pairing,** once the strap was in pairing mode. Before that, two attempts were refused within a
  second ("Encryption is insufficient" / "Authentication is insufficient"). After charging it and
  tapping it until its lights flashed blue, `CLIENT_HELLO` was acknowledged on the first try. iOS
  showed no pairing prompt.
- **Clock:** `SET_CLOCK` latched; `GET_CLOCK` read +0 s from the phone.
- **History download:** 304 chunks, 361 records, all acknowledged. Every record was dated outside the
  last 30 days, because the strap had never had its clock set, so all were skipped as intended.
  From now on it saves with the right time.
- **Live heart rate:** about 1 reading a second over `2A37`, with RR, while the app is running.
- **Health:** per-minute heart rate samples written (first ones 12:50 and 13:11–13:21 UTC).

### Built, not yet seen on real data

| Data | Source | Status |
|---|---|---|
| HRV (SDNN) | RR, best 5-min window per hour | Needs a full worn hour |
| Steps | R18 step counter (@57) deltas | Counter never checked against a reference |
| Sleep (asleep/awake) | Still, worn minutes with a below-waking heart rate | Thresholds are first guesses; the band's own sleep flag (@81) has never been seen set in a real capture |
| Resting heart rate | Lowest 30-min mean while asleep | Depends on sleep |
| Breathing rate | Respiratory sinus arrhythmia peak in 5-min RR windows while asleep | Tested on synthetic data only |
| Blood oxygen | R18 byte 82, the strap's own reading | See below |
| Skin temperature | R18 @73 / 100 | Shown in the app only: Health has no correct type |

Each history download logs a "History data …" summary line:

- step counter range
- band-state histogram
- motion range and % still
- skin temperature range
- SpO2 reading count
- counts of the other record layouts

Each finished night logs a "Sleep: …" line with its times, resting HR, breathing rate and SpO2.
These are what to check first.

### Not possible yet

- **SpO2 calibration:** we don't know whether byte 82's values are accurate; see the next section.
- **Respiratory rate from the strap's own sensors:** not decoded on 5/MG, so it's estimated from heart rate instead.

## SpO2 reverse engineering

**What's known.** R18 byte 82 is almost certainly the strap's own SpO2 output
(ryanbr/noop [#1099](https://github.com/ryanbr/noop/issues/1099), on a subscription-free MG):

- The strap measures in ~30 s runs about every 20 minutes while asleep.
- 70–100 are readings; values with bit 7 set are sentinels; small values are codes.
- The first ~5 readings of each run are a lock-on ramp.
- Post-ramp lows are followed by a heart-rate rise, as real desaturations are, but ramp lows at the
  same value aren't. A decode error couldn't produce that split.
- The firmware console logs "generated a valid SPO2 during sleep".

**What's not known.** Calibration. On one strap it tracked the WHOOP app almost exactly; on another,
two nights moved the opposite way.

**Done.** The app decodes byte 82 with the #1099 recipe:

- Keep readings of 70–100.
- Split runs on gaps over 60 s.
- Drop each run's first 5 readings, and drop runs left with fewer than 5.

It writes each run's median as oxygen saturation, and archives every raw frame (hourly files in
`Documents/raw`, 7 days) so nothing is lost after the strap deletes acknowledged history.

**Next:**

1. After the first night: pull the log and `secrets/raw` (`scripts/install-app.sh --pull-raw`).
   - Check byte 82 produced runs, at roughly 20-minute spacing, in a plausible 94–99% range.
   - Check which other record layouts the strap stores (R20 / R21 / R26 optical and IMU).
2. Calibrate against a reference: one night wearing a logging pulse oximeter (e.g. Wellue O2Ring)
   alongside. Then compare run medians with the reference at the same times, and fit an offset or
   linear correction if needed.
3. Independent SpO2 from raw optical data: the MAX86176 front end supports red and IR LEDs. If the
   archive shows red/IR channels in R20/R26, compute the ratio of ratios
   (AC/DC red over AC/DC IR) per run and check it against byte 82 and the reference.

## Pulling data off the phone

- `scripts/install-app.sh --pull`: logs, to `secrets/logs/`.
- `scripts/install-app.sh --pull-raw`: raw frame archive, to `secrets/raw/`.
  - Format: `[length u16 LE][frame]` repeated; hourly files named `yyyy-MM-ddTHH.bin` (UTC).
- Database:
  ```
  xcrun devicectl device copy from --device <id> --domain-type appDataContainer \
    --domain-identifier com.richarddraycott.WhoopSync \
    --source "Library/Application Support/WhoopSync/sync.sqlite-wal" --destination secrets/db/
  ```
  - Copy `sync.sqlite` the same way. Over RoamRun the copy sometimes fails part-way and leaves an
    empty file, so retry.
- `secrets/` is gitignored.

## Gotchas found along the way

- Reinstalling quits the app, and iOS doesn't restart it for Bluetooth until it's opened once.
- RoamRun can't install while the phone is locked.
- The fork's working MG path never sends `GET_HELLO` or `GET_DATA_RANGE`. The handshake is
  `CLIENT_HELLO` → `SET_CLOCK` (10) → `GET_CLOCK` (11) → `SEND_HISTORICAL_DATA` (22).
