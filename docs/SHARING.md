# Sharing data with other apps

Apple Health has no type for what the strap measures beyond heart rate and SDNN: skin temperature,
RMSSD and ECG recordings. Strap Sync shares them two ways:

- **[Through Apple Health](#through-apple-health):** as metadata on the heart-rate and HRV samples it
  already writes. Any app the user lets read those types gets them, whichever team signed it, with no
  setup.
- **Through a keychain group** (below), for Health Dashboard, signed by the same team.

Strap Sync publishes what Apple Health can't hold into a keychain group that Health Dashboard (now
Wellmaxx) also reads. Both apps are signed by the same team (`<TEAM_ID>`). The free
Apple ID can't sign App Groups (tested 2026-10-28: Xcode refuses), but every development profile allows
`<TEAM_ID>.*` keychain groups, so a shared keychain group works.

## Keychain items

| Attribute | Value |
|---|---|
| `kSecClass` | `kSecClassGenericPassword` |
| `kSecAttrAccessGroup` | `<TEAM_ID>.com.richarddraycott.healthshare` |
| `kSecAttrService` | `whoop-sync` |
| `kSecAttrAccount` | `skin-temperature`, `hrv`, or `ecg.<start unix seconds>` per ECG |
| `kSecAttrAccessible` | `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, so background refreshes can read it |
| `kSecAttrSynchronizable` | not set (never iCloud) |
| `kSecValueData` | UTF-8 JSON, below |

### Entitlement setup

Each app lists its **own** group first, then the shared one:

```yaml
keychain-access-groups:
  - $(AppIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)
  - $(AppIdentifierPrefix)com.richarddraycott.healthshare
