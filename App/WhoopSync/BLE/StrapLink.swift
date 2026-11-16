import CoreBluetooth
import Foundation
import SyncCore

struct FoundStrap: Identifiable, Equatable {
    let id: UUID
    let name: String
    let rssi: Int?
}

struct DeviceInfo: Equatable {
    var model: String?
    var serial: String?
    var firmware: String?
    var hardware: String?

    /// MG vs 5.0, from the Device Information Service (model "MG", serial 5AM / 5AG, hardware WG50).
    var variant: String {
        if model == "MG" || serial?.hasPrefix("5AM") == true { return "WHOOP MG" }
        if serial?.hasPrefix("5AG") == true || hardware?.contains("WG50") == true { return "WHOOP 5.0" }
        return "WHOOP 5.0 / MG"
    }
}

enum LinkState: Equatable {
    case bluetoothOff, noStrap, connecting, connected, disconnected
}

enum PairingState: Equatable {
    case unknown
    /// CLIENT_HELLO written, waiting for the write to be acknowledged (iOS pairs here).
    case waiting
    case bonded
    /// Failed attempts in a row. Live heart rate still works without the bond.
    case refused(Int)
    /// Stopped trying after repeated failures, until the user taps Retry pairing.
    case paused
}

/// The Bluetooth side, on the main queue: find the strap, pair it (the CLIENT_HELLO bond), set its clock,
/// stream live heart rate, and download its history in acknowledged chunks.
///
/// The connection behaviour follows what ryanbr/noop learned on real WHOOP 5/MG straps on iOS:
/// hello first and nothing else until it resolves (#1635), WHOOP channels only after the bond, the
/// clock-and-history handshake exactly once per connection, targeted reconnects in the background,
/// and a restored, already-open link set up again by hand (#613).
final class StrapLink: NSObject {
    enum Event {
        case state(LinkState)
        case pairing(PairingState)
        case found([FoundStrap])
        case liveHR(HeartRateMeasurement, at: Int)
        case battery(Int)
        case info(DeviceInfo)
        case clockOffset(Int)
        case historyStarted
        case historyFinished(ok: Bool, chunks: Int, records: Int)
        case ecgResponse(cmd: UInt8, result: UInt8)
        case ecgRecord(Ecg.FilteredRecord, at: Double)
    }

    var onEvent: (Event) -> Void = { _ in }
    /// Saves a history chunk. Return true only once it's durably stored: that's what allows the acknowledgement.
    var save: (HistoryChunk) -> Bool = { _ in false }

    static let historyInterval: TimeInterval = 15 * 60
    private static let restoreID = "WhoopSync.central"
    private static let maxRefusals = 3

    private let hrService = CBUUID(string: "180D"), hrChar = CBUUID(string: "2A37")
    private let batteryService = CBUUID(string: "180F"), batteryChar = CBUUID(string: "2A19")
    private let disService = CBUUID(string: "180A")
    private let disFields: [CBUUID: WritableKeyPath<DeviceInfo, String?>] = [
        CBUUID(string: "2A24"): \.model, CBUUID(string: "2A25"): \.serial,
        CBUUID(string: "2A26"): \.firmware, CBUUID(string: "2A27"): \.hardware,
    ]
    private let whoopService = CBUUID(string: Whoop5.service)
    private let commandUUID = CBUUID(string: Whoop5.commandChar)
    private let notifyUUIDs = Set(Whoop5.notifyChars.map { CBUUID(string: $0) })

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var restored: CBPeripheral?
    private var commandChar: CBCharacteristic?
    private var notifyChars: [CBCharacteristic] = []
    private var reassemblers: [CBUUID: Reassembler] = [:]
    private var seq: UInt8 = 1
    private var helloAttempt = 0
    private var helloOutstanding = false
    /// While set, a refused hello is retried every few seconds: the strap only accepts pairing while
    /// it's in pairing mode (lights flashing blue), which the user starts by tapping it.
    private var pairUntil: Date?
    private var loggedLiveHR = false
    /// An ECG is running: history waits, and filtered ECG records are passed on.
    private(set) var ecgActive = false
    /// Set while an ECG runs; if the link drops mid-recording, the next connection stops it.
    private var ecgCleanupNeeded: Bool {
        get { defaults.bool(forKey: "ecgCleanupNeeded") }
        set { defaults.set(newValue, forKey: "ecgCleanupNeeded") }
    }
    private var bonded = false
    private var handshakeDone = false
    private var downloading = false
    private var lastHistoryRequest: Date?
    private var idleTimer: Timer?
    private var chunks = 0
    private var records = 0
    private var badFrames = 0
    private var scanStop: DispatchWorkItem?
    private var found: [UUID: FoundStrap] = [:]
    private var info = DeviceInfo()
    private let history = HistorySession(now: { Int(Date().timeIntervalSince1970) })

