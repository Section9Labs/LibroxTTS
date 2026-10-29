#if os(macOS)
import Foundation
import Dispatch
import MLX

/// Offline numerical helper only. Never selected by a renderer or model loader.
enum CertifiedHalfProjection {
    enum Failure: Error { case configuration, nonfinite, timeout }
    struct Budget {
        let began = DispatchTime.now().uptimeNanoseconds
        func check() throws {
            try Task.checkCancellation()
            try ChatterboxMLXRenderer.healthy()
            guard DispatchTime.now().uptimeNanoseconds - began <= 180_000_000_000 else { throw Failure.timeout }
        }
    }
    struct Statistics: Codable {
        var certified = 0
        var exactFallback = 0
        var outputs: Int { certified + exactFallback }
    }
    struct Result {
        let values: [Float16]
        let shape: [Int]
        let statistics: Statistics
        let boundaries: [Boundary]
    }
    struct Boundary: Codable {
        let row: Int
        let column: Int
        let k: Int
        let fp64Sum: Double
        let maximumInput: Double
        let maximumWeight: Double
        let exactHalfBits: UInt16
    }

    static func coefficient(_ bits: UInt16) throws -> Int128 {
        let exponent = Int((bits >> 10) & 31), mantissa = Int128(bits & 1023)
        guard exponent != 31 else { throw Failure.nonfinite }
        let magnitude = exponent == 0 ? mantissa : (1024 + mantissa) << (exponent - 1)
        return bits & 0x8000 != 0 ? -magnitude : magnitude
    }
    /// Exact integer*2^-48 to IEEE half, nearest/ties-to-even. Exact zero is +0.
    static func roundedHalf(_ value: Int128) -> UInt16 {
        guard value != 0 else { return 0 }
        let sign: UInt16 = value < 0 ? 0x8000 : 0
        let magnitude = value.magnitude
        let shift = max(24, 128 - magnitude.leadingZeroBitCount - 11)
        var quotient = magnitude >> shift
        let remainder = magnitude & ((UInt128(1) << shift) - 1)
        let midpoint = UInt128(1) << (shift - 1)
        if remainder > midpoint || (remainder == midpoint && quotient & 1 != 0) { quotient += 1 }
        let units = (quotient << shift) >> 24
        if units < 1024 { return sign | UInt16(units) }
        let exponent = 128 - units.leadingZeroBitCount - 10
        if exponent >= 31 { return sign | 0x7C00 }
        let mantissa = UInt16((units >> (exponent - 1)) - 1024)
        return sign | UInt16(exponent << 10) | mantissa
    }
    static func exact(_ x: [Float16], _ w: [Float16], xOffset: Int = 0,
                      wOffset: Int = 0, count: Int) throws -> UInt16 {
        guard (1...4096).contains(count), xOffset >= 0, wOffset >= 0,
            xOffset + count <= x.count, wOffset + count <= w.count else { throw Failure.configuration }
        var sum: Int128 = 0
        for index in 0..<count {
            sum += try coefficient(x[xOffset + index].bitPattern) * coefficient(w[wOffset + index].bitPattern)
        }
        // Finite half coefficients are <2^40; products <2^80; K<=4096 => <2^92.
        return roundedHalf(sum)
    }

    /// Assumes ordinary IEEE binary64 accumulation in CPU BLAS. Half products
    /// are exact in binary64. gamma_K*K*max|x|*max|w| bounds accumulation error
    /// independent of addition order; directed endpoint inflation is explicit.
    static func certificate(sum: Double, k: Int, xMax: Double, wMax: Double) throws -> UInt16? {
        guard (1...4096).contains(k), sum.isFinite, xMax.isFinite, wMax.isFinite,
            (0...65504).contains(xMax), (0...65504).contains(wMax),
            Double(Float16(xMax)) == xMax, Double(Float16(wMax)) == wMax else { throw Failure.configuration }
        if xMax == 0 || wMax == 0 {
            guard sum == 0 else { throw Failure.nonfinite }
            return 0
        }
        let u = Double.ulpOfOne / 2
        let gamma = (Double(k) * u / (1 - Double(k) * u)).nextUp
        // For half maxima and K<=4096 this magnitude bound is exact in binary64.
        let magnitudeBound = Double(k) * xMax * wMax
        let error = (gamma * magnitudeBound).nextUp
        guard abs(sum) <= (magnitudeBound + error).nextUp else { throw Failure.configuration }
        let lower = Float16((sum - error).nextDown).bitPattern
        let upper = Float16((sum + error).nextUp).bitPattern
        return lower == upper ? lower : nil
    }

    static func evaluate(input: MLXArray, weight: MLXArray, budget: Budget) throws -> Result {
        try budget.check()
        guard input.dtype == .float16, weight.dtype == .float16,
            input.ndim == 3, weight.ndim == 2, input.dim(0) == 2,
            (1...93).contains(input.dim(1)), [1024, 4096].contains(input.dim(2)),
            [1024, 4096].contains(weight.dim(0)), weight.dim(1) == input.dim(2)
        else { throw Failure.configuration }
        let k = input.dim(2), n = weight.dim(0), m = input.size / k
        let x = input.asArray(Float16.self), w = weight.asArray(Float16.self)
        var xMax = [Double](repeating: 0, count: m), wMax = [Double](repeating: 0, count: n)
        for row in 0..<m {
            for index in 0..<k {
                let value = x[row * k + index]
                guard value.isFinite else { throw Failure.nonfinite }
                xMax[row] = max(xMax[row], abs(Double(value)))
            }
        }
        for row in 0..<n {
            if row % 64 == 0 { try budget.check() }
            for index in 0..<k {
                let value = w[row * k + index]
                guard value.isFinite else { throw Failure.nonfinite }
                wMax[row] = max(wMax[row], abs(Double(value)))
            }
        }
        let sums = matmul(input.asType(.float64, stream: .cpu),
            weight.asType(.float64, stream: .cpu).T, stream: .cpu)
        guard sums.dtype == .float64 else { throw Failure.configuration }
        let actual = sums.asArray(Double.self)
        guard actual.count == m * n, actual.allSatisfy(\.isFinite) else { throw Failure.nonfinite }
        try budget.check()
        var values = [Float16](); values.reserveCapacity(m * n)
        var statistics = Statistics()
        var boundaries: [Boundary] = []
        for row in 0..<m {
            try budget.check()
            for column in 0..<n {
                if column % 64 == 0 { try budget.check() }
                let bits: UInt16
                if let certified = try certificate(sum: actual[row * n + column], k: k,
                                                   xMax: xMax[row], wMax: wMax[column]) {
                    bits = certified; statistics.certified += 1
                } else {
                    bits = try exact(x, w, xOffset: row * k, wOffset: column * k, count: k)
                    statistics.exactFallback += 1
                    boundaries.append(Boundary(row: row, column: column, k: k,
                        fp64Sum: actual[row * n + column], maximumInput: xMax[row],
                        maximumWeight: wMax[column], exactHalfBits: bits))
                }
                let result = Float16(bitPattern: bits)
                guard result.isFinite else { throw Failure.nonfinite }
                values.append(result)
            }
        }
        var shape = input.shape; shape[shape.count - 1] = n
        return Result(values: values, shape: shape, statistics: statistics, boundaries: boundaries)
    }
}
#endif