```

The first entry is where an add without `kSecAttrAccessGroup` lands, so each app's private items
(API keys and so on) stay private. Each app also carries the full group name in Info.plist as
`SharedKeychainGroup = $(AppIdentifierPrefix)com.richarddraycott.healthshare` and reads it at
runtime, rather than hardcoding the team ID.

### Ownership and retention

- Strap Sync is the only writer. It keeps 7 days:
  - It rewrites `skin-temperature` and `hrv` whenever their content changes.
  - It adds one `ecg.*` item per recording, and deletes those older than 7 days.
- Health Dashboard only reads, and copies what it finds into its own database. It never writes or
  deletes these items.
- Readers must ignore an unknown `version` and fields they don't know.

## `skin-temperature`

```json
{
  "version": 1,
  "updated": 1793200000,
  "device": "WHOOP MG",
  "intervalSeconds": 600,
  "samples": [[1793190000, 33.12], [1793190600, 33.08]]
}
```

- `samples`: `[start, celsius]` pairs, oldest first. Each is the mean skin temperature over the
  worn minutes in `[start, start + intervalSeconds)`. Times are unix seconds (UTC).
- Intervals with fewer than 5 worn minutes are left out.
- The values are wrist skin temperature, about 31–35 °C while worn: cooler than core temperature,
  and a different sensor from Apple Watch's sleeping wrist temperature. Compare them with their own
  baseline, not with an absolute range.
- A sample's identity is its `start`, so re-reading the item must not duplicate it.
- A sample's value can change between rewrites while its interval is still filling in (more worn
  minutes arrive with each history download), so readers keep the latest value.
- Samples only leave the item by ageing past 7 days. A reader that has already copied one can
  keep it.
- Required: `version`, `intervalSeconds` and `samples`. Times carry no time zone; they're UTC
  instants.

## `hrv`

Each clock hour's HRV, as both RMSSD and SDNN, from the same 5-minute window. Apple Health has no
RMSSD type, so this is the only place RMSSD goes. SDNN also goes to Health as
`heartRateVariabilitySDNN`, one sample per hour, from the same window.

```json
{
  "version": 1,
  "updated": 1793200000,
  "device": "WHOOP MG",
  "windowSeconds": 300,
  "samples": [[1793190900, 1793191200, 38.1, 41.9], [1793194500, 1793194800, null, 44.0]]
}
```

- `samples`: `[start, end, rmssd, sdnn]` in ms, oldest first, one per hour at most. Times are unix
  seconds (UTC); `end` is `start + windowSeconds`.
- **The window:** among the hour's 5-minute windows (clock-aligned) with at least 240 s of clean
  beats, the steady one with the lowest mean heart rate. This is a rough stand-in for "at rest".
  - Steady: the mean heart rate of each minute stays within 5 bpm. When no window in the hour is
    steady, the one with the lowest mean heart rate.
  - Since 8 Nov 2026. An hour's window, and so its `start`, can change from what was shared before.
- **Clean beats:** 300–2000 ms, and within 20% of the previous kept beat.
- `sdnn`: the standard deviation of the window's clean intervals after smoothness-priors detrending
  (λ = 500), so a drift or step in heart rate doesn't count. Until 8 Nov 2026 it was the raw
  standard deviation, which ran 5–13% higher on ordinary nights.
- `rmssd`: the root mean square of differences between successive clean intervals.
  - A pair counts only when the two beats were neighbours in the recording. A rejected beat, or a
    gap in the records longer than the interval itself, breaks the pair.
  - It's `null` when under half the window's beats have a pair.
- A sample's identity is its `start`. Its values can change while more of the hour's beats
  download, so readers keep the latest values. Readers that keep samples should also drop their
  copies that the item no longer has within its span, since an hour's window can move.
- Readers that also read Health's SDNN from Strap Sync should take only one of the two, or they'll
  count each hour twice. Health Dashboard reads RMSSD from here and SDNN from Health.
- Required: `version` and `samples`. Hours since 29 Oct 2026 are filled in from stored beats (up to 7
  days back).

## `ecg.<start>`

One on-demand ECG from the MG: the wearer holds the clasp for about 40 s.

```json
{
  "version": 1,
  "id": "ecg.1793190000",
  "device": "WHOOP MG",
  "start": 1793190000,
  "end": 1793190041,
  "wrist": "left",
  "heartRate": 62,
  "hrvRaw": 41,
  "progress": 100,
  "quality": 3,
  "classifier": 0,
  "sampleRateHz": 102.6,
  "amplitudeUnit": "raw",
  "samples": [12, 15, 9, -3]
}
```

| Field | Meaning |
|---|---|
| `start`, `end` | Unix seconds, phone clock, from the first to the last waveform record. |
| `wrist` | `"left"` or `"right"`, as selected for the recording. |
| `heartRate` | bpm. The strap's own value (byte 27) when it gives one. A real MG left it at 0 for a whole recording, so it's otherwise counted from the trace's heartbeats over the last 30 s. May be `null` if neither works. |
| `heartRateSource` | `"strap"`, `"ecg"` (counted from the trace and within 15 % of the wrist heart rate), or `"optical"` (mean wrist heart rate during the recording). `null` with `heartRate`. |
| `hrvRaw` | Bytes 29–30 (u16) of the last record that had one. HRV-related, **units unresolved** upstream: show it as a raw number or not at all. May be `null`. |
| `progress` | Last progress byte (0–100). Only complete recordings (100) are shared. |
| `quality` | Last signal-quality code; 0–3 observed, meaning unresolved. |
| `classifier` | Byte 23 raw code. **No established meaning: never present it as a rhythm result.** |
| `samples` | The filtered (R17) waveform: signed integers in order, uncalibrated amplitude. |
| `sampleRateHz` | Estimated as the sample count over the time between the first and last record (an estimate, not a device constant). `null` if under 2 s of data. |
| `amplitudeUnit` | Always `"raw"` for now: the voltage scale isn't known. |

Required: `version`, `start`, `end` and `samples`; every other field may be missing or `null`.
An item is written once, when the recording completes, and may be rewritten only to fill in a
missing `heartRate`.

There's no rhythm classification (AFib etc.): that's WHOOP's own algorithm. Show the trace, the
heart rate and the time, and say plainly that it's uncalibrated and not a diagnosis.

## Reading, in Swift

```swift
let query: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrAccessGroup as String: group,      // Info.plist SharedKeychainGroup
    kSecAttrService as String: "whoop-sync",
    kSecMatchLimit as String: kSecMatchLimitAll,
    kSecReturnAttributes as String: true,
    kSecReturnData as String: true,
]
var result: CFTypeRef?
let status = SecItemCopyMatching(query as CFDictionary, &result)
// errSecItemNotFound: nothing shared yet. Otherwise an array of dictionaries:
// kSecAttrAccount names the item, kSecValueData holds the JSON.
```

## Through Apple Health

Since 13 Nov 2026, Strap Sync's heart-rate and HRV samples in Apple Health carry custom metadata:
skin temperature, RMSSD and ECG recordings. An app needs only permission to read heart rate
(and HRV, for RMSSD). It needs no keychain group, no App Group and no particular team.

### Where it is

| Health type | Samples | Sync identifier (`HKMetadataKeySyncIdentifier`) |
|---|---|---|
| `heartRate` | One per minute with at least 10 readings, from the minute's start to its end | `whoopsync:hr:<minute start>` |
| `heartRate` | An ECG's own, when its start minute has no sample: from the recording's start to its end | `whoopsync:ecg:<recording start>` |
| `heartRateVariabilitySDNN` | At most one per clock hour, over its 5-minute window | `whoopsync:hrv:<hour start>` |

The times are unix seconds. The source is Strap Sync, but its bundle ID is whatever the person who
built it chose, so find the samples by these keys or by the `whoopsync:` prefix, not by bundle ID.
The device is the strap (`HKDevice` manufacturer `WHOOP`, name e.g. `WHOOP MG`).

### Keys

| Key | Type | On | Value |
|---|---|---|---|
| `StrapSyncSkinTemperature` | NSNumber, °C | heart rate | The mean wrist skin temperature of the 10-minute interval the sample's minute lies in, to 0.01 °C |
| `StrapSyncSkinTemperatureStart` | NSDate | heart rate | That interval's start |
| `StrapSyncSkinTemperatureSeconds` | NSNumber, s | heart rate | The interval's length: 600 |
| `StrapSyncRMSSD` | NSNumber, ms | HRV | The RMSSD of the sample's own 5-minute window, to 0.1 ms |
| `StrapSyncECG` | NSString | heart rate | An ECG recording's waveform, base64 (below) |
| `StrapSyncECGStart` | NSDate | heart rate | The recording's start |
| `StrapSyncECGSampleRate` | NSNumber, Hz | heart rate | The recording's estimated sample rate, to 0.1 Hz. Missing when it couldn't be estimated |
| `StrapSyncECGHeartRate` | NSNumber, bpm | heart rate | The recording's heart rate. Missing when it has none |

- **Skin temperature:** every heart-rate sample whose minute lies in an interval with a value carries
  that interval, so up to ten samples carry the same one.
  - The intervals and the rule are those of the keychain's `skin-temperature` item: the mean over the
    interval's worn minutes, when at least 5 were worn. The same caveats apply: it's wrist skin,
    about 31–35 °C, so compare it with its own baseline.
  - Intervals start at unix seconds divisible by 600.
  - An interval in which no minute has a heart-rate sample isn't carried. An ECG's own sample
    carries the interval its start lies in, like any other.
- **RMSSD:** the value the keychain's `hrv` item has for the same hour (`rmssd`). The window, how it's
  chosen and the clean-beat rules are described there. The key is missing where that item has
  `null`: under half the window's beats have a pair.
- **ECG:** every complete recording is on a heart-rate sample. Find ECGs as the heart-rate samples
  that carry `StrapSyncECG`, from any sync identifier, and dedupe by `StrapSyncECGStart`.
  - Usually it's the sample of the minute the recording started in.
  - The MG's heart rate stays 0 during an ECG, so that minute often has no sample. The recording then
    gets a heart-rate sample of its own, `whoopsync:ecg:<start>`. It runs from the recording's start to
    its end, and its value is the recording's heart rate (`StrapSyncECGHeartRate`).
  - A recording keeps its own sample once it has one, even if its minute gets a sample later.
  - A recording with no heart-rate sample in its minute and no heart rate yet waits until it has one.
  - `StrapSyncECG` is the keychain `ecg` item's `samples` (the filtered waveform, uncalibrated), each
    a signed 16-bit little-endian integer, the strap's own format, then base64. A 41 s recording is
    about 11 KB.
  - The item's other fields (`end`, `wrist`, `quality`, `classifier`, `hrvRaw`) aren't carried.
  - As with the keychain item: there's no rhythm classification. Show it as uncalibrated, not a
    diagnosis.
- **Since when:** samples written before 13 Nov 2026 were rewritten once with their metadata. That
  covers the days the phone still had: 8 days of skin temperature, and 14 of RMSSD and ECGs. Older
  samples carry none.

### Time zone

Every sample Strap Sync writes, of every type, carries `HKMetadataKeyTimeZone`: the zone the phone was in
when the data was recorded, at the sample's start, from the app's own zone history. It isn't the zone the
phone has when the sample is written, so a night written again days later, after a change of zone, keeps the
zone it was slept in.

- The value is a TimeZone identifier: usually the phone's own zone (e.g. `Europe/Paris`), else a fixed offset
  such as `GMT-0800`. Read it with `TimeZone(identifier:)`, and take the offset at the sample's own time.
- The app records the phone's zone at launch, at each history download and when iOS says it changed, so a
  sample recorded in the minutes before a change was noticed can carry the zone before it.
- **Samples with no zone:** where the zone isn't known, the key is missing rather than wrong: data recorded
  before the app kept a history and that its logs don't cover.
- **Since when:** 14 Nov 2026. Before, each sample carried the phone's zone when it was written, which was
  wrong for data written again after a change of zone (a restaged night, a version bump, the metadata
  backfill). Samples of the 16 days before that Health had with the wrong zone were written again once, in
  place (same sync identifier, one sync version up), with the zone they were recorded in. A night Health had
  lost (deleted by a bug fixed the same day) was written again from what the app still had. Nothing else was
  added or removed. The zones of those days were reconstructed from the app's logs, as fixed offsets unless
  the phone was in the zone it has now, or taken from the owner's own record of them where there was one.

### Changes and duplicates

- **A value can change after its sample is first written:** an interval still filling in, an hour's
  beats still downloading, an ECG's heart rate found later. Strap Sync then writes the sample again,
  with the same sync identifier and a higher `HKMetadataKeySyncVersion`, and Health replaces it.
  - The new sample has a new UUID, so an anchored query sees the old one deleted and the new one
    added.
  - Keep each value by its own identity, and keep the latest: skin temperature by
    `StrapSyncSkinTemperatureStart`, RMSSD by the HRV sample's sync identifier (the hour; its window
    can move within the hour), ECG by `StrapSyncECGStart`.
- **Dedupe skin temperature by interval:** take one value per `StrapSyncSkinTemperatureStart`, not
  one per sample, or an interval counts up to ten times.
- **Don't count anything twice:** an app that also reads the keychain items should take each value
  from one place.
- **Types:** numbers come back as doubles, even 600 (seen in the Simulator), so read `doubleValue`.
  Dates are `NSDate`, which are UTC instants.
- **Unknown keys:** readers must ignore keys they don't know. More may be added.
- **Privacy:** the metadata goes wherever the samples go: to every app allowed to read heart rate or
  HRV, to Health's iCloud sync, and into a Health export.
- **Size:** in the iOS 18.6 Simulator (13 Nov 2026), metadata strings from 11 KB to 4 MB on a
  heart-rate sample saved and read back intact, also after a reboot. Not yet seen on a phone.

### Reading, in Swift

```swift
let health = HKHealthStore()
let heartRate = HKQuantityType(.heartRate)
try await health.requestAuthorization(toShare: [], read: [heartRate, HKQuantityType(.heartRateVariabilitySDNN)])
let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
    HKQuery.predicateForSamples(withStart: from, end: to),
    HKQuery.predicateForObjects(withMetadataKey: "StrapSyncSkinTemperature"),
])
let query = HKSampleQueryDescriptor(predicates: [.quantitySample(type: heartRate, predicate: predicate)],
                                    sortDescriptors: [SortDescriptor(\.startDate)])
var skin: [Date: Double] = [:]  // interval start → °C
for sample in try await query.result(for: health) {
    guard let m = sample.metadata, let start = m["StrapSyncSkinTemperatureStart"] as? Date,
          let celsius = (m["StrapSyncSkinTemperature"] as? NSNumber)?.doubleValue else { continue }
    skin[start] = celsius
}
// An ECG: HKQuery.predicateForObjects(withMetadataKey: "StrapSyncECG"), then
// let data = Data(base64Encoded: m["StrapSyncECG"] as! String)!
// let waveform = stride(from: 0, to: data.count - 1, by: 2).map {
//     Int(Int16(bitPattern: UInt16(data[$0]) | UInt16(data[$0 + 1]) << 8))
// }
```