    private(set) var state: LinkState = .bluetoothOff {
        didSet { if state != oldValue { onEvent(.state(state)) } }
    }

    // Persisted per strap.
    private let defaults = UserDefaults.standard
    private var savedId: UUID? {
        get { defaults.string(forKey: "strapId").flatMap(UUID.init(uuidString:)) }
        set { defaults.set(newValue?.uuidString, forKey: "strapId") }
    }
    private var refusals: Int {
        get { defaults.integer(forKey: "pairingRefusals") }
        set { defaults.set(newValue, forKey: "pairingRefusals") }
    }
    private var helloPaused: Bool {
        get { defaults.bool(forKey: "pairingPaused") }
        set { defaults.set(newValue, forKey: "pairingPaused") }
    }

    var hasStrap: Bool { savedId != nil }
    var isBonded: Bool { bonded }
    var isDownloading: Bool { downloading }

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionRestoreIdentifierKey: Self.restoreID])
    }

    #if DEBUG
    /// For screenshots in the Simulator (Demo.swift): a paired strap with no radio. The central has no
    /// delegate, so Bluetooth being unavailable doesn't reset the link; AppModel plays the strap's events.
    init(demoStrap id: UUID) {
        super.init()
        central = CBCentralManager(delegate: nil, queue: .main)
        savedId = id
        bonded = true
    }
    #endif

    // MARK: - Actions

    func startScan() {
        guard central.state == .poweredOn else { return log("Bluetooth is off") }
        found = [:]
        for p in central.retrieveConnectedPeripherals(withServices: [whoopService]) {
            found[p.identifier] = FoundStrap(id: p.identifier, name: p.name ?? "WHOOP", rssi: nil)
        }
        onEvent(.found(sortedFound))
        central.scanForPeripherals(withServices: [whoopService],
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        log("Scanning for WHOOP 5.0 / MG straps")
        scanStop?.cancel()
        let stop = DispatchWorkItem { [weak self] in self?.stopScan() }
        scanStop = stop
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: stop)
    }

    func stopScan() {
        scanStop?.cancel()
        if central.isScanning { central.stopScan() }
    }

    func choose(_ id: UUID) {
        stopScan()
        if let p = peripheral, p.identifier != id { central.cancelPeripheralConnection(p) }
        savedId = id
        refusals = 0
        helloPaused = false
        guard let p = central.retrievePeripherals(withIdentifiers: [id]).first else { return log("That strap is no longer visible") }
        log("Chose strap \(p.name ?? id.uuidString)")
        connect(p)
    }

    func forget() {
        stopScan()
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        peripheral = nil
        savedId = nil
        refusals = 0
        helloPaused = false
        resetLink()
        state = .noStrap
        onEvent(.pairing(.unknown))
        log("Forgot the strap. To pair it with another phone too, also use Forget This Device in Settings → Bluetooth.")
    }

    func retryPairing() {
        refusals = 0
        helloPaused = false
        pairUntil = Date().addingTimeInterval(60)
        log("Pairing: trying for 60 s. Keep the strap next to the phone and tap it until its lights flash blue.")
        guard let p = peripheral, p.state == .connected else {
            log("Retry pairing: not connected yet; will pair on the next connection")
            if let p = peripheral { central.connect(p) }
            return
        }
        if bonded { return log("Already paired") }
        if !helloOutstanding { sendHello() }
    }

    /// How often history downloads run: every 15 minutes, or 5 while a night is under way.
    var historyEvery = historyInterval

    func requestHistoryIfDue(reason: String, interval: TimeInterval = historyInterval) {
        if let last = lastHistoryRequest, Date().timeIntervalSince(last) < interval { return }
        requestHistory(reason: reason)
    }

    func requestHistory(reason: String) {
        guard bonded, handshakeDone else {
            return log("History: \(bonded ? "still setting up the link" : "needs the strap paired first")")
        }
        guard !downloading, !ecgActive else { return }
        history.begin()
        downloading = true
        chunks = 0
        records = 0
        lastHistoryRequest = Date()
        send(.sendHistoricalData, payload: [0x00], withResponse: true)
        armIdleTimer()
        log("History: download requested (\(reason))")
        onEvent(.historyStarted)
    }

    // MARK: - ECG

    /// Marks an ECG session as running (AppModel drives the command sequence).
    func beginEcg() -> Bool {
        guard bonded, handshakeDone, !downloading, !ecgActive else { return false }
        ecgActive = true
        ecgCleanupNeeded = true
        return true
    }

    func sendEcg(_ cmd: Ecg.Command, payload: [UInt8]) {
        log("ECG: → \(cmd) \(payload.map(String.init).joined(separator: " "))")
        send(raw: cmd.rawValue, payload: payload)
    }

    func endEcg() {
        ecgActive = false
        ecgCleanupNeeded = false
    }

    // MARK: - Connection

    private var sortedFound: [FoundStrap] {
        found.values.sorted { ($0.rssi ?? 0) > ($1.rssi ?? 0) }
    }

    private func connect(_ p: CBPeripheral) {
        peripheral = p
        p.delegate = self
        state = .connecting
        central.connect(p, options: nil)
    }

    private func reconnectSaved() {
        guard let id = savedId else { state = .noStrap; return }
        let p = restored ?? central.retrievePeripherals(withIdentifiers: [id]).first
        restored = nil
        guard let p else {
            log("iOS doesn't know the saved strap any more; use Find strap")
            state = .noStrap
            return
        }
        if p.state == .connected {
            // A link iOS restored for us never gets didConnect (#613), so set it up here.
            log("Restored an open link to the strap; setting it up again")
            peripheral = p
            p.delegate = self
            setUp(p)
        } else {
            log("Connecting to the saved strap (waits until it's in range)")
            connect(p)
        }
    }

    private func setUp(_ p: CBPeripheral) {
        resetLink()
        state = .connected
        p.discoverServices([hrService, batteryService, disService, whoopService])
    }

    private func resetLink() {
        commandChar = nil
        notifyChars = []
        reassemblers = [:]
        helloOutstanding = false
        bonded = false
        handshakeDone = false
        loggedLiveHR = false
        ecgActive = false
        if downloading {
            history.abandon()
            downloading = false
            onEvent(.historyFinished(ok: false, chunks: chunks, records: records))
        }
        idleTimer?.invalidate()
    }

    // MARK: - Pairing

    private func sendHello() {
        guard let p = peripheral, let c = commandChar else { return }
        if helloPaused {
            log("Pairing paused after \(Self.maxRefusals) failed attempts; live heart rate only. See the pairing steps, then tap Retry pairing.")
            onEvent(.pairing(.paused))
            return
        }
        helloAttempt += 1
        let attempt = helloAttempt
        helloOutstanding = true
        log("Pairing: sending CLIENT_HELLO (attempt \(refusals + 1)); if iOS asks to pair, tap Pair")
        onEvent(.pairing(.waiting))
        p.writeValue(Data(Whoop5.clientHello), for: c, type: .withResponse)
        // Long enough for the user to answer iOS's pairing prompt.
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, self.helloAttempt == attempt, self.helloOutstanding else { return }
            self.helloOutstanding = false
            self.pairingFailed("no answer to CLIENT_HELLO within 30 s")
        }
    }

    private func pairingFailed(_ reason: String) {
        if let until = pairUntil, Date() < until {
            log("Pairing refused (\(reason)); trying again in 3 s")
            onEvent(.pairing(.waiting))
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, !self.bonded, !self.helloOutstanding, self.peripheral?.state == .connected else { return }
                self.sendHello()
            }
            return
        }
        pairUntil = nil
        refusals += 1
        log("Pairing failed: \(reason) (\(refusals) in a row)")
        if refusals >= Self.maxRefusals {
            helloPaused = true
            log("""
                Stopped trying to pair. Live heart rate still works. To pair: delete the WHOOP app, \
                Settings → Bluetooth → WHOOP → Forget This Device, tap the strap until its lights flash blue, \
                then tap Retry pairing.
                """)
            onEvent(.pairing(.paused))
        } else {
            onEvent(.pairing(.refused(refusals)))
        }
    }

    private func didBond() {
        bonded = true
        refusals = 0
        pairUntil = nil
        log("Pairing: CLIENT_HELLO acknowledged, strap paired")
        onEvent(.pairing(.bonded))
        guard let p = peripheral else { return }
        for c in notifyChars where !c.isNotifying { p.setNotifyValue(true, for: c) }
        // Standard characteristics that refused before the bond.
        for s in p.services ?? [] {
            for c in s.characteristics ?? [] {
                if (c.uuid == hrChar || c.uuid == batteryChar) && !c.isNotifying { p.setNotifyValue(true, for: c) }
                if disFields[c.uuid] != nil { p.readValue(for: c) }
            }
        }
        startHandshakeWhenSubscribed(deadline: Date().addingTimeInterval(4))
    }

    /// Clock and history replies arrive on the WHOOP notify channels, so wait for them (briefly).
    private func startHandshakeWhenSubscribed(deadline: Date) {
        guard bonded, !handshakeDone else { return }
        if notifyChars.allSatisfy(\.isNotifying) || Date() >= deadline {
            runHandshake()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.startHandshakeWhenSubscribed(deadline: deadline)
            }
        }
    }

    /// Exactly once per connection: re-running it during a download makes the strap stop serving history.
    private func runHandshake() {
        guard !handshakeDone else { return }
        handshakeDone = true
        if ecgCleanupNeeded {
            // An ECG was running when the link dropped. Don't resend start (PROTOCOL_ECG.md); stop it.
            log("ECG: stopping a recording interrupted by a disconnect")
            for step in Ecg.stopSequence { send(raw: step.cmd.rawValue, payload: step.payload) }
            ecgCleanupNeeded = false
        }
        let now = UInt32(Date().timeIntervalSince1970)
        send(.setClock, payload: Whoop5.setClockPayload(unix: now))
        send(.getClock, payload: [])
        log("Handshake: clock set, history download in 1.5 s")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.requestHistory(reason: "connected")
        }
    }

    private func send(_ cmd: Whoop5.Command, payload: [UInt8], withResponse: Bool = false) {
        send(raw: cmd.rawValue, payload: payload, withResponse: withResponse)
    }

    private func send(raw cmd: UInt8, payload: [UInt8], withResponse: Bool = false) {
        guard let p = peripheral, p.state == .connected, let c = commandChar else { return }
        seq &+= 1
        let frame = Frame.command(cmd, seq: seq, payload: payload)
        let type: CBCharacteristicWriteType =
            withResponse || !c.properties.contains(.writeWithoutResponse) ? .withResponse : .withoutResponse
        p.writeValue(Data(frame), for: c, type: type)
    }

    // MARK: - History

    private func armIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { [weak self] _ in
            guard let self, self.downloading else { return }
            self.log("History: no data for 60 s; stopping this download")
            self.finishDownload(ok: false)
        }
    }

    private func finishDownload(ok: Bool) {
        guard downloading else { return }
        downloading = false
        idleTimer?.invalidate()
        if history.isOpen { history.abandon() }
        log("History: \(ok ? "complete" : "stopped"), \(chunks) chunks, \(records) records")
        onEvent(.historyFinished(ok: ok, chunks: chunks, records: records))
    }

    private func handle(_ message: Whoop5Message) {
        switch message {
        case .commandResponse(let cmd, _, let result, let body):
            handleResponse(cmd: cmd, result: result, body: body)
        case _ where message.isHistory:
            guard downloading else { return }
            armIdleTimer()
            switch history.feed(message) {
            case .chunk(let chunk):
                chunks += 1
                records += chunk.records
                if chunk.trimCursor == 0xFFFF_FFFF && chunk.records == 0 && records == 0 {
                    log("History: the strap has nothing stored. It only saves data once its clock is set, so expect history from now on.")
                }
                if chunk.implausible > 0 {
                    log("History: skipped \(chunk.implausible) records dated outside the last 30 days")
                }
                guard save(chunk) else {
                    log("History: couldn't save a chunk, so not acknowledging it; stopping")
                    return finishDownload(ok: false)
                }
                send(.historicalDataResult, payload: Whoop5.historyAckPayload(endBlock: chunk.endBlock), withResponse: true)
            case .complete:
                finishDownload(ok: true)
            case .none:
                break
            }
        default:
            break
        }
    }

    private func handleResponse(cmd: UInt8, result: UInt8, body: [UInt8]) {
        switch cmd {
        case Whoop5.Command.getClock.rawValue:
            // The reply carries the strap's unix time somewhere in its body; find the word near now.
            let now = Int(Date().timeIntervalSince1970)
            var words: [Int] = []
            if body.count >= 4 {
                for i in 0...(body.count - 4) {
                    var word: UInt32 = 0
                    for k in 0..<4 { word |= UInt32(body[i + k]) << UInt32(8 * k) }
                    words.append(Int(word))
                }
            }
            if let t = words.first(where: { abs($0 - now) < 2 * 86_400 }) {
                log("Clock: strap reads \(t - now >= 0 ? "+" : "")\(t - now) s from the phone")
                onEvent(.clockOffset(t - now))
            } else {
                log("Clock: GET_CLOCK reply (result \(result)) had no recognisable time")
            }
        case Whoop5.Command.setClock.rawValue:
            if result != 1 { log("Clock: SET_CLOCK result \(result)") }
        case Whoop5.Command.sendHistoricalData.rawValue:
            if result == 0 || result == 3 {
                log("History: the strap declined the request (result \(result))")
                finishDownload(ok: false)
            }
        case Whoop5.Command.historicalDataResult.rawValue:
            if result != 1 && result != 2 { log("History: acknowledgement result \(result)") }
        case Ecg.Command.selectWrist.rawValue, Ecg.Command.generation.rawValue, Ecg.Command.liveFiltered.rawValue:
            log("ECG: ← \(Ecg.Command(rawValue: cmd)!) result \(result)")
            onEvent(.ecgResponse(cmd: cmd, result: result))
        default:
            break
        }
    }

    private func log(_ message: String) { Log.shared(message) }
}

