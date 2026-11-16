import Foundation

/// A LightGBM multiclass model read from LightGBM's own text format (`Booster.model_to_string()`),
/// evaluated the way LightGBM does: numerical splits only, with its missing-value rules.
public struct GBDT {
    struct Tree {
        var feature: [Int] = []
        var threshold: [Double] = []
        var decision: [Int] = []
        var left: [Int] = []
        var right: [Int] = []
        var leaf: [Double] = []
    }

    let classes: Int
    let trees: [Tree]

    public enum ReadError: Error { case malformed(String) }

    public init(text: String) throws {
        var classes = 0
        var trees: [Tree] = []
        var tree: Tree?
        func numbers<T>(_ s: Substring, _ f: (Substring) -> T?) throws -> [T] {
            try s.split(separator: " ").map { guard let v = f($0) else { throw ReadError.malformed(String(s.prefix(40))) }; return v }
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("Tree=") {
                if let t = tree { trees.append(t) }
                tree = Tree()
                continue
            }
            if line == "end of trees" { break }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq], value = line[line.index(after: eq)...]
            if tree == nil {
                if key == "num_class" { classes = Int(value) ?? 0 }
                continue
            }
            switch key {
            case "split_feature": tree!.feature = try numbers(value) { Int($0) }
            case "threshold": tree!.threshold = try numbers(value) { Double($0) }
            case "decision_type": tree!.decision = try numbers(value) { Int($0) }
            case "left_child": tree!.left = try numbers(value) { Int($0) }
            case "right_child": tree!.right = try numbers(value) { Int($0) }
            case "leaf_value": tree!.leaf = try numbers(value) { Double($0) }
            default: break
            }
        }
        if let t = tree { trees.append(t) }
        guard classes > 1, !trees.isEmpty, trees.count % classes == 0 else { throw ReadError.malformed("\(classes) classes, \(trees.count) trees") }
        for t in trees where t.leaf.isEmpty || t.feature.count != t.leaf.count - 1 { throw ReadError.malformed("tree shape") }
        self.classes = classes
        self.trees = trees
    }

    static func value(_ t: Tree, _ x: [Double]) -> Double {
        guard !t.feature.isEmpty else { return t.leaf[0] }
        var node = 0
        while node >= 0 {
            var v = x[t.feature[node]]
            let missing = (t.decision[node] >> 2) & 3            // 0 none, 1 zero, 2 NaN
            let defaultLeft = t.decision[node] & 2 != 0
            if v.isNaN && missing != 2 { v = 0 }
            if (missing == 1 && abs(v) <= 1e-35) || (missing == 2 && v.isNaN) {
                node = defaultLeft ? t.left[node] : t.right[node]
            } else {
                node = v <= t.threshold[node] ? t.left[node] : t.right[node]
            }
        }
        return t.leaf[~node]
    }

    /// Class probabilities (softmax of the summed trees) for one row of features.
    public func probabilities(_ x: [Double]) -> [Double] {
        var score = [Double](repeating: 0, count: classes)
        for (i, t) in trees.enumerated() { score[i % classes] += GBDT.value(t, x) }
        let top = score.max()!
        let e = score.map { exp($0 - top) }
        let sum = e.reduce(0, +)
        return e.map { $0 / sum }
    }
}
