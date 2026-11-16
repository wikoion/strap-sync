import XCTest
@testable import SyncCore

/// Strap Sync's own metadata on Health samples (docs/SHARING.md, "Through Apple Health"), and the outbox's
/// rule for rewriting a sample when only its metadata changes. All values are made up.
final class HealthMetadataTests: XCTestCase {
    let hour = 1_780_912_800  // a whole hour

    /// The outbox as the app keeps it, one row per sync identifier, planned as `Store.plan` does.
    struct TestOutbox {
        var rows: [String: Outbox.Row] = [:]

        /// What goes (back) to Health, with the version Health is given.
        mutating func plan(_ samples: [PlannedSample]) -> [PlannedSample] {
            samples.compactMap { s in
                guard let row = Outbox.merge(s, over: rows[s.syncId]) else { return nil }
                rows[s.syncId] = row
                return row.forHealth
            }
        }
    }

    func minute(_ m: Int, skin: Double?, worn: Int = 60) -> MinuteSummary {
        MinuteSummary(minute: m, records: 60, worn: worn, meanHR: worn > 0 ? 60 : nil, motion: 0.01, sleepFlag: 0, skinTempC: skin)
    }

    func heartRate(_ minute: Int, bpm: Double = 60, version: Int = 100_060) -> PlannedSample {
        PlannedSample(kind: .heartRate, syncId: "whoopsync:hr:\(minute)", start: minute, end: minute + 60, value: bpm, version: version)
    }

    /// One beat per second at `ms` (alternating +/- `jitter`) across a 5-minute window.
    func window(_ start: Int, ms: Int, jitter: Int) -> [RRPoint] {
        var out: [RRPoint] = []
        var t = 0, i = 0
        while t < 300_000 {
            let v = ms + (i % 2 == 0 ? jitter : -jitter)
            out.append(RRPoint(ts: start + t / 1000, idx: i, ms: v))
            t += v
            i += 1
        }
        return out
    }

    // MARK: Which samples get which metadata

    func testSkinIntervalsAreTheKeychainsTenMinuteMeans() {
        // 5 worn minutes with a reading in the first interval; in the second only 4, plus one off the wrist and
        // one with no reading, so it has no value.
        let first = (0..<5).map { minute(hour + $0 * 60, skin: 33.0 + Double($0) * 0.01) }
        let second = (10..<14).map { minute(hour + $0 * 60, skin: 34) }
            + [minute(hour + 14 * 60, skin: 34, worn: 0), minute(hour + 15 * 60, skin: nil)]
        XCTAssertEqual(SkinTemperature.intervals(first + second), [SkinTemperature.Interval(start: hour, celsius: 33.02)])
    }

    func testHeartRateSamplesCarryTheirIntervalsSkinTemperature() {
        let minutes = (0..<10).map { minute(hour + $0 * 60, skin: 33.25) }  // the first interval only
        let samples = [heartRate(hour), heartRate(hour + 540), heartRate(hour + 600)]
        let out = HealthMetadata.withSkinTemperature(samples, SkinTemperature.intervals(minutes))
        for s in out.prefix(2) {
            XCTAssertEqual(s.metadata, [
                "StrapSyncSkinTemperature": .number(33.25),
                "StrapSyncSkinTemperatureStart": .date(hour),
                "StrapSyncSkinTemperatureSeconds": .number(600),
            ])
        }
        // Its interval has no value, so nothing; the sample itself is unchanged.
        XCTAssertEqual(out[2], samples[2])
    }

    func testOnlyHeartRateCarriesSkinTemperature() {
        let minutes = (0..<10).map { minute(hour + $0 * 60, skin: 33.25) }
        let steps = PlannedSample(kind: .steps, syncId: "whoopsync:steps:\(hour)", start: hour, end: hour + 60, value: 20, version: 30)
        XCTAssertEqual(HealthMetadata.withSkinTemperature([steps], SkinTemperature.intervals(minutes)), [steps])
    }

