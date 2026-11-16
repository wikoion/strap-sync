import SwiftUI
import SyncCore

/// The ECG section on the main screen: wrist, record, and recent recordings. The sheet itself is
/// presented from ContentView: one attached inside a List is dismissed when its row redraws.
struct EcgSection: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("ecgWrist") private var wrist = Int(Ecg.Wrist.left.rawValue)
    let record: () -> Void

    var body: some View {
        Section {
            Picker("Strap on", selection: $wrist) {
                Text("Left wrist").tag(Int(Ecg.Wrist.left.rawValue))
                Text("Right wrist").tag(Int(Ecg.Wrist.right.rawValue))
            }
            Button("Record ECG") {
                model.resetEcg()
                record()
            }
            .disabled(!model.strap.isBonded)
            ForEach(model.ecgRecordings.prefix(5)) { e in
                NavigationLink {
                    EcgDetailView(recording: e)
                } label: {
                    LabeledContent(Date(timeIntervalSince1970: TimeInterval(e.start)).formatted(date: .abbreviated, time: .shortened),
                                   value: e.heartRate.map { "\($0) bpm" } ?? "\(e.end - e.start) s")
                }
            }
        } header: {
            Text("ECG")
        } footer: {
            Text("WHOOP MG only. Uncalibrated, with no rhythm analysis: not a diagnosis. Recordings are shared with Wellmaxx for 7 days.")
        }
    }
}

