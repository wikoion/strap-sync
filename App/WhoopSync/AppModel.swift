import BackgroundTasks
import Foundation
import HealthKit
import SyncCore
import UIKit
import UserNotifications

/// Ties the strap, the local store and Apple Health together:
/// beats and records in (live and history) → store → samples (per-minute HR and steps, hourly HRV,
/// nightly sleep, resting HR and breathing rate) → outbox → Apple Health.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published private(set) var link: LinkState = .bluetoothOff
    @Published private(set) var pairing: PairingState = .unknown
    @Published private(set) var found: [FoundStrap] = []
    @Published private(set) var info = DeviceInfo()
    @Published private(set) var battery: Int?
    @Published private(set) var lastHR: (bpm: Int, at: Date)?
    @Published private(set) var clockOffset: Int?
    @Published private(set) var downloading = false
    @Published private(set) var lastDownload: (at: Date, ok: Bool, records: Int)?
    /// While a download runs: records so far and how far into the past-to-now they reach.
    @Published private(set) var downloadProgress: (records: Int, upTo: Date?) = (0, nil)
    @Published private(set) var pending = 0
    @Published private(set) var writtenToday: [PlannedSample.Kind: Int] = [:]
    @Published private(set) var skinTemp: (celsius: Double, at: Date)?
    @Published private(set) var lastNight: Sleep.Night?
    /// The night under way: asleep, or awake but not yet surely up.
    @Published private(set) var openNight: (night: Sleep.Night, awake: Bool)?
    /// How far the night under way is written, once an earlier version of it has been; nil until then.
    @Published private(set) var openWrittenUntil: Int?
    @Published private(set) var lastStages: StagedNight?
    /// The sleep-stage model, read on first use: SyncCore's, unless the build bundles its own as a
    /// `PersonalSleepModel` folder in the app (laid out like SyncCore's `Resources/SleepModel`).
    private lazy var stager: SleepStager? = {
        let own = Bundle.main.url(forResource: "PersonalSleepModel", withExtension: nil)
        do {
            let s = try own.map(SleepStager.load(from:)) ?? SleepStager.bundled()
            log("Sleep stages: model \(s.version)" + (own == nil ? "" : ", bundled with this build"))
            return s
        } catch {
            log("Sleep stages: the model didn't load: \(error)")
            return nil
        }
    }()
    @Published private(set) var storeError: String?

    enum EcgPhase: Equatable {
        case idle, starting, recording, saving
        case finished(saved: Bool)
        case failed(String)
    }

    @Published private(set) var ecgPhase: EcgPhase = .idle
    @Published private(set) var ecgStatus: Ecg.Status?
    /// The most recent ~5 s of the live trace.
    @Published private(set) var ecgLive: [Int] = []
    @Published private(set) var ecgRecordings: [EcgRecording] = []
    /// When the countdown reaches zero: a phone-side clock, re-synced to the strap's progress only when
    /// they drift apart, because the strap's progress moves in uneven 3-4 % steps.
    @Published private(set) var ecgDeadline: Date?
    /// The strap reported 100 %: the user can let go.
    @Published private(set) var ecgDone = false
    /// Counting had started and then the strap's progress fell back.
    @Published private(set) var ecgRestarted = false
    private var ecgLastProgress = 0
    private var recorder: EcgRecorder?
    private var ecgWrist = Ecg.Wrist.left
    private var ecgStartedAt = Date()
    private var ecgWatchdog: Timer?
    private var lastShare = Date.distantPast
    private var sharedSkin: [Int] = []
    private var sharedHRV: [Int] = []

    #if DEBUG
    let strap = Demo.enabled ? StrapLink(demoStrap: Demo.strapId) : StrapLink()
    #else
    let strap = StrapLink()
    #endif
    let health = HealthWriter()
    /// Not private, so a build's own sources can use it (PersonalHooks, docs/DEVELOPMENT.md).
    let store: Store?
    private var timer: Timer?
    private var aggregateSoon: DispatchWorkItem?
    private var lastPrune = Date.distantPast
    /// Nights weren't worked out because a batch was being saved to Health (processNights).
    private var nightsWaiting = false
    private var stats = DownloadStats()

    /// What one history download brought in, logged when it finishes so the strap's fields can be checked.
    private struct DownloadStats {
        var records = 0, worn = 0, rr = 0, spo2 = 0, stepsFirst: Int?, stepsLast: Int?
        var layouts: [UInt8: Int] = [:]
        var states: [Int: Int] = [:]
        var motion: [Double] = []
        var skin: [Double] = []
        var first: Int?, last: Int?

        mutating func add(_ c: HistoryChunk) {
            records += c.motion.count
            worn += c.hr.count
            rr += c.rr.count
            layouts.merge(c.otherLayouts, uniquingKeysWith: +)
            for m in c.motion {
                if Oximetry.isReading(m.spo2Raw) { spo2 += 1 }
                states[m.bandState, default: 0] += 1
                if let v = m.motion { motion.append(v) }
                if m.bpm > 0, let s = m.skinTempC { skin.append(s) }
                stepsFirst = stepsFirst ?? m.stepCounter
                stepsLast = m.stepCounter
                first = min(first ?? m.ts, m.ts)
                last = max(last ?? m.ts, m.ts)
            }
        }

        var summary: String? {
            guard records > 0, let first, let last else { return nil }
            let f = DateFormatter()
            f.dateFormat = "HH:mm"
            func range(_ xs: [Double], _ fmt: String) -> String {
                guard let lo = xs.min(), let hi = xs.max() else { return "none" }
                return String(format: "\(fmt)–\(fmt)", lo, hi)
            }
            let still = motion.isEmpty ? 0 : motion.filter { $0 <= Sleep.stillMotion }.count * 100 / motion.count
            return """
                History data \(f.string(from: Date(timeIntervalSince1970: TimeInterval(first))))–\
                \(f.string(from: Date(timeIntervalSince1970: TimeInterval(last)))): \(records) records, \(worn) worn, \(rr) RR; \
                step counter \(stepsFirst ?? 0)→\(stepsLast ?? 0); band states \(states.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: " ")); \
                motion \(range(motion, "%.3f")) g (\(still)% still); skin \(range(skin, "%.1f")) °C; \
                \(spo2) SpO2 readings; other layouts \(layouts.isEmpty ? "none" : layouts.sorted { $0.key < $1.key }.map { "R\($0.key):\($0.value)" }.joined(separator: " "))
                """
        }
    }

    private init() {
        do {
            store = try Store()
        } catch {
            store = nil
            storeError = "Couldn't open the local database: \(error)"
            log(storeError!)
        }
        strap.onEvent = { [weak self] event in MainActor.assumeIsolated { self?.handle(event) } }
        strap.save = { [weak self] chunk in MainActor.assumeIsolated { self?.save(chunk) ?? false } }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        NotificationCenter.default.addObserver(forName: UIApplication.protectedDataDidBecomeAvailableNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.unlocked() }
        }
        // Samples are stamped with the zone they were recorded in, so the zone history must follow the phone.
        recordZone("app launched")
        NotificationCenter.default.addObserver(forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.recordZone("the phone's time zone changed") }
        }
        refreshCounts()
        lastStages = try? store?.latestStages()
        // An earlier build saved incomplete recordings; drop them here and from the shared keychain.
        for start in (try? store?.deleteIncompleteEcgs()) ?? [] {
            SharedKeychain.delete("ecg.\(start)")
            log("ECG: removed an incomplete recording from \(start)")
        }
        // Recordings saved before heart rate fell back to the trace or the wrist get one now.
        for e in (try? store?.ecgRecordings(limit: 50)) ?? [] where e.heartRate == nil {
            let updated = withHeartRate(e, strap: nil)
            guard updated.heartRate != nil else { continue }
            try? store?.save(updated)
            try? store?.markDirty([updated.start])  // its heart-rate sample in Health carries the heart rate too
            publish(updated)
            log("ECG: recording from \(e.start) now has heart rate \(updated.heartRate!) bpm (\(updated.heartRateSource ?? ""))")
        }
        loadEcgRecordings()
        #if PERSONAL
        PersonalHooks.didLaunch(self)
        #endif
        #if DEBUG
        if Demo.enabled { playDemo() }
        #endif
    }

    // MARK: - Strap events

    private func handle(_ event: StrapLink.Event) {
        switch event {
        case .state(let s):
            link = s
            if s != .connected, [.starting, .recording].contains(ecgPhase) {
                finishEcg(stop: false, failure: "The strap disconnected during the recording.")
            }
        case .ecgResponse(let cmd, let result):
            handleEcgResponse(cmd: cmd, result: result)
        case .ecgRecord(let r, let at):
            handleEcgRecord(r, at: at)
        case .pairing(let p): pairing = p
        case .found(let f): found = f
        case .info(let i): info = i
        case .battery(let b): battery = b
        case .clockOffset(let o): clockOffset = o
        case .historyStarted:
            recordZone("history download")
            downloading = true
            stats = DownloadStats()
            downloadProgress = (0, nil)
        case .historyFinished(let ok, _, let records):
            downloading = false
            lastDownload = (Date(), ok, records)
            if let s = stats.summary { log(s) }
            if ok { scheduleStaleNotice() }
            tick()
        case .liveHR(let m, let at):
            guard m.isUsable else { return }
            lastHR = (m.bpm, Date(timeIntervalSince1970: TimeInterval(at)))
            do {
                try store?.insertLive(ts: at, bpm: m.bpm, rrMs: m.rrRaw)
            } catch {
                log("Saving a live reading failed: \(error)")
            }
        }
    }

    private func save(_ chunk: HistoryChunk) -> Bool {
        guard let store else { return false }
        do {
            try store.save(chunk)
        } catch {
            log("Saving history failed: \(error)")
            return false
        }
        stats.add(chunk)
        downloadProgress = (stats.records, stats.last.map { Date(timeIntervalSince1970: TimeInterval($0)) })
        scheduleAggregate()
        return true
    }

    // MARK: - Data → samples → Health

    private func scheduleAggregate() {
        aggregateSoon?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.tick() } }
        aggregateSoon = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    /// Turns every dirty hour (and any finished night) into samples, then writes the outbox to Health.
    func tick() {
        aggregate()
        Task { await flush() }
    }

    /// The phone was unlocked, so Health can be written: what has waited goes now, a night that went on after it
    /// was written brought up to where the stored data ends first (processNights). With a night under way, the
    /// strap is then asked for the minutes since its last download, which the pass after it adds.
    private func unlocked() {
        tick()
        if openNight != nil { strap.requestHistoryIfDue(reason: "phone unlocked", interval: 60) }
    }

    private func aggregate() {
        guard let store else { return }
        let now = Int(Date().timeIntervalSince1970)
        // Before anything is planned: the owner's zones for the past, if there's a file.
        readZoneFile(store: store)
        do {
            for hour in try store.dirtyHours() {
                let liveHR = try store.heartRates(hour: hour, source: .live)
                let historyHR = try store.heartRates(hour: hour, source: .history)
                let liveRR = try store.intervals(hour: hour, source: .live)
                let historyRR = try store.intervals(hour: hour, source: .history)
                let hrv = Aggregator.hourlyWindows(live: liveRR, history: historyRR, now: now)
                try store.saveHRV(hrv)
                var heartRate = Aggregator.heartRateMinutes(live: liveHR, history: historyHR, now: now)
                var plans = Aggregator.hrvSamples(hrv)
                // An ECG rides on the sample of the minute it started in, or on a heart-rate sample of its own, which
                // it keeps once it has one.
                let ecgs = try store.ecgRecordings(since: hour, until: hour + 3600)
                let own = try store.planned(ecgs.map { HealthMetadata.carrierId($0.start) })
                heartRate = HealthMetadata.withEcgs(heartRate, ecgs.map(\.forHealth),
                                                    carried: Set(ecgs.map(\.start).filter { own.contains(HealthMetadata.carrierId($0)) }))
                let motion = try store.motion(hour: hour)
                if !motion.isEmpty {
                    plans += Steps.perMinute(motion, previous: try store.motion(before: hour))
                    let minutes = MinuteSummary.summarise(motion)
                    try store.saveMinutes(minutes)
                    // Skin temperature rides on the hour's heart-rate samples (its 10-minute intervals never cross
                    // an hour). While an interval fills in, its samples are rewritten with each new value.
                    heartRate = HealthMetadata.withSkinTemperature(heartRate, SkinTemperature.intervals(minutes))
                }
                try store.plan(heartRate + plans)
                // A finished hour is done unless more data for it arrives (it'd mark it dirty again).
                if hour + 3600 <= now { try store.clearDirty(hour) }
            }
            try backfillHRV(store: store, now: now)
            try redoHRV(store: store, now: now)
            try backfillMetadata(store: store, now: now)
            // SpO2 runs: idempotent, since a run's sample only changes when more of it arrives.
            try store.plan(Oximetry.samples(Oximetry.runs(try store.spo2Readings(from: now - 48 * 3600))))
            try processNights(store: store, now: now)
            reconstructZones(store: store)
            logZones(store: store)
            try redoZones(store: store, now: now)
            if Date().timeIntervalSince(lastShare) > 600 { try share(store: store, now: now) }
            if Date().timeIntervalSince(lastPrune) > 3600 {
                try store.prune(now: now)
                lastPrune = Date()
            }
        } catch {
            log("Building samples failed: \(error)")
        }
        refreshCounts()
    }

    /// Once: HRV windows (SDNN and RMSSD) for the stored week before the `hrv` table existed, so the share
    /// starts with a week of RMSSD. Health's SDNN samples for those hours are already written and stay as they are.
    private func backfillHRV(store: Store, now: Int) throws {
        guard try store.value("hrvBackfill1") == nil else { return }
        var hours = 0
        for hour in try store.beatHours(from: now - SharedKeychain.retentionSeconds) where hour + 3600 <= now {
            let windows = Aggregator.hourlyWindows(live: try store.intervals(hour: hour, source: .live),
                                                   history: try store.intervals(hour: hour, source: .history), now: now)
            try store.saveHRV(windows)
            hours += windows.count
        }
        try store.setValue("hrvBackfill1", 1)
        log("HRV: computed SDNN and RMSSD for \(hours) stored hours")
    }

    /// Once: every stored hour (beats are kept two weeks) again with steady windows and detrended SDNN (8 Nov 2026).
    /// The new versions are higher, so the `hrv` table, the share and Health's SDNN samples are all replaced.
    private func redoHRV(store: Store, now: Int) throws {
        guard try store.value("hrvRedo1") == nil else { return }
        var hours = 0
        for hour in try store.beatHours(from: 0) where hour + 3600 <= now {
            let live = try store.intervals(hour: hour, source: .live), history = try store.intervals(hour: hour, source: .history)
            let windows = Aggregator.hourlyWindows(live: live, history: history, now: now)
            try store.saveHRV(windows)
            try store.plan(Aggregator.hrvSamples(windows))
            hours += windows.count
        }
        try store.setValue("hrvRedo1", 1)
        log("HRV: recomputed \(hours) stored hours with steady, detrended SDNN")
    }

    /// Once (metadataRedo1): the heart-rate and HRV samples already planned get Strap Sync's metadata, skin
    /// temperature, ECGs and RMSSD (docs/SHARING.md, "Through Apple Health"), so an app reading Health finds the
    /// stored days with it, not only what's written from now on: minutes are kept 8 days, HRV windows 14. Their data is
    /// unchanged, so each sample that gains metadata gets the next sync version and Health replaces it; the rest
    /// stay as they are. The outbox writes them in its batches of 500, once Health can be written to.
    ///
    /// Finished hours only, and not mid-download, as for nights: an interval being downloaded holds only part of
    /// its minutes. Hours still dirty were planned just now, with their metadata.
    private func backfillMetadata(store: Store, now: Int) throws {
        guard !downloading, try store.value("metadataRedo1") == nil else { return }
        let from = now - 14 * 86_400, until = now - now % 3600
        let plans = HealthMetadata.backfill(heartRate: try store.planned(.heartRate, from: from, to: until),
                                            minutes: try store.minutes(from: from, to: until),
                                            ecgs: try store.ecgRecordings(since: from, until: until, limit: 1000).map(\.forHealth),
                                            hrv: try store.hrv(from: from).filter { $0.hour + 3600 <= until })
        let rewritten = try store.plan(plans)
        try store.setValue("metadataRedo1", 1)
        log("Apple Health: \(rewritten) heart-rate and HRV samples to rewrite with skin temperature, ECGs and RMSSD")
    }

    // MARK: - Time zones

    /// Adds the phone's zone to the zone history if it's another one than the latest. Each sample is stamped with the
    /// zone at its start (HealthWriter), so rewriting old data later never gives it the zone of the day it's rewritten.
    private func recordZone(_ why: String) {
        guard let store else { return }
        // TimeZone.current stays what it was when first read, unless reset: the process can outlive a change of zone.
        NSTimeZone.resetSystemTimeZone()
        let zone = TimeZone.current
        do {
            if let entry = try store.recordZone(zone.identifier, at: Int(Date().timeIntervalSince1970)) {
                log("Time zone: \(ZoneHistory.describe([entry])) (\(why))")
            }
        } catch {
            log("Recording the time zone failed: \(error)")
        }
    }

    private var reconstructingZones = false

    /// Once (zonesFromLogs1): the zones before the first one recorded, from the app's own daily logs (ZoneLog has
    /// how), so the samples of those days can be stamped too. Where no log tells, the zone stays unknown, and those
    /// samples go to Health with none. The files are read and parsed off the main thread; saving stays on it.
    private func reconstructZones(store: Store) {
        guard !reconstructingZones, (try? store.value("zonesFromLogs1")) == nil, UIApplication.shared.isProtectedDataAvailable else { return }
        reconstructingZones = true
        let own = store.firstRecordedZone
        let until = own?.since ?? Int(Date().timeIntervalSince1970)
        let current = TimeZone.current
        Task.detached(priority: .utility) {
            let files = ZoneLog.files(in: Log.directory)
            let past = ZoneLog.reconstruct(files, current: current, until: until)
            await MainActor.run {
                do {
                    let added = try store.addPastZones(past)
                    try store.setValue("zonesFromLogs1", 1)
                    log("Time zones from the logs (\(files.count) files): " + (added.isEmpty ? "none" : ZoneHistory.describe(added))
                        + (own.map { "; then the app's own record, \(ZoneHistory.describe([$0]))" } ?? ""))
                } catch {
                    log("Time zones: saving those from the logs failed: \(error)")
                }
                self.reconstructingZones = false
                self.tick()
            }
        }
    }

    /// Read once a launch: the owner can add or change it in the Files app (Strap Sync's folder) at any time.
    private var zoneFileRead = false

    /// The owner's own zones for the past, `Documents/time-zones.json` (ZoneFile; docs/DEVELOPMENT.md has the
    /// format): where it reaches, they replace the ones reconstructed from the logs, which can be wrong when the
    /// phone's own zone was. A file that isn't right in every detail is ignored, whole, and the log says why.
    private func readZoneFile(store: Store) {
        guard !zoneFileRead else { return }
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(ZoneFile.name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            zoneFileRead = true
            return store.setZoneFile(nil)
        }
        guard let data = try? Data(contentsOf: url) else { return }  // locked: try again on the next pass
        zoneFileRead = true
        switch ZoneFile.parse(data) {
        case .success(let file):
            store.setZoneFile(file)
            log("Time zones: \(ZoneFile.name) read, \(file.entries.count) zones from \(ZoneHistory.utc(file.start)) until \(ZoneHistory.utc(file.until))")
        case .failure(let problem):
            store.setZoneFile(nil)
            log("Time zones: \(ZoneFile.name) ignored, \(problem)")
        }
    }

    /// Logs the history in effect, with where each stretch comes from, once both the logs and the file have been
    /// read, and again only when it changes (a new file, a new zone).
    private func logZones(store: Store) {
        guard zoneFileRead, (try? store.value("zonesFromLogs1")) != nil else { return }
        let text = ZoneHistory.describe(store.zonePeriods)
        // FNV-1a: a hash that stays the same across launches.
        let hash = text.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
        let key = Int(truncatingIfNeeded: hash)
        guard (try? store.value("zonesLogged")) != key else { return }
        log("Time zones in effect: " + text)
        try? store.setValue("zonesLogged", key)
    }

    private var redoingZones = false
    private var zoneRedoAfter = Date.distantPast
    private var zoneRedoWaiting: String?

    /// Once (zoneRedo1): until now every sample was stamped with the phone's zone when it was written. Right for
    /// what's written minutes after it's recorded, but every rewrite of older data (restaged nights, `nightsRedo6`,
    /// `metadataRedo1`, version bumps) stamped it with the zone of the day it was rewritten. So the app's own samples
    /// in Health from the last 16 days whose zone isn't the history's are written again from their outbox rows, with
    /// the right zone, one sync version up, so Health replaces each in place (HealthWriter.restampZones). Health
    /// decides what's rewritten, not the outbox: it can hold rows Health no longer has. The outbox then writes them
    /// in its batches of 500, once Health can be written to.
    ///
    /// Only once the zones before the first recorded one are back from the logs and the owner's time-zones.json, if
    /// there is one, has been read (so both rewrites use the history in effect), once protected data is available
    /// (the logs, and Health), not mid-download or while a batch is being saved (as for nights), and once the redos
    /// that rewrite the same samples are done: `metadataRedo1`, and `nightsRedo6` with its restaging. When it can't
    /// run yet, it tries again 15 minutes later.
    private func redoZones(store: Store, now: Int) throws {
        guard !redoingZones, Date() >= zoneRedoAfter, try store.value("zoneRedo1") == nil, try store.value("zonesFromLogs1") != nil, zoneFileRead,
              !downloading, !health.saving, UIApplication.shared.isProtectedDataAvailable,
              try store.value("metadataRedo1") != nil, try store.value("nightsRedo6") != nil,
              try (store.value("restageFrom") ?? 0) == 0 || stager == nil else { return }
        redoingZones = true
        Task {
            defer { redoingZones = false }
            switch await health.restampZones(store: store, now: now) {
            case .wait(let why):
                zoneRedoAfter = Date().addingTimeInterval(15 * 60)
                if why != zoneRedoWaiting { log("Apple Health: time zones not rewritten yet: \(why); trying again every 15 minutes") }
                zoneRedoWaiting = why
            case .done(let plan, let read, let changed):
                do { try store.setValue("zoneRedo1", 1) } catch { return log("Apple Health: time zones: \(error)") }
                let kinds = Dictionary(grouping: plan.rewrites, by: \.row.sample.kind).sorted { $0.key.rawValue < $1.key.rawValue }
                    .map { "\(HealthWriter.name($0.key)) \($0.value.count)" }
                log("Apple Health: of \(read) samples from the last \(ZoneRedo.days) days, \(plan.rewrites.count) to rewrite with the time zone they "
                    + "were recorded in\(kinds.isEmpty ? "" : " (\(kinds.joined(separator: ", ")))"), \(plan.right.count) right already; "
                    + "\(plan.noRow.count) wrongly stamped with no outbox row and \(plan.noSyncId.count) without a sync identifier left as they are; "
                    + "\(plan.notInHealth.count) outbox rows not in Health left alone; \(changed) rows changed")
                for night in plan.restored {
                    log("Apple Health: writing again a night Health had lost, \(ZoneHistory.utc(night.start))–\(ZoneHistory.utc(night.end)): "
                        + "\(night.count(.sleep)) sleep, \(night.count(.restingHR)) resting heart rate, \(night.count(.respiratoryRate)) breathing")
                }
                tick()
            }
        }
    }

    /// Writes each night once it's over: sleep intervals, resting heart rate and breathing rate.
    private func processNights(store: Store, now: Int) throws {
        // Mid-download the data stops wherever the download has reached, which looks like waking up.
        guard !downloading else { return }
        // While a batch is being saved to Health, a night's clear could delete samples of that batch after they're
        // saved, so nights wait, and are worked out again once the flush has finished (HealthFlush).
        guard !health.saving else { return nightsWaiting = true }
        // Once: the first real night was written from half a download, hours short. Step back a day so
        // it's recomputed; its samples replace the old ones by version.
        // Twice more: the band's own sleep flag now defines the night (the second redo), and a rewritten
        // night clears its earlier samples from Health first, so recomputing never leaves two versions.
        // A third time, two days back: nights now run across wake-ups of up to an hour and start before the
        // band's first flag, and two nights had lost 1 h 44 and 2 h 03 of sleep that way.
        for (flag, days) in [("nightsRedo1", 1), ("nightsRedo2", 1), ("nightsRedo3", 2)] where try store.value(flag) == nil {
            try store.setValue("nightsDoneUntil", max(0, (try store.value("nightsDoneUntil") ?? 0) - days * 86_400))
            try store.setValue(flag, 1)
        }
        // A fourth time (nightsRedo4): nights now also run across up to two hours lying in bed, and a night had
        // lost 2 h 12 that way. A rewritten night is cleared in Health, stages and all, so its stages go too and it's
        // staged again below; a night that hasn't changed would otherwise come back as plain "asleep".
        if try store.value("nightsRedo4") == nil {
            let back = max(0, (try store.value("nightsDoneUntil") ?? 0) - 2 * 86_400)
            try store.setValue("nightsDoneUntil", back)
            try store.deleteStages(overlapping: back, now)
            try store.setValue("nightsRedo4", 1)
        }
        // And nightsRedo5: samples now carry their time zone. The latest night is written again with it, stages and
        // all, if it ended in the last 36 hours, so it was most likely slept in the zone the phone has now. Older
        // nights keep theirs: stamping them with today's zone could be wrong.
        if try store.value("nightsRedo5") == nil {
            if let last = try store.value("nightLastStart"), let done = try store.value("nightsDoneUntil"), done > now - 36 * 3600 {
                try store.setValue("nightsDoneUntil", last)
                try store.deleteStages(overlapping: last, now)
            }
            try store.setValue("nightsRedo5", 1)
        }
        // And nightsRedo6: nights staged while a long write to Health was under way lost their samples there, to their
        // own clears (HealthFlush has how, and why it can't happen now). Every night still in the stored beats (14
        // days) is staged and written again, stages and all, by the stager below: its look-back reaches back to
        // `restageFrom` until it has been through every night there. Minutes are kept 8 days, so the older ones are
        // rebuilt from the motion records, kept 14 days like the beats. Only while protected data is available, so
        // the nights go to Health as they're staged, not once the phone is next unlocked.
        if try store.value("nightsRedo6") == nil, UIApplication.shared.isProtectedDataAvailable {
            let from = now - 14 * 86_400
            let rebuilt = try rebuildMinutes(store: store, from: from, now: now)
            try store.deleteStages(overlapping: from, now)
            try store.setValue("restageFrom", from)
            try store.setValue("nightsRedo6", 1)
            log("Sleep stages: staging the nights of the last 14 days again (\(rebuilt) minutes rebuilt from motion)")
        }
        let minutes = try store.minutes(from: now - 48 * 3600)
        guard let lastMinute = minutes.last?.minute else { return }
        let doneUntil = try store.value("nightsDoneUntil") ?? 0
        // A night is written as soon as you're up; back asleep within `Sleep.maxWake` minutes, it's the same
        // night, longer, and is written again.
        let lastStart = try store.value("nightLastStart")
        openNight = Sleep.open(minutes, dataUntil: lastMinute + 60)
        // While a night is under way, download every 5 minutes, so the morning shows soon after you're up.
        strap.historyEvery = openNight == nil ? StrapLink.historyInterval : 5 * 60
        let nights = Sleep.nights(minutes, dataUntil: lastMinute + 60, now: now)
        // A night written and then slept on isn't over until you're up for the day, and what was written is short
        // all that time. While Health can be written (the phone unlocked), it's written again as far as it has
        // got, before the flush, so the short one never goes to Health once more is known (`Sleep.due`).
        let soFar = UIApplication.shared.isProtectedDataAvailable ? Sleep.soFar(minutes) : nil
        for night in Sleep.due(finished: nights, soFar: soFar, doneUntil: doneUntil, lastStart: lastStart) {
            var rr = try store.intervals(from: night.start, to: night.end, source: .history)
            if rr.isEmpty { rr = try store.intervals(from: night.start, to: night.end, source: .live) }
            let samples = Sleep.samples(for: night, minutes: minutes, rr: rr)
            try store.stageNight(start: night.start, end: night.end, samples: samples,
                                 neighbours: nights.filter { $0 != night }.map { $0.start..<$0.end })
            try store.setValue("nightsDoneUntil", night.end)
            try store.setValue("nightLastStart", night.start)
            lastNight = night
            let f = DateFormatter()
            f.dateFormat = "HH:mm"
            func time(_ t: Int) -> String { f.string(from: Date(timeIntervalSince1970: TimeInterval(t))) }
            let rhr = samples.first { $0.kind == .restingHR }.map { "\(Int($0.value)) bpm" } ?? "none"
            let breathing = samples.filter { $0.kind == .respiratoryRate }.map { String(format: "%.1f", $0.value) }
            let runs = Oximetry.runs(try store.spo2Readings(from: night.start)).filter { $0.start < night.end }
            let medians = runs.map(\.median)
            let spo2 = medians.isEmpty ? "none" : String(format: "%.1f%% mean, %.0f%% lowest, %d runs",
                                                          medians.reduce(0, +) / Double(medians.count), medians.min()!, runs.count)
            log("""
                \(nights.contains(night) ? "Sleep" : "Sleep so far"): \(time(night.start))–\(time(night.end)), \(night.asleepSeconds / 3600)h \(night.asleepSeconds % 3600 / 60)m \
                asleep, woke \(night.awakenings)×; resting HR \(rhr); breathing \(breathing.isEmpty ? "none" : breathing.joined(separator: " ")) /min; \
                SpO2 \(spo2)
                """)
        }
        openWrittenUntil = try openNight.flatMap { try store.value("nightLastStart") == $0.night.start ? try store.value("nightsDoneUntil") : nil }
        // Sleep stages: any finished night not yet staged by this model, including nights written before
        // stages existed. They replace the night's plain "asleep" in Health with Awake / Core / Deep / REM.
        // Once: nights staged when stages were shown in the app only are staged (and written) again.
        // Once more (stagesRepair1): a night sliding out of the old 48-h window was restaged a minute
        // shorter every pass and rewritten in Health; staging them all again puts the whole nights back.
        for flag in ["stagesToHealth", "stagesRepair1"] where try store.value(flag) == nil {
            try store.clearStages()
            try store.setValue(flag, 1)
        }
        // Every night of the last 7 days (minutes are kept 8), or back to `restageFrom` while a redo is under way, at
        // most two a pass, newest first: a new model restages a week of nights, a second or so each, and a
        // background wake-up is short.
        let restageFrom = try store.value("restageFrom") ?? 0
        let week = try store.minutes(from: restageFrom > 0 ? min(restageFrom, now - 7 * 86_400) : now - 7 * 86_400)
        var stagedNow = 0
        let weekNights = Sleep.nights(week, dataUntil: lastMinute + 60, now: now)
        // With the night under way, when it's what was last written (above, in this pass or an earlier one).
        let underWay = try Sleep.soFar(minutes).flatMap { n -> Sleep.Night? in
            guard try store.value("nightLastStart") == n.start, try store.value("nightsDoneUntil") == n.end else { return nil }
            return weekNights.contains { $0.start < n.end && n.start < $0.end } ? nil : n
        }
        for night in (weekNights + (underWay.map { [$0] } ?? [])).reversed() where stagedNow < 2 {
            // Staged already, unless the night has grown since (back asleep after getting up, or found to
            // start earlier).
            guard let stager else { continue }
            if try store.stagesCover(model: stager.version, night.start, night.end) { continue }
            let rr = try store.intervals(from: night.start - 600, to: night.end + 600, source: .history)
            guard rr.count >= 1000 else { continue }
            let motion = try store.motion(from: night.start, to: night.end)
            let stages = stager.stages(rr: rr, motion: motion, start: night.start, end: night.end)
            guard !stages.isEmpty else { continue }
            // Clearing the night in Health deletes its resting HR and breathing too, so they go back with it. The
            // outbox first: should the app stop before the stages are saved, the night is just staged again.
            let others = Sleep.samples(for: night, minutes: week, rr: rr).filter { $0.kind != .sleep }
            try store.stageNight(start: night.start, end: night.end,
                                 samples: SleepStager.samples(start: night.start, stages: stages, version: stager.versionNumber) + others,
                                 neighbours: weekNights.filter { $0 != night }.map { $0.start..<$0.end })
            try store.deleteStages(overlapping: night.start, night.end)
            try store.saveStages(start: night.start, end: night.end, model: stager.version, stages: stages)
            lastStages = try store.latestStages()
            stagedNow += 1
            let staged = StagedNight(start: night.start, end: night.end, stages: stages)
            log("Sleep stages (model \(stager.version)): awake \(staged.minutes(.wake)) min, light \(staged.minutes(.light)), " +
                "deep \(staged.minutes(.deep)), REM \(staged.minutes(.rem)) from \(rr.count) beats and " +
                "\(motion.filter { $0.gravity != nil }.count * 100 / max(1, night.end - night.start))% of seconds with gravity")
        }
        // Under the limit, so the pass went through every night back to `restageFrom`: the redo is done.
        if restageFrom > 0, stager != nil, stagedNow < 2 {
            try store.setValue("restageFrom", 0)
            log("Sleep stages: every stored night has been staged again")
        }
    }

    /// Puts back the minutes from `from` up to the first one stored, a day at a time, from the motion records they're
    /// made of (as `aggregate` makes them). Returns how many.
    private func rebuildMinutes(store: Store, from: Int, now: Int) throws -> Int {
        let until = try store.firstMinute(from: from) ?? now
        var count = 0
        for day in stride(from: from, to: until, by: 86_400) {
            let minutes = MinuteSummary.summarise(try store.motion(from: day, to: min(day + 86_400, until)))
            try store.saveMinutes(minutes)
            count += minutes.count
        }
        return count
    }

    func flush() async {
        guard let store else { return }
        await health.flush(store: store, device: device)
        #if PERSONAL
        await PersonalHooks.didFlush(self)
        #endif
        refreshCounts()
        // Nights waited for a save to finish (processNights): work them out now, and write them.
        if nightsWaiting, !health.saving {
            nightsWaiting = false
            tick()
        }
    }

    private var device: HKDevice {
        HKDevice(name: info.variant, manufacturer: "WHOOP", model: info.model, hardwareVersion: info.hardware,
                 firmwareVersion: info.firmware, softwareVersion: nil, localIdentifier: nil, udiDeviceIdentifier: nil)
    }

    private func refreshCounts() {
        guard let store else { return }
        pending = (try? store.pendingCount()) ?? 0
        let midnight = Int(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970)
        writtenToday = (try? store.writtenCounts(since: midnight)) ?? [:]
        let recent = (try? store.minutes(from: Int(Date().timeIntervalSince1970) - 3 * 3600)) ?? []
        if let m = recent.last(where: { $0.skinTempC != nil && $0.worn > 0 }), let c = m.skinTempC {
            skinTemp = (c, Date(timeIntervalSince1970: TimeInterval(m.minute)))
        }
    }

    private var backfillingOptical = false

    /// Once: banks the R26 optical seconds still in the 7-day raw archive from before the `ppg` table existed.
    /// The files are read and parsed off the main thread; saving stays on it, like every other store write.
    private func backfillOptical() {
        guard let store, !backfillingOptical, (try? store.value("ppgBackfill1")) == nil else { return }
        backfillingOptical = true
        Task.detached(priority: .utility) {
            let files = ((try? FileManager.default.contentsOfDirectory(at: RawArchive.directory, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "bin" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            let chunks = files.compactMap { (try? Data(contentsOf: $0)).map { HistoryChunk.archived([UInt8]($0)) } }
            await MainActor.run {
                do {
                    for c in chunks where !c.optical.isEmpty || !c.banked.isEmpty { try store.save(c) }
                    try store.setValue("ppgBackfill1", 1)
                    log("Optical bursts: banked \(chunks.map(\.optical.count).reduce(0, +)) optical seconds and "
                        + "\(chunks.map(\.banked.count).reduce(0, +)) other records from \(files.count) raw archive files")
                } catch {
                    log("Optical bursts: banking the raw archive failed: \(error)")
                }
                self.backfillingOptical = false
                self.refreshCounts()
            }
        }
    }

    // MARK: - UI actions

    func foreground() {
        health.refresh()
        tick()
        backfillOptical()
        // Opening the app fetches what's new, so a night that has just finished shows without waiting for
        // the 15-minute download.
        strap.requestHistoryIfDue(reason: "app opened", interval: 60)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.staleNoticeId])
        if strap.isBonded {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    // MARK: - Stopped-syncing notice

    private static let staleNoticeId = "stale-sync"

    /// A notice 3 hours out, pushed back by every completed download. While syncing runs it never
    /// fires; if iOS stops the app (or it's swiped away, after which iOS won't relaunch it for
    /// Bluetooth), it does, so the gap gets noticed.
    private func scheduleStaleNotice() {
        let content = UNMutableNotificationContent()
        content.title = "Strap Sync stopped syncing"
        content.body = "No new WHOOP data since \(Date().formatted(date: .omitted, time: .shortened)). If the strap is nearby, open Strap Sync to restart it."
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 3 * 3600, repeats: false)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: Self.staleNoticeId, content: content, trigger: trigger))
    }

    func downloadNow() { strap.requestHistory(reason: "Download now") }

    /// Fetches what's new from the strap first, so a night that has just ended can be written; the download
    /// finishing works out nights and writes to Health. Without the strap, it writes what's waiting.
    func writeNow() {
        if strap.isBonded, !downloading { strap.requestHistory(reason: "Write to Apple Health now") } else { tick() }
    }
    func choose(_ strap: FoundStrap) { self.strap.choose(strap.id) }
    func forget() { strap.forget(); info = DeviceInfo(); battery = nil; lastHR = nil; clockOffset = nil }

    func connectHealth() async {
        await health.requestAccess()
        tick()
    }

    // MARK: - Sharing with Health Dashboard (docs/SHARING.md)

    /// Publishes skin temperature and hourly HRV when they changed, makes sure every ECG from the last 7 days
    /// is shared, and removes shared ECGs older than that.
    private func share(store: Store, now: Int) throws {
        lastShare = Date()
        guard SharedKeychain.group != nil else { return log("Sharing: no shared keychain group in this build") }
        let skin = SharedKeychain.skinSamples(minutes: try store.minutes(from: now - SharedKeychain.retentionSeconds), now: now)
        let signature = skin.flatMap { [$0.start, Int($0.celsius * 100)] }
        if signature != sharedSkin, !skin.isEmpty, let data = SharedKeychain.skinTemperature(skin, device: info.variant, now: now) {
            let status = SharedKeychain.write("skin-temperature", data)
            if status == errSecSuccess {
                sharedSkin = signature
            } else {
                log("Sharing: writing skin temperature failed (\(status))")
            }
        }
        let hrv = try store.hrv(from: now - SharedKeychain.retentionSeconds)
        let hrvSignature = hrv.flatMap { [$0.hour, $0.version] }
        if hrvSignature != sharedHRV, !hrv.isEmpty, let data = SharedKeychain.hrv(hrv, device: info.variant, now: now) {
            let status = SharedKeychain.write("hrv", data)
            if status == errSecSuccess {
                sharedHRV = hrvSignature
            } else {
                log("Sharing: writing HRV failed (\(status))")
            }
        }
        let shared = Set(SharedKeychain.accounts())
        let cutoff = now - SharedKeychain.retentionSeconds
        for e in try store.ecgRecordings(since: cutoff) where !shared.contains(e.account) {
            publish(e)
        }
        for account in shared where account.hasPrefix("ecg.") {
            if let start = Int(account.dropFirst(4)), start < cutoff { SharedKeychain.delete(account) }
        }
    }

    private func publish(_ e: EcgRecording) {
        guard let data = SharedKeychain.ecg(e, device: info.variant) else { return }
        let status = SharedKeychain.write(e.account, data)
        if status != errSecSuccess { log("Sharing: writing \(e.account) failed (\(status))") }
    }

    // MARK: - ECG

    var ecgBusy: Bool { [.starting, .recording, .saving].contains(ecgPhase) }

    /// Starts an on-demand ECG: wrist, live filtered output, then generation, a moment apart.
    func startEcg(wrist: Ecg.Wrist) {
        guard !ecgBusy else { return }
        guard strap.isBonded else { return ecgPhase = .failed("Pair the strap first: ECG needs the full pairing.") }
        guard !downloading else { return ecgPhase = .failed("A history download is running. Try again in a minute.") }
        guard strap.beginEcg() else { return ecgPhase = .failed("The strap isn't ready yet. Try again in a moment.") }
        recorder = EcgRecorder()
        ecgWrist = wrist
        ecgStatus = nil
        ecgLive = []
        ecgDeadline = nil
        ecgDone = false
        ecgRestarted = false
        ecgLastProgress = 0
        ecgStartedAt = Date()
        ecgPhase = .starting
        log("ECG: starting (\(wrist.name) wrist)")
        for (i, step) in Ecg.startSequence(wrist: wrist).enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4 * Double(i)) { [weak self] in
                guard let self, self.ecgPhase == .starting else { return }
                self.strap.sendEcg(step.cmd, payload: step.payload)
            }
        }
        ecgWatchdog?.invalidate()
        ecgWatchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.ecgTick() }
        }
    }

    func cancelEcg() {
        guard ecgBusy else { return }
        if recorder?.completedAt != nil {
            // Already complete: keep it.
            finishEcg(stop: true, failure: nil)
        } else {
            log("ECG: cancelled")
            finishEcg(stop: true, failure: nil, save: false)
        }
    }

    /// Back to the how-to screen, unless a recording is running.
    func resetEcg() {
        guard !ecgBusy else { return }
        ecgPhase = .idle
        ecgDone = false
        ecgDeadline = nil
    }

    private func handleEcgResponse(cmd: UInt8, result: UInt8) {
        guard ecgPhase == .starting || ecgPhase == .recording else { return }
        if cmd == Ecg.Command.generation.rawValue, ecgPhase == .starting, result != 1 && result != 2 {
            finishEcg(stop: true, failure: "The strap refused to start an ECG (result \(result)). ECG needs a WHOOP MG.")
        }
    }

    private func handleEcgRecord(_ r: Ecg.FilteredRecord, at: Double) {
        guard let recorder, ecgPhase == .starting || ecgPhase == .recording else { return }
        if ecgPhase == .starting {
            ecgPhase = .recording
            log("ECG: waveform arriving")
        }
        recorder.add(r, at: at)
        ecgStatus = r.status
        ecgLive = Array(recorder.samples.suffix(Int((recorder.sampleRateHz ?? 100) * 5)))
        updateCountdown(progress: r.status.progress)
    }

    private func updateCountdown(progress: Int) {
        defer { ecgLastProgress = progress }
        guard !ecgDone else { return }
        if progress >= 100 {
            // Done: say so straight away, then stop and save a moment later.
            ecgDone = true
            ecgDeadline = Date()
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            log("ECG: complete")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, self.ecgPhase == .recording else { return }
                self.finishEcg(stop: true, failure: nil)
            }
        } else if progress > 0 {
            let target = Date().addingTimeInterval(Double(Ecg.lengthSeconds) * Double(100 - progress) / 100)
            let restarted = progress < ecgLastProgress - 5
            if ecgDeadline == nil || restarted || abs(ecgDeadline!.timeIntervalSince(target)) > 2 {
                ecgDeadline = target
            }
            ecgRestarted = false
        } else if ecgLastProgress > 0 {
            // The strap fell back to 0: the countdown starts over once the signal is clean again.
            ecgDeadline = nil
            ecgRestarted = true
        }
    }

    /// Once a second while an ECG runs: finish when it's done, give up when nothing comes.
    private func ecgTick() {
        guard ecgBusy, let recorder else {
            ecgWatchdog?.invalidate()
            return
        }
        let elapsed = Date().timeIntervalSince(ecgStartedAt)
        let now = Date().timeIntervalSince1970
        if recorder.records == 0 && elapsed > 20 {
            finishEcg(stop: true, failure: "No ECG data arrived. ECG needs a WHOOP MG (a 5.0 has no ECG electrodes).")
        } else if ecgDone {
            // Finishing (scheduled when the strap reached 100).
        } else if let lost = recorder.contactLostSince, now - lost > 15 {
            finishEcg(stop: true, failure: "Lost contact with the clasp. Keep your thumb and finger on its two indents until the countdown ends.",
                      save: false)
        } else if elapsed > 90 {
            finishEcg(stop: true, failure: recorder.hadContact
                      ? "The signal stayed too weak to finish. Sit down, rest your arm on a table, press the clasp's two indents gently but firmly, and keep still and quiet."
                      : "The strap never felt your finger. Put your thumb and index finger on the two indents on the clasp.",
                      save: false)
        }
    }

    private func finishEcg(stop: Bool, failure: String?, save: Bool = true) {
        ecgWatchdog?.invalidate()
        if stop {
            for (i, step) in Ecg.stopSequence.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3 * Double(i)) { [weak self] in
                    self?.strap.sendEcg(step.cmd, payload: step.payload)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in self?.strap.endEcg() }
        } else {
            strap.endEcg()
        }
        defer { recorder = nil }
        // Only complete recordings are kept; the raw archive still holds every attempt for diagnosis.
        guard save, let r = recorder, r.completedAt != nil, let first = r.first, let last = r.last, r.samples.count >= 200 else {
            if let failure, let r = recorder {
                log("ECG: \(failure) (\(r.records) records, best progress \(r.maxProgress), contact \(r.hadContact), last quality \(r.status?.quality ?? 0))")
            }
            ecgPhase = failure.map { .failed($0) } ?? .finished(saved: false)
            return
        }
        let recording = withHeartRate(EcgRecording(start: Int(first), end: Int(last.rounded(.up)), wrist: ecgWrist.name,
                                                   heartRate: nil, hrvRaw: r.hrvRaw, progress: r.status?.progress ?? 0,
                                                   quality: r.status?.quality ?? 0, classifier: r.status?.classifier ?? 0,
                                                   sampleRateHz: r.sampleRateHz, samples: r.samples),
                                      strap: r.heartRate)
        do {
            try store?.save(recording)
            // Its hour is planned again, so the heart-rate sample of its first minute carries it into Health.
            try store?.markDirty([recording.start])
            publish(recording)
            log("""
                ECG: saved \(recording.samples.count) samples over \(recording.end - recording.start) s \
                (~\(Int(recording.sampleRateHz ?? 0)) Hz), progress \(recording.progress), \
                HR \(recording.heartRate.map { "\($0) (\(recording.heartRateSource ?? ""))" } ?? "none")
                """)
            ecgPhase = .finished(saved: true)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch {
            ecgPhase = .failed("Saving the ECG failed: \(error)")
        }
        loadEcgRecordings()
        if let failure { log("ECG: \(failure)") }
    }

    /// The strap's heart rate, else the trace's if it agrees with the optical one, else the optical one.
    private func withHeartRate(_ e: EcgRecording, strap: Int?) -> EcgRecording {
        let rate = e.sampleRateHz ?? 100
        // The last 30 s are the counted stretch, after the strap settled.
        let trace = EcgBeats.heartRate(Array(e.samples.suffix(Int(rate * Double(Ecg.lengthSeconds + 2)))), rateHz: rate)
        let optical = try? store?.meanLiveHeartRate(from: e.start, to: e.end)
        guard let chosen = EcgBeats.choose(strap: strap, trace: trace, optical: optical ?? nil) else { return e }
        return EcgRecording(start: e.start, end: e.end, wrist: e.wrist, heartRate: chosen.bpm, hrvRaw: e.hrvRaw,
                            progress: e.progress, quality: e.quality, classifier: e.classifier,
                            sampleRateHz: e.sampleRateHz, samples: e.samples, heartRateSource: chosen.source)
    }

    func loadEcgRecordings() {
        ecgRecordings = (try? store?.ecgRecordings(limit: 20)) ?? []
    }

    // MARK: - Background flush

    nonisolated static var flushTaskId: String { (Bundle.main.bundleIdentifier ?? "WhoopSync") + ".flush" }

    /// Registers the fallback wake. Must run before launch finishes.
    nonisolated static func registerBackgroundFlush() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: flushTaskId, using: nil) { task in
            scheduleBackgroundFlush()
            let work = Task { @MainActor in
                AppModel.shared.aggregate()
                await AppModel.shared.flush()
                task.setTaskCompleted(success: true)
            }
            task.expirationHandler = { work.cancel() }
        }
    }

    nonisolated static func scheduleBackgroundFlush() {
        let request = BGAppRefreshTaskRequest(identifier: flushTaskId)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}

