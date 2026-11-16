import Foundation
import SyncCore

/// A night's sleep stages, one per 30 s from `start`.
struct StagedNight: Equatable {
    let start: Int
    let end: Int
    let stages: [SleepStage]

    func minutes(_ stage: SleepStage) -> Int { stages.filter { $0 == stage }.count / 2 }
}

/// The local buffer between the strap and Apple Health.
///
/// - `hr` / `rr`: beats, live and from history, kept for two weeks.
/// - `dirty`: clock hours with new beats that still need turning into samples.
/// - `outbox`: planned Health samples; `written` flips to 1 once Health has saved that version. `version` is the
///   sync version Health is given; `basis` is the version the data was planned with, lower once Strap Sync's own
///   metadata (`meta`, JSON) has changed by itself (`Outbox.merge`). `zone` is the time zone the sample was
///   recorded in (HKMetadataKeyTimeZone), from `zones` when the row is first stored, and kept through rewrites;
///   null in rows from before it, and where the zone isn't known.
/// - `zones`: the phone's time zone from each instant it was seen in a new one (`ZoneHistory`), `source` "recorded";
///   and before the first of those, reconstructed from the logs (`ZoneLog`), `source` "logs". A null `id` means
///   not known from then. The owner's `time-zones.json` (`ZoneFile`) isn't stored: it's read at each launch.
/// - `clears`: spans whose night samples must be deleted from Health before a night is written there again
///   (`stageNight`, `HealthFlush`).
/// - `stages`: each night's sleep stages, also written to Health in place of plain "asleep".
/// - `hrv`: each hour's HRV window as SDNN and RMSSD, shared with Health Dashboard.
/// - `ppg`: R26 optical seconds, the strap's 25 Hz optical bursts, kept as they are for later study.
/// - `banked`: history records of layouts nothing decodes yet, whole, for later study.
///
/// Tables and migrations are only ever added, never changed, so any build of the app can open a database any
/// other build made; a table a build no longer creates stays in databases that have it. A build's own sources add their tables themselves (`IF NOT EXISTS`).
///
/// History chunks are saved in one transaction before the strap is told it can delete them.
final class Store: FlushOutbox {
    /// Not private, so a build's own sources can keep their own tables (PersonalHooks, docs/DEVELOPMENT.md).
    let db: SQLiteDB