/// How to, then the recording with a countdown, then the result.
struct EcgSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("ecgWrist") private var wristSetting = Int(Ecg.Wrist.left.rawValue)
    private var wrist: Ecg.Wrist { Ecg.Wrist(rawValue: UInt8(wristSetting)) ?? .left }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch model.ecgPhase {
                    case .idle, .finished(saved: false):
                        howTo
                    case .failed(let message):
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        howTo
                    case .starting, .recording, .saving:
                        recording
                    case .finished(saved: true):
                        result
                    }
                }
                .padding()
            }
            .navigationTitle("ECG")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if model.ecgBusy {
                    Button("Cancel", role: .cancel) { model.cancelEcg() }
                } else {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: How to

    private var howTo: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("How to take an ECG").font(.title2.bold())
            step(1, "chair.fill", "Sit down and rest the arm wearing the strap on a table.")
            step(2, "applewatch.side.right", "Make sure the strap is snug, with the sensor flat against your \(wrist.name) wrist.")
            step(3, "hand.point.up.left.fill",
                 "With your other hand, put your thumb and index finger on the two small indents on the strap's clasp, one on each.")
            step(4, "timer", "Press gently but firmly, then keep still and quiet for about \(Ecg.lengthSeconds) seconds. The countdown starts once the signal is clean.")
            Button {
                model.startEcg(wrist: wrist)
            } label: {
                Text("Start").font(.headline).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!model.strap.isBonded || model.downloading)
            if model.downloading {
                Text("Waiting for a history download to finish…").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func step(_ n: Int, _ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .frame(width: 36)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Step \(n)").font(.caption.bold()).foregroundStyle(.secondary)
                Text(text)
            }
        }
    }

    // MARK: Recording

    private var recording: some View {
        VStack(spacing: 20) {
            TimelineView(.periodic(from: .now, by: 0.2)) { context in
                countdown(at: context.date)
            }
            .frame(width: 200, height: 200)
            .frame(maxWidth: .infinity)

            if !model.ecgDone {
                Label(coaching.text, systemImage: coaching.symbol)
                    .foregroundStyle(coaching.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let s = model.ecgStatus, s.heartRate > 0 {
                Text("\(s.heartRate) bpm").font(.title3.bold())
            }

            EcgTrace(samples: model.ecgLive)
                .frame(height: 150)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    /// Seconds left on the phone's clock: whole seconds, counting down once a second, never 0 until the
    /// strap says it's done.
    @ViewBuilder
    private func countdown(at now: Date) -> some View {
        let length = Double(Ecg.lengthSeconds)
        let remaining = model.ecgDeadline.map { max(0, $0.timeIntervalSince(now)) }
        let fraction = model.ecgDone ? 1 : remaining.map { 1 - $0 / length } ?? 0
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.2), lineWidth: 14)
            Circle()
                .trim(from: 0, to: CGFloat(min(max(fraction, 0), 1)))
                .stroke(model.ecgDone ? Color.green : Color.red, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 4) {
                if model.ecgDone {
                    Image(systemName: "checkmark").font(.system(size: 48, weight: .bold)).foregroundStyle(.green)
                    Text("Done, you can let go").font(.headline)
                } else if let remaining {
                    Text("\(max(1, Int(remaining.rounded(.up))))")
                        .font(.system(size: 56, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("seconds left").font(.subheadline).foregroundStyle(.secondary)
                } else {
                    ProgressView()
                    Text(model.ecgPhase == .starting ? "Starting…"
                         : model.ecgRestarted ? "Signal dropped, hold still" : "Waiting for a clean signal")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding()
        }
    }

    private var coaching: (text: String, symbol: String, color: Color) {
        guard let s = model.ecgStatus else {
            return ("Put your thumb and index finger on the clasp's two indents.", "hand.point.up.left", .secondary)
        }
        if !s.present {
            return ("No contact: thumb and index finger on the clasp's two indents.", "hand.raised.slash", .orange)
        }
        if !s.signalGood {
            return ("Weak signal: rest your arm, press a little firmer, keep still and quiet.", "waveform.path.ecg", .orange)
        }
        return ("Good signal. Hold still.", "checkmark.circle.fill", .green)
    }

    // MARK: Result

    @ViewBuilder
    private var result: some View {
        Label("ECG saved", systemImage: "checkmark.circle.fill")
            .font(.title2.bold())
            .foregroundStyle(.green)
        if let e = model.ecgRecordings.first {
            if let hr = e.heartRate { Text("\(hr) bpm").font(.title3) }
            EcgTrace(samples: Array(e.samples.suffix(Int((e.sampleRateHz ?? 100) * 6))))
                .frame(height: 150)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
            Text("Saved in Strap Sync and shared with Wellmaxx. Uncalibrated, with no rhythm analysis: not a diagnosis.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        Button("Record another") { model.resetEcg() }
    }
}

struct EcgDetailView: View {
    let recording: EcgRecording

    var body: some View {
        List {
            Section {
                LabeledContent("Time", value: Date(timeIntervalSince1970: TimeInterval(recording.start)).formatted(date: .abbreviated, time: .standard))
                LabeledContent("Length", value: "\(recording.end - recording.start) s")
                if let hr = recording.heartRate {
                    LabeledContent("Heart rate", value: "\(hr) bpm")
                    if let source = recording.heartRateSource {
                        LabeledContent("Heart rate from", value: source == "ecg" ? "ECG trace" : source == "optical" ? "Wrist sensor" : "Strap")
                    }
                }
                LabeledContent("Wrist", value: recording.wrist.capitalized)
                if let rate = recording.sampleRateHz { LabeledContent("Sample rate (estimated)", value: String(format: "%.0f Hz", rate)) }
                LabeledContent("Completed", value: recording.progress >= 100 ? "Yes" : "\(recording.progress)%")
            }
            Section {
                ScrollView(.horizontal) {
                    EcgTrace(samples: recording.samples)
                        .frame(width: max(320, CGFloat(recording.samples.count) / CGFloat(recording.sampleRateHz ?? 100) * 60),
                               height: 200)
                }
            } footer: {
                Text("Uncalibrated amplitude from the strap's filtered ECG. No rhythm analysis: not a diagnosis.")
            }
        }
        .navigationTitle("ECG")
    }
}

/// A waveform drawn to fit its box.
struct EcgTrace: View {
    let samples: [Int]

    var body: some View {
        Canvas { context, size in
            guard samples.count > 1, let lo = samples.min(), let hi = samples.max() else { return }
            let span = max(Double(hi - lo), 1)
            var path = Path()
            for (i, v) in samples.enumerated() {
                let point = CGPoint(x: size.width * CGFloat(i) / CGFloat(samples.count - 1),
                                    y: size.height * (1 - CGFloat(Double(v - lo) / span)) * 0.9 + size.height * 0.05)
                i == 0 ? path.move(to: point) : path.addLine(to: point)
            }
            context.stroke(path, with: .color(.red), lineWidth: 1.2)
        }
    }
}
