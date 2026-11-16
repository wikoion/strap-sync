import XCTest
@testable import SyncCore

/// Real frames from our own worn MG, taken from the raw archive (28 Oct 2026, one history chunk except
/// `r18NoHeartRate`). The R18 heart rates match the strap's standard heart-rate service at the same
/// second, and their RR intervals arrive on it about 3 s later.
enum Captured {
    /// R18 record: unix 1793195836, 76 bpm, RR [817, 765] ms.
    static let r18 = hex("aa01740001003fb12f12801fca2c003cffe16a5118004c023103fd02000000000020af010eb30000ff80c79c3c66e6973e14e2713f66d61c3e4b030000000000000000000021012e01350c2007010c020c00000000000000000000000000000000000000000000010100705c2422000000b33792c00000003f2c487b")
    /// R18 record: unix 1793195838, 76 bpm, RR [668] ms.
    static let r18OneRR = hex("aa01740001003fb12f128021ca2c003effe16a5118004c019c020000000000004021cc070ebb0000f80027253c717d9b3ee152713f66b6193e4b030000000000000000000021012e01350c2007010c020c010000000000000000000000000000000000000000000101006f5b242100000017e292c00000009e9863a3")
    /// R18 record from an earlier chunk with no heart-rate reading (HR 0, no RR) while worn.
    static let r18NoHeartRate = hex("aa01740001003fb12f128060c52c007dfae16a511800000000000000000000000400000007000000d800a4fb3bb8be93bd52204b3fec95213f0003000000000000000000001e012901f70b0007010c020c00000000000000000000000000000000000000000000800100363f80800000002cc611c000000057821c06")
    /// A layout-26 optical record (25 Hz PPG), unix 1793195779, the first second of a burst, awake.
    static let r26 = hex("aa015000010035412f1a80e6c92c0003ffe16a51180100a034ffffd102de03c90162027f0402097a0b370b6001effe65fb61fd8afaf0e71ee0d2f124fc1b01bf0242002c002e0081fd6efa8019713d2007000000b6448858")
    /// HISTORY_END: unix 1793195889, trim cursor 90762.
    static let historyEnd = hex("aa011c00010023d131c30271ffe16acc2c3c0000008a620100010000000000004468f5f3")
    static let historyStart = hex("aa012c0001002cd131860171ffe16a47010d0000000000000000000000320000002300000002000000000000000a0320475bd970")
    /// The strap's reply to our acknowledgement of `historyEnd`: command 23, sequence 30, result 1. Its
    /// next chunk ended at cursor 90766, so the acknowledgement walked the cursor.
    static let historyAckReply = hex("aa010c0001002711246c171e01000000f1e9b72d")
    static let recordTime = 1_793_195_836

    static func hex(_ s: String) -> [UInt8] {
        var out: [UInt8] = []
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!)
            i = j
        }
        return out
    }
}

final class FrameTests: XCTestCase {
    func testCapturedFramesAreValid() {
        for f in [Captured.r18, Captured.r18OneRR, Captured.r18NoHeartRate, Captured.r26,
                  Captured.historyEnd, Captured.historyStart, Captured.historyAckReply, Whoop5.clientHello] {
            XCTAssertTrue(Frame.isValid(f))
        }
    }

    func testCorruptedFrameIsRejected() {
        var f = Captured.r18
        f[30] ^= 0xFF
        XCTAssertFalse(Frame.isValid(f))
    }

    func testAckIsTheCommandTheStrapAccepted() {
        guard case .historyEnd(_, let endBlock)? = Whoop5Message.parse(Captured.historyEnd) else {
            return XCTFail("not a history end")
        }
        guard case .commandResponse(let cmd, let seq, let result, _)? = Whoop5Message.parse(Captured.historyAckReply) else {
            return XCTFail("not a command response")
        }
        XCTAssertEqual(cmd, Whoop5.Command.historicalDataResult.rawValue)
        XCTAssertEqual(result, 1)
        let ack = Frame.command(cmd, seq: seq, payload: Whoop5.historyAckPayload(endBlock: endBlock))
        XCTAssertTrue(Frame.isValid(ack))
        XCTAssertEqual(Array(ack[8..<11]), [35, seq, cmd])
        XCTAssertEqual(Array(ack[11..<(ack.count - 4)]), [0x01] + endBlock)
    }

