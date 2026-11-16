import Foundation

/// The bidirectional GRU from research/sleep-stages/gru.py, evaluated in Double: a linear layer with
/// ReLU, two bidirectional GRU layers (PyTorch's gate order r, z, n), and a linear layer to the four
/// stages, then softmax. Weights come from `export_gru.py` as JSON.
struct GRUNet {
    struct Linear: Decodable {
        let weight: [[Double]]
        let bias: [Double]

        func callAsFunction(_ x: [Double]) -> [Double] {
            zip(weight, bias).map { w, b in GRUNet.dot(w, x) + b }
        }
    }

    /// One direction of one layer. `w_ih` is 3H x input and `w_hh` 3H x H, rows in gate order r, z, n.
    struct Cell: Decodable {
        let wIh: [[Double]]
        let wHh: [[Double]]
        let bIh: [Double]
        let bHh: [Double]
        enum CodingKeys: String, CodingKey { case wIh = "w_ih", wHh = "w_hh", bIh = "b_ih", bHh = "b_hh" }

        func run(_ xs: [[Double]]) -> [[Double]] {
            let h = bHh.count / 3
            var state = [Double](repeating: 0, count: h)
            return xs.map { x in
                let gi = zip(wIh, bIh).map { w, b in GRUNet.dot(w, x) + b }
                let gh = zip(wHh, bHh).map { w, b in GRUNet.dot(w, state) + b }
                for j in 0..<h {
                    let r = 1 / (1 + exp(-(gi[j] + gh[j])))
                    let z = 1 / (1 + exp(-(gi[h + j] + gh[h + j])))
                    let n = tanh(gi[2 * h + j] + r * gh[2 * h + j])
                    state[j] = (1 - z) * n + z * state[j]
                }
                return state
            }
        }
    }

    struct Layer: Decodable {
        let forward: Cell
        let reverse: Cell
    }

    struct Weights: Decodable {
        let input: Linear
        let layers: [Layer]
        let output: Linear
        /// Feature columns whose missingness is an extra input (gru.prep): hr1, hr5, rot, temp.
        let flags: [Int]
        /// Columns the net was trained without, set missing before it sees them (gru.heart_only).
        let masked: [Int]
    }

    let w: Weights

    init(json: Data) throws {
        w = try JSONDecoder().decode(Weights.self, from: json)
    }

    /// gru.prep: missing values to 0, clipped to +-5, then a 0/1 column per flag for "missing".
    func prep(_ x: [[Double]]) -> [[Double]] {
        let masked = Set(w.masked)
        return x.map { row in
            let r = row.indices.map { masked.contains($0) ? .nan : row[$0] }
            return r.map { $0.isNaN ? 0 : min(max($0, -5), 5) } + w.flags.map { r[$0].isNaN ? 1 : 0 }
        }
    }

    /// Stage probabilities for a whole night of feature rows.
    func probabilities(_ x: [[Double]]) -> [[Double]] {
        var seq = prep(x).map { w.input($0).map { max($0, 0) } }
        for layer in w.layers {
            let f = layer.forward.run(seq)
            let b = Array(layer.reverse.run(seq.reversed()).reversed())
            seq = zip(f, b).map { $0 + $1 }
        }
        return seq.map { row in
            let o = w.output(row), m = o.max()!
            let e = o.map { exp($0 - m) }, s = e.reduce(0, +)
            return e.map { $0 / s }
        }
    }

    static func dot(_ a: [Double], _ b: [Double]) -> Double {
        var s = 0.0
        for i in a.indices { s += a[i] * b[i] }
        return s
    }
}
