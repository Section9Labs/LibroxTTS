#if os(macOS)
import Foundation

/// Offline CPU reference component only. No renderer/profile selects this.
/// Ordinary IEEE binary64 operations with one outward ULP at each boundary.
enum CertifiedReferenceSoftmax {
    enum Failure: Error { case domain, shape }
    struct Interval {
        let low: Double
        let high: Double
        init(_ low: Double, _ high: Double? = nil) {
            self.low = low; self.high = high ?? low
        }
        func adding(_ b: Self) -> Self {
            Self((low + b.low).nextDown, (high + b.high).nextUp)
        }
        func multiplying(_ b: Self) -> Self {
            if low >= 0, b.low >= 0 {
                return Self((low * b.low).nextDown, (high * b.high).nextUp)
            }
            if high <= 0, b.high <= 0 {
                return Self((high * b.high).nextDown, (low * b.low).nextUp)
            }
            if low >= 0, b.high <= 0 {
                return Self((high * b.low).nextDown, (low * b.high).nextUp)
            }
            if high <= 0, b.low >= 0 {
                return Self((low * b.high).nextDown, (high * b.low).nextUp)
            }
            let products = [low * b.low, low * b.high, high * b.low, high * b.high]
            return Self(products.min()!.nextDown, products.max()!.nextUp)
        }
        func positiveSum(_ b: Self) -> Self {
            Self(max(0, (low + b.low).nextDown), (high + b.high).nextUp)
        }
        func positiveDivision(_ b: Self) -> Self {
            Self(max(0, (low / b.high).nextDown), (high / b.low).nextUp)
        }
    }
    // Coefficients of P24, each enclosed by directed inflation of the integer
    // conversion and reciprocal. factorial24 fits UInt128 (<2^80).
    private static let coefficients: [Interval] = {
        var factorial: UInt128 = 1
        return (0...24).map { n in
            if n > 0 { factorial *= UInt128(n) }
            if n < 2 { return Interval(1) }
            let d = Double(factorial)
            return Interval((1 / d.nextUp).nextDown, (1 / d.nextDown).nextUp)
        }
    }()

    /// e^x for -256<=x<=0. r=x/256 is exact binary scaling. On -1<=r<=0,
    /// P24 Taylor error<=1/25!<2^-83, since the real exponential derivative<=1.
    /// Eight interval squarings enclose e^x. No vendor exponential is used.
    static func exponential(_ x: Interval) throws -> Interval {
        guard x.low.isFinite, x.high.isFinite, -256 <= x.low,
            x.low <= x.high, x.high <= 0 else { throw Failure.domain }
        if x.low == 0, x.high == 0 { return Interval(1) }
        let r = Interval(x.low / 256, x.high / 256)
        var p = coefficients[24]
        for n in stride(from: 23, through: 0, by: -1) {
            p = p.multiplying(r).adding(coefficients[n])
        }
        p = p.adding(Interval(-0x1p-83, 0x1p-83))
        guard p.low > 0, p.high.isFinite else { throw Failure.domain }
        for _ in 0..<8 { p = p.multiplying(p) }
        return p
    }

    /// Error-free TwoSum on exactly represented F32 operands. All nonzero
    /// quantities here are far above binary64 underflow. Clamp the upper bound
    /// by the known mathematical ordering a<=maximum.
    static func difference(_ a: Float, maximum: Float) -> Interval {
        if a == maximum { return Interval(0) }
        let x = Double(a), y = -Double(maximum)
        let sum = x + y
        let z = sum - x
        let error = (x - (sum - z)) + (y - z)
        if error == 0 { return Interval(sum) }
        return Interval(error < 0 ? sum.nextDown : sum, min(0, error > 0 ? sum.nextUp : sum))
    }

    struct Result {
        let values: [Float]?
        let unresolvedComponents: Int
    }
    /// Nil values mean this entire row needs the exact Decimal resolver.
    /// Returning a rounded approximation for an unresolved row is forbidden.
    static func probabilities(_ scores: [Float]) throws -> Result {
        guard (1...1536).contains(scores.count), scores.allSatisfy(\.isFinite),
            let maximum = scores.max() else { throw Failure.shape }
        var terms: [Interval] = []; terms.reserveCapacity(scores.count)
        var denominator = Interval(0)
        for value in scores {
            let delta = difference(value, maximum: maximum)
            let term = delta.high <= -200 ? Interval(0, 0x1p-200) : try exponential(delta)
            terms.append(term); denominator = denominator.positiveSum(term)
        }
        guard denominator.low > 0, denominator.high.isFinite else { throw Failure.domain }
        var output: [Float] = []; output.reserveCapacity(scores.count)
        var unresolved = 0
        for term in terms {
            let bounds = term.positiveDivision(denominator)
            let low = Float(bounds.low), high = Float(bounds.high)
            if low.bitPattern != high.bitPattern { unresolved += 1 }
            output.append(low)
        }
        return Result(values: unresolved == 0 ? output : nil, unresolvedComponents: unresolved)
    }
}
#endif
