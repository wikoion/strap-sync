/// Decides what the outbox keeps for each sync identifier, and the sync version Health is given.
///
/// A planned sample's version grows with its data. Health only replaces a sample when the version goes up, so a
/// sample whose metadata changed while its data didn't (a skin-temperature interval still filling in, the
/// one-time metadata backfill) must go out with a higher version too. Bumping the planned version itself would
/// collide with the data's own: one more reading would then look like nothing new. So the outbox keeps both, the
/// version the data was planned with and the one Health was given, and the second goes up at every rewrite.
public enum Outbox {
    public struct Row: Equatable {
        /// As planned: its `version` is the data's.
        public let sample: PlannedSample
        /// HKMetadataKeySyncVersion as Health has it (or will): at least `sample.version`.
        public let syncVersion: Int

        public init(sample: PlannedSample, syncVersion: Int) {
            self.sample = sample; self.syncVersion = syncVersion
        }

        /// The sample as Health is given it: with the sync version.
        public var forHealth: PlannedSample {
            PlannedSample(kind: sample.kind, syncId: sample.syncId, start: sample.start, end: sample.end, value: sample.value,
                          version: syncVersion, metadata: sample.metadata, zone: sample.zone)
        }
    }

    /// The row to store for `planned`, or nil to keep `stored` as it is:
    /// - more data (a higher version): the new sample, as before metadata existed;
    /// - the same data with other metadata: the new metadata;
    /// - otherwise, or less data: nothing.
    ///
    /// A new row's sync version is above every one Health has had for that identifier, and equals the data's
    /// version until metadata alone has changed.
    ///
    /// A rewrite keeps the stored row's zone, the one the sample was recorded in ([ZoneHistory]), unless the
    /// planned sample brings its own: planners leave it nil, and the outbox fills it in from the zone history.
    public static func merge(_ planned: PlannedSample, over stored: Row?) -> Row? {
        guard let stored else { return Row(sample: planned, syncVersion: planned.version) }
        let moreData = planned.version > stored.sample.version
        let newMetadata = planned.version == stored.sample.version && planned.metadata != stored.sample.metadata
        guard moreData || newMetadata else { return nil }
        return Row(sample: planned.with(zone: planned.zone ?? stored.sample.zone), syncVersion: max(planned.version, stored.syncVersion + 1))
    }
}
