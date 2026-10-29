#if os(macOS)
import Foundation
import Accelerate

/// Offline reference GEMM/norm. Uses ordinary IEEE CPU64 BLAS, outward bounds
/// and exact dyadic fallback. Never used by a production renderer.
enum CertifiedReferenceMatrix {
    enum Failure: Error { case shape, nonfinite, certificate }
    final class Statistics {
        var certified = 0
        var exact128 = 0
        var bigint = 0
    }
    struct Pending {
        let index: Int
        let left: [Float]
        let right: [Float]
        let output: ReferenceDyadic.Output
    }
    typealias Resolver = ([Pending]) throws -> [UInt32]
    struct Prepared {
        let rows: Int, columns: Int
        let values: [Float], double: [Double], maxima: [Double]
    }
    static func prepare(_ values: [Float], rows: Int, columns: Int,
                        budget: CertifiedHalfProjection.Budget) throws -> Prepared {
        try budget.check()
        guard (1...8194).contains(rows), (1...4096).contains(columns),
            values.count == rows * columns, values.allSatisfy(\.isFinite) else { throw Failure.shape }
        try ChatterboxMLXRenderer.healthy(minimumAvailable: values.count * 8 + 1_073_741_824)
        var maxima = [Double](repeating: 0, count: rows)
        for row in 0..<rows {
            if row % 32 == 0 { try budget.check() }
            for x in values[row * columns..<(row + 1) * columns] { maxima[row] = max(maxima[row], abs(Double(x))) }
        }
        let double = values.map(Double.init)
        try budget.check()
        return Prepared(rows: rows, columns: columns, values: values, double: double, maxima: maxima)
    }
    static func certificate(sum: Double, count: Int, xMax: Double, wMax: Double,
                            output: ReferenceDyadic.Output, scale: Int = 0) throws -> UInt32? {
        guard (1...4096).contains(count), sum.isFinite, xMax.isFinite, wMax.isFinite,
            xMax >= 0, wMax >= 0, xMax <= Double(Float.greatestFiniteMagnitude),
            wMax <= Double(Float.greatestFiniteMagnitude), (-149...149).contains(scale) else { throw Failure.certificate }
        if xMax == 0 || wMax == 0 {
            guard sum == 0 else { throw Failure.certificate }
            return 0
        }
        let ku = Double(count) * (Double.ulpOfOne / 2)
        let gamma = (ku / (1 - ku)).nextUp
        // These products are NOT assumed exact for general F32 operands/K.
        let magnitude = ((Double(count) * xMax).nextUp * wMax).nextUp
        let error = (gamma * magnitude).nextUp
        guard abs(sum) <= (magnitude + error).nextUp else { throw Failure.certificate }
        let factor = Foundation.scalbn(1.0, Int32(scale))
        let lower = ((sum - error).nextDown * factor).nextDown
        let upper = ((sum + error).nextUp * factor).nextUp
        let a = output.bits(lower), b = output.bits(upper)
        return a == b ? a : nil
    }
    static func multiply(_ input: [Float], rows: Int, weight: Prepared,
                         output: ReferenceDyadic.Output, budget: CertifiedHalfProjection.Budget,
                         statistics: Statistics, resolver: Resolver) throws -> [Float] {
        let n = weight.rows, k = weight.columns, m = rows
        guard (1...1024).contains(m), input.count == m * k,
            input.allSatisfy(\.isFinite) else { throw Failure.shape }
        try budget.check()
        try ChatterboxMLXRenderer.healthy(minimumAvailable: (m * k + m * n) * 8 + 1_073_741_824)
        let x = input.map(Double.init)
        var sums = [Double](repeating: 0, count: m * n)
        x.withUnsafeBufferPointer { xp in
            weight.double.withUnsafeBufferPointer { wp in
                sums.withUnsafeMutableBufferPointer { sp in
                    cblas_dgemm(CblasRowMajor, CblasNoTrans, CblasTrans, Int32(m), Int32(n), Int32(k),
                                1, xp.baseAddress, Int32(k), wp.baseAddress, Int32(k), 0, sp.baseAddress, Int32(n))
                }
            }
        }
        try budget.check()
        var result = [Float](repeating: 0, count: m * n), pending: [Pending] = []
        for row in 0..<m {
            try budget.check()
            let range = row * k..<(row + 1) * k
            let maximum = input[range].reduce(0.0) { max($0, abs(Double($1))) }
            for column in 0..<n {
                if column % 64 == 0 { try budget.check() }
                let index = row * n + column
                if let bits = try certificate(sum: sums[index], count: k, xMax: maximum,
                                               wMax: weight.maxima[column], output: output) {
                    result[index] = try output.value(bits); statistics.certified += 1
                } else {
                    let wr = column * k..<(column + 1) * k
                    do {
                        result[index] = try output.value(ReferenceDyadic.dot(input[range], weight.values[wr], output: output))
                        statistics.exact128 += 1
                    } catch ReferenceDyadic.Failure.span {
                        guard pending.count < 4096, (pending.count + 1) * k * 2 <= 4_000_000 else { throw Failure.shape }
                        try ChatterboxMLXRenderer.healthy(minimumAvailable: (pending.count + 1) * k * 8 + 1_073_741_824)
                        pending.append(Pending(index: index, left: Array(input[range]),
                                               right: Array(weight.values[wr]), output: output))
                    }
                }
            }
        }
        if !pending.isEmpty {
            let bits = try resolver(pending)
            try budget.check()
            guard bits.count == pending.count else { throw Failure.shape }
            for (item, value) in zip(pending, bits) { result[item.index] = try output.value(value) }
            statistics.bigint += bits.count
        }
        try budget.check()
        return result
    }
    static func norm(_ input: [Float], weights: [Float], budget: CertifiedHalfProjection.Budget,
                     statistics: Statistics, resolver: Resolver) throws -> [Float] {
        guard weights.count == 1024, input.count % 1024 == 0, !input.isEmpty,
            input.count <= 1024 * 1024, input.allSatisfy(\.isFinite), weights.allSatisfy(\.isFinite) else { throw Failure.shape }
        var output: [Float] = []; output.reserveCapacity(input.count)
        for row in 0..<(input.count / 1024) {
            try budget.check()
            let values = input[row * 1024..<(row + 1) * 1024]
            let squares = values.map { $0 * $0 }
            guard squares.allSatisfy(\.isFinite) else { throw Failure.nonfinite }
            let sum = squares.reduce(0.0) { $0 + Double($1) }
            let maximum = squares.reduce(0.0) { max($0, Double($1)) }
            let bits: UInt32
            if let certified = try certificate(sum: sum, count: 1024, xMax: maximum, wMax: 1, output: .f32, scale: -10) {
                bits = certified; statistics.certified += 1
            } else {
                do {
                    bits = try ReferenceDyadic.reduce(squares.map { try ReferenceDyadic.term($0) }, binaryScale: -10)
                    statistics.exact128 += 1
                } catch ReferenceDyadic.Failure.span {
                    let pending = Pending(index: row, left: squares, right: Array(repeating: 0x1p-10, count: 1024), output: .f32)
                    let result = try resolver([pending])
                    guard result.count == 1 else { throw Failure.shape }
                    bits = result[0]; statistics.bigint += 1
                }
            }
            try budget.check()
            let mean = Float(bitPattern: bits)
            let inverse = try ReferenceDyadic.inverseRoot(mean + Float(1e-5))
            for (x, w) in zip(values, weights) {
                let scaled: Float = x * inverse
                let value: Float = scaled * w
                guard value.isFinite else { throw Failure.nonfinite }
                output.append(value)
            }
        }
        try budget.check()
        return output
    }
}
#endif