    /// The app's store, or one in `directory` (the Simulator's zone check, ZoneCheck.swift).
    init(directory: URL? = nil) throws {
        let fm = FileManager.default
        let dir = try directory ?? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("WhoopSync", isDirectory: true)
        // Writable while the phone is locked: Bluetooth wakes the app then.
        try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                               attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        db = try SQLiteDB(path: dir.appendingPathComponent("sync.sqlite").path)
        try db.exec("""
            CREATE TABLE IF NOT EXISTS hr (ts INTEGER NOT NULL, source INTEGER NOT NULL, bpm INTEGER NOT NULL,
                PRIMARY KEY (ts, source)) WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS rr (ts INTEGER NOT NULL, source INTEGER NOT NULL, idx INTEGER NOT NULL,
                ms INTEGER NOT NULL, PRIMARY KEY (ts, source, idx)) WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS dirty (hour INTEGER PRIMARY KEY);
            CREATE TABLE IF NOT EXISTS outbox (sync_id TEXT PRIMARY KEY, kind INTEGER NOT NULL,
                start INTEGER NOT NULL, end INTEGER NOT NULL, value REAL NOT NULL, version INTEGER NOT NULL,
                written INTEGER NOT NULL DEFAULT 0);
            CREATE INDEX IF NOT EXISTS outbox_unwritten ON outbox (written, start);
            CREATE TABLE IF NOT EXISTS motion (ts INTEGER PRIMARY KEY, bpm INTEGER NOT NULL, steps INTEGER NOT NULL,
                step_sw INTEGER NOT NULL, state INTEGER NOT NULL, motion REAL, skin REAL, spo2 INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE IF NOT EXISTS minutes (minute INTEGER PRIMARY KEY, records INTEGER NOT NULL,
                worn INTEGER NOT NULL, hr REAL, motion REAL, sleep_flag INTEGER NOT NULL, skin REAL);
            CREATE TABLE IF NOT EXISTS kv (key TEXT PRIMARY KEY, value INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS ecg (start INTEGER PRIMARY KEY, end INTEGER NOT NULL, wrist TEXT NOT NULL,
                heart_rate INTEGER, hrv_raw INTEGER, progress INTEGER NOT NULL, quality INTEGER NOT NULL,
                classifier INTEGER NOT NULL, rate REAL, samples TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS clears (start INTEGER NOT NULL, end INTEGER NOT NULL, PRIMARY KEY (start, end));
            CREATE TABLE IF NOT EXISTS stages (start INTEGER PRIMARY KEY, end INTEGER NOT NULL, model TEXT NOT NULL,
                epochs TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS hrv (hour INTEGER PRIMARY KEY, start INTEGER NOT NULL, sdnn REAL NOT NULL, rmssd REAL,
                version INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS ppg (ts INTEGER PRIMARY KEY, base INTEGER NOT NULL, deltas BLOB NOT NULL,
                motion REAL, status INTEGER NOT NULL, on_wrist INTEGER NOT NULL, acceptance INTEGER NOT NULL,
                burst INTEGER NOT NULL, aux INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS banked (layout INTEGER NOT NULL, ts INTEGER NOT NULL, frame BLOB NOT NULL,
                PRIMARY KEY (layout, ts)) WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS zones (since INTEGER PRIMARY KEY, id TEXT, source TEXT);
            """)
        // Added after the first install; fails harmlessly when the column is already there.
        try? db.exec("ALTER TABLE motion ADD COLUMN spo2 INTEGER NOT NULL DEFAULT 0")
        try? db.exec("ALTER TABLE ecg ADD COLUMN hr_source TEXT")
        // Null in rows from before: their basis is their version, and they carry no metadata.
        try? db.exec("ALTER TABLE outbox ADD COLUMN basis INTEGER")
        try? db.exec("ALTER TABLE outbox ADD COLUMN meta TEXT")
        // Null in rows from before: Health has them with the zone the phone had when each was written.
        try? db.exec("ALTER TABLE outbox ADD COLUMN zone TEXT")
        for axis in ["gx", "gy", "gz"] { try? db.exec("ALTER TABLE motion ADD COLUMN \(axis) REAL") }
        for r in try db.query("SELECT since, id, source FROM zones") {
            let entry = ZoneHistory.Entry(since: r[0].int ?? 0, zone: r[1].text)
            if r[2].text == ZoneHistory.Source.logs.rawValue { logZones.append(entry) } else { recordedZones.add(entry) }
        }
        updateZones()
    }

    // MARK: Time zones

    /// The phone's time zone over time, as in effect (`ZoneHistory.effective`); a sample's zone is the one at its start.
    private(set) var zones = ZoneHistory()
    /// The same, with where each stretch comes from.
    private(set) var zonePeriods: [ZoneHistory.Period] = []
    private var recordedZones = ZoneHistory()
    private var logZones: [ZoneHistory.Entry] = []
    /// The owner's time-zones.json, once read (AppModel.readZoneFile).
    private var zoneFile: ZoneFile?

    private func updateZones() {
        zonePeriods = ZoneHistory.effective(recorded: recordedZones.entries, logs: logZones, file: zoneFile)
        zones = ZoneHistory(zonePeriods)
    }

    /// The first zone the app recorded itself.
    var firstRecordedZone: ZoneHistory.Entry? { recordedZones.entries.first }

    /// Records the phone's zone at `t` if it isn't the latest one already. Returns the entry added.
    @discardableResult
    func recordZone(_ id: String, at t: Int) throws -> ZoneHistory.Entry? {
        guard let entry = recordedZones.observing(id, at: t) else { return nil }
        try db.run("INSERT OR REPLACE INTO zones (since, id, source) VALUES (?, ?, ?)",
                   [[.int(entry.since), .text(id), .text(ZoneHistory.Source.recorded.rawValue)]])
        recordedZones.add(entry)
        updateZones()
        return entry
    }

    /// Adds the zones reconstructed from the logs for the time before the first one recorded. Returns those added.
    func addPastZones(_ past: [ZoneHistory.Entry]) throws -> [ZoneHistory.Entry] {
        let added = recordedZones.before(past)
        try db.transaction {
            try db.run("INSERT OR IGNORE INTO zones (since, id, source) VALUES (?, ?, ?)", added.map {
                [.int($0.since), $0.zone.map { .text($0) } ?? .null, .text(ZoneHistory.Source.logs.rawValue)]
            })
        }
        logZones += added
        updateZones()
        return added
    }

    /// The owner's time-zones.json, or nil without one (or with one that was ignored).
    func setZoneFile(_ file: ZoneFile?) {
        zoneFile = file
        updateZones()
    }