    func testClientHelloIsAGetHelloFrame() {
        XCTAssertEqual(Frame.command(145, seq: 1, payload: [1]), Whoop5.clientHello)
    }

    func testCommandBodyIsPaddedToFourBytes() {
        let f = Frame.command(Whoop5.Command.setClock.rawValue, seq: 7, payload: Whoop5.setClockPayload(unix: 1_800_000_000))
        XCTAssertTrue(Frame.isValid(f))
        XCTAssertEqual((f.count - 12) % 4, 0)
        XCTAssertEqual(Array(f[8..<11]), [35, 7, 10])
    }

    func testReassemblerJoinsFragmentsAndSkipsNoise() {
        let r = Reassembler()
        let stream = [0xAA, 0x00, 0x13] + Captured.r18 + Captured.historyEnd
        var out: [[UInt8]] = []
        var i = 0
        while i < stream.count {
            let j = min(i + 20, stream.count)
            out += r.feed(Array(stream[i..<j]))
            i = j
        }
        XCTAssertEqual(out, [Captured.r18, Captured.historyEnd])
    }
}

final class MessageTests: XCTestCase {
    func record(_ frame: [UInt8]) -> R18Record? {
        if case .record(let r)? = Whoop5Message.parse(frame) { return r }
        return nil
    }

    func testR18Record() {
        let r = record(Captured.r18)
        XCTAssertEqual(r?.ts, 1_793_195_836)
        XCTAssertEqual(r?.bpm, 76)
        XCTAssertEqual(r?.rrMs, [817, 765])
        XCTAssertEqual(record(Captured.r18OneRR)?.rrMs, [668])
        XCTAssertEqual(record(Captured.r18OneRR)?.bpm, 76)
    }

    /// The same worn, daytime frame, read by hand at the documented offsets.
    func testR18MotionStepsAndTemperature() {
        let r = record(Captured.r18)!
        XCTAssertEqual(r.stepCounter, 843)
        XCTAssertFalse(r.stepSoftware)
        XCTAssertEqual(r.bandState, 0)
        XCTAssertEqual(r.motion ?? -1, 0.0191, accuracy: 0.0005)
        XCTAssertEqual(r.skinTempC ?? 0, 31.25, accuracy: 0.001)
    }

    func testBandStateIsBitsFourAndFive() {
        var f = Captured.r18
        f[81] = 0x2D
        XCTAssertEqual(record(f)?.bandState, 2)
    }

    func testRecordWithoutAHeartRate() {
        let r = record(Captured.r18NoHeartRate)!
        XCTAssertEqual(r.bpm, 0)
        XCTAssertEqual(r.rrMs, [])
        XCTAssertEqual(r.skinTempC ?? 0, 30.63, accuracy: 0.001)  // still on the wrist
    }

    func testOpticalRecord() {
        guard case .optical(let r)? = Whoop5Message.parse(Captured.r26) else { return XCTFail("not R26") }
        XCTAssertEqual(r.ts, 1_793_195_779)
        XCTAssertEqual(r.base, -52_064)  // signed: negative on this strap
        XCTAssertEqual(r.deltas.count, 24)
        XCTAssertEqual(Array(r.deltas.prefix(3)), [721, 990, 457])
        XCTAssertEqual(r.samples.count, 25)
        XCTAssertEqual(r.samples.last, -63_052)
        XCTAssertEqual(r.samples.min(), -63_052)
        XCTAssertEqual(r.samples[13], -43_189)
        XCTAssertEqual(r.aux, 6225)
        XCTAssertEqual(r.burstCounter, 1)
        XCTAssertEqual(r.motion ?? 0, 0.0589, accuracy: 0.0001)
        XCTAssertEqual(r.status, 1824)
        XCTAssertEqual(r.acceptance, 0)
        XCTAssertEqual(R26Record.deltas(from: r.deltaBytes), r.deltas)
    }

    func testOtherLayoutsAreKeptWhole() {
        var f = Captured.r26
        f[9] = 20
        XCTAssertEqual(Whoop5Message.parse(f), .otherRecord(layout: 20, ts: 1_793_195_779, frame: f))
    }

    func testMetadata() {
        XCTAssertEqual(Whoop5Message.parse(Captured.historyStart), .historyStart)
        XCTAssertEqual(Whoop5Message.parse(Captured.historyEnd),
                       .historyEnd(unix: 1_793_195_889, endBlock: [0x8A, 0x62, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00]))
    }
}