    func testHRVSamplesCarryTheirWindowsRMSSD() {
        let hours = Aggregator.hourlyWindows(live: window(hour, ms: 1000, jitter: 50), history: [], now: hour + 3600)
        let sample = Aggregator.hrvSamples(hours)[0]
        // The same RMSSD the `hrv` table, and so the keychain item, has for the hour.
        XCTAssertEqual(sample.metadata, ["StrapSyncRMSSD": .number(hours[0].rmssd!)])
        XCTAssertEqual(Aggregator.hourlyHRV(live: window(hour, ms: 1000, jitter: 50), history: [], now: hour + 3600), [sample])
        let noRmssd = Aggregator.HourlyHRV(hour: hour, start: hour, sdnn: 40, rmssd: nil, version: 1_100_300)
        XCTAssertEqual(Aggregator.hrvSamples([noRmssd])[0].metadata, [:])
    }

    func testAnEcgRidesOnTheMinuteItStartedIn() {
        let trace = [0, 12, -3, 900, -32_768, 32_767, 40_000]
        let ecg = HealthMetadata.Recording(start: hour + 125, end: hour + 166, sampleRateHz: 102.63, heartRate: 62, samples: trace)
        let out = HealthMetadata.withEcgs([heartRate(hour + 60), heartRate(hour + 120), heartRate(hour + 180)], [ecg])
        XCTAssertEqual(out.count, 3)  // no sample of its own
        XCTAssertEqual(out[0].metadata, [:])
        XCTAssertEqual(out[2].metadata, [:])
        let m = out[1].metadata
        XCTAssertEqual(m["StrapSyncECGStart"], .date(hour + 125))
        XCTAssertEqual(m["StrapSyncECGSampleRate"], .number(102.6))
        XCTAssertEqual(m["StrapSyncECGHeartRate"], .number(62))
        guard case .text(let base64)? = m["StrapSyncECG"] else { return XCTFail("no waveform") }
        // Two bytes a sample, little-endian; beyond 16 bits is clamped (the strap's samples never are).
        XCTAssertEqual(Data(base64Encoded: base64)!.prefix(4), Data([0, 0, 12, 0]))
        XCTAssertEqual(HealthMetadata.samples(fromWaveform: base64), [0, 12, -3, 900, -32_768, 32_767, 32_767])
    }

    func ecg(_ start: Int, heartRate: Int?) -> HealthMetadata.Recording {
        HealthMetadata.Recording(start: start, end: start + 41, sampleRateHz: 98.4, heartRate: heartRate, samples: [5, -5, 9])
    }

    func testAnEcgWhoseMinuteHasNoHeartRateGetsASampleOfItsOwn() {
        // The MG's heart rate stays 0 during an ECG: no sample for the minute it started in.
        let out = HealthMetadata.withEcgs([heartRate(hour), heartRate(hour + 180)], [ecg(hour + 75, heartRate: 63)])
        XCTAssertEqual(out.count, 3)
        XCTAssertEqual(out[0].metadata, [:])
        XCTAssertEqual(out[1].metadata, [:])
        let own = out[2]
        XCTAssertEqual(own.kind, .heartRate)
        XCTAssertEqual(own.syncId, "whoopsync:ecg:\(hour + 75)")
        XCTAssertEqual([own.start, own.end], [hour + 75, hour + 116])
        XCTAssertEqual(own.value, 63)
        XCTAssertEqual(own.version, 1)
        XCTAssertEqual(own.metadata["StrapSyncECGStart"], .date(hour + 75))
        XCTAssertEqual(own.metadata["StrapSyncECGHeartRate"], .number(63))
        XCTAssertEqual(own.metadata["StrapSyncECG"], .text(HealthMetadata.waveform([5, -5, 9])))
        // Its start minute lies in an interval with a value, so it carries skin temperature like any other.
        let skin = HealthMetadata.withSkinTemperature(out, [SkinTemperature.Interval(start: hour, celsius: 33.2)])
        XCTAssertEqual(skin[2].metadata["StrapSyncSkinTemperature"], .number(33.2))
    }

    func testAnEcgWithNoHeartRateYetWaitsThenGoesOut() {
        var outbox = TestOutbox()
        // No minute's sample and no heart rate: nothing to write it on yet.
        XCTAssertEqual(outbox.plan(HealthMetadata.withEcgs([], [ecg(hour + 75, heartRate: nil)])), [])
        // The heart rate is found (counted from the trace at the next launch), and its hour is planned again.
        let first = outbox.plan(HealthMetadata.withEcgs([], [ecg(hour + 75, heartRate: 63)]))
        XCTAssertEqual(first.map(\.syncId), ["whoopsync:ecg:\(hour + 75)"])
        XCTAssertEqual(first.map(\.version), [1])
        // Planned again unchanged: nothing.
        XCTAssertEqual(outbox.plan(HealthMetadata.withEcgs([], [ecg(hour + 75, heartRate: 63)], carried: [hour + 75])), [])
        // Its heart rate changes: the same sample, rewritten one version up, so Health replaces it.
        let again = outbox.plan(HealthMetadata.withEcgs([], [ecg(hour + 75, heartRate: 64)], carried: [hour + 75]))
        XCTAssertEqual(again.map(\.syncId), ["whoopsync:ecg:\(hour + 75)"])
        XCTAssertEqual(again.map(\.version), [2])
        XCTAssertEqual(again.map(\.value), [64])
        XCTAssertEqual(outbox.rows.count, 1)
    }

