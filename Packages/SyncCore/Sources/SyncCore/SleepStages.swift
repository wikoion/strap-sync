import Foundation

public enum SleepStage: Int, CaseIterable, Equatable {
    case wake = 0, light, deep, rem
}

/// Sleep stages per 30-second epoch from the strap's history RR and gravity vector. The heart part is
/// the mean of two LightGBM stages and a bidirectional GRU over the night's HRV features. A third
/// LightGBM over wrist rotation gives movement. The two are fused, then a tempered Viterbi pass. A port of research/sleep-stages (`hrv.py`, `stack.py`,
/// `gru.py`, `mlp.py`, `mg.py`, `export_model.py`), checked against it by `SleepStagesTests`; the model and its
/// scores are in docs/SLEEP_STAGES.md.
///
/// The heart model was trained on ECG sleep-lab nights and the movement model on Apple Watch nights.
/// Rotation (degrees turned between 5-s gravity directions) is the movement measure because it
/// doesn't depend on the device. Movement only moves wake against sleep; epochs without gravity
/// stay heart-only. Skin temperature isn't used.
public struct SleepStager {
    struct Config: Decodable {
        let version: String
        let features: Int
        let transitions: [[Double]]
        let temper: Double
        let freqs: [Double]
        let move: Move?
    }

    /// model.fuse's settings: the movement model's training prior, its weight, and whether it only
    /// moves wake against sleep.
    struct Move: Decodable {
        let prior: [Double]
        let weight: Double
        let wakeOnly: Bool
        enum CodingKeys: String, CodingKey { case prior, weight, wakeOnly = "wake_only" }
    }

    let stage1: GBDT
    let stage2: GBDT
    let move: GBDT?
    let gru: GRUNet?
    let config: Config
    let logT: [[Double]]
    public var version: String { config.version }
    /// The version as a number (2026-10-29 is 20261029), for Health's sync versions.
    public var versionNumber: Int { Int(config.version.filter(\.isNumber)) ?? 1 }

    public init(stage1: String, stage2: String, move: String? = nil, gru: Data? = nil, config: Data) throws {
        self.stage1 = try GBDT(text: stage1)
        self.stage2 = try GBDT(text: stage2)
        self.move = try move.map { try GBDT(text: $0) }
        self.gru = try gru.map { try GRUNet(json: $0) }
        let c = try JSONDecoder().decode(Config.self, from: config)
        self.config = c
        logT = c.transitions.map { $0.map { c.temper * log($0) } }
    }

    /// The model shipped in SyncCore's resources.
    public static func bundled() throws -> SleepStager {
        guard let dir = Bundle.module.url(forResource: "SleepModel", withExtension: nil) else { throw CocoaError(.fileNoSuchFile) }
        return try load(from: dir)
    }

    /// A model in a folder laid out like SyncCore's `Resources/SleepModel` (all five files, as
    /// research/sleep-stages/export_model.py writes them). A build can bundle its own model this way.
    public static func load(from dir: URL) throws -> SleepStager {
        func url(_ file: String) -> URL { dir.appendingPathComponent(file) }
        return try SleepStager(stage1: String(contentsOf: url("stage1.txt"), encoding: .utf8),
                               stage2: String(contentsOf: url("stage2.txt"), encoding: .utf8),
                               move: String(contentsOf: url("move.txt"), encoding: .utf8),
                               gru: Data(contentsOf: url("gru.json")),
                               config: Data(contentsOf: url("model.json")))
    }

    /// One stage per 30 s from `start` while it's before `end`. `rr` is history RR ordered by
    /// (ts, idx), ideally from ten minutes either side of the night so the edge windows fill.
    /// `motion` gives the gravity vector per second (records without one are skipped).
    public func stages(rr: [RRPoint], motion: [MotionPoint] = [], start: Int, end: Int) -> [SleepStage] {
        let n = (end - start) / 30
        guard n > 0, !rr.isEmpty else { return [] }
        let x = features(rr: rr, motion: motion, start: start, epochs: n)
        return viterbi(probabilities(x).fused).map { SleepStage(rawValue: $0)! }
    }

    func probabilities(_ x: [[Double]])
        -> (stage1: [[Double]], stage2: [[Double]], gru: [[Double]]?, move: [[Double]]?, fused: [[Double]]) {
        let p1 = x.map(stage1.probabilities)
        let p2 = Self.context(p1, x).map(stage2.probabilities)
        let pg = gru?.probabilities(x)
        let heart = pg.map { zip(p2, $0).map { a, b in zip(a, b).map { ($0 + $1) / 2 } } } ?? p2
        guard let move, let m = config.move else { return (p1, p2, pg, nil, heart) }
        let pm = x.map(move.probabilities)
        let rot = Self.columns.firstIndex(of: "rot")!
        return (p1, p2, pg, pm, zip(x, zip(heart, pm)).map { row, p in Self.fuse(p.0, p.1, m, has: row[rot].isFinite) })
    }

