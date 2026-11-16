# Development

Notes for building, installing and debugging Strap Sync on your own iPhone. The basics (XcodeGen,
`Config/Local.xcconfig`, the first run) are in the [README](../README.md).

## Scripts

```sh
scripts/install-app.sh              # build a Debug build and install it on the iPhone (USB or RoamRun)
scripts/install-app.sh --pull       # copy the app's logs to secrets/logs/
scripts/install-app.sh --pull-raw   # copy the raw strap archive to secrets/raw/
cd Packages/SyncCore && swift test  # protocol, aggregation and sleep-stage tests
STRAPSYNC_DRYRUN_DIR=<copied logs> swift test --filter ZoneDryRunTests  # (in Packages/SyncCore) time zones from the logs, writes nothing
STRAPSYNC_DRYRUN_DB=<copied sync.sqlite> swift test --filter NightDryRunTests  # (in Packages/SyncCore) the nights a copy of the phone's database gives, locked and unlocked; writes nothing
scripts/zone-check.sh               # the zone redo against Apple Health, in a new Simulator (deleted afterwards)
scripts/testflight.sh               # archive a Release build and upload it to TestFlight
```

Both scripts read the team and bundle ID from `Config/Local.xcconfig`. `secrets/` is git-ignored. Copying the
database off the phone, and the raw archive's format, are in
[`PROGRESS.md`](PROGRESS.md#pulling-data-off-the-phone).

## TestFlight

TestFlight builds last 90 days and install from the TestFlight app anywhere, with no Mac nearby.
`scripts/testflight.sh` uploads with the Apple ID signed in to Xcode, to the app's App Store Connect
record for `APP_BUNDLE_ID`, and the build number is the UTC date and time. App Store Connect takes
only iOS 26 SDK builds, so it uses the side-by-side `/Applications/Xcode-26.3.0.app` when there is one;
`/Applications/Xcode.app` stays the default for everything else. `App/WhoopSync/PrivacyInfo.xcprivacy`
lists the required-reason APIs the app uses; an upload that uses one it doesn't list is rejected.

A TestFlight build isn't development-signed: if `--pull` can't reach its files, install a development
build with `scripts/install-app.sh` (it replaces the TestFlight one and keeps the app's data), or share
them from the Files app (On My iPhone → Strap Sync).

## The Simulator and demo data

The Simulator has no Bluetooth, so on its own the app shows no strap. A Debug build launched in the
Simulator with `-demo YES` plays a paired strap's events over made-up data instead: a night with sleep
stages, two ECGs and a day of samples in the outbox, which go to the Simulator's Apple Health once you tap
Connect Apple Health. The code is `App/WhoopSync/Support/Demo.swift`; it's compiled into Debug builds only
and does nothing outside the Simulator.

```sh
xcodegen generate
xcodebuild -project WhoopSync.xcodeproj -scheme WhoopSync -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/DerivedData build
xcrun simctl install booted build/DerivedData/Build/Products/Debug-iphonesimulator/WhoopSync.app
xcrun simctl launch booted dev.local.WhoopSync -demo YES
```

In Xcode, add `-demo YES` under the scheme's Run → Arguments. `dev.local.WhoopSync` is the default bundle ID
from `Config/Base.xcconfig`; use your own if `Config/Local.xcconfig` sets one.

The README's screenshots come from this mode on an iPhone 17 Pro Simulator (iOS 26.3), with the status bar
overridden (`xcrun simctl status_bar <device> override --time 9:41 …`), taken with
`xcrun simctl io <device> screenshot` and halved to 603 px wide.

## A build's own sources and sleep model

A build can add Swift sources to the app target and bundle its own sleep model without changing anything
here. Without them, the app compiles and runs exactly as this repo has it.

- **Sources:** set the `PERSONAL` compilation condition (`SWIFT_ACTIVE_COMPILATION_CONDITIONS =
  $(inherited) PERSONAL`) and add sources that define `PersonalHooks`. These are the only calls to it, each
  under `#if PERSONAL`:

  | Hook | Called from | When |
  |---|---|---|
  | `static func didLaunch(_ model: AppModel)` | `AppModel.init` | Once, with the store open, before the first sync |
  | `static func didFlush(_ model: AppModel) async` | `AppModel.flush()` | After each write to Apple Health: on open, after downloads, in background refreshes |
  | `static func section(_ model: AppModel) -> some View` | `ContentView` | A `Section` after ECG, while a strap is chosen |

  The sources can use the app's own types; `AppModel.store` and `Store.db` aren't private for them. They
  create any tables they need themselves (`CREATE TABLE IF NOT EXISTS`) and never change the store's own,
  so any build can open a database another build wrote.
- **Sleep model:** a `PersonalSleepModel` folder in the app bundle, laid out like
  `Packages/SyncCore/Sources/SyncCore/Resources/SleepModel` (all five files), is used in place of SyncCore's,
  and the log says which version loaded. Give it a `version` later than any model the phone has used: a new
  version restages the nights still stored, and Health's sync versions must keep growing.

An XcodeGen spec can `include` this repo's `project.yml` and add the sources, the folder (as a folder
resource) and the setting.

## Correcting the past time zones

Samples are stamped with the zone the phone was in when they were recorded (SPEC §4, "Dedup"). For the time
before the app kept its own record, the zones are reconstructed from its logs, which go by the phone's own
zone; that can be wrong for days. To say what was right, put a `time-zones.json` in the app's Documents
folder (Files app → On My iPhone → Strap Sync):

```json
{
  "zones": [
    {"since": "2030-01-01T00:00:00Z", "zone": "Europe/Paris"},
    {"since": "2030-01-09T18:30:00Z", "zone": "America/Chicago"}
  ],
  "until": "2030-01-20T00:00:00Z"
}
```

- Each zone holds from its `since` until the next one's, the last until `until`. Dates are ISO 8601 with a zone
  (`Z`, or an offset such as `+01:00`); zones are IANA place names (`Europe/Paris`, not `CET`, `GMT+1` or
  `Etc/GMT-1`), or `UTC`.
- The file covers the first `since` up to `until`. There it replaces what the logs say; elsewhere the logs
  still count. From the app's own first recorded zone on, the app's record wins and the file is ignored.
- It's read at each launch, strictly: bad JSON, another key, an unknown zone, dates out of order or an
  `until` before the last `since`, and the whole file is ignored. The log says which (`Time zones:
  time-zones.json …`), and logs the history in effect with each stretch's source (file, logs or recorded).
- The one-time rewrite of Health's samples (`zoneRedo1`) waits until the file, if there is one, has been read.
  A later change to the file affects only samples written after it.
- The dry run reads the same file from its folder (`STRAPSYNC_DRYRUN_DIR/time-zones.json`).