    // MARK: Strap records (steps, sleep, temperature)

    private static let motionColumns = "ts, bpm, steps, step_sw, state, motion, skin, spo2, gx, gy, gz"

    func motion(hour: Int) throws -> [MotionPoint] {
        try motion(from: hour, to: hour + 3600)
    }

    func motion(from start: Int, to end: Int) throws -> [MotionPoint] {
        try db.query("SELECT \(Self.motionColumns) FROM motion WHERE ts >= ? AND ts < ? ORDER BY ts",
                     [.int(start), .int(end)]).map(motionPoint)
    }

    /// The record just before `ts`, the baseline for the first step delta of an hour.
    func motion(before ts: Int) throws -> MotionPoint? {
        try db.query("SELECT \(Self.motionColumns) FROM motion WHERE ts < ? ORDER BY ts DESC LIMIT 1",
                     [.int(ts)]).first.map(motionPoint)
    }

    private func motionPoint(_ r: [SQLiteDB.Value]) -> MotionPoint {
        let g = r[8...10].compactMap(\.double)
        return MotionPoint(ts: r[0].int ?? 0, bpm: r[1].int ?? 0, stepCounter: r[2].int ?? 0, stepSoftware: r[3].int == 1,
                           bandState: r[4].int ?? 0, motion: r[5].double, skinTempC: r[6].double, spo2Raw: r[7].int ?? 0,
                           gravity: g.count == 3 ? SIMD3(g) : nil)
    }

    func saveMinutes(_ minutes: [MinuteSummary]) throws {
        func opt(_ d: Double?) -> SQLiteDB.Value { d.map { .double($0) } ?? .null }
        try db.run("INSERT OR REPLACE INTO minutes (minute, records, worn, hr, motion, sleep_flag, skin) VALUES (?, ?, ?, ?, ?, ?, ?)",
                   minutes.map { [.int($0.minute), .int($0.records), .int($0.worn), opt($0.meanHR), opt($0.motion),
                                  .int($0.sleepFlag), opt($0.skinTempC)] })
    }

    /// The first stored minute from `from` on, if any.
    func firstMinute(from: Int) throws -> Int? {
        try db.query("SELECT MIN(minute) FROM minutes WHERE minute >= ?", [.int(from)]).first?[0].int
    }

    func minutes(from: Int, to: Int = .max) throws -> [MinuteSummary] {
        try db.query("SELECT minute, records, worn, hr, motion, sleep_flag, skin FROM minutes WHERE minute >= ? AND minute < ? ORDER BY minute",
                     [.int(from), .int(to)])
            .map { MinuteSummary(minute: $0[0].int ?? 0, records: $0[1].int ?? 0, worn: $0[2].int ?? 0, meanHR: $0[3].double,
                                 motion: $0[4].double, sleepFlag: $0[5].int ?? 0, skinTempC: $0[6].double) }
    }

    func intervals(from: Int, to: Int, source: Source) throws -> [RRPoint] {
        try db.query("SELECT ts, idx, ms FROM rr WHERE ts >= ? AND ts < ? AND source = ? ORDER BY ts, idx",
                     [.int(from), .int(to), .int(source.rawValue)])
            .map { RRPoint(ts: $0[0].int ?? 0, idx: $0[1].int ?? 0, ms: $0[2].int ?? 0) }
    }

    /// The strap's in-band SpO2 readings (byte 82, 70–100) since `from`.
    func spo2Readings(from: Int) throws -> [(ts: Int, raw: Int)] {
        try db.query("SELECT ts, spo2 FROM motion WHERE ts >= ? AND spo2 BETWEEN 70 AND 100 ORDER BY ts", [.int(from)])
            .map { (ts: $0[0].int ?? 0, raw: $0[1].int ?? 0) }
    }

    // MARK: ECG