    /// model.fuse for one epoch: the heart's probabilities times the movement model's over its
    /// training prior, raised to the weight; with wakeOnly, only wake against sleep. An epoch
    /// without rotation keeps the heart's.
    static func fuse(_ ph: [Double], _ pm: [Double], _ m: Move, has: Bool) -> [Double] {
        let l: [Double]
        if !has {
            l = [0, 0, 0, 0]
        } else if m.wakeOnly {
            let w = log(pm[0] / m.prior[0] + 1e-9) - log((1 - pm[0]) / (1 - m.prior[0]) + 1e-9)
            l = [w, 0, 0, 0]
        } else {
            l = (0..<4).map { log(pm[$0] / m.prior[$0] + 1e-9) }
        }
        let p = (0..<4).map { exp(log(ph[$0] + 1e-9) + m.weight * l[$0]) }
        let sum = p.reduce(0, +)
        return p.map { $0 / sum }
    }

    /// A night's stages as Health sleep samples, one per run of the same stage: Awake, Core (light),
    /// Deep or REM (HKCategoryValueSleepAnalysis 2, 3, 4, 5). `version` is the model's, so a night
    /// restaged by a newer model replaces the older samples.
    public static func samples(start: Int, stages: [SleepStage], version: Int) -> [PlannedSample] {
        let value: [SleepStage: Double] = [.wake: 2, .light: 3, .deep: 4, .rem: 5]
        var out: [PlannedSample] = []
        var i = 0
        while i < stages.count {
            var j = i
            while j < stages.count && stages[j] == stages[i] { j += 1 }
            let a = start + i * 30
            out.append(PlannedSample(kind: .sleep, syncId: "whoopsync:stage:\(a)", start: a, end: start + j * 30,
                                     value: value[stages[i]]!, version: version))
            i = j
        }
        return out
    }

    // MARK: Features (hrv.py)

    /// Beat times relative to `start` (mg.py), then intervals as in `rr_series`, then `features`.
    func features(rr: [RRPoint], motion: [MotionPoint] = [], start: Int, epochs n: Int) -> [[Double]] {
        var cols = Self.rotation(motion, start: start, epochs: n)
        let ts = rr.map { Double($0.ts - start) }, iv = rr.map { Double($0.ms) / 1000 }
        var b = [Double](repeating: 0, count: iv.count)
        b[0] = ts[0]
        for k in 1..<max(1, iv.count) {
            b[k] = ts[k] - ts[k - 1] <= iv[k] + 1.5 && abs(b[k - 1] + iv[k] - ts[k]) < 2 ? b[k - 1] + iv[k] : ts[k]
        }
        let beats = b.filter { $0 >= 0 }
        guard beats.count > 1 else { return Self.assemble(n: n, cols: cols) }
        let (t, r, idx) = Self.clean(t: Array(beats.dropFirst()), rr: (1..<beats.count).map { beats[$0] - beats[$0 - 1] },
                                     idx: Array(0..<(beats.count - 1)))
        let centres = (0..<n).map { Double($0 * 30) + 15 }
        let w1 = windows(t, r, idx, centres, half: 30, spectral: false)
        let w5 = windows(t, r, idx, centres, half: 150, spectral: true)
        for (j, name) in Self.names1.enumerated() { cols[name] = w1.map { $0[j] } }
        for (j, name) in Self.names5.enumerated() { cols[name] = w5.map { $0[j] } }
        for k in ["hr5", "rmssd5", "hf5", "lfhf5", "dfa5", "hfnu5"] {
            cols[k + "_m5"] = Self.windowMean(cols[k]!, 10); cols[k + "_m15"] = Self.windowMean(cols[k]!, 30)
        }
        let base = Self.windowMean(cols["hr1"]!, 30)
        cols["hr_vs_base"] = zip(cols["hr1"]!, base).map { $0 - $1 }
        let resp = cols["resp5"]!
        cols["resp_sd"] = (0..<n).map { i in
            let s = resp[max(0, i - 10)..<min(n, i + 11)].filter(\.isFinite)
            return s.count > 3 ? Self.std(s) : .nan
        }
        return Self.assemble(n: n, cols: cols)
    }

