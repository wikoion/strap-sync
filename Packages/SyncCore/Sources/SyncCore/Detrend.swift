import Foundation

/// Smoothness-priors detrending (Tarvainen, Ranta-aho & Karjalainen 2002), as Kubios applies it before short-term
/// HRV: the trend z solves (I + λ²D₂ᵀD₂) z = x, with D₂ the second-difference matrix, and the result is x − z.
/// λ = 500 removes what changes slower than about 0.035 Hz at a beat a second (drifts, and most of a step in heart
/// rate), and keeps the breathing and the ~0.1 Hz baroreflex rhythms.
public enum Detrend {
    public static let lambda = 500.0

    /// [x] minus its smooth trend. Under three values there's nothing to detrend, so it's only centred.
    public static func smoothnessPriors(_ x: [Double], lambda: Double = lambda) -> [Double] {
        let n = x.count
        guard n >= 3 else {
            let mean = x.reduce(0, +) / Double(max(n, 1))
            return x.map { $0 - mean }
        }
        // The matrix is symmetric with two bands: a[i] on the diagonal, b[i] at (i, i+1), c[i] at (i, i+2).
        let l2 = lambda * lambda
        var a = [Double](repeating: 1, count: n), b = [Double](repeating: 0, count: n), c = [Double](repeating: 0, count: n)
        for r in 0..<(n - 2) {
            // Row r of D₂ is 1, −2, 1 at columns r, r+1, r+2.
            a[r] += l2; a[r + 1] += 4 * l2; a[r + 2] += l2
            b[r] -= 2 * l2; b[r + 1] -= 2 * l2
            c[r] += l2
        }
        // LDLᵀ with L unit lower triangular: l1[i] = L(i, i−1), l2[i] = L(i, i−2).
        var d = [Double](repeating: 0, count: n), f1 = [Double](repeating: 0, count: n), f2 = [Double](repeating: 0, count: n)
        for i in 0..<n {
            if i >= 2 { f2[i] = c[i - 2] / d[i - 2] }
            if i >= 1 { f1[i] = (b[i - 1] - (i >= 2 ? f2[i] * f1[i - 1] * d[i - 2] : 0)) / d[i - 1] }
            d[i] = a[i] - (i >= 1 ? f1[i] * f1[i] * d[i - 1] : 0) - (i >= 2 ? f2[i] * f2[i] * d[i - 2] : 0)
        }
        var z = x
        for i in 1..<n { z[i] -= f1[i] * z[i - 1] + (i >= 2 ? f2[i] * z[i - 2] : 0) }
        for i in 0..<n { z[i] /= d[i] }
        for i in stride(from: n - 2, through: 0, by: -1) { z[i] -= f1[i + 1] * z[i + 1] + (i + 2 < n ? f2[i + 2] * z[i + 2] : 0) }
        return zip(x, z).map { $0 - $1 }
    }
}
