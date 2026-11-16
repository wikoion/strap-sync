import Foundation

/// Breathing rate from heartbeat timing (respiratory sinus arrhythmia): the heart speeds up on each
/// breath in and slows on each breath out, so the RR intervals oscillate at the breathing rate.
///
/// The RR series is turned into a tachogram on its own beat clock, resampled at 4 Hz, detrended and
/// windowed, and the strongest frequency between 0.1 and 0.5 Hz (6–30 breaths/min) is the rate. Only a
/// clear peak counts, so restless or irregular stretches give nothing rather than a guess.
public enum Respiration {
    /// How far above the band's average power the peak must stand.
    public static let minStrength = 6.0
    static let sampleRate = 4.0

    public static func rate(_ rr: [Int]) -> (breathsPerMinute: Double, strength: Double)? {
        guard rr.count >= 60 else { return nil }
        var times: [Double] = []
        var elapsed = 0.0
        for r in rr {
            elapsed += Double(r) / 1000
            times.append(elapsed)
        }
        let values = rr.map(Double.init)
        let n = Int((times[times.count - 1] - times[0]) * sampleRate)
        guard n >= 240 else { return nil }

        // Linear interpolation onto an even 4 Hz grid.
        var x = [Double](repeating: 0, count: n)
        var j = 0
        for k in 0..<n {
            let t = times[0] + Double(k) / sampleRate
            while j < times.count - 2 && times[j + 1] < t { j += 1 }
            let span = times[j + 1] - times[j]
            x[k] = span > 0 ? values[j] + (values[j + 1] - values[j]) * (t - times[j]) / span : values[j]
        }

        // Remove the mean and linear trend, then apply a Hann window.
        let kMean = Double(n - 1) / 2
        let xMean = x.reduce(0, +) / Double(n)
        var sxy = 0.0, sxx = 0.0
        for k in 0..<n {
            let dk = Double(k) - kMean
            sxy += dk * (x[k] - xMean)
            sxx += dk * dk
        }
        let slope = sxy / sxx
        for k in 0..<n {
            let hann = 0.5 - 0.5 * cos(2 * Double.pi * Double(k) / Double(n - 1))
            x[k] = (x[k] - xMean - slope * (Double(k) - kMean)) * hann
        }

        var best = (f: 0.0, power: 0.0)
        var total = 0.0
        var bins = 0
        for f in stride(from: 0.1, through: 0.5, by: 0.005) {
            let w = 2 * Double.pi * f / sampleRate
            var re = 0.0, im = 0.0
            for k in 0..<n {
                re += x[k] * cos(w * Double(k))
                im -= x[k] * sin(w * Double(k))
            }
            let power = re * re + im * im
            total += power
            bins += 1
            if power > best.power { best = (f, power) }
        }
        guard total > 0 else { return nil }
        let strength = best.power / (total / Double(bins))
        guard strength >= minStrength else { return nil }
        return (best.f * 60, strength)
    }
}