    static let names1 = ["hr1", "rmssd1", "sdnn1", "cover1"]
    static let names5 = ["hr5", "rmssd5", "sdnn5", "cover5", "lf5", "hf5", "lfhf5", "hfnu5", "resp5", "resp_peak5", "dfa5", "pnn50_5"]
    static let rotationNames = ["rot", "rot_m1", "rot_m5", "rot_m10", "rot_big", "rot_big_m5", "rot_since", "rot_until"]
    /// hrv.features' column order before the time columns; temperature comes out empty.
    static let columns: [String] = {
        let means = ["hr5", "rmssd5", "hf5", "lfhf5", "dfa5", "hfnu5"].flatMap { [$0 + "_m5", $0 + "_m15"] }
        let temp = ["temp", "temp_m5", "temp_m15", "temp_vs_base"]
        return names1 + names5 + means + ["hr_vs_base", "resp_sd"] + rotationNames + temp
    }()

    /// hrv.rotation: per epoch, the share of its six 5-s steps whose gravity direction turns more
    /// than 5 degrees (and more than 30, a change of position), means of that over +-1, 5 and 10
    /// minutes, and minutes since and until the nearest epoch with a turn (capped at 60). Empty
    /// (so NaN) without gravity.
    static func rotation(_ motion: [MotionPoint], start: Int, epochs n: Int) -> [String: [Double]] {
        var g = [SIMD3<Double>?](repeating: nil, count: n * 30)
        for p in motion where p.ts >= start && p.ts - start < n * 30 { if let v = p.gravity { g[p.ts - start] = v } }
        guard g.contains(where: { $0 != nil }) else { return [:] }
        // Mean direction per 5 s, then the angle between successive ones (hrv.turns).
        let dirs = (0..<(n * 6)).map { k -> SIMD3<Double>? in
            let v = g[(k * 5)..<(k * 5 + 5)].compactMap { $0 }
            guard !v.isEmpty else { return nil }
            let m = v.reduce(SIMD3<Double>(), +) / Double(v.count)
            return m / (m * m).sum().squareRoot()
        }
        let turn = (0..<(n * 6)).map { k -> Double in
            guard k > 0, let a = dirs[k], let b = dirs[k - 1] else { return .nan }
            return acos(min(max((a * b).sum(), -1), 1)) * (180 / Double.pi)       // numpy.degrees
        }
        func share(_ over: Double) -> [Double] {
            (0..<n).map { e in
                let r = turn[(e * 6)..<(e * 6 + 6)].filter(\.isFinite)
                return r.isEmpty ? .nan : Double(r.filter { $0 > over }.count) / Double(r.count)
            }
        }
        let f = share(5), big = share(30)
        var since = [Double](repeating: 0, count: n), until = since
        var last = -1_000_000
        for e in 0..<n {
            if f[e].isFinite && f[e] > 0 { last = e }
            since[e] = min(Double(e - last) / 2, 60)
        }
        var next = 1_000_000
        for e in stride(from: n - 1, through: 0, by: -1) {
            if f[e].isFinite && f[e] > 0 { next = e }
            until[e] = min(Double(next - e) / 2, 60)
        }
        return Dictionary(uniqueKeysWithValues: zip(rotationNames, [f, windowMean(f, 2), windowMean(f, 10), windowMean(f, 20), big,
                                                                     windowMean(big, 10), since, until]))
    }

    /// Per-night robust scaling (except coverage and rotation), then the time columns.
    static func assemble(n: Int, cols: [String: [Double]]) -> [[Double]] {
        var scaled: [[Double]] = []
        for name in columns {
            var c = cols[name] ?? [Double](repeating: .nan, count: n)
            if !name.hasPrefix("cover") && !name.hasPrefix("rot") {
                let v = c.filter(\.isFinite).sorted()
                if v.count < 20 {
                    c = [Double](repeating: .nan, count: n)
                } else {
                    let lo = percentile(v, 0.05), med = percentile(v, 0.5), hi = percentile(v, 0.95)
                    c = c.map { ($0 - med) / (hi - lo + 1e-9) }
                }
            }
            scaled.append(c)
        }
        let h = (0..<n).map { Double($0) / 120 }
        let last = max(h.last ?? 0, 1e-9)
        let frac = h.map { $0 / last }
        scaled += [h, h.map { exp(-$0 / 2) }, frac, frac.map { cos(2 * Double.pi * $0) }]
        return (0..<n).map { i in scaled.map { $0[i] } }
    }

