/// Steps from the strap's cumulative R18 step counter, one Health sample per minute with steps.
///
/// The counter is a u16 that wraps, and can reset or switch to a software count (byte 64); a delta
/// across a reset, a switch, a gap over 10 s, or faster than 4 steps a second is dropped rather than
/// guessed. Nobody has checked this counter against the official app's step count yet.
public enum Steps {
    public static func perMinute(_ points: [MotionPoint], previous: MotionPoint?) -> [PlannedSample] {
        let sequence = (previous.map { [$0] } ?? []) + points.sorted { $0.ts < $1.ts }
        var byMinute: [Int: (steps: Int, pairs: Int)] = [:]
        for (a, b) in zip(sequence, sequence.dropFirst()) {
            let gap = b.ts - a.ts
            guard gap > 0, gap <= 10, a.stepSoftware == b.stepSoftware else { continue }
            var delta = b.stepCounter - a.stepCounter
            if delta < 0 { delta += 65_536 }
            guard delta <= 4 * gap else { continue }
            let minute = b.ts - b.ts % 60
            byMinute[minute, default: (0, 0)].steps += delta
            byMinute[minute, default: (0, 0)].pairs += 1
        }
        return byMinute.keys.sorted().compactMap { minute in
            let m = byMinute[minute]!
            guard m.steps > 0 else { return nil }
            // More readings behind a minute means a higher version, so a minute first seen half-downloaded
            // is replaced once the rest of it arrives.
            return PlannedSample(kind: .steps, syncId: "whoopsync:steps:\(minute)", start: minute, end: minute + 60,
                                 value: Double(m.steps), version: m.pairs)
        }
    }
}