    func save(_ e: EcgRecording) throws {
        let samples = String(decoding: try JSONEncoder().encode(e.samples), as: UTF8.self)
        func opt(_ v: Int?) -> SQLiteDB.Value { v.map { .int($0) } ?? .null }
        try db.run("""
            INSERT OR REPLACE INTO ecg (start, end, wrist, heart_rate, hrv_raw, progress, quality, classifier, rate, samples, hr_source)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [[.int(e.start), .int(e.end), .text(e.wrist), opt(e.heartRate), opt(e.hrvRaw), .int(e.progress),
                   .int(e.quality), .int(e.classifier), e.sampleRateHz.map { .double($0) } ?? .null, .text(samples),
                   e.heartRateSource.map { .text($0) } ?? .null]])
    }

    /// Mean optical (live) heart rate between two times, for an ECG with no heart rate of its own.
    func meanLiveHeartRate(from: Int, to: Int) throws -> Int? {
        try db.query("SELECT AVG(bpm) FROM hr WHERE ts >= ? AND ts <= ? AND source = ?",
                     [.int(from), .int(to), .int(Source.live.rawValue)]).first?[0].double.map { Int($0.rounded()) }
    }

    /// Deletes recordings that never reached 100 % and returns their start times.
    func deleteIncompleteEcgs() throws -> [Int] {
        let starts = try db.query("SELECT start FROM ecg WHERE progress < 100").compactMap { $0[0].int }
        try db.run("DELETE FROM ecg WHERE progress < 100")
        return starts
    }

    /// Newest first, starting in [since, until).
    func ecgRecordings(since: Int = 0, until: Int = .max, limit: Int = 50) throws -> [EcgRecording] {
        try db.query("""
            SELECT start, end, wrist, heart_rate, hrv_raw, progress, quality, classifier, rate, samples, hr_source
            FROM ecg WHERE start >= ? AND start < ? ORDER BY start DESC LIMIT ?
            """, [.int(since), .int(until), .int(limit)]).map { r in
            EcgRecording(start: r[0].int ?? 0, end: r[1].int ?? 0, wrist: r[2].text ?? "", heartRate: r[3].int,
                         hrvRaw: r[4].int, progress: r[5].int ?? 0, quality: r[6].int ?? 0, classifier: r[7].int ?? 0,
                         sampleRateHz: r[8].double,
                         samples: (try? JSONDecoder().decode([Int].self, from: Data((r[9].text ?? "[]").utf8))) ?? [],
                         heartRateSource: r[10].text)
        }
    }

    // MARK: HRV windows

    /// Saves each hour's window, replacing a stored one only when the version is higher, as `plan` does.
    func saveHRV(_ hours: [Aggregator.HourlyHRV]) throws {
        try db.run("""
            INSERT INTO hrv (hour, start, sdnn, rmssd, version) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT (hour) DO UPDATE SET start = excluded.start, sdnn = excluded.sdnn, rmssd = excluded.rmssd,
                version = excluded.version
            WHERE excluded.version > hrv.version
            """, hours.map { [.int($0.hour), .int($0.start), .double($0.sdnn), $0.rmssd.map { .double($0) } ?? .null, .int($0.version)] })
    }

    func hrv(from: Int) throws -> [Aggregator.HourlyHRV] {
        try db.query("SELECT hour, start, sdnn, rmssd, version FROM hrv WHERE hour >= ? ORDER BY hour", [.int(from)]).map {
            Aggregator.HourlyHRV(hour: $0[0].int ?? 0, start: $0[1].int ?? 0, sdnn: $0[2].double ?? 0, rmssd: $0[3].double, version: $0[4].int ?? 0)
        }
    }

    /// Clock hours with beats since `from`, for computing HRV windows over stored beats.
    func beatHours(from: Int) throws -> [Int] {
        try db.query("SELECT DISTINCT ts - ts % 3600 FROM rr WHERE ts >= ? ORDER BY 1", [.int(from)]).compactMap { $0[0].int }
    }

    // MARK: Sleep stages

    /// The model version a night was staged with, if it has been.
    /// Whether this model has already staged a night overlapping [start, end).
    func hasStages(model: String, overlapping start: Int, _ end: Int) throws -> Bool {
        try !db.query("SELECT 1 FROM stages WHERE model = ? AND start < ? AND end > ? LIMIT 1",
                      [.text(model), .int(end), .int(start)]).isEmpty
    }

    /// Whether this model's stages already span [start, end): a night that grew at either end (back asleep
    /// after getting up, or started earlier) needs staging again.
    func stagesCover(model: String, _ start: Int, _ end: Int) throws -> Bool {
        try !db.query("SELECT 1 FROM stages WHERE model = ? AND start <= ? AND end >= ? LIMIT 1",
                      [.text(model), .int(start), .int(end)]).isEmpty
    }

    /// Drops stages overlapping a span, before a night that grew is staged again.
    func deleteStages(overlapping start: Int, _ end: Int) throws {
        try db.run("DELETE FROM stages WHERE start < ? AND end > ?", [[.int(end), .int(start)]])
    }

    /// One stage per 30 s from `start`, kept as a string of digits (SleepStage raw values).
    func saveStages(start: Int, end: Int, model: String, stages: [SleepStage]) throws {
        try db.run("INSERT OR REPLACE INTO stages (start, end, model, epochs) VALUES (?, ?, ?, ?)",
                   [[.int(start), .int(end), .text(model), .text(stages.map { String($0.rawValue) }.joined())]])
    }

    /// Forgets every night's stages, so they're all staged (and written to Health) again.
    func clearStages() throws {
        try db.run("DELETE FROM stages")
    }

    func latestStages() throws -> StagedNight? {
        try db.query("SELECT start, end, epochs FROM stages ORDER BY start DESC LIMIT 1").first.map { r in
            StagedNight(start: r[0].int ?? 0, end: r[1].int ?? 0,
                        stages: (r[2].text ?? "").compactMap { $0.wholeNumberValue.flatMap(SleepStage.init(rawValue:)) })
        }
    }

    func value(_ key: String) throws -> Int? {
        try db.query("SELECT value FROM kv WHERE key = ?", [.text(key)]).first?[0].int
    }

    func setValue(_ key: String, _ value: Int) throws {
        try db.run("INSERT OR REPLACE INTO kv (key, value) VALUES (?, ?)", [[.text(key), .int(value)]])
    }

    func insertLive(ts: Int, bpm: Int, rrMs: [Int]) throws {
        try db.transaction {
            try db.run("INSERT OR REPLACE INTO hr (ts, source, bpm) VALUES (?, ?, ?)",
                       [[.int(ts), .int(Source.live.rawValue), .int(bpm)]])
            try db.run("""
                INSERT INTO rr (ts, source, idx, ms) VALUES
                (?, ?, (SELECT COALESCE(MAX(idx) + 1, 0) FROM rr WHERE ts = ? AND source = ?), ?)
                """, rrMs.map { [.int(ts), .int(Source.live.rawValue), .int(ts), .int(Source.live.rawValue), .int($0)] })
            try markDirty([ts])
        }
    }

    func save(_ chunk: HistoryChunk) throws {
        let src = SQLiteDB.Value.int(Source.history.rawValue)
        try db.transaction {
            try db.run("INSERT OR REPLACE INTO hr (ts, source, bpm) VALUES (?, ?, ?)",
                       chunk.hr.map { [.int($0.ts), src, .int($0.bpm)] })
            try db.run("INSERT OR REPLACE INTO rr (ts, source, idx, ms) VALUES (?, ?, ?, ?)",
                       chunk.rr.map { [.int($0.ts), src, .int($0.idx), .int($0.ms)] })
            try db.run("INSERT OR REPLACE INTO motion (\(Self.motionColumns)) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                       chunk.motion.map { m in
                           [.int(m.ts), .int(m.bpm), .int(m.stepCounter), .int(m.stepSoftware ? 1 : 0),
                            .int(m.bandState), m.motion.map { .double($0) } ?? .null,
                            m.skinTempC.map { .double($0) } ?? .null, .int(m.spo2Raw)]
                               + (0..<3).map { k in m.gravity.map { .double($0[k]) } ?? .null }
                       })
            try db.run("INSERT OR REPLACE INTO ppg (ts, base, deltas, motion, status, on_wrist, acceptance, burst, aux) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                       chunk.optical.map { r in
                           [.int(r.ts), .int(Int(r.base)), .blob(r.deltaBytes), r.motion.map { .double($0) } ?? .null,
                            .int(r.status), .int(r.onWrist), .int(r.acceptance), .int(r.burstCounter), .int(r.aux)]
                       })
            try db.run("INSERT OR REPLACE INTO banked (layout, ts, frame) VALUES (?, ?, ?)",
                       chunk.banked.map { [.int($0.layout), .int($0.ts), .blob($0.frame)] })
            try markDirty(chunk.motion.map(\.ts))
        }
    }

    // MARK: Optical bursts (R26)

    /// R26 optical seconds in [start, end), oldest first.
    func optical(from start: Int, to end: Int) throws -> [R26Record] {
        try db.query("SELECT ts, base, deltas, motion, status, on_wrist, acceptance, burst, aux FROM ppg WHERE ts >= ? AND ts < ? ORDER BY ts",
                     [.int(start), .int(end)]).compactMap { row in
            guard let deltas = row[2].blob.flatMap(R26Record.deltas(from:)) else { return nil }
            var r = R26Record(ts: row[0].int ?? 0, base: Int32(truncatingIfNeeded: row[1].int ?? 0), deltas: deltas)
            r.motion = row[3].double
            r.status = row[4].int ?? 0
            r.onWrist = row[5].int ?? 0
            r.acceptance = row[6].int ?? 0
            r.burstCounter = row[7].int ?? 0
            r.aux = row[8].int ?? 0
            return r
        }
    }

    func opticalSeconds(since: Int) throws -> Int {
        try db.query("SELECT COUNT(*) FROM ppg WHERE ts >= ?", [.int(since)]).first?[0].int ?? 0
    }

    /// Marks the hours of these times for turning into samples again: new beats, or an ECG to attach.
    func markDirty(_ timestamps: [Int]) throws {
        let hours = Set(timestamps.map { $0 - $0 % 3600 })
        try db.run("INSERT OR IGNORE INTO dirty (hour) VALUES (?)", hours.map { [.int($0)] })
    }

    func dirtyHours() throws -> [Int] {
        try db.query("SELECT hour FROM dirty ORDER BY hour").compactMap { $0[0].int }
    }

    func clearDirty(_ hour: Int) throws {
        try db.run("DELETE FROM dirty WHERE hour = ?", [[.int(hour)]])
    }

    func heartRates(hour: Int, source: Source) throws -> [HRPoint] {
        try db.query("SELECT ts, bpm FROM hr WHERE ts >= ? AND ts < ? AND source = ? ORDER BY ts",
                     [.int(hour), .int(hour + 3600), .int(source.rawValue)])
            .map { HRPoint(ts: $0[0].int ?? 0, bpm: $0[1].int ?? 0) }
    }

    func intervals(hour: Int, source: Source) throws -> [RRPoint] {
        try db.query("SELECT ts, idx, ms FROM rr WHERE ts >= ? AND ts < ? AND source = ? ORDER BY ts, idx",
                     [.int(hour), .int(hour + 3600), .int(source.rawValue)])
            .map { RRPoint(ts: $0[0].int ?? 0, idx: $0[1].int ?? 0, ms: $0[2].int ?? 0) }
    }

    private static let outboxColumns = "kind, sync_id, start, end, value, version, basis, meta, zone"

    private func outboxRow(_ r: [SQLiteDB.Value]) -> Outbox.Row? {
        guard let kind = r[0].int.flatMap(PlannedSample.Kind.init(rawValue:)), let id = r[1].text else { return nil }
        let synced = r[5].int ?? 0
        return Outbox.Row(sample: PlannedSample(kind: kind, syncId: id, start: r[2].int ?? 0, end: r[3].int ?? 0,
                                                value: r[4].double ?? 0, version: r[6].int ?? synced,
                                                metadata: HealthMetadata.decode(r[7].text), zone: r[8].text),
                          syncVersion: synced)
    }

    /// Stores rows unwritten. A row without a zone (a new sample, or one stored before rows kept one) gets the zone
    /// in effect at its start.
    private func saveOutbox(_ rows: [Outbox.Row]) throws {
        try db.run("""
            INSERT OR REPLACE INTO outbox (sync_id, kind, start, end, value, version, basis, meta, zone, written)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
            """, rows.map { r in
                [.text(r.sample.syncId), .int(r.sample.kind.rawValue), .int(r.sample.start), .int(r.sample.end),
                 .double(r.sample.value), .int(r.syncVersion), .int(r.sample.version),
                 HealthMetadata.encode(r.sample.metadata).map { .text($0) } ?? .null,
                 (r.sample.zone ?? zones.zone(at: r.sample.start)).map { .text($0) } ?? .null]
            })
    }

    /// Rows to write again in another zone (`ZoneRedo`), in one transaction: their zone and sync version, unwritten.
    /// Only rows that still have the sync version they were read with: one planned again meanwhile goes out with
    /// its own data and zone anyway. The data's version goes in `basis`, which rows from before metadata didn't
    /// have. Returns how many were changed.
    @discardableResult
    func rezone(_ rewrites: [ZoneRedo.Rewrite]) throws -> Int {
        var changed = 0
        try db.transaction {
            changed = try db.run("UPDATE outbox SET zone = ?, version = ?, basis = ?, written = 0 WHERE sync_id = ? AND version = ?", rewrites.map { w in
                [w.row.sample.zone.map { .text($0) } ?? .null, .int(w.row.syncVersion), .int(w.row.sample.version),
                 .text(w.row.sample.syncId), .int(w.storedVersion)]
            })
        }
        return changed
    }

    /// Every outbox row starting from `from`, by sync identifier.
    func outboxRows(from: Int) throws -> [String: Outbox.Row] {
        var out: [String: Outbox.Row] = [:]
        for r in try db.query("SELECT \(Self.outboxColumns) FROM outbox WHERE start >= ?", [.int(from)]) {
            if let row = outboxRow(r) { out[row.sample.syncId] = row }
        }
        return out
    }

    /// The sync identifiers of the rows starting from `from` that Health has been given.
    func writtenIds(from: Int) throws -> Set<String> {
        Set(try db.query("SELECT sync_id FROM outbox WHERE written = 1 AND start >= ?", [.int(from)]).compactMap { $0[0].text })
    }

    /// How many rows starting from `from` Health has been given.
    func writtenCount(from: Int) throws -> Int {
        try db.query("SELECT COUNT(*) FROM outbox WHERE written = 1 AND start >= ?", [.int(from)]).first?[0].int ?? 0
    }

    /// Goes up each time a night is staged: its clear can delete samples from Health (ZoneRedo waits for it).
    private(set) var stagingGeneration = 0

    /// The stored rows for these sync identifiers, 500 to a query.
    func outboxRows(_ ids: [String]) throws -> [String: Outbox.Row] {
        let unique = Array(Set(ids))
        var out: [String: Outbox.Row] = [:]
        for first in stride(from: 0, to: unique.count, by: 500) {
            let chunk = unique[first..<min(first + 500, unique.count)]
            let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            for r in try db.query("SELECT \(Self.outboxColumns) FROM outbox WHERE sync_id IN (\(marks))", chunk.map { .text($0) }) {
                if let row = outboxRow(r) { out[row.sample.syncId] = row }
            }
        }
        return out
    }

    /// Which of these sync identifiers the outbox has.
    func planned(_ ids: [String]) throws -> Set<String> {
        Set(try outboxRows(ids).keys)
    }

    /// Adds planned samples, replacing a stored one when it has more data, or the same data with other metadata
    /// (`Outbox.merge`), and marking it unwritten. Returns how many it added or replaced.
    @discardableResult
    func plan(_ samples: [PlannedSample]) throws -> Int {
        guard !samples.isEmpty else { return 0 }
        var changed: [String: Outbox.Row] = [:]
        try db.transaction {
            var stored = try outboxRows(samples.map(\.syncId))
            for s in samples {
                guard let row = Outbox.merge(s, over: stored[s.syncId]) else { continue }
                stored[s.syncId] = row
                changed[s.syncId] = row
            }
            try saveOutbox(Array(changed.values))
        }
        return changed.count
    }

    /// Planned samples of one kind starting in [from, to), with the version their data was planned with.
    func planned(_ kind: PlannedSample.Kind, from: Int, to: Int) throws -> [PlannedSample] {
        try db.query("SELECT \(Self.outboxColumns) FROM outbox WHERE kind = ? AND start >= ? AND start < ? ORDER BY start",
                     [.int(kind.rawValue), .int(from), .int(to)]).compactMap(outboxRow).map(\.sample)
    }

    private static let nightKinds = NightClear.kinds.map { String($0.rawValue) }.sorted().joined(separator: ",")

    /// A night written (again) to Health, in one transaction: its clear first (`NightClear`), so Health loses what
    /// the app wrote for it before; then the night's earlier sleep, resting-HR and breathing rows leave the outbox,
    /// all those starting within it whatever their identifiers; the samples of the `neighbours` the clear will
    /// take too are marked unwritten (`NightClear.rewrites`); then its new samples go in, unwritten and whatever
    /// their version. Until the clear has run, `unwritten` holds all of them back (HealthFlush has why).
    func stageNight(start: Int, end: Int, samples: [PlannedSample], neighbours: [Range<Int>]) throws {
        let clear = NightClear(night: start, end)
        stagingGeneration += 1
        try db.transaction {
            try db.run("INSERT OR IGNORE INTO clears (start, end) VALUES (?, ?)", [[.int(clear.start), .int(clear.end)]])
            try db.run("DELETE FROM outbox WHERE kind IN (\(Self.nightKinds)) AND start >= ? AND start < ?", [[.int(start), .int(end)]])
            let written = try db.query("""
                SELECT \(Self.outboxColumns) FROM outbox WHERE written = 1 AND kind IN (\(Self.nightKinds)) AND start <= ? AND end >= ?
                """, [.int(clear.end), .int(clear.start)]).compactMap(outboxRow).map(\.sample)
            try db.run("UPDATE outbox SET written = 0 WHERE sync_id = ?", clear.rewrites(written, neighbours: neighbours).map { [.text($0.syncId)] })
            try saveOutbox(samples.map { Outbox.Row(sample: $0, syncVersion: $0.version) })
        }
    }

    func clears() throws -> [NightClear] {
        try db.query("SELECT start, end FROM clears ORDER BY start, end").map { NightClear(start: $0[0].int ?? 0, end: $0[1].int ?? 0) }
    }

    func removeClear(_ clear: NightClear) throws {
        try db.run("DELETE FROM clears WHERE start = ? AND end = ?", [[.int(clear.start), .int(clear.end)]])
    }

    /// Unwritten samples of the given kinds (the ones Health lets us write), oldest first, as Health is given them:
    /// with their sync version, metadata and zone (the history's at their start for rows stored before rows kept
    /// one). Night samples a pending clear covers wait for it, as `NightClear.covers` says: one of its kinds,
    /// overlapping the span, ends included.
    func unwritten(limit: Int, kinds: Set<PlannedSample.Kind>) throws -> [PlannedSample] {
        guard !kinds.isEmpty else { return [] }
        let list = kinds.map { String($0.rawValue) }.joined(separator: ",")
        return try db.query("""
            SELECT \(Self.outboxColumns) FROM outbox o WHERE written = 0 AND kind IN (\(list))
            AND NOT (kind IN (\(Self.nightKinds)) AND EXISTS (SELECT 1 FROM clears c WHERE o.start <= c.end AND o.end >= c.start))
            ORDER BY start LIMIT ?
            """, [.int(limit)]).compactMap(outboxRow).map { r in
                let s = r.forHealth
                return s.zone == nil ? s.with(zone: zones.zone(at: s.start)) : s
            }
    }

    /// Marks exactly these versions written, so a newer version planned meanwhile still goes out.
    func markWritten(_ samples: [PlannedSample]) throws {
        try db.transaction {
            try db.run("UPDATE outbox SET written = 1 WHERE sync_id = ? AND version = ?",
                       samples.map { [.text($0.syncId), .int($0.version)] })
        }
    }

    func pendingCount() throws -> Int {
        try db.query("SELECT COUNT(*) FROM outbox WHERE written = 0").first?[0].int ?? 0
    }

    /// Written samples per kind since `since`.
    func writtenCounts(since: Int) throws -> [PlannedSample.Kind: Int] {
        var out: [PlannedSample.Kind: Int] = [:]
        for r in try db.query("SELECT kind, COUNT(*) FROM outbox WHERE written = 1 AND end > ? GROUP BY kind", [.int(since)]) {
            if let k = r[0].int.flatMap(PlannedSample.Kind.init(rawValue:)) { out[k] = r[1].int ?? 0 }
        }
        return out
    }

    /// Drops beats and records older than two weeks (once their hour is processed) and written samples older than 30.
    /// Two weeks, not a few days, so nights can be copied off the phone for the sleep-stage research.
    func prune(now: Int) throws {
        let cutoff = now - 14 * 86_400
        for table in ["hr", "rr", "motion"] {
            try db.run("DELETE FROM \(table) WHERE ts < ? AND (ts - ts % 3600) NOT IN (SELECT hour FROM dirty)", [[.int(cutoff)]])
        }
        // A week of skin temperature is shared with Health Dashboard, so minutes stay 8 days; while older nights are
        // staged again (AppModel.processNights), from `restageFrom`, but never past the 14 days of beats.
        let restageFrom = try value("restageFrom") ?? 0
        let keepMinutes = restageFrom > 0 ? min(now - 8 * 86_400, max(restageFrom, cutoff)) : now - 8 * 86_400
        try db.run("DELETE FROM minutes WHERE minute < ?", [[.int(keepMinutes)]])
        try db.run("DELETE FROM ecg WHERE start < ?", [[.int(now - 90 * 86_400)]])
        try db.run("DELETE FROM hrv WHERE hour < ?", [[.int(cutoff)]])
        try db.run("DELETE FROM outbox WHERE written = 1 AND end < ?", [[.int(now - 30 * 86_400)]])
        // ppg is never pruned (~0.3 MB a day): months of optical bursts are worth keeping for study, and once the
        // strap has deleted them nothing can bring them back.
        try db.run("DELETE FROM banked WHERE ts < ?", [[.int(now - 30 * 86_400)]])
    }
}