    func testAnEcgKeepsItsOwnSampleWhenItsMinuteGetsOneLater() {
        // History for the minute arrives after the ECG went out on a sample of its own: it isn't carried twice.
        let out = HealthMetadata.withEcgs([heartRate(hour + 60)], [ecg(hour + 75, heartRate: 63)], carried: [hour + 75])
        XCTAssertEqual(out.map(\.syncId), ["whoopsync:hr:\(hour + 60)", "whoopsync:ecg:\(hour + 75)"])
        XCTAssertEqual(out[0].metadata, [:])
        // The same from the outbox, as the backfill reads it: its own sample is among the samples.
        let stored = [heartRate(hour + 60), out[1]]
        XCTAssertEqual(HealthMetadata.withEcgs(stored, [ecg(hour + 75, heartRate: 63)]), stored)
    }

    func testTwoEcgsInOneMinuteBothReachHealth() {
        let out = HealthMetadata.withEcgs([heartRate(hour)], [ecg(hour + 5, heartRate: 60), ecg(hour + 50, heartRate: 61)])
        // The later rides on the minute's sample, the earlier on one of its own.
        XCTAssertEqual(out[0].metadata["StrapSyncECGStart"], .date(hour + 50))
        XCTAssertEqual(out.map(\.syncId), ["whoopsync:hr:\(hour)", "whoopsync:ecg:\(hour + 5)"])
    }

    func testAnEcgWithoutRateOrHeartRateLeavesThoseKeysOut() {
        let ecg = HealthMetadata.Recording(start: hour, end: hour + 40, sampleRateHz: nil, heartRate: nil, samples: [1, 2])
        XCTAssertEqual(Set(HealthMetadata.withEcgs([heartRate(hour)], [ecg])[0].metadata.keys), ["StrapSyncECG", "StrapSyncECGStart"])
    }

    func testEachKindOfMetadataKeepsTheOthers() {
        let ecg = HealthMetadata.Recording(start: hour + 30, end: hour + 71, sampleRateHz: 100, heartRate: 60, samples: [1])
        let minutes = (0..<10).map { minute(hour + $0 * 60, skin: 33) }
        let both = HealthMetadata.withSkinTemperature(HealthMetadata.withEcgs([heartRate(hour)], [ecg]), SkinTemperature.intervals(minutes))[0]
        XCTAssertEqual(both.metadata.count, 7)
        // A new value for the interval replaces the old one and keeps the ECG.
        let warmer = HealthMetadata.withSkinTemperature([both], [SkinTemperature.Interval(start: hour, celsius: 33.5)])[0]
        XCTAssertEqual(warmer.metadata.count, 7)
        XCTAssertEqual(warmer.metadata["StrapSyncSkinTemperature"], .number(33.5))
        XCTAssertEqual(warmer.metadata["StrapSyncECGHeartRate"], .number(60))
        // With its minutes no longer stored (no intervals), a sample read back from the outbox keeps what it has.
        XCTAssertEqual(HealthMetadata.withSkinTemperature([both], []), [both])
        XCTAssertEqual(HealthMetadata.withEcgs([both], []), [both])
    }

    func testKeysAreStrapSyncsOwn() {
        let keys = [HealthMetadata.skinTemperature, HealthMetadata.skinTemperatureStart, HealthMetadata.skinTemperatureSeconds,
                    HealthMetadata.rmssd, HealthMetadata.ecg, HealthMetadata.ecgStart, HealthMetadata.ecgSampleRate,
                    HealthMetadata.ecgHeartRate]
        for key in keys {
            XCTAssertTrue(key.hasPrefix("StrapSync"))
            XCTAssertFalse(key.hasPrefix("HK"))  // Apple's prefix
        }
    }