#if DEBUG
// MARK: - Demo

extension AppModel {
    /// Plays a paired strap's events over Demo's made-up day (Demo.swift), for screenshots in the Simulator.
    /// Its samples go to the outbox like any others, so Apple Health gets them once it's connected.
    private func playDemo() {
        let now = Int(Date().timeIntervalSince1970)
        guard let store, let day = Demo.Day(now: now) else { return }
        for event: StrapLink.Event in [.state(.connected), .pairing(.bonded), .info(Demo.info), .battery(76), .clockOffset(0)] {
            handle(event)
        }
        do {
            try store.plan(day.samples)
            for e in day.ecgs { try store.save(e) }
        } catch {
            log("Demo: \(error)")
        }
        lastNight = day.night
        lastStages = day.stages
        _ = stager  // loads the sleep model, which logs its version
        skinTemp = (33.7, Date(timeIntervalSinceNow: -240))
        loadEcgRecordings()
        // Live heart rate about once a second, as the strap sends it.
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                let now = Int(Date().timeIntervalSince1970)
                guard let m = HeartRateMeasurement.parse([0x06, UInt8(60 + now % 3)]) else { return }
                self?.handle(.liveHR(m, at: now))
            }
        }
        handle(.historyStarted)
        handle(.historyFinished(ok: true, chunks: 3, records: 912))
    }
}
#endif