    func windows(_ t: [Double], _ rr: [Double], _ idx: [Int], _ centres: [Double], half: Double, spectral: Bool) -> [[Double]] {
        let lo = Self.searchsorted(t, centres.map { $0 - half }), hi = Self.searchsorted(t, centres.map { $0 + half })
        let freqs = config.freqs
        let lf = freqs.indices.filter { freqs[$0] < 0.15 }, hf = freqs.indices.filter { freqs[$0] >= 0.15 }
        let width = spectral ? 12 : 4
        return zip(lo, hi).map { a, b -> [Double] in
            let count = b - a
            guard count >= (spectral ? 40 : 12) else { return [Double](repeating: .nan, count: width) }
            let r = Array(rr[a..<b])
            var d: [Double] = []
            for j in a..<(b - 1) where idx[j + 1] - idx[j] == 1 { d.append(rr[j + 1] - rr[j]) }
            let mean = r.reduce(0, +) / Double(count)
            let hr = 60 / mean, cover = Double(count) / (2 * half * hr / 60)
            let rmssd = d.count > 5 ? (d.map { $0 * $0 }.reduce(0, +) / Double(d.count)).squareRoot() : .nan
            var row = [hr, log(rmssd + 1e-4), log(Self.std(r) + 1e-4), cover]
            if spectral {
                let p = Self.lombScargle(Array(t[a..<b]), r.map { $0 - mean }, freqs.map { 2 * Double.pi * $0 })
                let lfp = lf.map { p[$0] }.reduce(0, +), hfp = hf.map { p[$0] }.reduce(0, +)
                var k = hf[0]
                for i in hf where p[i] > p[k] { k = i }
                row += [log(lfp + 1e-9), log(hfp + 1e-9), log((lfp + 1e-9) / (hfp + 1e-9)), hfp / (lfp + hfp + 1e-12),
                        freqs[k] * 60, p[k] / (hfp + 1e-12), count >= 64 ? Self.dfa(r) : .nan,
                        d.count > 5 ? Double(d.filter { abs($0) > 0.05 }.count) / Double(d.count) : .nan]
            }
            return row
        }
    }

    /// Oura's artefact rule (hrv.clean): 0.33-1.5 s, within 20% of the 7-beat median, and two normal
    /// intervals either side.
    static func clean(t: [Double], rr: [Double], idx: [Int]) -> ([Double], [Double], [Int]) {
        let n = rr.count
        var ok = [Bool](repeating: false, count: n)
        for i in 0..<n {
            let w = (-3...3).map { rr[min(max(i + $0, 0), n - 1)] }.sorted()
            ok[i] = rr[i] > 0.33 && rr[i] < 1.5 && abs(rr[i] - w[3]) < 0.2 * w[3]
        }
        var keep = ok
        for s in [1, 2] where s < n {
            for i in s..<n { keep[i] = keep[i] && ok[i - s] }
            for i in 0..<(n - s) { keep[i] = keep[i] && ok[i + s] }
        }
        let k = (0..<n).filter { keep[$0] }
        return (k.map { t[$0] }, k.map { rr[$0] }, k.map { idx[$0] })
    }

    /// numpy.searchsorted(side="left") with numpy's own search, which matters when `a` isn't sorted.
    static func searchsorted(_ a: [Double], _ keys: [Double]) -> [Int] {
        var lo = 0, hi = a.count
        var last = keys.first ?? 0
        return keys.map { key in
            if last < key { hi = a.count } else { lo = 0; hi = hi < a.count ? hi + 1 : a.count }
            last = key
            while lo < hi {
                let mid = lo + (hi - lo) >> 1
                if a[mid] < key { lo = mid + 1 } else { hi = mid }
            }
            return lo
        }
    }

    /// scipy.signal.lombscargle with its defaults: unit weights, no floating mean, "power" units.
    static func lombScargle(_ x: [Double], _ y: [Double], _ omegas: [Double]) -> [Double] {
        let w = 1 / Double(x.count), eps = Double.ulpOfOne / 2
        return omegas.map { om in
            var cc = 0.0, cs = 0.0
            for xi in x { let a = om * xi, c = cos(a); cc += w * (c * c); cs += w * (c * sin(a)) }
            let tau = 0.5 * atan2(2 * cs, cc - (1 - cc))
            var yc = 0.0, ys = 0.0, c2 = 0.0
            for (xi, yi) in zip(x, y) {
                let a = om * xi - tau, c = cos(a), s = sin(a)
                yc += w * yi * c; ys += w * yi * s; c2 += w * (c * c)
            }
            let ccT = max(c2, eps), ssT = max(1 - c2, eps)
            return 2 * (yc / ccT * yc + ys / ssT * ys) * Double(x.count) / 4
        }
    }