    func testMetadataSurvivesTheOutboxColumn() {
        let m: [String: MetadataValue] = ["a": .number(33.12), "b": .date(hour), "c": .text("AAEC/w==")]
        XCTAssertEqual(HealthMetadata.decode(HealthMetadata.encode(m)), m)
        XCTAssertNil(HealthMetadata.encode([:]))
        XCTAssertEqual(HealthMetadata.decode(nil), [:])
    }

    // MARK: Rewrites

    func testWithoutMetadataTheOutboxBehavesAsBefore() {
        var outbox = TestOutbox()
        XCTAssertEqual(outbox.plan([heartRate(hour, version: 30)]).map(\.version), [30])
        XCTAssertEqual(outbox.plan([heartRate(hour, version: 30)]), [])  // sending it again changes nothing
        XCTAssertEqual(outbox.plan([heartRate(hour, version: 20)]), [])  // less data never replaces more
        XCTAssertEqual(outbox.plan([heartRate(hour, bpm: 61, version: 100_045)]).map(\.version), [100_045])
    }

    func testAnIntervalFillingInRewritesItsSamplesWithHigherVersions() {
        var outbox = TestOutbox()
        let samples = [heartRate(hour), heartRate(hour + 60), heartRate(hour + 600)]
        // Five minutes of the first interval have downloaded so far, and the second interval is complete.
        let early = (0..<5).map { minute(hour + $0 * 60, skin: 33.0) } + (10..<20).map { minute(hour + $0 * 60, skin: 34.0) }
        let first = outbox.plan(HealthMetadata.withSkinTemperature(samples, SkinTemperature.intervals(early)))
        XCTAssertEqual(first.map(\.version), [100_060, 100_060, 100_060])
        // The rest of the first interval arrives, warmer. The heart-rate data hasn't changed.
        let late = early + (5..<10).map { minute(hour + $0 * 60, skin: 33.5) }
        let again = outbox.plan(HealthMetadata.withSkinTemperature(samples, SkinTemperature.intervals(late)))
        XCTAssertEqual(again.map(\.syncId), ["whoopsync:hr:\(hour)", "whoopsync:hr:\(hour + 60)"])
        XCTAssertEqual(again.map(\.version), [100_061, 100_061])
        XCTAssertEqual(again[0].metadata["StrapSyncSkinTemperature"], .number(33.25))
        XCTAssertEqual(again[0].value, 60)
    }

    func testMoreDataAfterAMetadataRewriteStillGoesOut() {
        var outbox = TestOutbox()
        let skin = [SkinTemperature.Interval(start: hour, celsius: 33)]
        _ = outbox.plan([heartRate(hour, version: 100_030)])
        XCTAssertEqual(outbox.plan(HealthMetadata.withSkinTemperature([heartRate(hour, version: 100_030)], skin)).map(\.version), [100_031])
        // One more reading: version 100_031 from the data, which Health already has. It must still go out, higher.
        let more = outbox.plan(HealthMetadata.withSkinTemperature([heartRate(hour, bpm: 62, version: 100_031)], skin))
        XCTAssertEqual(more.map(\.version), [100_032])
        XCTAssertEqual(more.map(\.value), [62])
        // And a jump in data goes out at the data's own version again.
        XCTAssertEqual(outbox.plan([heartRate(hour, version: 100_060)]).map(\.version), [100_060])
    }

    func testLessDataIsIgnoredEvenWithOtherMetadata() {
        var outbox = TestOutbox()
        _ = outbox.plan([heartRate(hour, version: 100_060)])
        let skin = [SkinTemperature.Interval(start: hour, celsius: 33)]
        XCTAssertEqual(outbox.plan(HealthMetadata.withSkinTemperature([heartRate(hour, version: 100_020)], skin)), [])
    }

    func testAnRmssdChangeAtTheSameVersionRewritesTheHour() {
        var outbox = TestOutbox()
        let a = Aggregator.HourlyHRV(hour: hour, start: hour + 300, sdnn: 40, rmssd: 35, version: 1_100_300)
        let b = Aggregator.HourlyHRV(hour: hour, start: hour + 300, sdnn: 40, rmssd: 36, version: 1_100_300)
        _ = outbox.plan(Aggregator.hrvSamples([a]))
        let out = outbox.plan(Aggregator.hrvSamples([b]))
        XCTAssertEqual(out.map(\.version), [1_100_301])
        XCTAssertEqual(out.first?.metadata, ["StrapSyncRMSSD": .number(36)])
    }