final class HistorySessionTests: XCTestCase {
    func testChunkThenComplete() {
        let s = HistorySession(now: { Captured.recordTime + 3600 })
        s.begin()
        for f in [Captured.historyStart, Captured.r18, Captured.r18OneRR, Captured.r18NoHeartRate, Captured.r26] {
            XCTAssertEqual(s.feed(Whoop5Message.parse(f)!), .none)
        }
        guard case .chunk(let c) = s.feed(Whoop5Message.parse(Captured.historyEnd)!) else { return XCTFail() }
        XCTAssertEqual(c.hr, [HRPoint(ts: 1_793_195_836, bpm: 76), HRPoint(ts: 1_793_195_838, bpm: 76)])
        XCTAssertEqual(c.rr, [RRPoint(ts: 1_793_195_836, idx: 0, ms: 817), RRPoint(ts: 1_793_195_836, idx: 1, ms: 765),
                              RRPoint(ts: 1_793_195_838, idx: 0, ms: 668)])
        XCTAssertEqual(c.records, 3)
        XCTAssertEqual(c.motion.map(\.ts), [1_793_195_836, 1_793_195_838, 1_793_194_621])
        XCTAssertEqual(c.motion.map(\.bpm), [76, 76, 0])
        XCTAssertEqual(c.otherRecords, 1)
        XCTAssertEqual(c.otherLayouts, [26: 1])
        XCTAssertEqual(c.optical.map(\.ts), [1_793_195_779])
        XCTAssertEqual(c.banked, [])
        XCTAssertEqual(c.trimCursor, 90_762)

        var complete = Captured.historyEnd
        complete[10] = 3
        XCTAssertEqual(s.feed(Whoop5Message.parse(complete)!), .complete)
        XCTAssertFalse(s.isOpen)
    }

    func testRecordsFromAnUnsetClockAreDropped() {
        let s = HistorySession(now: { Captured.recordTime + 40 * 86_400 })
        s.begin()
        _ = s.feed(Whoop5Message.parse(Captured.r18)!)
        guard case .chunk(let c) = s.feed(Whoop5Message.parse(Captured.historyEnd)!) else { return XCTFail() }
        XCTAssertEqual(c.hr, [])
        XCTAssertEqual(c.implausible, 1)
    }

    func testArchiveFileGivesItsOpticalRecords() {
        func entry(_ f: [UInt8]) -> [UInt8] { [UInt8(f.count & 0xFF), UInt8(f.count >> 8)] + f }
        var r20 = Captured.r26
        r20[9] = 20
        let file = [Captured.historyStart, Captured.r18, Captured.r26, r20, Captured.historyEnd].flatMap(entry)
        let c = HistoryChunk.archived(file + [0x40, 0x00, 0xAA])  // a torn last entry is ignored
        XCTAssertEqual(c.optical.map(\.ts), [1_793_195_779])
        XCTAssertEqual(c.banked, [BankedRecord(layout: 20, ts: 1_793_195_779, frame: r20)])
        XCTAssertEqual(c.motion, [])
    }

    func testIgnoredWhenNotDownloading() {
        let s = HistorySession(now: { Captured.recordTime })
        XCTAssertEqual(s.feed(Whoop5Message.parse(Captured.historyEnd)!), .none)
    }
}

final class HeartRateMeasurementTests: XCTestCase {
    func testEightBitWithRR() {
        // flags: RR present, contact supported + detected; 62 bpm; RR 968, 975.
        let m = HeartRateMeasurement.parse([0x16, 62, 0xC8, 0x03, 0xCF, 0x03])
        XCTAssertEqual(m, HeartRateMeasurement(bpm: 62, contact: .detected, rrRaw: [968, 975]))
        XCTAssertEqual(m?.isUsable, true)
    }

    func testSixteenBitWithEnergyAndNoContact() {
        let m = HeartRateMeasurement.parse([0x0D, 0x48, 0x00, 0x10, 0x00])
        XCTAssertEqual(m, HeartRateMeasurement(bpm: 72, contact: .notDetected, rrRaw: []))
        XCTAssertEqual(m?.isUsable, false)
    }

    func testTruncatedIsNil() {
        XCTAssertNil(HeartRateMeasurement.parse([0x01, 0x48]))
        XCTAssertNil(HeartRateMeasurement.parse([]))
    }
}