    /// Short-term DFA alpha-1 over scales of 4-16 beats.
    static func dfa(_ r: [Double]) -> Double {
        let mean = r.reduce(0, +) / Double(r.count)
        var y = [Double](repeating: 0, count: r.count), acc = 0.0
        for (i, v) in r.enumerated() { acc += v - mean; y[i] = acc }
        let scales = [4, 6, 8, 11, 16]
        let f = scales.map { n -> Double in
            let m = y.count / n
            let x = (0..<n).map { Double($0) - Double(n - 1) / 2 }
            let xx = x.map { $0 * $0 }.reduce(0, +)
            var sum = 0.0
            for s in 0..<m {
                let seg = y[(s * n)..<(s * n + n)]
                let segMean = seg.reduce(0, +) / Double(n)
                let slope = zip(seg, x).map { $0 * $1 }.reduce(0, +) / xx
                for (v, xi) in zip(seg, x) { let e = v - segMean - slope * xi; sum += e * e }
            }
            return (sum / Double(m * n)).squareRoot()
        }
        let lx = scales.map { log(Double($0)) }, ly = f.map { log($0) }
        let mx = lx.reduce(0, +) / 5, my = ly.reduce(0, +) / 5
        return zip(lx, ly).map { ($0 - mx) * ($1 - my) }.reduce(0, +) / lx.map { ($0 - mx) * ($0 - mx) }.reduce(0, +)
    }

    /// model.window_mean: the mean of the finite values within +-half epochs, NaN with none.
    static func windowMean(_ x: [Double], _ half: Int) -> [Double] {
        x.indices.map { i in
            var sum = 0.0, count = 0
            for j in max(0, i - half)...min(x.count - 1, i + half) where x[j].isFinite { sum += x[j]; count += 1 }
            return count > 0 ? sum / Double(count) : .nan
        }
    }

    static func std(_ v: [Double]) -> Double {
        let m = v.reduce(0, +) / Double(v.count)
        return (v.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(v.count)).squareRoot()
    }

    /// numpy.percentile's default (linear) method on sorted values, with its interpolation.
    static func percentile(_ v: [Double], _ q: Double) -> Double {
        let n = v.count
        let vi = Double(n) * q + (1 + q * (1 - 1 - 1)) - 1
        let prev = min(max(Int(vi.rounded(.down)), 0), n - 1), next = min(prev + 1, n - 1)
        let g = vi - Double(prev), a = v[prev], b = v[next], diff = b - a
        return g >= 0.5 ? b - diff * (1 - g) : a + diff * g
    }

    // MARK: Second stage and smoothing (stack.py, mlp.py)

    /// The first stage's probabilities at +-1, 2, 5, 10, 20 and 40 epochs (clamped at the night's
    /// ends) and their means over +-2 to +-40 epochs, after the features and the probabilities.
    static func context(_ p: [[Double]], _ x: [[Double]]) -> [[Double]] {
        let n = p.count
        let means = [2, 5, 10, 20, 40].map { h in (0..<4).map { k in windowMean(p.map { $0[k] }, h) } }
        return (0..<n).map { i in
            var row = x[i] + p[i]
            for o in [1, 2, 5, 10, 20, 40] { row += p[max(0, i - o)] + p[min(n - 1, i + o)] }
            for m in means { row += (0..<4).map { m[$0][i] } }
            return row
        }
    }

    /// Viterbi with the transition log-probabilities tempered (mlp.tempered_viterbi).
    func viterbi(_ p: [[Double]]) -> [Int] {
        let n = p.count
        let lp = p.map { $0.map { log($0 + 1e-9) } }
        var d = lp[0]
        var back = [[Int]](repeating: [0, 0, 0, 0], count: n)
        for i in 1..<max(1, n) {
            var next = [Double](repeating: 0, count: 4)
            for to in 0..<4 {
                var best = 0
                for from in 1..<4 where d[from] + logT[from][to] > d[best] + logT[best][to] { best = from }
                back[i][to] = best; next[to] = d[best] + logT[best][to] + lp[i][to]
            }
            d = next
        }
        var path = [Int](repeating: 0, count: n)
        var s = 0
        for k in 1..<4 where d[k] > d[s] { s = k }
        path[n - 1] = s
        for i in stride(from: n - 1, to: 0, by: -1) { path[i - 1] = back[i][path[i]] }
        return path
    }
}
