/// A span whose night samples (sleep, resting heart rate, breathing) this app wrote to Health must be deleted there
/// before the night is written again. A rewritten night's earlier samples can have other sync identifiers (an
/// interval that moved, an hour of breathing dropped, plain "asleep" replaced by stages), so only a delete by time
/// range removes them all.
public struct NightClear: Hashable {
    public let start: Int
    public let end: Int

    public init(start: Int, end: Int) {
        self.start = start; self.end = end
    }

    /// A night's clear: two hours either side of it, for an earlier version of it that ran longer.
    public init(night start: Int, _ end: Int) {
        self.init(start: start - 7200, end: end + 7200)
    }

    /// The kinds a clear deletes: a night's own samples.
    public static let kinds: Set<PlannedSample.Kind> = [.sleep, .restingHR, .respiratoryRate]

    /// Whether this clear can delete the sample from Health: one of `kinds` overlapping the span. The ends count
    /// too, so this errs towards holding a sample back until the clear has run.
    public func covers(_ s: PlannedSample) -> Bool {
        Self.kinds.contains(s.kind) && s.start <= end && s.end >= start
    }

    /// Of the samples already written that this clear covers, the ones to write again once it has run: those of
    /// another night, starting within one of `neighbours`. A night less than two hours from the one being staged
    /// would otherwise lose its samples at that end. The rest start outside any night as it is now: left by an
    /// earlier version of one, they're the clear's to delete.
    public func rewrites(_ written: [PlannedSample], neighbours: [Range<Int>]) -> [PlannedSample] {
        written.filter { s in covers(s) && neighbours.contains { $0.contains(s.start) } }
    }
}

/// What `HealthFlush` needs from the outbox. The app's `Store` keeps it in SQLite.
public protocol FlushOutbox: AnyObject {
    /// The clears still to run, oldest first.
    func clears() throws -> [NightClear]
    func removeClear(_ clear: NightClear) throws
    /// Up to `limit` unwritten samples of these kinds, oldest first, as Health is given them, leaving out every
    /// sample a pending clear covers (`NightClear.covers`): those wait until it has run.
    func unwritten(limit: Int, kinds: Set<PlannedSample.Kind>) throws -> [PlannedSample]
    /// Marks exactly these versions written, so a newer version planned meanwhile still goes out.
    func markWritten(_ samples: [PlannedSample]) throws
}

/// Writes the outbox to Apple Health in an order that can't lose a night's samples to a clear, however staging
/// (`AppModel.processNights`) and the flush interleave.
///
/// Both run on the main actor, so staging can only run while the flush waits: on a clear's delete, or on a batch's
/// save. On 13 Nov 2026 a flush ran the clears it had read at its start, then saved batches for 11 seconds. Two
/// nights were staged during the save: the loop saved their new samples, and the next flush ran their clears, which
/// deleted those samples from Health. Already marked written, they were never saved again. Three rules make that
/// impossible:
///
/// 1. Staging registers a night's clear and puts its new samples in the outbox in one transaction
///    (`Store.stageNight`), so the samples are never there without their clear. The same transaction marks
///    unwritten the samples of nearby nights the clear will delete too (`NightClear.rewrites`).
/// 2. Before each batch every pending clear runs, read again each time, so one registered during a delete runs
///    too. The batch is read only once none is left, and its save starts with no await in between, so nothing
///    is staged between the two. If a clear fails, the outbox holds back the samples it covers
///    (`FlushOutbox.unwritten`), the rest are written, and the next flush tries the clear again.
/// 3. Staging doesn't run while a batch is being saved (`saving`); it runs again once the flush has finished.
///
/// So a clear is never registered with a save under way, and by 2, no sample it covers is saved until it has
/// run: its delete removes only samples saved before it was registered, which it's there to remove. Re-registering
/// a span whose delete is under way adds nothing: no save runs during a delete, so that delete already removes
/// everything the app had in the span.
///
/// Letting staging run during a save, and marking unwritten afterwards whatever a clear deleted after it was saved,
/// would need to know which of those samples are still wanted. The outbox can't tell: it can still hold rows a
/// night's rewrite superseded under other identifiers (written by earlier builds, or outside the night as it is
/// now), which the clear is there to remove.
@MainActor
public final class HealthFlush {
    /// A batch is being saved, until it's marked written or the save fails. Staging waits while this is true.
    public private(set) var saving = false
    /// A flush is under way; another one returns at once.
    public private(set) var running = false

    public struct Outcome {
        public var saved = 0
        /// A clear's delete failed: the samples it covers wait for the next flush.
        public var clearError: Error?
        /// Reading the outbox failed: nothing more was written.
        public var readError: Error?
        /// A save (or marking it written) failed: what's left waits for the next flush.
        public var saveError: Error?
    }

    public init() {}

    /// Runs the pending clears and saves every unwritten sample of `kinds` in batches, by the rules above.
    /// `clear` deletes the app's samples in a span from Health, `save` saves a batch there.
    public func run(_ outbox: some FlushOutbox, kinds: Set<PlannedSample.Kind>, batchSize: Int = 500,
                    clear: (NightClear) async throws -> Void,
                    save: ([PlannedSample]) async throws -> Void) async -> Outcome {
        var out = Outcome()
        guard !running else { return out }
        running = true
        defer { running = false }
        var clearing = true
        while true {
            if clearing {
                do {
                    while let next = try outbox.clears().first {
                        try await clear(next)
                        try outbox.removeClear(next)
                    }
                } catch {
                    out.clearError = error
                    clearing = false
                }
            }
            // No await from here until the save starts.
            let batch: [PlannedSample]
            do {
                batch = try outbox.unwritten(limit: batchSize, kinds: kinds)
            } catch {
                out.readError = error
                break
            }
            guard !batch.isEmpty else { break }
            saving = true
            do {
                try await save(batch)
                try outbox.markWritten(batch)
                saving = false
                out.saved += batch.count
            } catch {
                // Typically the phone is locked (errorDatabaseInaccessible). The rows stay in the outbox.
                saving = false
                out.saveError = error
                break
            }
        }
        return out
    }
}
