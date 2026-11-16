# Strap Sync: spec

Status: built, paired with the MG and writing to Health (2026-10-28). Where the build differs from
the plan below, §13 says so; what's been seen working is in [`PROGRESS.md`](PROGRESS.md).

## 0. What this is

A small iOS app that pairs with your own WHOOP strap over Bluetooth and writes what it
measures into Apple Health. That is the whole product. No scores, dashboards, coaching
or history screens: Apple Health is the UI.

- **Target strap:** WHOOP MG (the owner's strap, and the one acceptance is tested on).
  WHOOP 5.0 shares its protocol and comes along for free.
- **Secondary:** WHOOP 4.0. Its protocol is the best understood, but there's no hardware
  here to test it on.

The owner doesn't use the official app, so this app can take the strap's bond outright. The
owner wears either the MG or a Fitbit Air, never both, so heart rate in Health never overlaps.

Informed by [`ryanbr/noop`](https://github.com/ryanbr/noop), the active fork of NOOP (the
original `muftiarfan/noop` has had no commits since June). The fork already ships an iOS
app that writes to Apple Health, plus a lot more. We follow its protocol docs and the
Bluetooth behaviour it learned on real straps, and copy none of its code (§9).

## 1. What an MG can give us

Everything hinges on the **bond**. Without a bond the strap can't be given its clock, and an
MG without a clock doesn't save sensor data to its memory.

- **Live heart rate and RR intervals always work.** They arrive over the standard Bluetooth
  Heart Rate Service (`180D` / `2A37`), which needs no bond.
- **History works on iPhone once the strap is bonded.**
  - [#2809](https://github.com/ryanbr/noop/issues/2809) (19 Oct): an MG on firmware
    50.42.1.0 with iOS 27.0.1 and the fork's v12.0.0, downloading history every ~10 minutes,
    with sleep and workouts landing at the right times.
  - [#613](https://github.com/ryanbr/noop/issues/613): a WHOOP 5.0 on iOS 26.5 with its
    hello acknowledged and the bond holding.
  - [#217](https://github.com/ryanbr/noop/issues/217): a WHOOP 5.0 on iOS 27.0 with the hello
    acknowledged and history downloads completing in R18 records, both before and after a
    firmware update (50.40.1.0 → 50.41.1.0).
- **Upstream's changelog still says MG history is "unsolved".** That line comes from straps
  that won't bond, and the reports are from Android:
  - [#1635](https://github.com/ryanbr/noop/issues/1635): on a Samsung, the strap refused
    Bluetooth pairing (SMP error 0x05), and 14 of 16 hellos went unanswered. The app was also
    firing a second command while the hello was still outstanding.
  - [#2127](https://github.com/ryanbr/noop/issues/2127): also Android.
- **Some metrics aren't decodable on 5.0/MG at all.** SpO₂ can't be recovered from the data,
  there are no sleep stages (only a WAKE/STILL/SLEEP/UP band state), and respiratory rate
  isn't decoded. History does carry skin temperature and a step counter.

So the plan is: bond, set the clock, and download history every ~15 minutes while the
phone is in range. Gaps fill in on their own when the phone comes back. Live heart rate
gives instant feedback while pairing, and it's the fallback if this strap refuses to bond.

| Metric | MG bonded (history + live) | MG not bonded (live only) | WHOOP 4.0 | Apple Health type | Phase |
|---|---|---|---|---|---|
| Heart rate | history R18 + live `2A37` | live `2A37` | history v24 + live | `heartRate` | 1 |
| HRV (SDNN) | R18 RR (up to 4 per 1 s record) | live RR | history + live | `heartRateVariabilitySDNN` | 1 |
| Battery | `2A19` | `2A19` | `2A19` | shown in app only | 1 |
| Resting HR | computed from HR | same | same | `restingHeartRate` | 2, optional |
| Steps | R18 pedometer counter, unvalidated | no | no | `stepCount` | 2, optional |
| Sleep | band state only, unvalidated | no | needs NOOP's sleep stager | `sleepAnalysis` | out |
| Skin temperature | R18 raw/100 °C | no | raw sensor value | none (see §6) | out |
| SpO₂, breathing rate | no | no | raw sensor values only | — | out |

## 2. Phases

### Phase 1: pair, download, write (the product)

There's no separate hardware spike any more. Upstream has already answered the protocol
questions, so the first build of Phase 1 is the hardware test, and its log answers the rest
(§11).

Scope:

- First-run pairing, including the bond (§3).
- Clock set and history download every ~15 minutes (§10).
- Live heart rate.
- Per-minute heart rate and hourly HRV into Health (§4).
- A local buffer, a status screen and a log.

Acceptance, on the MG:

- From a fresh install, pairing (bond included) takes under 5 minutes by following the
  on-screen steps.
- After a night with the phone locked on the nightstand and the app in the background,
  Health has heart rate for at least 95% of the minutes the strap was worn.
- After leaving the phone at home for 3 hours while wearing the strap, those 3 hours appear
  in Health within 30 minutes of getting back, without the app being opened.
- Pressing "Write now" twice, or reinstalling and re-downloading, creates no duplicates.
- No more than one HRV sample per hour.

**Go/no-go inside Phase 1:** if the bond is refused even after the full recovery steps in §3,
the app runs live-only: the phone must stay in range, and gaps aren't filled.

### Phase 2: optional extras

- Daily resting HR, using one simple rule: the lowest 30-minute rolling mean of the previous
  night, written at 10:00.
- A local notification when the strap's battery drops below 15%.
- Steps from the R18 pedometer counter. This only goes ahead if a week of counts lines up
  with the iPhone's own step count to within 15%. Counter rollover and reset behaviour are
  unknown upstream.

## 3. Pairing and connection

### GATT

| Service | UUID | Used for |
|---|---|---|
| Heart Rate | `180D`, `2A37` notify | HR + RR. No bond needed. |
| Battery | `180F`, `2A19` read + notify | Battery % (on 5.0/MG, reads only succeed after bonding: #490) |
| Device Information | `180A`: `2A24` model, `2A25` serial, `2A26` firmware, `2A27` hardware | Telling MG / 5.0 / 4.0 apart; the `HKDevice` |
| WHOOP 5.0 / MG | `fd4b0001-cce1-4033-93ce-002d5875f58a`; write `fd4b0002`; notify `fd4b0003/0004/0005/0007` | Scan anchor, bond, commands, history |
| WHOOP 4.0 | `61080001-8d6d-82b8-614a-1c8cb0f8dcc6`; write `…0002`; notify `…0003`–`…0005` | Same, for 4.0 |

### Finding the strap

- Scan only for the two WHOOP service UUIDs. Never scan for `180D`, because AirPods, Apple
  Watches and other heart-rate straps advertise it too.
- Call `retrieveConnectedPeripherals(withServices:)` with both WHOOP UUIDs **before**
  scanning. A strap that's already connected at the OS level doesn't advertise, so a scan
  won't find it.
- A link iOS already holds shows as `.connected` even though this app has no session of its
  own. Call `connect()` anyway, and only treat the strap as connected once `didConnect`
  fires (upstream #689).
- List the straps found, closest (strongest RSSI) first, with their DIS model. The user taps
  one, and the app saves `peripheral.identifier`. Every connection after that targets that
  identifier.
- Identifying MG vs 5.0: model `MG` or serial prefix `5AM` means MG; serial prefix `5AG` or a
  hardware revision containing `WG50` means 5.0. If it's unclear, that's fine, because the
  protocol is the same. This is only used for labels and the `HKDevice`.

### First-run pairing

On-screen steps for the user:

1. **Delete the WHOOP app** from the phone: it competes for the strap.
2. If the strap was ever paired to **this** iPhone, iOS already holds the bond, and the bond
   belongs to the phone rather than to an app. Try connecting first: it may just work, with
   no pairing mode needed.
3. If the bond is refused, go to Settings → Bluetooth → WHOOP → Forget This Device. Then tap
   the strap firmly and repeatedly until its LEDs flash blue (pairing mode), and connect
   again.

What the app does (MG / 5.0), strictly one operation at a time:

1. Connect, discover services, and subscribe to `2A37`. Live heart rate shows straight away,
   which proves the radio link is good.
2. Subscribe to `fd4b0003/0004/0005/0007`, waiting for every
   `didUpdateNotificationStateFor` before continuing.
3. Write `CLIENT_HELLO` to `fd4b0002` with response:
   `AA 01 08 00 00 01 E6 71 23 01 91 01 36 3E 5C 8D`. iOS does "just works" bonding, with no
   PIN.
4. **Send nothing else until the hello resolves.** In #1635, a second write landing while
   the hello was outstanding happened in 15 of 16 failed attempts. iOS queues writes better
   than Android does, but keep strict ordering anyway.
5. Only count the hello as acknowledged when `didWriteValueFor` fires **for `fd4b0002`**, with
   no error, within 10 s. #1635 had a false acknowledgement from a different
   characteristic's write completing.
6. Outcomes (port this behaviour from upstream, see §9):
   - **Acknowledged:** bonded. Run the handshake in §10.
   - **ATT `insufficientEncryption` / `insufficientAuthentication`:** the bond was refused.
     Show steps 1–3 above. Stop retrying automatically after 3 refusals in a row (upstream's
     `BondRefusalGiveUp`); retrying harder doesn't help.
   - **No callback, and the link drops** (#1635 saw a fixed ~3.16 s local teardown): treat it
     as a refusal. After 3 in a row, stop sending the hello to this strap and stay live-only
     (upstream's `HelloSuppression.swift`), with a "Retry pairing" button.

**4.0:** a single confirmed write (the `GET_BATTERY_LEVEL` frame) triggers the bond, then run
the handshake in §10.

### Staying connected in the background

- Set `UIBackgroundModes: bluetooth-central`. Create the `CBCentralManager` with
  `CBCentralManagerOptionRestoreIdentifierKey`.
- **Restore fix (#613):** a peripheral handed back by `willRestoreState` that is already
  connected never gets a `didConnect`. When `centralManagerDidUpdateState` reaches
  `.poweredOn`:
  - If the peripheral is `.connected`: set the app's connected state and the saved
    identifier, re-discover services, re-enable every notification, and re-run the
    once-per-connection handshake gate.
  - Otherwise: call `connect()`.

  Upstream skipped this, so a restored link sat half-alive: no live HR, and empty
  downloads.
- On disconnect, call `connect(p)` again straight away. A pending connect never times out,
  and iOS wakes the app when the strap comes back in range.
- Never scan in the background. iOS throttles background scans so heavily that upstream
  logged 8 minutes of finding nothing. Background reconnects only target the saved
  identifier.
- Known iOS limit: force-quitting the app from the app switcher stops all background
  relaunches until it's opened again.

## 4. Turning the data into Health samples

All of this goes in a pure Swift package (`SyncCore`) with unit tests and no CoreBluetooth
or HealthKit imports. Live beats and history records feed the same code; both carry HR and
RR with a timestamp.

### Parsing `2A37` (live)

- Flags byte: bit 0 is the HR format (u8 or u16), bits 1–2 are sensor contact, bit 3 means
  energy expended is present, and bit 4 means RR intervals are present. RR values are u16 LE
  after the HR (and after the energy field, if it's present).
- The timestamp is the phone's arrival time.
- **RR unit:** WHOOP 5.0/MG sends **milliseconds** on `2A37`, not the 1/1024 s the Bluetooth
  spec defines (upstream `Whoop5RR.swift`, from 71k frames). As a guard against firmware
  differences, check it on each connection anyway: compare `60000 / mean(RR)` over the first
  30 beats with the mean bpm, and pick the unit that agrees to within 5 bpm. If neither unit
  agrees, drop live RR for that connection and log it.
- Drop readings with HR of 0, or with sensor contact reported as false.

### History records (MG R18)

These come from `WhoopProtocol` decoding: HR at byte 22, RR count at 23, up to 4 RR words from
24, and a unix timestamp at 15. The fork treats these RR words as milliseconds too, the same
as live. Upstream's protocol doc still says 1/1024 s, so run the same unit check per download.

### Heart rate: one sample per minute

- For each clock minute with at least 10 readings, take the mean bpm. Only use minutes where
  the mean is between 25 and 230.
- Write a `heartRate` sample from the minute's start to its end, in count/min.
- When worn all day that's up to 1,440 samples a day, the same per-minute stream upstream
  writes.

### HRV: at most one sample per hour

- Accept RR values between 300 and 2000 ms. Drop any value that differs by more than 20%
  from the previous accepted beat; this is a simple filter for ectopic beats.
- Split time into 5-minute windows aligned to the clock. A window qualifies when its accepted
  RR values add up to at least 240 s.
- SDNN is the standard deviation of a window's accepted RR values after smoothness-priors
  detrending (Tarvainen 2002, λ = 500, as Kubios does). Drifts and steps in heart rate don't count
  as variability.
- A window is **steady** when the mean HR of each of its minutes (those with at least 20 accepted
  beats, and at least 4 of them) stays within 5 bpm.
- For each clock hour, write the steady qualifying window with the lowest mean HR (a rough
  stand-in for "at rest"); with no steady window, the qualifying one with the lowest mean HR. It's
  a `heartRateVariabilitySDNN` sample in ms, from the window's start to its end. Its version
  starts at 1,000,000, so these replace the samples written before 8 Nov 2026.
- The same window's RMSSD is computed too: the root mean square of differences between
  successive clean intervals that were neighbours in the recording. Health has no RMSSD type, so
  it rides on the SDNN sample as metadata (`StrapSyncRMSSD`), and is shared with Health Dashboard
  with the SDNN (SHARING.md, "Through Apple Health" and `hrv`).
- If no window qualifies, write nothing for that hour.
- Apple Watch measures SDNN over roughly 1-minute readings, so these numbers won't line up
  exactly with the Watch's.

### Dedup

Every sample carries `HKMetadataKeySyncIdentifier` and `HKMetadataKeySyncVersion`:

- `whoopsync:hr:<minute start, unix>`: version 1 from live, 2 from history, so the strap's
  own record replaces the live estimate.
- `whoopsync:hrv:<window start, unix>`: same version rule.

HealthKit only replaces a sample with the same identifier when the new version is higher, so
sending a sample again is safe. A minute or window that gains data later (live first, then
history) gets the higher version, so it replaces the earlier sample. Also set an `HKDevice`
(name, manufacturer "WHOOP", model, firmware and hardware from DIS) and
`HKMetadataKeyHeartRateSensorLocation = .wrist`.

Every sample also carries `HKMetadataKeyTimeZone`, the zone the phone was in at the sample's start. Without
it, readers guess the zone, and after the phone changes zone they can guess the one it left. It's not the
phone's zone when the sample is written: that's right for live data, written minutes after, but not for
older data written again (a restaged night, a version bump, a metadata backfill) after a change of zone.

- **Zone history** (`ZoneHistory` in SyncCore, the `zones` table): the phone's zone (`TimeZone.current`, reset
  first) from each instant it was seen in a new one: at launch, at each history download and on
  `NSSystemTimeZoneDidChange`. A row is added only when the zone differs from the latest.
- **The outbox keeps the zone** each row was stored with (`zone`): the history's zone at its start, filled in
  when the row is first stored, and kept when the row is rewritten (`Outbox.merge`). Health is given that.
- **The owner's record:** `Documents/time-zones.json` (`ZoneFile`; DEVELOPMENT.md has the format), read at
  each launch, replaces the logs' zones where it reaches, before the app's own first record. Anything wrong in
  it and it's ignored, whole.
- **Before the history:** reconstructed once from the app's daily logs (`ZoneLog`). A log's lines are in the
  zone its process started in, so a change shows only in a new process ("App launched…"), and each file's
  modification time gives the offset of the process that wrote its last line. Earlier processes keep the
  offset before them, unless the lines, which never go back in time, say the change came earlier. Offsets
  hold across silences of up to a day.
  - An offset becomes the phone's own zone where that zone has the offset throughout, else a fixed-offset
    zone (`GMT-0800`).
  - Where no log covers an instant (before the first line, a day with no log), the zone is unknown, and
    samples starting then go to Health without one, rather than with a wrong one.
- **`zoneRedo1`** rewrites, once, the app's own samples in Health from the last 16 days whose zone isn't the
  history's at their start (or that have none; the same offset under another name counts as right).
  - **Health decides, not the outbox.** The outbox can hold rows Health no longer has, still marked written: a
    night staged again from a later start keeps the earlier version's rows that start before it, and its clear
    deletes them from Health. Rewriting from the outbox would put those deleted, overlapping stages back.
  - So it reads the samples (`HealthWriter.ownSamples`: this app as source, each type it may write; an app
    allowed only to write can read what it wrote, so it needs no read permission) and, for each wrongly
    stamped one, takes its outbox row of the same sync identifier, kind, start and end. The row gets the
    history's zone and a sync version one above both the outbox's and Health's, and is marked unwritten, so
    Health replaces the sample in place; data, data version and metadata are kept. A sample with no such row is
    left as it is, and nothing new is written. Outbox rows Health doesn't have are never touched (`ZoneRedo`).
  - It goes through the outbox like any write (HealthFlush: batches of 500, held while locked) and restages
    nothing. It runs with no clear pending, and gives up and tries again if a night was staged while Health
    was read, since a clear could have deleted a sample after it was read. A row planned again meanwhile is
    left to go out as planned (it's only rewritten if it still has the version it was read with).
  - It uses the history in effect (the app's record, the owner's file, the logs), and waits for the logs'
    zones and for the file, if there is one, to be read; then for protected data, no download or save under
    way, and `metadataRedo1` and `nightsRedo6` to be done. If Health returns nothing while the outbox says it
    was given samples, it does nothing and tries again later.
  - **Lost nights** (the same pass, `ZoneRedo.lostNights`): a night Health lost to the clear-after-save race
    (fixed in `HealthFlush`) whose rows the outbox still has, marked written, is written again, but only when
    all of these hold: its outbox sleep rows (less than two hours apart) start in the 16 days, were all given
    to Health, and have one version, the highest of any outbox sleep row overlapping the night; and Health has
    none of the app's sleep, resting-heart-rate or breathing samples within two hours of it. Then its sleep rows,
    and the resting-heart-rate and breathing rows within it that were written, go out in the history's zone,
    one sync version up. Only when every night kind could be read. Each such night is logged.
- **Checks:**
  - `scripts/zone-check.sh`: end to end in a new Simulator, with HealthKit (`ZoneCheck.swift`). Made-up nights
    and heart rate go through the app's writer in one zone, then the night is restaged stamped with another,
    leaving stale written rows in the outbox, and two nights are deleted from Health: one at its newest version,
    one staged twice. After the redo, Health must have exactly the same samples plus the first of those nights,
    each in the history's zone, the rewritten ones one version up.
  - `ZoneDryRunTests`, on copies of the logs, the database and Wellmaxx's database (standing in for Health): the
    reconstructed history, and what the redo would rewrite by night and kind. Skipped unless
    `STRAPSYNC_DRYRUN_DIR` is set.

### Strap Sync's own metadata

Health has no type for skin temperature, RMSSD or a WHOOP ECG, so they ride on samples it does have, under
custom keys (`StrapSync…`, never Apple's `HK` prefix; SHARING.md, "Through Apple Health" has the contract):

- Each heart-rate sample carries the skin temperature of its 10-minute interval, the keychain's intervals and
  rule: the mean over the interval's worn minutes, when at least 5 were worn.
- Each HRV sample carries its window's RMSSD.
- The heart-rate sample of the minute an ECG started in carries the recording, base64 of its 16-bit samples.
  The MG's heart rate stays 0 during an ECG, so when that minute has no sample, the recording gets a heart-rate
  sample of its own (`whoopsync:ecg:<start>`, its start to its end, at its own heart rate), and keeps it.

A sample's metadata can change while its data doesn't: an interval fills in over several downloads. Health
only replaces a sample when the sync version goes up, so the outbox keeps two versions per row (`Outbox.merge`):

- `basis`, the version the data was planned with, by the rules above;
- `version`, the sync version Health is given. It equals `basis` until the metadata alone changes, then goes
  up by one at each such rewrite, and never below `basis`.

So more data still replaces the sample as before, and the same data with other metadata replaces it one
version up. (In the Simulator an equal version replaced the sample too, and a lower one was silently
ignored.) `metadataRedo1` replans the stored days once, so samples written before carry the metadata.

## 5. Local buffer and Health writes

- Keep one SQLite file (GRDB) in Application Support, with file protection
  `completeUntilFirstUserAuthentication` so it can be written while the phone is locked.
  Bluetooth wakes the app while it's locked.
- Tables:
  - `beats`: ts, bpm, RR values, source (live/history). Kept for the open minute and HRV
    windows, and deleted after 48 hours.
  - `outbox`: sync identifier, type, start, end, value, version, `written_at` (null until
    written).
  - `state`: peripheral identifier, detected RR units, bond outcome, hello suppression,
    refusal count.
- A downloaded chunk's records and its acknowledgement block are saved in **one** transaction.
  Only after that is the chunk acknowledged to the strap (§10).
- **Writer:** every 5 minutes, after each download, when the app comes to the foreground, and
  on `protectedDataDidBecomeAvailable`. It saves unwritten outbox rows in batches of up to
  500, then sets `written_at`. If a save fails, the rows stay in the outbox for the next pass.
- **Rewriting a night:** a night written again first deletes, by time range, the sleep, resting-HR and
  breathing samples the app wrote from two hours before it to two hours after (a `clears` row), since
  its earlier samples can have other sync identifiers. That order must hold whatever else runs
  (`HealthFlush` in SyncCore):
  - Staging a night adds its clear and its new rows in one transaction (`Store.stageNight`), drops the
    night's earlier rows from the outbox, and marks unwritten the samples of a night less than two hours
    away that the clear deletes too.
  - Before each batch, the writer runs every pending clear, read again each time. While a clear can't
    run (the phone is locked), the rows it covers wait and the rest are written.
  - Nights aren't staged while a batch is being saved; they're worked out again once the writer is done.
    So a clear never deletes a sample saved after it was added.
- **A night that goes on after it was written:** twelve minutes awake in the small hours writes the night
  as over, and it's only over again once you're up for the day. Until then what was written is short, and
  it's what would go to Health when the phone is unlocked in the morning. So each pass while protected data
  is available, the one on `protectedDataDidBecomeAvailable` included, first writes that night again as far
  as it has got (`Sleep.soFar`: the whole stored minutes, so it only ever grows; `Sleep.due` chooses what a
  pass writes), stages and all, and only then writes the outbox. With a night under way, unlocking also asks
  the strap for a download if the last was over a minute ago. A night not yet written waits until it's over,
  and when a night is over is decided as before.
- Apple says HealthKit caches writes made while the phone is locked. Don't rely on it: the
  outbox is the source of truth until a save succeeds, including when it fails with
  `errorDatabaseInaccessible`.
- As a fallback wake, schedule a `BGAppRefreshTask` that flushes the outbox.

## 6. Apple Health

- Entitlements: `com.apple.developer.healthkit` and `healthkit.access: []`. The owner's free
  personal team already signs HealthKit apps.
- Request write access to `heartRate` and `heartRateVariabilitySDNN`, plus `restingHeartRate`
  and `stepCount` if Phase 2 happens. No read access is needed, so the app asks for none and has
  only the update usage string (`NSHealthUpdateUsageDescription`).
- **Never** put `appleSleepingWristTemperature` in the set of types the app asks to write.
  It's reserved for Apple Watch, and asking for it throws an Objective-C exception Swift
  can't catch, which kills the app at launch (upstream #1366, verified on iOS 27). Skin
  temperature has no other correct type: `bodyTemperature` would record ~33 °C wrist readings
  as body temperature. So it isn't written as a type of its own; since 13 Nov 2026 it rides on
  heart-rate samples as metadata (§4).

## 7. App

One screen, plus a log.

- **Strap:** name, MG / 5.0 / 4.0, link (Bonded / Live only / Disconnected), battery, last HR
  and its time, clock set (yes/no, from GET_CLOCK), last download time and record count.
- **Health:** permission status, last sample written, outbox count, last error.
- **Actions:** Find strap, Retry pairing, Forget strap, Connect Apple Health, Download now,
  Write now.
- **Log:** the last 500 lines in the app, plus daily files in `Documents/logs`.
  `UIFileSharingEnabled` lets `scripts/install-app.sh --pull` copy them off the phone. Log
  every hello outcome, ATT error, clock reply, data range and chunk acknowledgement: that log
  is how the open hardware questions get answered.

## 8. Repo layout and build

The layout:

```
project.yml              XcodeGen; iOS 17; target WhoopSync
Config/Base.xcconfig     APP_BUNDLE_ID / DEVELOPMENT_TEAM defaults; includes Local.xcconfig
Config/Local.xcconfig    not committed: team <TEAM_ID>, bundle com.richarddraycott.WhoopSync
App/WhoopSync/           BLE/, Health/, Store/, UI/
Packages/SyncCore/       2A37 parsing, RR unit check, minute + HRV windows, sync IDs (swift test)
Vendor/WhoopProtocol/    planned, not used: SyncCore implements the protocol itself (§13)
scripts/install-app.sh   build and install over USB or RoamRun
```

Info.plist needs:

- `UIBackgroundModes: [bluetooth-central, fetch]`
- `BGTaskSchedulerPermittedIdentifiers`
- `NSBluetoothAlwaysUsageDescription`
- Both Health usage strings
- `UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace`

Free-team builds expire after 7 days. Install with the same RoamRun route as the other apps.

## 9. Behaviour to match from ryanbr/noop (read, not copied)

**Licence:** PolyForm Noncommercial 1.0.0. Nothing in this repo is copied from noop: the parts of its
code and docs listed below were read for behaviour, and SyncCore is an independent implementation of
the protocol (§13).
Protocol facts (UUIDs, frame layouts, command numbers, byte offsets) are explicitly free to reuse.
Any code copied from noop in future would need its licence and the line "Required Notice: Copyright
2026 NoopApp" with it, and would be non-commercial only.

| Behaviour | Where noop has it | Why |
|---|---|---|
| Framing and CRCs, the 5/MG hello, history streams, data range, RR units | `Packages/WhoopProtocol`: `DeviceFamily.whoop5ClientHello`, `extractHistoricalStreams`, `DataRange`, `Whoop5RR` | The protocol facts, reimplemented in SyncCore |
| Connect, restore and reconnect | `Strand/BLE/BLEManager.swift`: `connectCore(model:)`, `issueStandingConnect`, `scheduleReconnect`, `willRestoreState` (plus the #613 fix in §3) | iOS edge cases learned on real straps |
| Bond refusal handling | `BLEManager.swift`: `BondRefusalGiveUp`, `isInsufficientAuthError`; `HelloSuppression.swift`; `ClientHelloOutcome.swift` | Don't keep retrying a strap that refuses |
| Handshake and history | `BLEManager.swift`: the `connectHandshakeDone` block, `setClockPayload`, `ackHistoricalChunk`, `beginBackfill`; `Strand/Collect/Backfiller.swift`; `Strand/BLE/BackfillPolicy.swift`; `Commands.swift` | The order that works on iOS |
| Per-minute HR writes | `StrandiOS/Health/HealthKitBridge.swift` `writeHeartRate` | How upstream writes the same stream |
| Ground truth | `docs/PROTOCOL_WHOOP5.md`, `PROTOCOL_TRANSPORT.md`, `PROTOCOL_SENSORS.md`, `PROTOCOL_COMMANDS.md`, README "Pairing a WHOOP 5.0 / MG" | Protocol reference |

Not used at all: `StrandAnalytics`, `WhoopStore`, `StrandDesign`, or any of the UI.

**Safety rule** (from upstream): only send commands from the curated `WhoopCommand` set.
Never send `FORCE_TRIM`, `SET_READ_POINTER`, reboot, firmware/DFU or ship mode. Never
acknowledge a history chunk before its records are saved locally, because the
acknowledgement lets the strap delete them.

## 10. Handshake and history download

Commands use format-1 framing:

- The command body is packet type 35, a sequence byte and the command number, then the
  command bytes, zero-padded to a multiple of 4.
- The header carries a CRC16-Modbus over bytes 0–5, and the body ends with a CRC32.
- Responses are type 36. Match a response on command number plus the originating sequence
  (byte 11). The result is at byte 12: 0 failed, 1 success, 2 pending, 3 unsupported.
- Use `WhoopProtocol` for framing and parsing rather than hand-rolling it.

**MG / 5.0**, after the hello is acknowledged, **exactly once per connection**.
`didWriteValueFor` fires on every confirmed write, and re-running the handshake partway
through a download makes the strap stop serving history. Upstream calls this "the iOS-side
root cause" of its own early failures.

1. `GET_HELLO` (145): firmware version.
2. `SET_CLOCK` (10), payload `[unix seconds u32 LE, 00 00 00 00]`. This is the 8-byte form the
   fork has validated on 5.0/MG hardware.
3. `GET_CLOCK` (11), empty payload, to confirm the clock is set. Success alone doesn't prove
   a valid clock, so check the returned seconds against the phone's time (within 5 s). If it
   didn't take, try the newer documented pair once: `SET_CLOCK` (146) with revision 1, u32
   seconds and u16 ticks of 1/32768 s, then `GET_CLOCK` (147). The fork doesn't use this
   pair yet.
4. `GET_DATA_RANGE` (34). 5.0/MG needs this before history. The first reply is "pending" with
   an empty body, and no reply doesn't mean the history is empty.
5. About 1.5 s later, `SEND_HISTORICAL_DATA` (22) with payload `00`.
6. The strap streams type-49 metadata (START = 1, END = 2, COMPLETE = 3) with type-47 records
   in between. Decode R18 records with `extractHistoricalStreams`.
7. At each END, save the chunk's records plus its 8-byte acknowledgement block in one
   transaction. Then send `HISTORICAL_DATA_RESULT` (23) with payload `01` followed by those
   8 bytes, exactly as received.
8. Repeat from step 4 every ~15 minutes while connected, and on reconnect.

Expected cost: 5.0 streams about 35 records/s, so a full day of history takes ~41 minutes of
radio time (#1007). Acknowledge each chunk as soon as it's saved, because the strap won't
send the next one until then.

If the strap's battery ever runs flat, it loses its clock and stops saving data until the
next `SET_CLOCK`. The handshake re-sets the clock on every connection, so that's covered.

**4.0:** once bonded, run:

1. `GET_HELLO_HARVARD`
2. `SET_CLOCK`, in both the 8-byte and 9-byte forms. Firmware 41.17.x only takes the 9-byte
   one; newer firmware takes the 8-byte one.
3. `GET_CLOCK`, in both the empty and `[00]` forms.
4. `SEND_R10_R11_REALTIME [00]`, which stops a ~2 packets/s raw flood.
5. `GET_DATA_RANGE`.
6. `SEND_HISTORICAL_DATA`, then the same chunk loop as above.

## 11. Open questions: resolved

| Question | Answer | Source |
|---|---|---|
| Keep the WHOOP app alongside? | No. Delete it; this app takes the bond. | Owner |
| Overlapping heart rate in Health? | Never: the owner wears the MG or the Air, not both. | Owner |
| Does MG history work at all? | Yes on iPhone once bonded. The "unsolved" reports are straps refusing to bond, mostly on Android. | #2809, #613, #217, #1635, #2127 |
| Is a bond required for history? | Yes: no bond means no clock, and a strap with no clock saves nothing. An unbonded history probe exists upstream but has never produced a clean result. | #1802, #2127 |
| Which commands, in what order? | §10. | `BLEManager.swift`, `PROTOCOL_TRANSPORT.md` |
| RR units? | Milliseconds on 5.0/MG, not the Bluetooth spec's 1/1024 s. Checked per connection anyway. | `Whoop5RR.swift` |
| Why do some iOS links come back half-alive? | An upstream restore bug, avoided in §3. | #613 |
| Will a firmware update change the protocol under us? | Not while the WHOOP app is gone: it's what pushes updates. | #217 |
| Daily resting HR? | Optional, Phase 2. | — |

**Still open:** these can only be answered by the owner's strap, and the first build's log
answers them.

1. Does this MG bond with this iPhone, first try or after Forget This Device and pairing
   mode?
2. Does iOS keep the link and the 15-minute downloads going overnight with the phone locked?
3. After a phone reboot, does the app reconnect without being opened?

## 12. Risks

- **This particular MG may refuse to bond.** Then the app runs live-only (§2), which needs the
  phone in range all the time.
- **iOS may starve a backgrounded Bluetooth link overnight.** The overnight acceptance test
  covers it.
- **History download costs radio time:** ~41 minutes a day on 5.0, and every minute of
  live streaming costs some phone battery too. Measure it during the first week; if it
  matters, stop live `2A37` notifications while bonded and rely on history alone.
- **Upstream moves fast** (many commits a day in October 2026). Pin the vendored commit and
  update it on purpose.

## 13. What v0.1.0 does differently from this plan

- **WHOOP 5.0 / MG only.** There's no 4.0 to test against, so the 4.0 path is left out rather
  than shipped untested.
- **No vendored `WhoopProtocol`, no GRDB.** The app has no third-party code at all.
  - `Packages/SyncCore` is an independent implementation of just the protocol subset it needs:
    format-1 framing and CRCs, reassembly, R18 records and history metadata.
  - It's tested against real frames from our own MG's raw archive, including the strap's reply
    to an acknowledgement that walked its cursor.
  - Storage is the system SQLite.
  - The fork's code was read for behaviour, not copied, so its non-commercial licence doesn't
    apply to this repo.
- **Pairing order follows the fork's working iOS code, not §3.** It sends `CLIENT_HELLO` as
  soon as the WHOOP service is discovered, and only subscribes to the WHOOP channels after the
  bond: the strap rejects those subscriptions before it.
  - Before the bond, the hello is the only write, so any successful write completion on the
    command characteristic counts as the bond. That includes one arriving after the 30 s
    timeout, since the user may still be answering iOS's pairing prompt.
- **Handshake is `SET_CLOCK` (10) + `GET_CLOCK` (11), then `SEND_HISTORICAL_DATA` (22).** The
  fork's working MG path drops `GET_HELLO` (145) and `GET_DATA_RANGE` (34): its 5/MG send
  allowlist excludes them. So §10 steps 1 and 4 aren't sent.
- **No per-connection RR unit check.** Milliseconds and 1/1024 s differ by only 2.4%, which a
  comparison against bpm can't tell apart, so RR is taken as milliseconds (the fork's finding)
  on both live and history.
- **Download cadence rides the live stream.** Each `2A37` notification checks whether 15 minutes
  have passed. Those notifications are what keep waking the app in the background.
- **More than heart rate and HRV.** At the owner's request the app also writes steps, sleep
  (asleep/awake), resting heart rate, breathing rate and blood oxygen. §1 had these as optional or
  out of scope.
  - Sleep comes from movement plus heart rate, not the band's sleep flag.
  - Breathing rate is estimated from RR intervals.
  - Blood oxygen comes from R18 byte 82, the strap's own reading.

  Sources, status and the SpO2 plan are in `PROGRESS.md`.