// MARK: - CBCentralManagerDelegate

extension StrapLink: CBCentralManagerDelegate {
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        restored = peripherals.first { $0.identifier == savedId } ?? peripherals.first
        restored?.delegate = self
        log("iOS relaunched the app for the strap")
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            reconnectSaved()
        case .unauthorized:
            log("Bluetooth permission is off: Settings → Strap Sync → Bluetooth")
            resetLink()
            state = .bluetoothOff
        default:
            log("Bluetooth is \(central.state == .poweredOff ? "off" : "unavailable (state \(central.state.rawValue))")")
            resetLink()
            state = .bluetoothOff
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi: NSNumber) {
        let name = p.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? "WHOOP"
        let isNew = found[p.identifier] == nil
        found[p.identifier] = FoundStrap(id: p.identifier, name: name, rssi: rssi.intValue == 127 ? nil : rssi.intValue)
        if isNew { log("Found \(name) (\(rssi) dBm)") }
        onEvent(.found(sortedFound))
    }

    func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        log("Connected to \(p.name ?? "strap")")
        setUp(p)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        log("Couldn't connect: \(error?.localizedDescription ?? "unknown"); retrying in 5 s")
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, p.identifier == self.savedId else { return }
            self.connect(p)
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        let wasHello = helloOutstanding
        helloOutstanding = false
        resetLink()
        log("Disconnected\(error.map { ": \($0.localizedDescription)" } ?? "")")
        if wasHello { pairingFailed("the link dropped while pairing") }
        guard p.identifier == savedId else { return }
        state = .disconnected
        // A pending connect never times out: iOS wakes the app when the strap is back in range.
        connect(p)
    }
}

