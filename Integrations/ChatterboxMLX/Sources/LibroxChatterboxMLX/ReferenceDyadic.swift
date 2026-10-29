#if os(macOS)
import Foundation

/// Diagnostic exact dyadic arithmetic. Overwide reductions throw before any
/// shift/add; their caller must use the audited bigint resolver, never native.
enum ReferenceDyadic {
    enum Failure: Error { case nonfinite, span, shape }
    enum Output: String, Codable { case f16, f32
        var fraction: Int { self == .f16 ? 10 : 23 }
        var bias: Int { self == .f16 ? 15 : 127 }
        func bits(_ value: Double) -> UInt32 {
            self == .f16 ? UInt32(Float16(value).bitPattern) : Float(value).bitPattern
        }
        func value(_ bits: UInt32) throws -> Float {
            let value = self == .f16 ? Float(Float16(bitPattern: UInt16(exactly: bits) ?? 0x7C00)) : Float(bitPattern: bits)
            guard value.isFinite else { throw Failure.nonfinite }
            return value
        }
    }
    struct Term {
        let coefficient: Int128
        let exponent: Int
    }
    static func term(_ value: Float) throws -> Term {
        guard value.isFinite else { throw Failure.nonfinite }
        let b = value.bitPattern, field = Int((b >> 23) & 255)
        var m = UInt32(b & 0x7FFFFF)
        if field != 0 { m |= 0x800000 }
        if m == 0 { return Term(coefficient: 0, exponent: 0) }
        let zeros = m.trailingZeroBitCount
        let exponent = (field == 0 ? -149 : field - 150) + zeros
        m >>= zeros
        let signed = b & 0x80000000 != 0 ? -Int128(m) : Int128(m)
        return Term(coefficient: signed, exponent: exponent)
    }
    static func reduce(_ terms: [Term], binaryScale: Int = 0, output: Output = .f32) throws -> UInt32 {
        let active = terms.filter { $0.coefficient != 0 }
        guard let minimum = active.map(\.exponent).min() else { return 0 }
        let countBits = active.count <= 1 ? 0 : Int.bitWidth - (active.count - 1).leadingZeroBitCount
        for t in active {
            let width = 128 - t.coefficient.magnitude.leadingZeroBitCount
            let shift = t.exponent - minimum
            guard shift >= 0, shift < 127, width + shift + countBits <= 126 else { throw Failure.span }
        }
        var sum: Int128 = 0
        for t in active { sum += t.coefficient << (t.exponent - minimum) }
        return rounded(sum, exponent: minimum + binaryScale, output: output)
    }
    static func dot(_ x: ArraySlice<Float>, _ w: ArraySlice<Float>, output: Output) throws -> UInt32 {
        guard x.count == w.count, (1...4096).contains(x.count) else { throw Failure.shape }
        let terms = try zip(x, w).map { a, b -> Term in
            let l = try term(a), r = try term(b)
            return Term(coefficient: l.coefficient * r.coefficient, exponent: l.exponent + r.exponent)
        }
        return try reduce(terms, output: output)
    }
    /// Exact integer*2^exponent to nearest/ties-even IEEE F16/F32.
    static func rounded(_ integer: Int128, exponent: Int, output: Output) -> UInt32 {
        guard integer != 0 else { return 0 }
        let fraction = output.fraction, bias = output.bias
        let sign: UInt32 = integer < 0 ? (output == .f16 ? 0x8000 : 0x80000000) : 0
        let magnitude = integer.magnitude
        let highest = 127 - magnitude.leadingZeroBitCount + exponent
        var step = max(1 - bias - fraction, highest - fraction)
        let shift = step - exponent
        var q: UInt128
        if shift >= 128 { q = 0 }
        else if shift > 0 {
            q = magnitude >> shift
            let remainder = magnitude & ((UInt128(1) << shift) - 1)
            let midpoint = UInt128(1) << (shift - 1)
            if remainder > midpoint || (remainder == midpoint && q & 1 != 0) { q += 1 }
        } else { q = magnitude << (-shift) }
        guard q != 0 else { return sign }
        if 128 - q.leadingZeroBitCount > fraction + 1 { q >>= 1; step += 1 }
        let h = 127 - q.leadingZeroBitCount + step
        if h > bias {
            return sign | (output == .f16 ? 0x7C00 : 0x7F800000)
        }
        if h < 1 - bias { return sign | UInt32(q) }
        return sign | UInt32((h + bias) << fraction) | (UInt32(q) - UInt32(1 << fraction))
    }

    /// Compare positive integer*2^e with1 without constructing a huge shift.
    private static func compareOne(_ integer: UInt128, exponent: Int) -> Int {
        if integer == 0 { return -1 }
        let highest = 127 - integer.leadingZeroBitCount + exponent
        if highest != 0 { return highest < 0 ? -1 : 1 }
        return integer & (integer - 1) == 0 ? 0 : 1
    }
    static func inverseRoot(_ value: Float) throws -> Float {
        guard value > 0, value.isFinite else { throw Failure.nonfinite }
        let z = try term(value)
        func compare(_ bits: UInt32) throws -> Int {
            let v = try term(Float(bitPattern: bits))
            let product = v.coefficient.magnitude * v.coefficient.magnitude * z.coefficient.magnitude
            return compareOne(product, exponent: 2 * v.exponent + z.exponent)
        }
        var low: UInt32 = 0, high: UInt32 = 0x7F7FFFFF
        while low < high {
            let m = low + (high - low) / 2
            if try compare(m) < 0 { low = m + 1 } else { high = m }
        }
        if try compare(low) == 0 { return Float(bitPattern: low) }
        guard low > 0 else { throw Failure.shape }
        let a = try term(Float(bitPattern: low - 1)), b = try term(Float(bitPattern: low))
        let e = min(a.exponent, b.exponent)
        let sum = (a.coefficient << (a.exponent - e)) + (b.coefficient << (b.exponent - e))
        let product = sum.magnitude * sum.magnitude * z.coefficient.magnitude
        let side = compareOne(product, exponent: 2 * (e - 1) + z.exponent)
        return Float(bitPattern: side < 0 || (side == 0 && low & 1 == 0) ? low : low - 1)
    }
}
#endif
