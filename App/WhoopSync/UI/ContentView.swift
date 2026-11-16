import SwiftUI
import SyncCore

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var health: HealthWriter
    @State private var scanning = false
    @State private var recordingEcg = false

    var body: some View {
        NavigationStack {
            List {
                strapSection
                if let night = model.lastStages {
                    StagesSection(night: night)
                }
                healthSection
                if model.strap.hasStrap {
                    EcgSection { recordingEcg = true }
                    #if PERSONAL
                    PersonalHooks.section(model)
                    #endif
                }
                if model.strap.hasStrap && !model.strap.isBonded {
                    pairingHelp
                }
                Section {
                    NavigationLink("Log") { LogView() }
                }
            }
            .navigationTitle("Strap Sync")
            .sheet(isPresented: $scanning) { ScanView() }
            .sheet(isPresented: $recordingEcg) {
                EcgSheet().interactiveDismissDisabled(model.ecgBusy)
            }
        }
    }

    private var strapSection: some View {
        Section("Strap") {
            row("Status", linkText)
            if model.strap.hasStrap {
                row("Pairing", pairingText)
                row("Model", [model.info.variant, model.info.firmware.map { "fw \($0)" }].compactMap { $0 }.joined(separator: " · "))
                if let b = model.battery { row("Battery", "\(b)%") }
                if let hr = model.lastHR {
                    TimelineView(.periodic(from: .now, by: 5)) { _ in
                        row("Heart rate", "\(hr.bpm) bpm · \(ago(hr.at))")
                    }
                }
                if let o = model.clockOffset { row("Strap clock", o == 0 ? "matches the phone" : "\(o) s from the phone") }
                row("History", historyText)
                if let open = openNightText { row("Sleep", open) }
                if let night = nightText { row("Last night", night) }
                if let t = model.skinTemp {
                    row("Skin temperature", String(format: "%.1f °C · ", t.celsius) + ago(t.at))
                }
            }
            if model.strap.hasStrap {
                Button("Download history now") { model.downloadNow() }
                    .disabled(!model.strap.isBonded || model.downloading)
                if !model.strap.isBonded {
                    Button("Pair (tap the strap until it flashes blue)") { model.strap.retryPairing() }
                }
                Button("Forget strap", role: .destructive) { model.forget() }
            } else {
                Button("Find strap") { scanning = true }
            }
        }
    }

    private var healthSection: some View {
        Section {
            ForEach(PlannedSample.Kind.allCases, id: \.self) { kind in
                row(HealthWriter.name(kind), health.allowed.contains(kind) ? "\(model.writtenToday[kind] ?? 0)" : "not allowed")
            }
            row("Waiting to write", "\(model.pending)")
            if let w = health.lastWrite {
                TimelineView(.periodic(from: .now, by: 30)) { _ in row("Last write", ago(w)) }
            }
            if let e = health.lastError { Text(e).font(.footnote).foregroundStyle(.secondary) }
            if !health.missing.isEmpty {
                Button(health.allowed.isEmpty ? "Connect Apple Health" : "Allow the other types in Apple Health") {
                    Task { await model.connectHealth() }
                }
            } else {
                Button("Write to Apple Health now") { model.writeNow() }
                    .disabled(model.downloading)
            }
        } header: {
            Text("Apple Health, written today")
        } footer: {
            Text("Sleep, resting heart rate and breathing rate are written once you're up: five minutes awake and moving about, or twelve awake in bed. If you fall asleep again within an hour, the night is written again with the extra sleep: as far as it has got whenever the phone is unlocked, and whole once you're up. Blood oxygen is written as the strap takes its readings during sleep. Steps, sleep and blood oxygen come from the strap's own sensors and haven't been checked against a reference yet.")
        }
    }

    /// The night under way: "Asleep since 02:24", or "Woke 10:37 · written once you're up, by 10:49 at the latest".
    /// Written before and slept on since, also how far what's written goes: "Asleep since 23:10 · written up to 07:42".
    private var openNightText: String? {
        guard let open = model.openNight else { return nil }
        let n = open.night, awake = open.awake
        func time(_ t: Int) -> String { Date(timeIntervalSince1970: TimeInterval(t)).formatted(date: .omitted, time: .shortened) }
        if let until = model.openWrittenUntil {
            return (awake ? "Woke \(time(n.end))" : "Asleep since \(time(n.fellAsleep))") + " · written up to \(time(until))"
        }
        return awake ? "Woke \(time(n.end)) · written once you're up, by \(time(n.end + Sleep.settle * 60)) at the latest"
            : "Asleep since \(time(n.fellAsleep))"
    }

    private var nightText: String? {
        guard let n = model.lastNight else { return nil }
        let start = Date(timeIntervalSince1970: TimeInterval(n.start)).formatted(date: .omitted, time: .shortened)
        let end = Date(timeIntervalSince1970: TimeInterval(n.end)).formatted(date: .omitted, time: .shortened)
        return "\(start)–\(end), \(n.asleepSeconds / 3600)h \(n.asleepSeconds % 3600 / 60)m asleep"
    }

    private var pairingHelp: some View {
        Section("Pairing") {
            Text("""
                The strap only accepts pairing while its lights flash blue.
                1. Delete the WHOOP app, and make sure no other phone has it running.
                2. If Settings → Bluetooth lists your WHOOP, tap ⓘ → Forget This Device.
                3. Hold the strap next to the phone and tap Pair above. It keeps trying for a minute.
                4. Tap the strap firmly and repeatedly until its lights flash blue.
                5. If iOS asks to pair, tap Pair.

                Live heart rate works without pairing, but history (filling gaps while the phone was \
                away) needs it.
                """)
            .font(.footnote)
        }
    }

    private var linkText: String {
        switch model.link {
        case .bluetoothOff: return "Bluetooth off"
        case .noStrap: return "No strap chosen"
        case .connecting: return "Waiting for the strap…"
        case .connected: return "Connected"
        case .disconnected: return "Disconnected"
        }
    }

    private var pairingText: String {
        switch model.pairing {
        case .unknown: return "Not yet"
        case .waiting: return "Trying to pair…"
        case .bonded: return "Paired"
        case .refused(let n): return "Failed (\(n)×), retrying on reconnect"
        case .paused: return "Paused, live heart rate only"
        }
    }

    private var historyText: String {
        if model.downloading {
            let p = model.downloadProgress
            guard p.records > 0 else { return "Downloading…" }
            return "Downloading: \(p.records.formatted()) records" + (p.upTo.map { ", up to \($0.formatted(date: .omitted, time: .shortened))" } ?? "")
        }
        guard let d = model.lastDownload else { return "Not yet" }
        return "\(d.ok ? "Done" : "Stopped") \(ago(d.at)), \(d.records) records"
    }

    private func row(_ label: String, _ value: String) -> some View {
        LabeledContent(label, value: value)
    }

    private func ago(_ date: Date) -> String {
        let s = Int(-date.timeIntervalSinceNow)
        if s < 60 { return "just now" }
        if s < 3600 { return "\(s / 60) min ago" }
        return date.formatted(date: .omitted, time: .shortened)
    }
}

struct ScanView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if model.found.isEmpty {
                        Text("Looking for WHOOP 5.0 / MG straps… Keep the strap close. If it doesn't show up, tap it until its lights flash blue. After you pick it, if iOS asks to pair, tap Pair.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.found) { s in
                        Button {
                            model.choose(s)
                            dismiss()
                        } label: {
                            LabeledContent(s.name, value: s.rssi.map { "\($0) dBm" } ?? "connected")
                        }
                    }
                } footer: {
                    Text("Delete the WHOOP app first: it competes for the strap.")
                }
            }
            .navigationTitle("Find strap")
            .toolbar { Button("Cancel") { dismiss() } }
            .onAppear { model.strap.startScan() }
            .onDisappear { model.strap.stopScan() }
        }
    }
}

struct LogView: View {
    @EnvironmentObject private var log: Log

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(log.lines.enumerated()), id: \.offset) { i, line in
                        Text(line).font(.caption.monospaced()).textSelection(.enabled).id(i)
                    }
                }
                .padding(.horizontal)
            }
            .onAppear { proxy.scrollTo(log.lines.count - 1, anchor: .bottom) }
        }
        .navigationTitle("Log")
        .toolbar { ShareLink(item: log.text) }
    }
}