// MARK: - CBPeripheralDelegate

extension StrapLink: CBPeripheralDelegate {
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { return log("Service discovery failed: \(error.localizedDescription)") }
        for s in p.services ?? [] {
            switch s.uuid {
            case hrService: p.discoverCharacteristics([hrChar], for: s)
            case batteryService: p.discoverCharacteristics([batteryChar], for: s)
            case disService: p.discoverCharacteristics(Array(disFields.keys), for: s)
            case whoopService: p.discoverCharacteristics([commandUUID] + Array(notifyUUIDs), for: s)
            default: break
            }
        }
        if p.services?.contains(where: { $0.uuid == whoopService }) != true {
            log("This strap has no WHOOP 5.0 / MG service; live heart rate only")
        }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        if let error { return log("Characteristic discovery failed: \(error.localizedDescription)") }
        for c in s.characteristics ?? [] {
            if c.uuid == hrChar {
                p.setNotifyValue(true, for: c)
            } else if c.uuid == batteryChar {
                p.readValue(for: c)
                if c.properties.contains(.notify) { p.setNotifyValue(true, for: c) }
            } else if disFields[c.uuid] != nil {
                p.readValue(for: c)
            } else if notifyUUIDs.contains(c.uuid) {
                notifyChars.append(c)
                reassemblers[c.uuid] = Reassembler()
            } else if c.uuid == commandUUID {
                commandChar = c
            }
        }
        // Hello once the whole WHOOP service is known; subscriptions to its channels wait for the bond.
        if s.uuid == whoopService, commandChar != nil, !bonded, !helloOutstanding {
            sendHello()
        }
    }

    func peripheral(_ p: CBPeripheral, didWriteValueFor c: CBCharacteristic, error: Error?) {
        guard c.uuid == commandUUID else { return }
        if !bonded {
            // Only a write completion on the command characteristic counts as the hello's answer (#1635).
            // Nothing else is written before the bond, so a late success (after the timeout) still counts.
            let wasOutstanding = helloOutstanding
            helloOutstanding = false
            if error == nil {
                didBond()
            } else if wasOutstanding, let error {
                let code = (error as? CBATTError)?.code
                if code == .insufficientAuthentication || code == .insufficientEncryption {
                    pairingFailed("the strap refused to pair (\(error.localizedDescription)); it may be paired to another phone")
                } else if (error as? CBError)?.code == .peerRemovedPairingInformation {
                    pairingFailed("the strap forgot this phone; use Forget This Device in Settings → Bluetooth")
                } else {
                    pairingFailed(error.localizedDescription)
                }
            }
        } else if let error {
            log("Command write failed: \(error.localizedDescription)")
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        if let error { log("Subscribe to \(c.uuid) failed: \(error.localizedDescription)") }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard error == nil, let value = c.value else { return }
        let bytes = [UInt8](value)
        if c.uuid == hrChar {
            guard let m = HeartRateMeasurement.parse(bytes) else { return }
            if !loggedLiveHR {
                loggedLiveHR = true
                log("Live heart rate: \(m.bpm) bpm, \(m.rrRaw.count) RR, contact \(m.contact)")
            }
            onEvent(.liveHR(m, at: Int(Date().timeIntervalSince1970)))
            // History cadence rides the live stream, which keeps waking the app in the background.
            if bonded, handshakeDone, !downloading { requestHistoryIfDue(reason: "every \(Int(historyEvery / 60)) min", interval: historyEvery) }
        } else if c.uuid == batteryChar, let level = bytes.first {
            onEvent(.battery(Int(level)))
        } else if let field = disFields[c.uuid] {
            let text = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .controlCharacters.union(.whitespaces))
            guard info[keyPath: field] != text else { return }
            info[keyPath: field] = text
            onEvent(.info(info))
        } else if let r = reassemblers[c.uuid] {
            for frame in r.feed(bytes) {
                guard Frame.isValid(frame) else {
                    badFrames += 1
                    if badFrames == 1 || badFrames % 100 == 0 { log("Dropped \(badFrames) damaged frames so far") }
                    continue
                }
                RawArchive.shared.append(frame)
                if let ecg = Ecg.filtered(frame) {
                    if ecgActive { onEvent(.ecgRecord(ecg, at: Date().timeIntervalSince1970)) }
                    continue
                }
                if let message = Whoop5Message.parse(frame) { handle(message) }
            }
        }
    }
}