    // MARK: The backfill (metadataRedo1)

    func testTheBackfillRewritesOnlySamplesThatGainMetadata() {
        // What the outbox held before metadata existed: two intervals' heart rate (the second without enough worn
        // minutes for a value), an ECG's minute, and two hours of HRV, one with RMSSD.
        var outbox = TestOutbox()
        let hr = (0..<20).map { heartRate(hour + $0 * 60) } + [heartRate(hour + 3600 + 120)]
        let hrv = [Aggregator.HourlyHRV(hour: hour, start: hour + 900, sdnn: 41, rmssd: 38.5, version: 1_100_280),
                   Aggregator.HourlyHRV(hour: hour + 3600, start: hour + 3600, sdnn: 44, rmssd: nil, version: 1_100_250)]
        _ = outbox.plan(hr + hrv.map { Aggregator.hrvSamples([$0])[0].with(metadata: [:]) })
        let minutes = (0..<10).map { minute(hour + $0 * 60, skin: 33.4) } + (10..<13).map { minute(hour + $0 * 60, skin: 33.4) }
        let ecg = HealthMetadata.Recording(start: hour + 3600 + 150, end: hour + 3600 + 191, sampleRateHz: 100, heartRate: 58, samples: [3, 4])
        let stored = outbox.rows.values.filter { $0.sample.kind == .heartRate }.map(\.sample).sorted { $0.start < $1.start }

        let rewritten = outbox.plan(HealthMetadata.backfill(heartRate: stored, minutes: minutes, ecgs: [ecg], hrv: hrv))
        XCTAssertEqual(Set(rewritten.map(\.syncId)),
                       Set((0..<10).map { "whoopsync:hr:\(hour + $0 * 60)" } + ["whoopsync:hr:\(hour + 3720)", "whoopsync:hrv:\(hour)"]))
        for s in rewritten {
            // Same data, one version up, so Health replaces each.
            XCTAssertEqual(s.version, (s.kind == .hrv ? 1_100_280 : 100_060) + 1)
        }
        XCTAssertEqual(rewritten.first { $0.kind == .hrv }?.metadata, ["StrapSyncRMSSD": .number(38.5)])
        XCTAssertEqual(rewritten.first { $0.start == hour + 3720 }?.metadata["StrapSyncECGHeartRate"], .number(58))
        // An ECG whose minute has no heart-rate sample gets one of its own.
        let lone = HealthMetadata.Recording(start: hour + 7300, end: hour + 7341, sampleRateHz: 100, heartRate: 70, samples: [1])
        let own = outbox.plan(HealthMetadata.backfill(heartRate: outbox.rows.values.filter { $0.sample.kind == .heartRate }.map(\.sample),
                                                      minutes: minutes, ecgs: [ecg, lone], hrv: hrv))
        XCTAssertEqual(own.map(\.syncId), ["whoopsync:ecg:\(hour + 7300)"])
        XCTAssertEqual(own.map(\.value), [70])
        // Running it again finds nothing new, and nor does it once the minutes are no longer stored.
        let storedNow = outbox.rows.values.filter { $0.sample.kind == .heartRate }.map(\.sample)
        XCTAssertEqual(outbox.plan(HealthMetadata.backfill(heartRate: storedNow, minutes: minutes, ecgs: [ecg, lone], hrv: hrv)), [])
        XCTAssertEqual(outbox.plan(HealthMetadata.backfill(heartRate: storedNow, minutes: [], ecgs: [], hrv: hrv)), [])
    }

    func testTheBackfillKeepsTheVersionOfDataThatArrivedSince() {
        // A sample rewritten by the backfill goes back to growing with its data afterwards.
        var outbox = TestOutbox()
        _ = outbox.plan([heartRate(hour, version: 100_040)])
        let minutes = (0..<10).map { minute(hour + $0 * 60, skin: 33.4) }
        let stored = outbox.rows.values.map(\.sample)
        XCTAssertEqual(outbox.plan(HealthMetadata.backfill(heartRate: stored, minutes: minutes, ecgs: [], hrv: [])).map(\.version), [100_041])
        XCTAssertEqual(outbox.rows["whoopsync:hr:\(hour)"]?.sample.version, 100_040)
    }
}
