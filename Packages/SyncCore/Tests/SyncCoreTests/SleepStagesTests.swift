import XCTest
@testable import SyncCore

/// The Swift stager against the Python it was ported from: Fixtures/stages-hmc.json holds three hours
/// of an open sleep-lab night (HMC SN003, CC BY 4.0) as MG-style RR records with three 30-s gaps,
/// three hours of an open Apple Watch night's gravity (BIDSleep BS00-1, ODC-By) with two gaps, and what
/// research/sleep-stages/export_model.py computes from them.
final class SleepStagesTests: XCTestCase {
    struct Fixture: Decodable {
        let epochs: Int
        let records: [[Int]]
        let gravity: [[Double]]
        let columns: [String]
        let features: [[Double?]]
        let stage1: [[Double]]
        let stage2: [[Double]]
        let gru: [[Double]]
        let move: [[Double]]
        let fused: [[Double]]
        let stages: [Int]
    }

    static let fixture: Fixture = {
        let url = Bundle.module.url(forResource: "stages-hmc", withExtension: "json", subdirectory: "Fixtures")!
        return try! JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }()
    static let stager = try! SleepStager.bundled()

    var rr: [RRPoint] { Self.fixture.records.map { RRPoint(ts: $0[0], idx: $0[1], ms: $0[2]) } }
    var motion: [MotionPoint] {
        Self.fixture.gravity.map {
            MotionPoint(ts: Int($0[0]), bpm: 0, stepCounter: 0, stepSoftware: false, bandState: 0, motion: nil, skinTempC: nil,
                        gravity: SIMD3($0[1], $0[2], $0[3]))
        }
    }

    func testColumnsMatchPython() {
        XCTAssertEqual(SleepStager.columns + ["hours", "decay", "frac", "cos"], Self.fixture.columns)
    }

    func testFeaturesMatchPython() {
        let x = Self.stager.features(rr: rr, motion: motion, start: 0, epochs: Self.fixture.epochs)
        XCTAssertEqual(x.count, Self.fixture.epochs)
        var worst = 0.0
        for (i, (row, want)) in zip(x, Self.fixture.features).enumerated() {
            for (j, (v, w)) in zip(row, want).enumerated() {
                guard let w else { XCTAssertTrue(v.isNaN, "epoch \(i) \(Self.fixture.columns[j]): \(v), want NaN"); continue }
                worst = max(worst, abs(v - w))
                XCTAssertEqual(v, w, accuracy: 1e-6, "epoch \(i) \(Self.fixture.columns[j])")
            }
        }
        print("largest feature difference from Python: \(worst)")
    }

    func testModelMatchesLightGBM() {
        let x = Self.fixture.features.map { $0.map { $0 ?? .nan } }
        let p = Self.stager.probabilities(x)
        for (a, b) in zip(p.stage1, Self.fixture.stage1) { for (u, v) in zip(a, b) { XCTAssertEqual(u, v, accuracy: 1e-9) } }
        for (a, b) in zip(p.stage2, Self.fixture.stage2) { for (u, v) in zip(a, b) { XCTAssertEqual(u, v, accuracy: 1e-9) } }
        XCTAssertEqual(p.gru?.count, Self.fixture.gru.count)
        for (a, b) in zip(p.gru ?? [], Self.fixture.gru) { for (u, v) in zip(a, b) { XCTAssertEqual(u, v, accuracy: 1e-9) } }
        XCTAssertEqual(p.move?.count, Self.fixture.move.count)
        for (a, b) in zip(p.move ?? [], Self.fixture.move) { for (u, v) in zip(a, b) { XCTAssertEqual(u, v, accuracy: 1e-9) } }
        for (a, b) in zip(p.fused, Self.fixture.fused) { for (u, v) in zip(a, b) { XCTAssertEqual(u, v, accuracy: 1e-9) } }
        XCTAssertEqual(Self.stager.viterbi(p.fused), Self.fixture.stages)
    }

    func testStagesEndToEnd() {
        let s = Self.stager.stages(rr: rr, motion: motion, start: 0, end: Self.fixture.epochs * 30)
        XCTAssertEqual(s.map(\.rawValue), Self.fixture.stages)
    }

    /// Nights stored before gravity was decoded stage from the heart alone (LightGBM and GRU).
    func testNoGravityIsHeartOnly() {
        let x = Self.stager.features(rr: rr, start: 0, epochs: Self.fixture.epochs)
        let rot = SleepStager.columns.firstIndex(of: "rot")!
        XCTAssertTrue(x.allSatisfy { $0[rot].isNaN })
        let p = Self.stager.probabilities(x)
        for (f, (a, b)) in zip(p.fused, zip(p.stage2, p.gru!)) {
            for k in 0..<4 { XCTAssertEqual(f[k], (a[k] + b[k]) / 2, accuracy: 1e-8) }
        }
    }

    /// The GRU only sees heart columns, so gravity doesn't change what it says.
    func testGRUIgnoresRotation() {
        let with = Self.stager.features(rr: rr, motion: motion, start: 0, epochs: Self.fixture.epochs)
        let without = Self.stager.features(rr: rr, start: 0, epochs: Self.fixture.epochs)
        XCTAssertEqual(Self.stager.gru!.probabilities(with), Self.stager.gru!.probabilities(without))
    }

    func testR18Gravity() {
        var f = [UInt8](repeating: 0, count: 124)
        f[8] = 47; f[9] = 18
        func put(_ v: Float, _ at: Int) { withUnsafeBytes(of: v.bitPattern.littleEndian) { f.replaceSubrange(at..<(at + 4), with: $0) } }
        put(0.25, 45); put(-0.5, 49); put(0.875, 53)
        guard case .record(let r)? = Whoop5Message.parse(f) else { return XCTFail("not an R18 record") }
        XCTAssertEqual(r.gravity, SIMD3(0.25, -0.5, 0.875))
        XCTAssertEqual(MotionPoint(r).gravity, r.gravity)
        put(.nan, 49)
        guard case .record(let bad)? = Whoop5Message.parse(f) else { return XCTFail("not an R18 record") }
        XCTAssertNil(bad.gravity)
    }

    func testHealthSamplesAreOnePerRun() {
        let s = SleepStager.samples(start: 1000, stages: [.light, .light, .deep, .wake, .rem, .rem], version: 7)
        XCTAssertEqual(s.map(\.start), [1000, 1060, 1090, 1120])
        XCTAssertEqual(s.map(\.end), [1060, 1090, 1120, 1180])
        XCTAssertEqual(s.map(\.value), [3, 4, 2, 5])        // core, deep, awake, REM
        XCTAssertEqual(Set(s.map(\.syncId)).count, 4)
        XCTAssertTrue(s.allSatisfy { $0.kind == .sleep && $0.version == 7 })
        XCTAssertEqual(Self.stager.versionNumber, Int(Self.stager.version.filter(\.isNumber)))
    }

    /// `bundled()` reads SyncCore's folder through `load(from:)`; a folder without a model throws.
    func testLoadFromAFolderWithoutAModelThrows() {
        XCTAssertThrowsError(try SleepStager.load(from: FileManager.default.temporaryDirectory.appendingPathComponent("no-model")))
    }

    func testNoBeatsGivesNoStages() {
        XCTAssertEqual(Self.stager.stages(rr: [], start: 0, end: 3600), [])
    }
}
