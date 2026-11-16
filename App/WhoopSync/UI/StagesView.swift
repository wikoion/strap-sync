import SwiftUI
import SyncCore

/// The latest night's sleep stages: a hypnogram and the time in each. The same stages go to Health
/// as Awake / Core / Deep / REM.
struct StagesSection: View {
    let night: StagedNight

    var body: some View {
        Section {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Hypnogram.order, id: \.self) { s in
                        Text(Self.name(s)).font(.caption2).foregroundStyle(.secondary).frame(height: 24)
                    }
                }
                VStack(spacing: 2) {
                    Hypnogram(stages: night.stages).frame(height: 96)
                    HStack {
                        Text(time(night.start)); Spacer(); Text(time(night.end))
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
            ForEach([SleepStage.wake, .light, .deep, .rem], id: \.self) { s in
                LabeledContent {
                    Text(Self.duration(night.minutes(s)))
                } label: {
                    Label { Text(Self.name(s)) } icon: { Circle().fill(Hypnogram.color(s)).frame(width: 10, height: 10) }
                }
            }
        } header: {
            Text("Sleep stages (experimental)")
        } footer: {
            Text("Estimated from your heart-rate variability and wrist movement by a model trained and tested on public research recordings, not yet checked against this strap's own beats. Wake is its weakest stage. Written to Apple Health as Awake, Core, Deep and REM.")
        }
    }

    private func time(_ t: Int) -> String {
        Date(timeIntervalSince1970: TimeInterval(t)).formatted(date: .omitted, time: .shortened)
    }

    static func name(_ s: SleepStage) -> String {
        switch s {
        case .wake: return "Awake"
        case .light: return "Light"
        case .deep: return "Deep"
        case .rem: return "REM"
        }
    }

    static func duration(_ minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
    }
}

/// Stages as bars, in the usual hypnogram order: awake on top, then REM, light, deep.
struct Hypnogram: View {
    let stages: [SleepStage]
    static let order: [SleepStage] = [.wake, .rem, .light, .deep]

    static func color(_ s: SleepStage) -> Color {
        switch s {
        case .wake: return .orange
        case .rem: return .cyan
        case .light: return .blue
        case .deep: return .indigo
        }
    }

    var body: some View {
        Canvas { ctx, size in
            guard !stages.isEmpty else { return }
            let rowHeight = size.height / CGFloat(Self.order.count)
            let width = size.width / CGFloat(stages.count)
            var i = 0
            while i < stages.count {
                var j = i
                while j < stages.count && stages[j] == stages[i] { j += 1 }
                let row = CGFloat(Self.order.firstIndex(of: stages[i])!)
                let rect = CGRect(x: CGFloat(i) * width, y: row * rowHeight + 3,
                                  width: max(CGFloat(j - i) * width, 1), height: rowHeight - 6)
                ctx.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(Self.color(stages[i])))
                i = j
            }
        }
    }
}
